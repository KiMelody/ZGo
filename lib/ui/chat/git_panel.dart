import 'dart:async';

import 'package:flutter/material.dart';

import '../../protocol/channel_client.dart';
import '../../protocol/git_service.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'chat_page.dart' show commandErrorCopy;
import 'diff_view.dart';

/// Workspace Git UI for the chat page: the status-panel 「Git 工具」 group
/// (design D2), the message-level change capsule (D3), the review panel
/// (D4) and the branch/commit/push write flows with their confirmation
/// dialogs (D5).
///
/// One [GitWorkspaceController] is owned by the chat page and shared by all
/// four surfaces, so a workspace read happens once and a successful write
/// refreshes every surface through a single notify. The controller is a thin
/// facade over the widget-free [GitPort]; every confirmation gate lives in
/// the UI layer (the write methods never render and are only reached after
/// the user confirms — tests lock "no confirmation, no call").

/// Resolves UI copy through the pure function family with the page locale.
String _loc(BuildContext context) =>
    UiSettingsProvider.of(context)?.locale ?? 'zh-CN';

/// Mutable shared state of one workspace's Git view.
class GitWorkspaceController extends ChangeNotifier {
  GitWorkspaceController(this.git, this.workspacePath);

  final GitPort git;
  final String workspacePath;

  GitRepositoryInfo? repo;

  /// All changed rows (both sections); the panel groups them locally.
  GitChanges changes = GitChanges.empty;
  GitBranchList branches = GitBranchList.empty;
  GitIdentity identity = const GitIdentity();

  bool loading = false;
  bool loaded = false;

  /// Set on [dispose]; in-flight reads must not notify a dead notifier.
  bool _disposed = false;

  /// A [reload] that arrived while one was in flight; replayed once it lands
  /// so a write's refresh is never silently dropped (P2-1).
  bool _reloadQueued = false;

  /// Raw error text of the last failed read; the UI maps it through
  /// [commandErrorCopy] before showing anything.
  Object? error;

  /// Set once the desktop rejected [generateCommitMessage] with its fixed
  /// "not available" string — the AI button hides permanently after that
  /// (design-inputs §1/§5; no capability probe needed).
  bool aiUnavailable = false;

  bool get available => workspacePath.isNotEmpty;

  /// Whether the workspace is a Git repository (verdict from
  /// `getRepositorySummary` / `getWorkspaceRepositoryInfo`).
  bool get isRepository => loaded && repo?.isNotRepository == false;

  /// Whether Git itself is available on the desktop (same summary verdict).
  /// A missing field from an older build is treated as available.
  bool get isGitAvailable => repo?.isGitAvailable != false;

  /// Client-side `+N -M` over every changed row (the official UI sums the
  /// rows too, @315028049).
  GitChangeStats get workspaceStats => GitChangeStats.of(changes.entries);

  int get dirtyFileCount => changes.entries.length;

  /// Loads once; later calls are no-ops until [reload].
  Future<void> ensureLoaded() async {
    if (loaded || loading || !available) return;
    await reload();
  }

  /// Re-reads the workspace Git state (design decision 4: both the panel
  /// open and manual refresh run this same chain — `refresh()` to ask the
  /// desktop for fresh state, then read it back).
  Future<void> reload() async {
    if (!available) return;
    if (loading) {
      _reloadQueued = true;
      return;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final info = await git.repositoryInfo(workspacePath);
      repo = info;
      loaded = true;
      if (info.isNotRepository) {
        changes = GitChanges.empty;
        branches = GitBranchList.empty;
        identity = const GitIdentity();
      } else {
        // Best-effort aggregate refresh; older desktops answer missing →
        // false and the reads below still work.
        await git.refresh(workspacePath);
        changes = await git.getChanges(workspacePath);
        branches = await git.getLocalBranches(workspacePath);
        identity = await git.getIdentity(workspacePath);
      }
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
      if (_reloadQueued && !_disposed) {
        _reloadQueued = false;
        await reload();
      }
    }
  }

  /// Reads one file's unified diff (`getDiff`).
  Future<GitDiff> diffFor(GitChangeEntry entry) => git.getDiff(
        workspacePath,
        entry.path,
        sourceId: entry.isStaged ? 'staged' : 'unstaged',
      );

