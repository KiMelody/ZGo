import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/conversation.dart';
import '../protocol/file_service.dart';
import '../state/device_session.dart';
import '../state/task_directory.dart';
import 'slash_items.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// Which tab the search page opens on (design D6: the desktop sidebar's
/// Ctrl+K entry lands on actions, the mobile header button on all).
enum TaskSearchTab { all, actions, tasks, files }

/// Command-palette-style search over three sources (design D6): actions
/// (slash commands + skills, contains-matched, select opens a new chat
/// pre-filled), tasks (local filter over the merged task directory with
/// title matching), and files (probed workspace file
/// search; the tab hides when the desktop serves neither method, and the
/// all tab degrades with it). The official palette's static actions
/// (new task / open workspace / settings) are not adopted — ZGo has its
/// own navigation.
class TaskSearchPage extends StatefulWidget {
  final DeviceSession session;

  /// Where the page opens; defaults to the 全部 tab.
  final TaskSearchTab initialTab;

  /// Opens a task row's session. [workspace] is the resolved scope from
  /// the merged directory (null = ownership undeterminable — the caller
  /// refuses to open, same rule as the task list rows).
  final void Function(SessionEntry entry, Map<String, dynamic>? workspace)
      onOpenTask;

  /// Opens a new chat with the slash/skill entry pre-filled.
  final void Function(SlashItem item) onOpenCommand;

  const TaskSearchPage({
    super.key,
    required this.session,
    this.initialTab = TaskSearchTab.all,
    required this.onOpenTask,
    required this.onOpenCommand,
  });

  @override
  State<TaskSearchPage> createState() => _TaskSearchPageState();
}

