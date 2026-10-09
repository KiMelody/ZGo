import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';

// --------------------------------------------------------------------------
// Insert formats (official renderer @313879525-313880700). The pickers below
// and the add-context panel share these so the wire text is generated in one
// place; every format is asserted verbatim in the unit tests.
// --------------------------------------------------------------------------

/// files → `[名称](./相对路径)` (official `r9e`): a directory gets a trailing
/// `/`, a relative path that does not start with `/`, `./`, `../`, `#` or a
/// `scheme:` gets a `./` prefix, and `\ [ ]` in the name are escaped.
String mentionFileMarkdown({
  required String name,
  required String relativePath,
  required bool isDirectory,
}) {
  var path = relativePath;
  if (isDirectory && !path.endsWith('/')) path = '$path/';
  final absolute =
      path.startsWith('/') ||
      path.startsWith('./') ||
      path.startsWith('../') ||
      path.startsWith('#') ||
      path.contains(':');
  if (!absolute) path = './$path';
  final escaped = name
      .replaceAll(r'\', r'\\')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]');
  return '[$escaped]($path)';
}

/// sessions → `#sess_<id>` (official `LQe` bare-token branch). The desktop's
/// send-side parser only accepts the `#sess_[a-zA-Z0-9._-]+` token, so the
/// raw session id must carry the `sess_` prefix (design Q2: the prefix
/// assumption is verified on-device).
String mentionSessionToken(String sessionId) => '#$sessionId';

/// skills → `$name` (official `oM`).
String mentionSkillToken(String name) => '\$$name';

/// subagents → `@name` (official `IQe`).
String mentionSubagentToken(String name) => '@$name';

/// Applies a picked mention: replaces the `@` trigger at [triggerEnd]-1 with
/// [insert] plus one trailing space.
String applyMentionInsert(String text, int triggerEnd, String insert) {
  final start = (triggerEnd - 1).clamp(0, text.length);
  return text.replaceRange(start, triggerEnd, '$insert ');
}

/// One selectable mention result; [insert] is the FULL text written into the
/// composer (already in the official wire format, no trailing space).
class MentionEntry {
  final String insert;
  final String title;
  final String? subtitle;
  final IconData icon;

  const MentionEntry({
    required this.insert,
    required this.title,
    this.subtitle,
    required this.icon,
  });
}

/// The `@` mention panel. Official `@` taxonomy is files/sessions (plus
/// plugins/whiteboards, which have no ZGo channel); skills live on `$` and
/// subagents were folded into the composer `/` capability list, so the panel
/// offers exactly these two categories.
Future<MentionEntry?> showMentionSheet(
  BuildContext context,
  ChatGateway gateway,
) {
  return showModalBottomSheet<MentionEntry>(
    context: context,
    useRootNavigator: false,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _MentionSheet(gateway: gateway),
  );
}

class _MentionSheet extends StatefulWidget {
  final ChatGateway gateway;

  const _MentionSheet({required this.gateway});

  @override
  State<_MentionSheet> createState() => _MentionSheetState();
}