  Future<GitBranchMutationResult> switchBranch(String targetBranchName) async {
    final res = await git.switchBranch(workspacePath, targetBranchName);
    if (res.ok) await reload();
    return res;
  }

  Future<void> stage(List<String> paths) async {
    await git.stagePaths(workspacePath, paths);
    await reload();
  }

  Future<void> unstage(List<String> paths) async {
    await git.unstagePaths(workspacePath, paths);
    await reload();
  }

  Future<GitCommitResult> commit({
    required String message,
    required bool includeUnstaged,
  }) async {
    final res = await git.commit(
      workspacePath,
      message: message,
      stagedOnly: !includeUnstaged,
    );
    await reload();
    return res;
  }

  Future<GitPushResult> push() async {
    final res = await git.push(workspacePath);
    await reload();
    return res;
  }

  Future<String> generateMessage({bool includeUnstaged = true}) async {
    try {
      return await git.generateCommitMessage(
        workspacePath,
        includeUnstaged: includeUnstaged,
      );
    } on ChannelRpcError catch (e) {
      if (e.message.contains('not available')) {
        aiUnavailable = true;
        if (!_disposed) notifyListeners();
      }
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// `{additions, deletions, files}` → [GitChangeStats], or null when the map
/// carries no positive/usable counts. The turn header's `fileChanges` is the
/// ZGo carrier of the official `activeTaskChangeSummary` prop.
GitChangeStats? statsFromFileChanges(Object? changes) {
  if (changes is! Map) return null;
  final added = (changes['additions'] as num?)?.toInt() ?? 0;
  final removed = (changes['deletions'] as num?)?.toInt() ?? 0;
  final files = (changes['files'] as num?)?.toInt() ?? 0;
  if (added == 0 && removed == 0 && files == 0) return null;
  return GitChangeStats(fileCount: files, added: added, removed: removed);
}

// ---------------------------------------------------------------------------
// D2 — status panel Git group
// ---------------------------------------------------------------------------

/// The status-strip 「Git 工具」group. Hidden until the workspace verdict is
/// in; hidden entirely on a non-repository workspace (graceful degradation,
/// design D2). Rows: 更改 (+N -M → review panel), 分支 (switcher),
/// 提交或推送 (menu → commit / push).
class GitStatusGroup extends StatefulWidget {
  final GitWorkspaceController controller;

  const GitStatusGroup({super.key, required this.controller});

  @override
  State<GitStatusGroup> createState() => _GitStatusGroupState();
}

class _GitStatusGroupState extends State<GitStatusGroup> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        if (c.error != null) {
          final copy = commandErrorCopy('${c.error}', _loc(context)) ??
              '${c.error}';
          return _groupFrame(
            context,
            children: [
              _groupHeader(context, c),
              _GitStatusRow(
                icon: Icons.error_outline,
                label: tr(context, 'git.error.title'),
                trailing: Text(
                  copy,
                  style: ZType.caption.copyWith(color: ZInk.dangerTone(context)),
                ),
                onTap: c.loading ? null : () => c.reload(),
              ),
            ],
          );
        }
        if (!c.isGitAvailable) {
          return _groupFrame(
            context,
            children: [
              _groupHeader(context, c),
              _GitStatusRow(
                icon: Icons.info_outline,
                label: tr(context, 'git.empty.gitUnavailableTitle'),
                trailing: Text(
                  tr(context, 'git.empty.gitUnavailableDescription'),
                  style: ZType.caption.copyWith(color: ZInk.muted(context)),
                ),
                onTap: c.loading ? null : () => c.reload(),
              ),
            ],
          );
        }
        if (!c.isRepository) return const SizedBox.shrink();
        final stats = c.workspaceStats;
        final branch = c.repo?.branchName ?? c.branches.currentBranchName;
        return _groupFrame(
          context,
          children: [
            _groupHeader(context, c),
            _GitStatusRow(
              icon: Icons.edit_note_outlined,
              label: tr(context, 'git.changes.label'),
              trailing: _statsSpan(context, stats),
              onTap: () => showGitReviewPanel(context, c),
            ),
            _GitStatusRow(
              icon: Icons.alt_route_outlined,
              label: branch == null || branch.isEmpty
                  ? tr(context, 'git.status.noBranch')
                  : branch,
              trailing: c.dirtyFileCount > 0
                  ? Text(
                      trP(context, 'git.branchSwitcher.currentDirty',
                          ['${c.dirtyFileCount}']),
                      style:
                          ZType.caption.copyWith(color: ZInk.muted(context)),
                    )
                  : (stats.fileCount == 0
                      ? Text(
                          tr(context, 'chat.statusPanel.clean'),
                          style: ZType.caption
                              .copyWith(color: ZInk.muted(context)),
                        )
                      : null),
              onTap: () => showGitBranchSwitcher(context, c),
            ),
            _GitStatusRow(
              icon: Icons.upload_outlined,
              label: tr(context, 'git.actionMenu.trigger'),
              trailing: Icon(Icons.keyboard_arrow_right,
                  size: 16, color: ZInk.ghost(context)),
              onTap: () => _showCommitPushMenu(context, c),
            ),
          ],
        );
      },
    );
  }

  /// The rounded group frame shared by the normal and failure states.
  Widget _groupFrame(BuildContext context, {required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.field),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _groupHeader(BuildContext context, GitWorkspaceController c) {
    return Row(
      children: [
        Icon(Icons.account_tree_outlined,
            size: 14, color: ZInk.muted(context)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            tr(context, 'chat.statusPanel.environment'),
            style: ZType.caption.copyWith(color: ZInk.muted(context)),
          ),
        ),
        SizedBox(
          width: zTouchWidth,
          height: zTouchHeight,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 16,
            tooltip: tr(context, 'git.action.refresh'),
            icon: c.loading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : Icon(Icons.refresh, color: ZInk.muted(context)),
            onPressed: c.loading ? null : () => c.reload(),
          ),
        ),
      ],
    );
  }

  Widget _statsSpan(BuildContext context, GitChangeStats stats) {
    if (stats.fileCount == 0 && stats.added == 0 && stats.removed == 0) {
      return Text(
        tr(context, 'chat.statusPanel.clean'),
        style: ZType.caption.copyWith(color: ZInk.muted(context)),
      );
    }
    return _StatsText(
      stats: stats,
      style: ZType.caption.copyWith(color: ZInk.soft(context)),
    );
  }
}