class _TaskSearchPageState extends State<TaskSearchPage>
    with TickerProviderStateMixin {
  static const _sectionCap = 5;
  static const _taskCap = 50;

  late TabController _tabs;
  final _query = TextEditingController();

  /// Slash/skill entries (commands + skills), loaded once per open.
  List<SlashItem> _actions = const [];

  /// File-tab availability: null = probe in flight, true/false = verdict.
  /// False (and pending) removes the 文件 tab (and the all tab's file
  /// section) — the tab only appears on a positive probe verdict.
  bool? _filesReachable;

  List<WorkspaceFileEntry> _fileHits = const [];
  bool _filesLoading = false;
  Timer? _fileDebounce;
  Object? _fileError;

  @override
  void initState() {
    super.initState();
    // The files tab exists only after a positive reachability verdict
    // (design Q7: miss → the tab never renders) — the probe-pending state
    // already counts 3 so TabBar and the controller never disagree.
    _tabs = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab.index.clamp(0, 2),
    );
    _tabs.addListener(() => HapticFeedback.selectionClick());
    unawaited(_loadActions());
    unawaited(_probeFiles());
  }

  @override
  void dispose() {
    _fileDebounce?.cancel();
    _query.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadActions() async {
    List<SlashItem> items = const [];
    try {
      final prep = await widget.session.prepareWorkspace();
      List<SkillEntry> skills = const [];
      try {
        skills = await widget.session.skills();
      } catch (_) {}
      items = buildSlashItems(
        commands: prep.slashCommands,
        skills: skills,
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() => _actions = items);
  }

  Future<void> _probeFiles() async {
    final root = widget.session.workspacePath;
    bool reachable = false;
    if (root != null && root.isNotEmpty) {
      try {
        reachable =
            await widget.session.fileService.workspaceFilesReachable(root);
      } catch (_) {
        reachable = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _filesReachable = reachable;
      if (reachable) _growFilesTab();
    });
  }

  /// Rebuilds the tab controller with the files tab added once the probe
  /// answers reachable; the current index is preserved (a mid-probe user
  /// cannot sit past 任务, index 2).
  void _growFilesTab() {
    if (_tabs.length != 3) return;
    final index = _tabs.index;
    _tabs.dispose();
    _tabs = TabController(
      length: 4,
      vsync: this,
      initialIndex: index,
    );
    _tabs.addListener(() => HapticFeedback.selectionClick());
  }

  void _onQueryChanged(String value) {
    setState(() {});
    _fileDebounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _fileHits = const [];
        _filesLoading = false;
      });
      return;
    }
    _fileDebounce = Timer(const Duration(milliseconds: 250), _searchFiles);
  }

  Future<void> _searchFiles() async {
    final root = widget.session.workspacePath;
    final q = _query.text.trim();
    if (root == null || root.isEmpty || q.isEmpty) return;
    setState(() {
      _filesLoading = true;
      _fileError = null;
    });
    try {
      final hits = await widget.session.fileService.searchWorkspaceFiles(
        root,
        query: q,
      );
      if (!mounted) return;
      setState(() {
        _fileHits = hits;
        _filesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fileError = e;
        _fileHits = const [];
        _filesLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filesTab = _filesReachable == true;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: MaterialLocalizations.of(context)
                        .backButtonTooltip,
                    icon: const Icon(Icons.arrow_back, size: 20),
                    color: ZInk.muted(context),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _query,
                      autofocus: true,
                      onChanged: _onQueryChanged,
                      decoration: InputDecoration(
                        hintText: tr(context, 'search.hint'),
                        prefixIcon:
                            const Icon(Icons.search, size: 20),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            TabBar(
              // Keyed by the count: growing past the probe swaps the
              // controller, and an in-place TabBar update would read the
              // disposed controller's animation — remount instead.
              key: ValueKey<int>(_tabs.length),
              controller: _tabs,
              onTap: (_) => setState(() {}),
              tabs: [
                Tab(text: tr(context, 'search.tab.all')),
                Tab(text: tr(context, 'search.tab.actions')),
                Tab(text: tr(context, 'search.tab.tasks')),
                if (filesTab) Tab(text: tr(context, 'search.tab.files')),
              ],
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: Listenable.merge([widget.session]),
                builder: (context, _) {
                  final tasks = _filteredTasks();
                  return TabBarView(
                    key: ValueKey<int>(_tabs.length),
                    controller: _tabs,
                    children: [
                      _allView(tasks),
                      _actionsView(),
                      _tasksView(tasks),
                      if (filesTab) _filesView(),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ sources

  /// Task-directory filter (design D6): contains on the title, most
  /// recently active first.
  List<(SessionEntry, String?)> _filteredTasks() {
    final needle = _query.text.trim().toLowerCase();
    final entries = widget.session.taskDirectory.allEntries();
    final hits = needle.isEmpty
        ? entries
        : [
            for (final (e, key) in entries)
              if (e.title.toLowerCase().contains(needle)) (e, key),
          ];
    final sorted = [...hits]
      ..sort((a, b) => b.$1.lastActivityAt.compareTo(a.$1.lastActivityAt));
    return sorted.length > _taskCap ? sorted.sublist(0, _taskCap) : sorted;
  }

  List<SlashItem> _filteredActions() {
    final needle = _query.text.trim().toLowerCase();
    if (needle.isEmpty) return _actions;
    return [
      for (final c in _actions)
        if (c.name.toLowerCase().contains(needle) ||
            c.description.toLowerCase().contains(needle))
          c,
    ];
  }

  // -------------------------------------------------------------- views

  Widget _allView(List<(SessionEntry, String?)> tasks) {
    // Official palette sections: each source contributes a header + its
    // capped rows only when it has hits — an empty section renders nothing.
    final sections = <Widget>[];
    if (tasks.isNotEmpty) {
      sections
        ..add(_sectionHeader(tr(context, 'search.tab.tasks')))
        ..addAll(_taskRows(tasks.take(_sectionCap).toList()));
    }
    final actions = _filteredActions();
    if (actions.isNotEmpty) {
      sections
        ..add(_sectionHeader(tr(context, 'search.tab.actions')))
        ..addAll(_actionRows(actions.take(_sectionCap).toList()));
    }
    if (_filesReachable == true && _fileHits.isNotEmpty) {
      sections
        ..add(_sectionHeader(tr(context, 'search.tab.files')))
        ..addAll(_fileRows(_fileHits.take(_sectionCap).toList()));
    }
    if (sections.isEmpty) return _emptyNote(tr(context, 'search.empty'));
    return ListView(children: sections);
  }

  Widget _actionsView() {
    final filtered = _filteredActions();
    if (filtered.isEmpty) return _emptyNote(tr(context, 'search.empty'));
    return ListView(children: _actionRows(filtered));
  }

  Widget _tasksView(List<(SessionEntry, String?)> tasks) {
    if (tasks.isEmpty) {
      return _emptyNote(
          _query.text.trim().isEmpty
              ? tr(context, 'search.tasks.hint')
              : tr(context, 'search.tasks.empty'),
      );
    }
    return ListView(children: _taskRows(tasks));
  }

  Widget _filesView() {
    if (_query.text.trim().isEmpty) {
      return _emptyNote(tr(context, 'search.files.hint'));
    }
    if (_filesLoading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_fileError != null || _fileHits.isEmpty) {
      return _emptyNote(tr(context, 'search.empty'));
    }
    return ListView(children: _fileRows(_fileHits));
  }

  // --------------------------------------------------------------- rows

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          label,
          style: ZType.bodyStrong.copyWith(
            fontWeight: FontWeight.w500,
            color: ZInk.ghost(context),
          ),
        ),
      );

  Widget _emptyNote(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: ZType.body.copyWith(color: ZInk.faint(context)),
          ),
        ),
      );

  List<Widget> _actionRows(List<SlashItem> items) => [
        for (final item in items)
          ListTile(
            dense: true,
            leading: Icon(
              item.isSkill ? ZSymbols.extension : ZSymbols.terminal,
              size: 16,
              color: ZInk.iconNeutral(context),
            ),
            title: Text(
              item.isSkill ? '\$${item.name}' : '/${item.name}',
              style: ZType.body.copyWith(fontFamily: 'monospace'),
            ),
            subtitle: item.description.isEmpty
                ? null
                : Text(
                    item.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () {
              Navigator.of(context).pop();
              widget.onOpenCommand(item);
            },
          ),
      ];

  List<Widget> _taskRows(List<(SessionEntry, String?)> tasks) {
    final needle = _query.text.trim().toLowerCase();
    return [
      for (final (entry, key) in tasks)
        ListTile(
          dense: true,
          title: RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: ZType.body.copyWith(
                color: ZInk.solid(context),
                fontWeight: FontWeight.w500,
              ),
              children: highlightSpans(
                entry.title.trim().isEmpty
                    ? tr(context, 'tasks.untitled')
                    : entry.title,
                needle,
                highlightStyle: ZType.body.copyWith(
                  color: ZColors.sky400,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          subtitle: Text(
            _taskCaption(entry, key),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ZType.caption.copyWith(color: ZInk.ghost(context)),
          ),
          onTap: () {
            Navigator.of(context).pop();
            final ws = TaskDirectory.workspaceForKey(
              widget.session.workspaces,
              entry,
              key,
            );
            widget.onOpenTask(entry, ws);
          },
        ),
    ];
  }

  /// `工作区 · 相对时间` caption (design D6), resolved from the merged
  /// directory like the task list rows.
  String _taskCaption(SessionEntry entry, String? key) {
    final ws = TaskDirectory.workspaceForKey(
      widget.session.workspaces,
      entry,
      key,
    );
    return [
      if (ws != null) workspaceTitle(ws),
      relativeTimeShort(context, entry.lastActivityAt),
    ].join(' · ');
  }

  List<Widget> _fileRows(List<WorkspaceFileEntry> files) => [
        for (final f in files)
          ListTile(
            dense: true,
            leading: Icon(
              f.isDirectory
                  ? Icons.folder_outlined
                  : Icons.description_outlined,
              size: 16,
              color: ZInk.iconNeutral(context),
            ),
            title: Text(
              f.relativePath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.body.copyWith(fontFamily: 'monospace'),
            ),
            // Display-only for now (design D6): the official tap opens the
            // desktop editor — ZGo has no editor surface to hand off to.
            onTap: null,
          ),
      ];
}

/// Case-insensitive highlight of [needle] inside [text] as TextSpans; an
/// empty needle yields the plain text. Used by the tasks tab's title row
/// (design D6: 匹配段 TextSpan 着色).
List<InlineSpan> highlightSpans(
  String text,
  String needle, {
  required TextStyle highlightStyle,
}) {
  final base = TextSpan(text: text);
  if (needle.isEmpty) return [base];
  final lower = text.toLowerCase();
  final at = lower.indexOf(needle.toLowerCase());
  if (at == -1) return [base];
  return [
    if (at > 0) TextSpan(text: text.substring(0, at)),
    TextSpan(
      text: text.substring(at, at + needle.length),
      style: highlightStyle,
    ),
    if (at + needle.length < text.length)
      TextSpan(text: text.substring(at + needle.length)),
  ];
}