class _MentionSheetState extends State<_MentionSheet> {
  /// The offered categories — files is dropped when its probe is negative.
  List<String> _categories = const ['files', 'sessions'];
  String? _category;
  String _query = '';
  List<Map<String, dynamic>> _files = const [];
  bool _loading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (_categories.contains('files')) unawaited(_probeFiles());
    if (_category == 'files') unawaited(_loadFiles());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// File-section reachability (task 2's probe): a negative verdict drops the
  /// category entirely — no channel, no section.
  Future<void> _probeFiles() async {
    bool ok;
    try {
      ok = await widget.gateway.workspaceFilesReachable();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _categories = ok ? const ['files', 'sessions'] : const ['sessions'];
      if (!_categories.contains(_category)) {
        _category = _categories.length == 1 ? _categories.single : null;
        if (_category == 'files') unawaited(_loadFiles());
      }
    });
  }

  Future<void> _loadFiles() async {
    setState(() => _loading = true);
    List<Map<String, dynamic>> files;
    try {
      files = await widget.gateway.searchWorkspaceFiles(_query, limit: 50);
    } catch (_) {
      files = const [];
    }
    if (!mounted) return;
    setState(() {
      _files = [...files]..sort(_byRelativePath);
      _loading = false;
    });
  }

  static int _byRelativePath(Map<String, dynamic> a, Map<String, dynamic> b) =>
      '${a['relativePath'] ?? ''}'.compareTo('${b['relativePath'] ?? ''}');

  void _onQueryChanged(String value) {
    setState(() => _query = value.trim());
    if (_category != 'files') return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), _loadFiles);
  }

  List<MentionEntry> get _entries {
    final q = _query.toLowerCase();
    switch (_category) {
      case 'files':
        return [
          for (final f in _files)
            if (q.isEmpty ||
                '${f['relativePath'] ?? ''}'.toLowerCase().contains(q) ||
                '${f['name'] ?? ''}'.toLowerCase().contains(q))
              MentionEntry(
                insert: mentionFileMarkdown(
                  name: '${f['name'] ?? ''}',
                  relativePath: '${f['relativePath'] ?? f['name'] ?? ''}',
                  isDirectory: f['type'] == 'directory',
                ),
                title: '${f['name'] ?? ''}',
                subtitle: '${f['relativePath'] ?? ''}',
                icon: f['type'] == 'directory'
                    ? Icons.folder_outlined
                    : Icons.description_outlined,
              ),
        ];
      case 'sessions':
        return [
          for (final sess in widget.gateway.mentionSessions())
            if (q.isEmpty || sess.title.toLowerCase().contains(q))
              MentionEntry(
                insert: mentionSessionToken(sess.id),
                title: sess.title,
                subtitle: sess.id,
                icon: Icons.chat_bubble_outline,
              ),
        ];
    }
    return const [];
  }

  Future<void> _enterCategory(String category) async {
    setState(() {
      _category = category;
      _query = '';
    });
    if (category == 'files') await _loadFiles();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  ZSpacing.screen, 0, ZSpacing.screen, 8),
              child: Row(
                children: [
                  if (_category != null)
                    IconButton(
                      icon: const Icon(Icons.arrow_back, size: 18),
                      onPressed: () =>
                          setState(() {
                            _category = null;
                            _query = '';
                          }),
                    ),
                  Expanded(
                    child: Text(
                      tr(context, _category == null
                          ? 'chat.mention.title'
                          : 'chat.mention.category.$_category'),
                      style: ZType.heading,
                    ),
                  ),
                ],
              ),
            ),
            if (_category == null)
              Expanded(
                child: _categories.isEmpty
                    ? Center(
                        child: Text(
                          tr(context, 'chat.mention.emptyResults'),
                          style: ZType.sub.copyWith(color: ZInk.faint(context)),
                        ),
                      )
                    : ListView(
                        children: [
                          for (final c in _categories)
                            ListTile(
                              leading: Icon(_categoryIcon(c)),
                              title: Text(
                                  tr(context, 'chat.mention.category.$c'),
                                  style: ZType.body),
                              subtitle: Text(
                                  tr(context,
                                      'chat.mention.category.$c.description'),
                                  style: ZType.caption.copyWith(
                                    color: ZInk.faint(context),
                                  )),
                              onTap: () => _enterCategory(c),
                            ),
                        ],
                      ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  autofocus: true,
                  onChanged: _onQueryChanged,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: tr(
                      context,
                      _category == 'files'
                          ? 'chat.mention.searchHint'
                          : 'chat.mention.sessions.searchHint',
                    ),
                    prefixIcon: const Icon(Icons.search, size: 18),
                  ),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : _entries.isEmpty
                        ? Center(
                            child: Text(
                              tr(context, _category == 'files'
                                  ? 'chat.mention.files.empty'
                                  : 'chat.mention.sessions.empty'),
                              style: ZType.sub.copyWith(
                                color: ZInk.faint(context),
                              ),
                            ))
                        : SingleChildScrollView(
                            child: Column(
                              children: [
                                for (final e in _entries.take(100))
                                  ListTile(
                                    leading: Icon(e.icon,
                                        size: 18, color: ZInk.muted(context)),
                                    title: Text(e.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: ZType.body),
                                    subtitle: (e.subtitle ?? '').isNotEmpty
                                        ? Text(e.subtitle!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: ZType.caption.copyWith(
                                              color: ZInk.faint(context),
                                            ))
                                        : null,
                                    dense: true,
                                    onTap: () => Navigator.pop(context, e),
                                  ),
                              ],
                            ),
                          ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  ZSpacing.screen, 4, ZSpacing.screen, 10),
              child: Text(tr(context, 'chat.mention.selectItem'),
                  style: ZType.caption.copyWith(color: ZInk.ghost(context))),
            ),
          ],
        ),
      ),
    );
  }

  IconData _categoryIcon(String c) => switch (c) {
        'files' => Icons.description_outlined,
        _ => Icons.chat_bubble_outline,
      };
}

// --------------------------------------------------------------------------
// Add-context panel (official ＋ / `chat.composer.actionMenu`, design D4).
// --------------------------------------------------------------------------

/// A page-level action the add-context panel hands back (附件/`@`/`$` are not
/// inserts — they open their own surfaces).
enum AddContextAction { attach, mention, skills }

/// Result of [showAddContextSheet]: either an [insert] string written into the
/// composer at the cursor, or an [action] the page dispatches.
class AddContextResult {
  final String? insert;
  final AddContextAction? action;