/// One tappable status row (icon + label + trailing), 44px min height.
class _GitStatusRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _GitStatusRow({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: zTouchHeight),
        child: Row(
          children: [
            Icon(icon, size: 16, color: ZInk.soft(context)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ZType.sub.copyWith(color: ZInk.solid(context)),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// `+N -M` colored span pair.
class _StatsText extends StatelessWidget {
  final GitChangeStats stats;
  final TextStyle style;

  const _StatsText({required this.stats, required this.style});

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          if (stats.added > 0)
            TextSpan(
              text: '+${stats.added}',
              style: TextStyle(color: ZInk.successTone(context)),
            ),
          if (stats.added > 0 && stats.removed > 0) const TextSpan(text: ' '),
          if (stats.removed > 0)
            TextSpan(
              text: '-${stats.removed}',
              style: TextStyle(color: ZInk.dangerTone(context)),
            ),
        ],
      ),
    );
  }
}

Future<void> _showCommitPushMenu(
  BuildContext context,
  GitWorkspaceController controller,
) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: false,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.check_circle_outline),
            title: Text(tr(sheetCtx, 'git.actionMenu.commitDialog.action.commit')),
            onTap: () => Navigator.pop(sheetCtx, 'commit'),
          ),
          ListTile(
            leading: const Icon(Icons.upload_outlined),
            title: Text(tr(sheetCtx, 'git.actionMenu.pushDialog.confirm')),
            onTap: () => Navigator.pop(sheetCtx, 'push'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  if (action == 'commit') {
    await showGitCommitDialog(context, controller);
  } else {
    await showGitPushConfirm(context, controller);
  }
}

// ---------------------------------------------------------------------------
// D3 — message-level change capsule
// ---------------------------------------------------------------------------

/// The message-attached 「更改 +N -M」pill (official 05c). Data priority
/// (design decision 3): the workspace-level git summary
/// (`gitWorktreeChangeSummary`, from the shared controller) wins over the
/// turn-level `activeTaskChangeSummary` (the turn header's `fileChanges`).
/// Neither → nothing renders. Tapping opens the review panel.
class ChangeCapsule extends StatelessWidget {
  final GitChangeStats? gitWorktree;
  final GitChangeStats? activeTask;
  final VoidCallback onOpen;

  const ChangeCapsule({
    super.key,
    this.gitWorktree,
    this.activeTask,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final stats = gitWorktree ?? activeTask;
    if (stats == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(ZRadius.field),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: ZInk.tile(context),
              borderRadius: BorderRadius.circular(ZRadius.field),
              border: Border.all(color: ZInk.hairline(context)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit_note_outlined,
                    size: 13, color: ZInk.muted(context)),
                const SizedBox(width: 4),
                Text(
                  tr(context, 'git.changes.label'),
                  style: ZType.caption.copyWith(color: ZInk.soft(context)),
                ),
                const SizedBox(width: 6),
                _StatsText(
                  stats: stats,
                  style: ZType.caption.copyWith(color: ZInk.muted(context)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// D4 — review panel (full-height sheet)
// ---------------------------------------------------------------------------

/// Opens the review panel for [controller] as a full-height modal sheet (the
/// mobile form of the official side panel; design D4 "全屏 sheet 按形态").
Future<void> showGitReviewPanel(
  BuildContext context,
  GitWorkspaceController controller,
) {
  unawaited(controller.reload());
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: false,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetCtx) => SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.92,
        child: GitReviewPanel(controller: controller),
      ),
    ),
  );
}

/// The review panel body: source switch (未暂存/已暂存), grouped file rows
/// with `+N -M` and stage/unstage, and the selected file's diff
/// (unified → [DiffView]).
class GitReviewPanel extends StatefulWidget {
  final GitWorkspaceController controller;

  const GitReviewPanel({super.key, required this.controller});

  @override
  State<GitReviewPanel> createState() => _GitReviewPanelState();
}

class _GitReviewPanelState extends State<GitReviewPanel> {
  String _source = 'unstaged';
  GitChangeEntry? _selected;
  GitDiff? _diff;
  bool _diffLoading = false;
  Object? _diffError;

  Future<void> _openDiff(GitChangeEntry entry) async {
    setState(() {
      _selected = entry;
      _diff = null;
      _diffError = null;
      _diffLoading = true;
    });
    try {
      final diff = await widget.controller.diffFor(entry);
      if (!mounted || _selected != entry) return;
      setState(() {
        _diff = diff;
        _diffLoading = false;
      });
    } catch (e) {
      if (!mounted || _selected != entry) return;
      setState(() {
        _diffError = e;
        _diffLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, c),
            const Divider(height: 1),
            Expanded(
              child: _selected != null
                  ? _diffBody(context)
                  : _listBody(context, c),
            ),
          ],
        );
      },
    );
  }

  Widget _header(BuildContext context, GitWorkspaceController c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: Row(
        children: [
          if (_selected != null)
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 20),
              tooltip: tr(context, 'common.cancel'),
              onPressed: () => setState(() => _selected = null),
            ),
          Expanded(
            child: Text(
              _selected?.displayPath ?? tr(context, 'sidePane.review'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.heading.copyWith(color: ZInk.solid(context)),
            ),
          ),
          IconButton(
            tooltip: tr(context, 'git.action.refresh'),
            icon: c.loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Icon(Icons.refresh, size: 20),
            onPressed: c.loading ? null : () => c.reload(),
          ),
        ],
      ),
    );
  }

  Widget _listBody(BuildContext context, GitWorkspaceController c) {
    if (c.error != null) {
      return _message(
        context,
        icon: Icons.error_outline,
        title: tr(context, 'git.error.title'),
        body: trP(
          context,
          'git.error.description',
          [commandErrorCopy('${c.error}', _loc(context)) ?? '${c.error}'],
        ),
        danger: true,
      );
    }
    if (!c.isGitAvailable) {
      return _message(
        context,
        icon: Icons.info_outline,
        title: tr(context, 'git.empty.gitUnavailableTitle'),
        body: tr(context, 'git.empty.gitUnavailableDescription'),
      );
    }
    if (!c.isRepository) {
      return _message(
        context,
        icon: Icons.folder_off_outlined,
        title: tr(context, 'git.empty.notRepositoryTitle'),
        body: tr(context, 'git.empty.notRepositoryDescription'),
      );
    }
    if (c.loading && !c.loaded) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          tr(context, 'git.loading.description'),
          style: ZType.sub.copyWith(color: ZInk.muted(context)),
        ),
      );
    }
    final sections = _sections(c);
    if (sections.every((s) => s.entries.isEmpty)) {
      return _message(
        context,
        icon: Icons.check_circle_outline,
        title: tr(context, 'git.empty.title'),
        body: '',
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _sourceSwitch(context),
        for (final section in sections)
          if (section.entries.isNotEmpty) ...[
            _sectionLabel(context, section.key, section.entries.length),
            for (final entry in section.entries) _fileRow(context, entry),
          ],
      ],
    );
  }

  List<({String key, List<GitChangeEntry> entries})> _sections(
    GitWorkspaceController c,
  ) {
    final all = c.changes.entries;
    if (_source == 'staged') {
      return [
        (
          key: 'git.section.staged',
          entries: all.where((e) => e.isStaged).toList(),
        ),
      ];
    }
    return [
      (
        key: 'git.section.unstaged',
        entries:
            all.where((e) => !e.isStaged && !e.isUntracked).toList(),
      ),
      (
        key: 'git.section.untracked',
        entries: all.where((e) => e.isUntracked).toList(),
      ),
    ];
  }

  Widget _sourceSwitch(BuildContext context) {
    Widget chip(String value, String key) {
      final selected = _source == value;
      return ChoiceChip(
        label: Text(tr(context, key)),
        selected: selected,
        onSelected: (_) => setState(() {
          _source = value;
          _selected = null;
        }),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        spacing: 8,
        children: [
          chip('unstaged', 'git.source.unstaged'),
          chip('staged', 'git.source.staged'),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String key, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Text(
            tr(context, key),
            style: ZType.caption.copyWith(
              color: ZInk.muted(context),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: ZType.caption.copyWith(color: ZInk.faint(context)),
          ),
        ],
      ),
    );
  }

  Widget _fileRow(BuildContext context, GitChangeEntry entry) {
    final kindKey = _kindKey(entry.kind);
    return InkWell(
      onTap: () => _openDiff(entry),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.displayPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZType.sub.copyWith(color: ZInk.solid(context)),
                  ),
                  if (kindKey != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        tr(context, kindKey),
                        style: ZType.caption
                            .copyWith(color: ZInk.faint(context)),
                      ),
                    ),
                ],
              ),
            ),
            _StatsText(
              stats: GitChangeStats(
                fileCount: 1,
                added: entry.added,
                removed: entry.removed,
              ),
              style: ZType.caption.copyWith(color: ZInk.muted(context)),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: () => _toggleStage(entry),
              child: Text(
                tr(
                  context,
                  entry.isStaged
                      ? 'git.action.unstage'
                      : 'git.action.stage',
                ),
                style: ZType.caption,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleStage(GitChangeEntry entry) async {
    final c = widget.controller;
    try {
      if (entry.isStaged) {
        await c.unstage([entry.path]);
      } else {
        await c.stage([entry.path]);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${commandErrorCopy('$e', _loc(context)) ?? e}')),
        );
      }
    }
  }

  Widget _diffBody(BuildContext context) {
    if (_diffLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_diffError != null) {
      return _message(
        context,
        icon: Icons.error_outline,
        title: tr(context, 'git.error.title'),
        body: trP(
          context,
          'git.error.description',
          [
            commandErrorCopy('$_diffError', _loc(context)) ?? '$_diffError',
          ],
        ),
        danger: true,
      );
    }
    final diff = _diff;
    if (diff == null) return const SizedBox.shrink();
    // `truncated` still carries the rows the desktop managed to read, so it
    // renders like a patch with a trailing notice instead of the empty state.
    final truncated = diff.availability == 'truncated';
    if (!diff.isPatch && !truncated) {
      return _message(
        context,
        icon: Icons.info_outline,
        title: tr(context, 'git.diff.${diff.availability}Title'),
        body: diff.availability == 'unavailable'
            ? tr(context, 'git.diff.unavailableDescription')
            : '',
      );
    }
    final entry = _selected!;
    final view = SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: DiffView(
        diff: unifiedDiffToDiffData(
          diff.patch ?? '',
          filePath: entry.displayPath,
          additions: entry.added,
          deletions: entry.removed,
        ),
      ),
    );
    if (!truncated) return view;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: view),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: ZInk.tile(context),
          child: Text(
            tr(context, 'git.diff.truncatedTitle'),
            style: ZType.caption.copyWith(color: ZInk.muted(context)),
          ),
        ),
      ],
    );
  }

  Widget _message(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String body,
    bool danger = false,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 28,
                color: danger
                    ? ZInk.dangerTone(context)
                    : ZInk.faint(context)),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: ZType.body.copyWith(
                color: danger ? ZInk.dangerTone(context) : ZInk.soft(context),
              ),
            ),
            if (body.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  body,
                  textAlign: TextAlign.center,
                  style: ZType.caption.copyWith(color: ZInk.muted(context)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String? _kindKey(String kind) => switch (kind) {
      'modified' => 'git.kind.modified',
      'added' => 'git.kind.added',
      'deleted' => 'git.kind.deleted',
      'renamed' => 'git.kind.renamed',
      'conflicted' => 'git.kind.conflicted',
      _ => null,
    };

// ---------------------------------------------------------------------------
// D5 — write flows (all gated by a confirmation dialog)
// ---------------------------------------------------------------------------

/// Branch switcher: list local branches → pick a non-current one → confirm
/// (target name + dirty warning) → `switchBranch`. A structured `ok:false`
/// answer opens the issue dialog; nothing is called before the confirm.
Future<void> showGitBranchSwitcher(
  BuildContext context,
  GitWorkspaceController controller,
) async {
  unawaited(controller.reload());
  final target = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: false,
    showDragHandle: true,
    builder: (sheetCtx) {
      final branches = controller.branches.branches;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Text(
                    tr(sheetCtx, 'git.branchSwitcher.title'),
                    style: ZType.heading.copyWith(color: ZInk.solid(sheetCtx)),
                  ),
                ],
              ),
            ),
            if (branches.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr(sheetCtx, 'git.branchSwitcher.empty'),
                  style: ZType.sub.copyWith(color: ZInk.muted(sheetCtx)),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final b in branches)
                      ListTile(
                        leading: Icon(
                          b.isCurrent
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          size: 18,
                          color: b.isCurrent
                              ? ZColors.sky500
                              : ZInk.faint(sheetCtx),
                        ),
                        title: Text(b.name, style: ZType.body),
                        subtitle: b.upstreamName == null
                            ? null
                            : Text(b.upstreamName!,
                                style: ZType.caption
                                    .copyWith(color: ZInk.muted(sheetCtx))),
                        enabled: !b.isCurrent,
                        onTap: b.isCurrent
                            ? null
                            : () => Navigator.pop(sheetCtx, b.name),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
  if (!context.mounted || target == null) return;
  final confirmed = await _confirmBranchSwitch(context, controller, target);
  if (confirmed != true || !context.mounted) return;
  try {
    final res = await controller.switchBranch(target);
    if (!context.mounted) return;
    if (!res.ok) {
      await showGitBranchIssues(context, res.issues);
    }
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${commandErrorCopy('$e', _loc(context)) ?? e}')),
    );
  }
}

/// The switch confirmation gate itself — returns true only on 切换.
Future<bool?> _confirmBranchSwitch(
  BuildContext context,
  GitWorkspaceController controller,
  String target,
) {
  final dirty = controller.dirtyFileCount;
  return showDialog<bool>(
    context: context,
    useRootNavigator: false,
    builder: (dialogCtx) => AlertDialog(
      title: Text(trP(dialogCtx, 'git.branchSwitcher.confirmTitle', [target])),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr(dialogCtx, 'git.branchSwitcher.confirmBody'),
            style: ZType.body.copyWith(color: ZInk.soft(dialogCtx)),
          ),
          if (dirty > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                trP(dialogCtx, 'git.branchSwitcher.currentDirty', ['$dirty']),
                style: ZType.sub.copyWith(color: ZInk.dangerTone(dialogCtx)),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: Text(tr(dialogCtx, 'common.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: Text(tr(dialogCtx, 'git.branchSwitcher.switch')),
        ),
      ],
    ),
  );
}

/// Human copy for the eight structured switch issues.
Future<void> showGitBranchIssues(
  BuildContext context,
  List<GitBranchIssue> issues,
) {
  if (issues.isEmpty) return Future.value();
  return showDialog<void>(
    context: context,
    useRootNavigator: false,
    builder: (dialogCtx) => AlertDialog(
      title: Text(tr(dialogCtx, 'git.branchSwitcher.issueTitle')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final issue in issues)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                _issueCopy(dialogCtx, issue),
                style: ZType.sub.copyWith(color: ZInk.soft(dialogCtx)),
              ),
            ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx),
          child: Text(tr(dialogCtx, 'common.close')),
        ),
      ],
    ),
  );
}