  const AddContextResult.insert(String text)
      : insert = text,
        action = null;
  const AddContextResult.action(AddContextAction value)
      : insert = null,
        action = value;
}

/// The composer's add-context panel: an 添加 section (附件 / 目标 in drafts /
/// 工作流), a 文件 section (task 2's workspace search), a 会话 section, and a
/// footer pairing the `@`/`$` shortcuts. The 插件 section is omitted — its
/// data source (`getPluginReferenceCatalog`) has no ZGo channel (documented
/// degradation).
Future<AddContextResult?> showAddContextSheet(
  BuildContext context, {
  required ChatGateway gateway,
  required bool isDraft,
  String? workflowCommand,
}) {
  return showModalBottomSheet<AddContextResult>(
    context: context,
    useRootNavigator: false,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AddContextSheet(
      gateway: gateway,
      isDraft: isDraft,
      workflowCommand: workflowCommand,
    ),
  );
}

class _AddContextSheet extends StatefulWidget {
  final ChatGateway gateway;
  final bool isDraft;
  final String? workflowCommand;

  const _AddContextSheet({
    required this.gateway,
    required this.isDraft,
    required this.workflowCommand,
  });

  @override
  State<_AddContextSheet> createState() => _AddContextSheetState();
}

class _AddContextSheetState extends State<_AddContextSheet> {
  /// null = probe pending (the 文件 row appears only on a positive verdict).
  bool? _filesReachable;
  String? _view; // null = home; 'files' / 'sessions'
  String _query = '';
  List<Map<String, dynamic>> _files = const [];
  bool _loading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    unawaited(_probeFiles());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _probeFiles() async {
    bool ok;
    try {
      ok = await widget.gateway.workspaceFilesReachable();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _filesReachable = ok);
  }

  Future<void> _loadFiles() async {
    setState(() => _loading = true);
    List<Map<String, dynamic>> files;
    try {
      files = await widget.gateway.searchWorkspaceFiles(_query, limit: 50);
    } catch (_) {
      files = const [];
    }
    if (!mounted) return;
    setState(() {
      _files = [...files]..sort(_byRelativePath);
      _loading = false;
    });
  }

  static int _byRelativePath(Map<String, dynamic> a, Map<String, dynamic> b) =>
      '${a['relativePath'] ?? ''}'.compareTo('${b['relativePath'] ?? ''}');

  void _pop(AddContextResult result) => Navigator.pop(context, result);

  void _enter(String view) {
    setState(() {
      _view = view;
      _query = '';
    });
    if (view == 'files') unawaited(_loadFiles());
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  ZSpacing.screen, 0, ZSpacing.screen, 8),
              child: Row(
                children: [
                  if (_view != null)
                    IconButton(
                      icon: const Icon(Icons.arrow_back, size: 18),
                      onPressed: () => setState(() {
                        _view = null;
                        _query = '';
                      }),
                    ),
                  Expanded(
                    child: Text(
                      tr(context, _view == null
                          ? 'chat.composer.actionMenu'
                          : _view == 'files'
                              ? 'chat.mention.files.title'
                              : 'chat.mention.sessions.title'),
                      style: ZType.heading,
                    ),
                  ),
                ],
              ),
            ),
            if (_view == null)
              Expanded(child: _buildHome(context))
            else
              Expanded(child: _buildPicker(context)),
            _buildFooter(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHome(BuildContext context) {
    return ListView(
      children: [
        _sectionLabel(context, 'chat.composer.addSection'),
        ListTile(
          dense: true,
          leading: const Icon(Icons.attach_file, size: 18),
          title: Text(tr(context, 'chat.composer.attachment'),
              style: ZType.body),
          onTap: () => _pop(const AddContextResult.action(
              AddContextAction.attach)),
        ),
        if (widget.isDraft)
          ListTile(
            dense: true,
            leading: const Icon(Icons.flag_outlined, size: 18),
            title: Text(tr(context, 'chat.goalBanner.label'), style: ZType.body),
            onTap: () => _pop(const AddContextResult.insert('/goal')),
          ),
        if (widget.workflowCommand != null)
          ListTile(
            dense: true,
            leading: const Icon(Icons.account_tree_outlined, size: 18),
            title: Text(tr(context, 'chat.composer.addWorkflow'),
                style: ZType.body),
            onTap: () => _pop(AddContextResult.insert(
                '/${widget.workflowCommand}')),
          ),
        if (_filesReachable == true) ...[
          _sectionLabel(context, 'chat.mention.files.title'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.description_outlined, size: 18),
            title: Text(tr(context, 'chat.mention.files.title'),
                style: ZType.body),
            onTap: () => _enter('files'),
          ),
        ],
        _sectionLabel(context, 'chat.mention.sessions.title'),
        ListTile(
          dense: true,
          leading: const Icon(Icons.chat_bubble_outline, size: 18),
          title: Text(tr(context, 'chat.mention.sessions.title'),
              style: ZType.body),
          onTap: () => _enter('sessions'),
        ),
        // 插件 section intentionally omitted: getPluginReferenceCatalog is an
        // agent-services channel ZGo does not speak (design D4 / PRD).
      ],
    );
  }

  Widget _buildPicker(BuildContext context) {
    final q = _query.toLowerCase();
    if (_view == 'files') {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: true,
              onChanged: (v) {
                setState(() => _query = v.trim());
                _debounce?.cancel();
                _debounce =
                    Timer(const Duration(milliseconds: 200), _loadFiles);
              },
              decoration: InputDecoration(
                isDense: true,
                hintText: tr(context, 'chat.mention.searchHint'),
                prefixIcon: const Icon(Icons.search, size: 18),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _files.isEmpty
                    ? Center(
                        child: Text(
                          tr(context, 'chat.mention.files.empty'),
                          style:
                              ZType.sub.copyWith(color: ZInk.faint(context)),
                        ),
                      )
                    : ListView(
                        children: [
                          for (final f in _files)
                            if (q.isEmpty ||
                                '${f['relativePath'] ?? ''}'
                                    .toLowerCase()
                                    .contains(q) ||
                                '${f['name'] ?? ''}'.toLowerCase().contains(q))
                              ListTile(
                                dense: true,
                                leading: Icon(
                                  f['type'] == 'directory'
                                      ? Icons.folder_outlined
                                      : Icons.description_outlined,
                                  size: 18,
                                ),
                                title: Text('${f['name'] ?? ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ZType.body),
                                subtitle: Text('${f['relativePath'] ?? ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ZType.caption
                                        .copyWith(color: ZInk.faint(context))),
                                onTap: () => _pop(AddContextResult.insert(
                                  mentionFileMarkdown(
                                    name: '${f['name'] ?? ''}',
                                    relativePath:
                                        '${f['relativePath'] ?? f['name'] ?? ''}',
                                    isDirectory: f['type'] == 'directory',
                                  ),
                                )),
                              ),
                        ],
                      ),
          ),
        ],
      );
    }
    // sessions
    final sessions = widget.gateway.mentionSessions();
    final filtered = [
      for (final s in sessions)
        if (q.isEmpty || s.title.toLowerCase().contains(q)) s,
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: true,
            onChanged: (v) => setState(() => _query = v.trim()),
            decoration: InputDecoration(
              isDense: true,
              hintText: tr(context, 'chat.mention.sessions.searchHint'),
              prefixIcon: const Icon(Icons.search, size: 18),
            ),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    tr(context, 'chat.mention.sessions.empty'),
                    style: ZType.sub.copyWith(color: ZInk.faint(context)),
                  ),
                )
              : ListView(
                  children: [
                    for (final s in filtered)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.chat_bubble_outline, size: 18),
                        title: Text(s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ZType.body),
                        subtitle: Text(s.id,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ZType.caption
                                .copyWith(color: ZInk.faint(context))),
                        onTap: () => _pop(
                            AddContextResult.insert(mentionSessionToken(s.id))),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, String key) => Padding(
        padding: const EdgeInsets.fromLTRB(ZSpacing.screen, 10, ZSpacing.screen,
            2),
        child: Text(
          tr(context, key),
          style: ZType.caption.copyWith(color: ZInk.muted(context)),
        ),
      );

  /// Footer: the official `@` / `$` shortcuts plus the context search hint.
  Widget _buildFooter(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          ZSpacing.screen, 6, ZSpacing.screen, 10),
      child: Row(
        children: [
          _ShortcutChip(
            token: '@',
            label: tr(context, 'chat.composer.contextShortcut'),
            onTap: () =>
                _pop(const AddContextResult.action(AddContextAction.mention)),
          ),
          const SizedBox(width: 8),
          _ShortcutChip(
            token: '\$',
            label: tr(context, 'chat.composer.skillShortcut'),
            onTap: () =>
                _pop(const AddContextResult.action(AddContextAction.skills)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr(context, 'chat.composer.contextSearchHint'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: ZType.caption.copyWith(color: ZInk.ghost(context)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShortcutChip extends StatelessWidget {
  final String token;
  final String label;
  final VoidCallback onTap;

  const _ShortcutChip({
    required this.token,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(ZRadius.field),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: ZInk.tile(context),
                borderRadius: BorderRadius.circular(ZRadius.field),
              ),
              child: Text(token,
                  style: ZType.caption.copyWith(
                    color: ZInk.soft(context),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
            ),
            const SizedBox(width: 4),
            Text(label,
                style: ZType.caption.copyWith(color: ZInk.soft(context))),
          ],
        ),
      ),
    );
  }
}