/// Pure mapping of one issue code to human copy (paths appended when the
/// wire carries them).
String _issueCopy(BuildContext context, GitBranchIssue issue) {
  final paths = issue.paths.take(5).join(', ');
  return switch (issue.code) {
    GitBranchIssueCode.trackedOverwrite =>
      trP(context, 'git.branchSwitcher.issue.trackedOverwrite', [paths]),
    GitBranchIssueCode.untrackedOverwrite =>
      trP(context, 'git.branchSwitcher.issue.untrackedOverwrite', [paths]),
    GitBranchIssueCode.branchAlreadyExists =>
      tr(context, 'git.branchSwitcher.issue.branchAlreadyExists'),
    GitBranchIssueCode.targetBranchNotFound =>
      tr(context, 'git.branchSwitcher.issue.targetBranchNotFound'),
    GitBranchIssueCode.branchInOtherWorktree =>
      tr(context, 'git.branchSwitcher.issue.branchInOtherWorktree'),
    GitBranchIssueCode.conflictsPresent =>
      tr(context, 'git.branchSwitcher.issue.conflictsPresent'),
    GitBranchIssueCode.operationInProgress =>
      tr(context, 'git.branchSwitcher.issue.operationInProgress'),
    GitBranchIssueCode.unknown =>
      issue.message?.isNotEmpty == true
          ? issue.message!
          : tr(context, 'git.branchSwitcher.issue.unknown'),
  };
}

/// Commit dialog: message input, include-unstaged switch, optional AI
/// generate (hidden once the desktop reports it unavailable),
/// identityMissing blocker, and 提交 / 提交并推送 actions.
Future<void> showGitCommitDialog(
  BuildContext context,
  GitWorkspaceController controller,
) async {
  unawaited(controller.reload());
  await showDialog<void>(
    context: context,
    useRootNavigator: false,
    builder: (dialogCtx) => _GitCommitDialog(controller: controller),
  );
}

class _GitCommitDialog extends StatefulWidget {
  final GitWorkspaceController controller;

  const _GitCommitDialog({required this.controller});

  @override
  State<_GitCommitDialog> createState() => _GitCommitDialogState();
}

class _GitCommitDialogState extends State<_GitCommitDialog> {
  final _message = TextEditingController();
  bool _includeUnstaged = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  GitWorkspaceController get _c => widget.controller;

  bool get _identityMissing => _c.identity.isMissing;

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final msg = await _c.generateMessage(includeUnstaged: _includeUnstaged);
      if (mounted) _message.text = msg;
    } on ChannelRpcError {
      if (mounted) {
        setState(() => _error = tr(context, 'git.actionMenu.commitDialog.error.generateFailed'));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '${commandErrorCopy('$e', _loc(context)) ?? e}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit({required bool andPush}) async {
    if (_identityMissing) return;
    var message = _message.text.trim();
    if (message.isEmpty) {
      if (_c.aiUnavailable) {
        setState(() => _error =
            tr(context, 'git.actionMenu.commitDialog.error.messageRequired'));
        return;
      }
      // Try to generate one; fall back to the message-required copy.
      try {
        message = (await _c.generateMessage(includeUnstaged: _includeUnstaged))
            .trim();
      } catch (_) {
        if (mounted) {
          setState(() => _error = tr(context,
              'git.actionMenu.commitDialog.error.messageRequired'));
        }
        return;
      }
      if (message.isEmpty) {
        if (mounted) {
          setState(() => _error = tr(context,
              'git.actionMenu.commitDialog.error.messageRequired'));
        }
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _c.commit(message: message, includeUnstaged: _includeUnstaged);
      if (!mounted) return;
      if (andPush) {
        try {
          await _c.push();
        } catch (e) {
          if (!mounted) return;
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr(context,
                  'git.actionMenu.commitDialog.error.pushAfterCommitFailed')),
            ),
          );
          return;
        }
      }
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr(
            context,
            andPush
                ? 'git.actionMenu.commitDialog.toast.committedPushed'
                : 'git.actionMenu.commitDialog.toast.committed',
          )),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = trP(
          context,
          'git.actionMenu.commitDialog.error.requestFailed',
          ['${commandErrorCopy('$e', _loc(context)) ?? e}'],
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final branch = _c.repo?.branchName ?? _c.branches.currentBranchName;
        return AlertDialog(
          title: Text(tr(context, 'git.actionMenu.commitDialog.title')),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (branch != null && branch.isNotEmpty)
                  Text(
                    trP(context, 'git.actionMenu.commitDialog.currentBranch',
                        [branch]),
                    style: ZType.caption.copyWith(color: ZInk.muted(context)),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 8),
                  child: Text(
                    trP(
                      context,
                      'git.actionMenu.commitDialog.changedFiles',
                      ['${_c.dirtyFileCount}'],
                    ),
                    style: ZType.caption.copyWith(color: ZInk.muted(context)),
                  ),
                ),
                if (_identityMissing)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      tr(context, 'git.actionMenu.commitDialog.identityMissing'),
                      style:
                          ZType.sub.copyWith(color: ZInk.dangerTone(context)),
                    ),
                  ),
                TextField(
                  controller: _message,
                  maxLines: 4,
                  minLines: 2,
                  enabled: !_busy,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText:
                        tr(context, 'git.actionMenu.commitDialog.placeholder'),
                  ),
                ),
                const SizedBox(height: 8),
                if (!_c.aiUnavailable)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _busy ? null : _generate,
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: Text(
                        tr(
                          context,
                          _message.text.trim().isEmpty
                              ? 'git.actionMenu.commitDialog.generate'
                              : 'git.actionMenu.commitDialog.regenerate',
                        ),
                        style: ZType.sub,
                      ),
                    ),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _includeUnstaged,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _includeUnstaged = v),
                  title: Text(
                    tr(context,
                        'git.actionMenu.commitDialog.includeUnstaged'),
                    style: ZType.sub,
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _error!,
                      style:
                          ZType.sub.copyWith(color: ZInk.dangerTone(context)),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: Text(tr(context, 'common.cancel')),
            ),
            TextButton(
              onPressed: _busy || _identityMissing
                  ? null
                  : () => _submit(andPush: false),
              child: Text(
                tr(context, 'git.actionMenu.commitDialog.action.commit'),
              ),
            ),
            FilledButton(
              onPressed: _busy || _identityMissing
                  ? null
                  : () => _submit(andPush: true),
              child: Text(
                tr(context,
                    'git.actionMenu.commitDialog.action.commitAndPush'),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Push confirmation: 推送更改 with branch/remote rows; confirm → `push`.
Future<void> showGitPushConfirm(
  BuildContext context,
  GitWorkspaceController controller,
) async {
  unawaited(controller.reload());
  final branch = controller.repo?.branchName ?? controller.branches.currentBranchName;
  final detached = controller.repo?.isDetached == true ||
      controller.branches.isDetached;
  final tracking = controller.repo?.trackingBranchName ??
      controller.branches.branches
          .where((b) => b.isCurrent)
          .map((b) => b.upstreamName)
          .firstWhere((u) => u != null, orElse: () => null);
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: false,
    builder: (dialogCtx) => AlertDialog(
      title: Text(tr(dialogCtx, 'git.actionMenu.pushDialog.title')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (branch != null && branch.isNotEmpty)
            Text(
              trP(dialogCtx, 'git.actionMenu.pushDialog.branch', [branch]),
              style: ZType.sub.copyWith(color: ZInk.solid(dialogCtx)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              tr(
                dialogCtx,
                tracking == null
                    ? 'git.actionMenu.pushDialog.untracked'
                    : 'git.actionMenu.pushDialog.tracked',
              ),
              style: ZType.caption.copyWith(color: ZInk.muted(dialogCtx)),
            ),
          ),
          if (detached)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                tr(dialogCtx, 'git.actionMenu.pushDialog.error.detached'),
                style: ZType.sub.copyWith(color: ZInk.dangerTone(dialogCtx)),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: Text(tr(dialogCtx, 'common.cancel')),
        ),
        if (!detached)
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(tr(dialogCtx, 'git.actionMenu.pushDialog.confirm')),
          ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final res = await controller.push();
    if (!context.mounted) return;
    final target = res.trackingBranchName ?? res.branchName ?? branch ?? '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          trP(context, 'git.actionMenu.pushDialog.toast.pushed', [target]),
        ),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${commandErrorCopy('$e', _loc(context)) ?? e}')),
    );
  }
}
