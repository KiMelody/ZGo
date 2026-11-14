import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/channel_client.dart';
import '../protocol/conversation.dart';
import '../protocol/project_resolver.dart';
import '../protocol/task_groups.dart';
import '../protocol/window_controller.dart';
import '../state/device_session.dart';
import '../state/device_store.dart';
import '../state/task_directory.dart';
import 'automations_page.dart';
import 'chat/chat_page.dart';
import 'chat/copy_mappings.dart';
import 'desktop_settings_page.dart';
import 'device_usage_page.dart';
import 'model_providers_page.dart';
import 'new_task_defaults_page.dart';
import 'off_peak_page.dart';
import 'phase_pill.dart';
import 'remote_page.dart';
import 'task_search_page.dart';
import 'theme.dart';
import 'ui_settings.dart';
import 'widgets/device_name.dart';
import 'widgets/sheet_scaffold.dart';
import 'widgets/swipe_actions.dart';
import 'widgets/task_branch_chip.dart';

/// Activity window of the dual-tier task order (2026-10-31): a card or row
/// counts as ACTIVE while its most recent activity lies closer to `now` than
/// this window; everything else is IDLE.
///
/// 60 s carries two reasons:
/// - It covers the agent's thinking gaps: a turn that is still in flight must
///   not drop out of the active tier between two output frames.
/// - It matches the 「刚刚」 window of [relativeTimeShort] (the label switches
///   to `N分` at `diff.inMinutes >= 1`), so the order flip and the visible
///   label flip happen at the same moment.
///
/// Crossing the window demotes on the NEXT rebuild — the page runs no 60 s
/// ticker (its own cadence is the ~30 s overview timer), so the demotion
/// rides the next build; no timer is added.
@visibleForTesting
const Duration activeOrderWindow = Duration(seconds: 60);

/// Whether an epoch-millisecond activity stamp is inside [activeOrderWindow]
/// at the [now] snapshot. A null key (workspace without a directory) is never
/// active.
@visibleForTesting
bool isActiveForOrder(int? lastActivityAt, DateTime now) =>
    lastActivityAt != null &&
    now.millisecondsSinceEpoch - lastActivityAt <
        activeOrderWindow.inMilliseconds;

/// Card comparator of the activity card order: the active tier (see
/// [activeOrderWindow]) first, by [workspaceTitle] codepoint order with the
/// workspace key as tiebreak — the millisecond activity key does NOT order
/// the front tier, so concurrent streaming cards cannot swap places frame by
/// frame. Idle cards follow by key descending (the pre-10-31 recency order;
/// their key no longer changes), null keys last. Idle and null ties break on
/// the title then the key, exactly as before, so the order is total.
///
/// [fallbackActivityA]/[fallbackActivityB] are the PERSISTED activity keys
/// (design 11-01 §4), used for the idle order while a card has no live rows
/// yet (cold start: its sidecar sessions-index has not delivered). They never
/// join the active tier — the 60 s window only accepts live keys, so a
/// restored key can only stabilize the idle layer.
@visibleForTesting
int compareWorkspaceCardsByActivity(
  Map<String, dynamic> a,
  int? activityA,
  Map<String, dynamic> b,
  int? activityB,
  DateTime now, {
  int? fallbackActivityA,
  int? fallbackActivityB,
}) {
  final activeA = isActiveForOrder(activityA, now);
  final activeB = isActiveForOrder(activityB, now);
  if (activeA != activeB) return activeA ? -1 : 1;
  if (!activeA) {
    final keyA = activityA ?? fallbackActivityA;
    final keyB = activityB ?? fallbackActivityB;
    if (keyA != keyB) {
      if (keyA == null) return 1;
      if (keyB == null) return -1;
      return keyB.compareTo(keyA);
    }
  }
  final byTitle = workspaceTitle(a).compareTo(workspaceTitle(b));
  if (byTitle != 0) return byTitle;
  return (workspaceKeyOf(a) ?? '').compareTo(workspaceKeyOf(b) ?? '');
}

/// Row comparator of the 更新时间 order. With [stabilizeActive] the rows are
/// two-tiered like the cards: rows active within [activeOrderWindow] sort
/// first by [SessionEntry.title] codepoint order with
/// [SessionEntry.sessionId] as tiebreak (empty/equal titles still get a total
/// order — Dart's sort is not stable, a missing tiebreak would be a fresh
/// swap source); idle rows follow by `lastActivityAt` descending, then title,
/// then session id. Without [stabilizeActive] this is the plain recency
/// comparator, so timeline buckets and archive rows keep their pre-10-31
/// order.
@visibleForTesting
int compareSessionEntriesByUpdated(
  SessionEntry a,
  SessionEntry b, {
  required DateTime now,
  bool stabilizeActive = false,
}) {
  final byActivity = b.lastActivityAt.compareTo(a.lastActivityAt);
  if (!stabilizeActive) return byActivity;
  final activeA = isActiveForOrder(a.lastActivityAt, now);
  final activeB = isActiveForOrder(b.lastActivityAt, now);
  if (activeA != activeB) return activeA ? -1 : 1;
  final byTitle = a.title.compareTo(b.title);
  if (activeA) {
    if (byTitle != 0) return byTitle;
    return a.sessionId.compareTo(b.sessionId);
  }
  if (byActivity != 0) return byActivity;
  if (byTitle != 0) return byTitle;
  return a.sessionId.compareTo(b.sessionId);
}

/// Native task list of one device (mobile layout): a connection
/// banner, the "workspaces and tasks" header with stats, and one card per
/// workspace whose rows are the live sessions. Tapping a task opens the
/// NATIVE chat page (no WebView suspend); the WebView stays available from
/// the overflow menu as a fallback.
class TaskListPage extends StatefulWidget {
  final DeviceStore store;
  final DeviceSessionHub hub;
  final Device device;
  final ThemeController? theme;

  /// Test seam: overrides `hub.sessionOf(device.id)` when set.
  @visibleForTesting
  final DeviceSession? sessionOverride;

  /// Test / screenshot seam: pre-select a task in the desktop right pane.
  @visibleForTesting
  final String? initialPaneSessionId;
  @visibleForTesting
  final String? initialPaneTitle;

  /// Task-overview refresh cadence while this page is up (Addendum 3: a
  /// non-active workspace's new chats only arrive via the relay overview —
  /// the desktop push stalls in the background). Tests inject a short one.
  @visibleForTesting
  final Duration overviewInterval;

  const TaskListPage({
    super.key,
    required this.store,
    required this.hub,
    required this.device,
    this.theme,
    this.sessionOverride,
    this.initialPaneSessionId,
    this.initialPaneTitle,
    this.overviewInterval = const Duration(seconds: 30),
  });

  @override
  State<TaskListPage> createState() => _TaskListPageState();
}

class _TaskListPageState extends State<TaskListPage>
    with WidgetsBindingObserver {
  /// Periodic [DeviceSession.refreshTaskOverview] timer; armed while the
  /// page is up, dropped on app pause and dispose (quota-watch cadence
  /// pattern from main.dart).
  Timer? _overviewTimer;
  /// Per-workspace expand overrides, both directions (web model):
  /// absent = default target state — only the ACTIVE workspace (the one
  /// owning the device's live session) is expanded; every other card starts
  /// collapsed. Overrides survive until 收起全部 clears them.
  final Map<String, bool> _expandOverrides = {};

  /// 整理任务 state: grouping (workspace cards / timeline buckets)
  /// and ordering (updated = lastActivityAt, created = createdAt).
  String _groupBy = 'workspace';
  String _sortBy = 'updated';

  /// Card-to-card ordering: `activity` is the default dual-tier order (active
  /// cards by title, idle cards by recency — see [_orderedWorkspaces]),
  /// `nameAsc` / `nameDesc` sort by [workspaceTitle] codepoint order (en/
  /// numbers as usual, CJK by Unicode codepoint — no intl collation).
  String _cardSort = 'activity';

  /// Desktop sidebar 归档 filter: shows only archived task rows (the web
  /// sidebar carries the same entry; empty when nothing is archived).
  bool _showArchived = false;

  /// Grouped task view of the current session (3.17.1 direct read): the
  /// resolver caches 30 s, so the page re-asks after [_groupedViewTtl].
  /// Null/empty keeps the flat timeline (R4 silent degrade).
  GroupedTaskView? _groupedView;
  DeviceSession? _groupedViewSession;
  DateTime? _groupedViewLoadedAt;

  /// Page-level counterpart of the task-group resolver's 30 s cache: a
  /// panel open after this window re-pulls (group writes have no push
  /// surface).
  static const _groupedViewTtl = Duration(seconds: 30);

  /// Per-task token-usage futures (3.12.3): one RPC per task per reload
  /// window ([_reloadTasks] clears the map, so a refresh re-issues the
  /// query); a miss completes null and the sheet hides the row (R4).
  final Map<String, Future<TaskTokenUsage?>> _tokenUsage = {};

  /// Organize preferences persist across restarts (the mobile
  /// home stores them in localStorage
  /// `zcode-web-remote-control-mobile-task-home-preferences`, same default).
  static const _organizePrefsKey = 'zgo_task_organize_v1';

  @override
  void initState() {
    super.initState();
    _paneSessionId = widget.initialPaneSessionId;
    _paneTitle = widget.initialPaneTitle;
    _loadOrganizePrefs();
    WidgetsBinding.instance.addObserver(this);
    _startOverviewCadence(refreshNow: true);
  }

  /// App lifecycle (quota-watch pattern): doze stalls the RPCs anyway, so
  /// pausing drops the cadence and a resume refreshes at once instead of
  /// waiting out the next periodic tick.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startOverviewCadence(refreshNow: true);
    } else if (state == AppLifecycleState.paused) {
      _overviewTimer?.cancel();
      _overviewTimer = null;
    }
  }

  /// (Re)arms the periodic task-overview refresh; [refreshNow] also pulls
  /// once immediately (page entry, app resume). The refresh is best-effort
  /// and silent (DeviceSession.refreshTaskOverview) — no spinner, no error
  /// UI: the relay overview usually updates via push anyway.
  void _startOverviewCadence({bool refreshNow = false}) {
    _overviewTimer?.cancel();
    _overviewTimer = Timer.periodic(widget.overviewInterval, (_) {
      unawaited(_pullOverview());
    });
    if (refreshNow) unawaited(_pullOverview());
  }

  /// One cadence pull plus the「最后同步」stamp. [refreshTaskOverview] keeps
  /// its own RPC errors (old rows survive), so the stamp marks the moment the
  /// round finished — it proves the cadence is alive, not that every leg
  /// reached the desktop.
  Future<void> _pullOverview() async {
    final session = _session;
    if (session == null) return;
    await session.refreshTaskOverview();
    if (!mounted) return;
    setState(() => _lastSyncAt = clock.now());
  }

  /// `hh:mm` of a sync stamp — the 「最后同步」 line only needs the wall clock;
  /// the relative-time family lives in `ui_settings.dart` and is not
  /// borrowed here (i18n spec §4).
  static String _clockLabel(DateTime at) {
    final local = at.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  void dispose() {
    _overviewTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadOrganizePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_organizePrefsKey);
    if (raw == null || !mounted) return;
    try {
      final saved = jsonDecode(raw);
      if (saved is! Map) return;
      setState(() {
        if (saved['groupBy'] == 'workspace' || saved['groupBy'] == 'timeline') {
          _groupBy = saved['groupBy'];
        }
        if (saved['sortBy'] == 'created' || saved['sortBy'] == 'updated') {
          _sortBy = saved['sortBy'];
        }
        if (saved['cardSort'] == 'activity' ||
            saved['cardSort'] == 'nameAsc' ||
            saved['cardSort'] == 'nameDesc') {
          _cardSort = saved['cardSort'];
        }
      });
    } catch (_) {}
  }

  Future<void> _saveOrganizePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _organizePrefsKey,
      jsonEncode({
        'groupBy': _groupBy,
        'sortBy': _sortBy,
        'cardSort': _cardSort,
      }),
    );
  }

  /// Dual-pane desktop selection (≥768px): the task opened in the right
  /// pane instead of a pushed route.
  String? _paneSessionId;
  String? _paneTitle;
  String? _paneInitialComposerText;
  bool _panePinned = false;

  /// The workspace a draft pane was opened in (captured when the pane is
  /// opened, not read live): the chat page uses it to re-point the bridge
  /// before the first send when a reconnect moved the connection elsewhere.
  String? _paneDraftWorkspacePath;

  /// True while a [DeviceSession.reloadTasks] RPC is in flight — the list
  /// is about to be replaced, so the list surfaces go pointer-dead for the
  /// round-trip (no stale-row taps mid-reshuffle; page-level, not per row).
  bool _reloading = false;

  /// True while the native link is being suspended for the WebView handover
  /// (B-01): all four entry points funnel through [_openRemote], which shows
  /// the wait and refuses a second tap.
  bool _handoverBusy = false;

  /// When the last silent overview pull finished (B-02): the header shows it
  /// as 「最后同步 hh:mm」 so an unchanged list still proves the cadence is
  /// alive. `refreshTaskOverview` absorbs RPC errors internally, so this is
  /// the last *attempt* — never a claim that every leg succeeded.
  DateTime? _lastSyncAt;

  /// Layout breakpoint: Tailwind md — single column below, dual ≥768.
  static const double kDualPaneBreakpoint = 768;

  /// Sidebar width (`--workspace-sidebar-panel-width`).
  static const double kSidebarWidth = 264;

  DeviceSession? get _session =>
      widget.sessionOverride ?? widget.hub.sessionOf(widget.device.id);

  bool _isWorkspaceActive(DeviceSession session, Map<String, dynamic> ws) =>
      identical(session.activeWorkspace, ws) ||
      workspaceKeyOf(ws) == workspaceKeyOf(session.activeWorkspace ?? const {});

  /// Whether a NON-active workspace card's rows are still loading, so the
  /// empty-state copy would be a lie (design 11-01 §3). Two sources:
  /// - the workspace's sidecar sessions-index is subscribed but its first
  ///   snapshot has not landed (`false` in [DeviceSession.sidecarReadiness]);
  /// - the session has not landed its first relay overview yet (cold start
  ///   between the bootstrap workspaces and the first task pull) — an
  ///   absent readiness key then means "not loaded", not "no tasks".
  /// An absent key after the overview landed = relay-only rows are the whole
  /// truth, so the empty-state copy is correct.
  bool _cardRowsPending(DeviceSession session, String? dirKey) {
    if (dirKey == null) return false;
    final readiness = session.sidecarReadiness[dirKey];
    if (readiness != null) return !readiness;
    return session.status == DeviceStatus.connected &&
        !session.taskOverviewLoaded;
  }

  /// Whether opening a task/draft must re-point the bridge first. A cold
  /// runtime failure means the previous open failed: even the active
  /// workspace needs a successful re-open to clear the banner and rebuild
  /// its live index (the chat subscription alone only warms the runtime).
  bool _needsWorkspaceOpen(DeviceSession session, Map<String, dynamic> ws) =>
      !_isWorkspaceActive(session, ws) ||
      session.lastWorkspaceOpenFailure is WorkspaceOpenRuntimeNotRunning;

  /// 3.16.2 conversation workspaces (desktop "New task" drafts,
  /// `.zcode/workspace/draft-*`) own no card: the desktop hides them from
  /// its workspace list (`Bbt` default) and their rows display under the
  /// default group through the session's key aliases (design 10-21 A2a).
  /// Live 3.16.2 frames carry no `workspacePurpose` for drafts, so the
  /// shared predicate also matches the path convention.
  static bool _isConversationWorkspace(Map<String, dynamic> ws) =>
      isConversationWorkspace(ws);

  /// Shared expand state for the mobile card and the desktop sidebar folder:
  /// manual override wins, otherwise the active workspace is expanded.
  bool _isWorkspaceExpanded(String key, {required bool isActive}) =>
      _expandOverrides[key] ?? isActive;

  /// Shared header tap: two-way toggle (aria-expanded flips both
  /// ways). The mobile home EXPANDS ONLY (switching workspaces
  /// happens when opening a task — workspace-bridge-open rides the taskId);
  /// the desktop sidebar still switches on tap ([openIfInactive]).
  void _toggleWorkspace(
    DeviceSession session,
    Map<String, dynamic> ws, {
    bool openIfInactive = true,
  }) {
    final isActive = _isWorkspaceActive(session, ws);
    final key = workspaceKeyOf(ws) ?? workspaceTitle(ws);
    if (!isActive && openIfInactive) session.openWorkspace(ws);
    HapticFeedback.lightImpact();
    setState(
      () => _expandOverrides[key] = !_isWorkspaceExpanded(
        key,
        isActive: isActive,
      ),
    );
  }

  /// 收起全部工作区: one-way collapse of every workspace (the
  /// label and icon stay constant; tapping it again just re-collapses).
  void _collapseAllWorkspaces(DeviceSession? session) {
    final workspaces = session?.workspaces ?? const <Map<String, dynamic>>[];
    setState(() {
      for (final ws in workspaces) {
        _expandOverrides[workspaceKeyOf(ws) ?? workspaceTitle(ws)] = false;
      }
    });
  }

  /// 整理任务 ordering: 更新时间 = lastActivityAt (device default),
  /// 创建时间 = createdAt.
  ///
  /// [stabilizeActive] opts the container into the dual-tier activity order
  /// (10-31): rows active within [activeOrderWindow] sort by title (codepoint
  /// order, session id tiebreak) so several streaming rows cannot trade
  /// places on every output frame; idle rows keep the recency order. Off by
  /// default — the timeline buckets and the archive rows keep their pre-10-31
  /// order, only the card containers (mobile card, desktop sidebar folder)
  /// opt in.
  List<SessionEntry> _sortedEntries(
    List<SessionEntry> entries, {
    bool stabilizeActive = false,
  }) {
    if (_sortBy == 'created') {
      return [...entries]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    // 更新时间 (device default): recency by last activity. The merged
    // directory's source order is the relay overview's and appends
    // live-only rows at the tail, so the default must sort actively too.
    // One clock snapshot per sort: the comparator must not re-read the clock
    // mid-sort or tier membership could drift inside one comparison.
    final now = clock.now();
    return [...entries]
      ..sort((a, b) => compareSessionEntriesByUpdated(
            a,
            b,
            now: now,
            stabilizeActive: stabilizeActive,
          ));
  }

  /// Workspace cards ordered by [_cardSort]: the dual-tier activity order by
  /// default (10-31), or the workspace title in codepoint order (A→Z / Z→A
  /// over en, numbers and CJK).
  ///
  /// Activity order uses the SAME key the card chip prints:
  /// `max(lastActivityAt)` over the workspace's non-archived directory rows
  /// (default [TaskDirectory.entriesFor] scope, no `includeArchived`). Wire
  /// entries and synthesized completion entries share this key.
  ///
  /// The order is two-tiered. A card whose key lies inside
  /// [activeOrderWindow] is ACTIVE: the front tier sorts by title codepoint
  /// order (workspace key tiebreak), NOT by the millisecond key, so two live
  /// streaming cards can no longer trade places on every output frame. The
  /// remaining IDLE cards sort behind by key descending — the pre-10-31
  /// recency order, naturally stable now that their keys stop moving. A new
  /// activity event (distance to now ≈ 0) promotes a card into the front tier
  /// on the very next rebuild; crossing the window demotes it on the next
  /// rebuild as well.
  ///
  /// Conversation workspaces own no card (see [_isConversationWorkspace]),
  /// so the gate lives here instead of repeating at each call site. A null
  /// activity key — no workspace key, or an empty non-archived directory (no
  /// tasks at all, or archived only) — is never active and sorts last among
  /// the idle cards. Ties, including null-null, break on the title and then
  /// on the key so the order is total: Dart's sort is not stable, never rely
  /// on the incoming list order. The title modes break title ties on the key
  /// for the same reason; nameDesc is the exact reverse of nameAsc.
  List<Map<String, dynamic>> _orderedWorkspaces(DeviceSession session) {
    if (_cardSort != 'activity') {
      final workspaces = <Map<String, dynamic>>[
        for (final ws in session.workspaces)
          if (!_isConversationWorkspace(ws)) ws,
      ];
      workspaces.sort((a, b) {
        final byTitle = workspaceTitle(a).compareTo(workspaceTitle(b));
        if (byTitle != 0) return byTitle;
        return (workspaceKeyOf(a) ?? '').compareTo(workspaceKeyOf(b) ?? '');
      });
      return _cardSort == 'nameDesc'
          ? workspaces.reversed.toList()
          : workspaces;
    }

    // One clock snapshot per sort: the comparator must not re-read the clock
    // mid-sort or a card's tier could drift inside one comparison.
    final now = clock.now();

    int? activityOf(Map<String, dynamic> ws) {
      final dirKey = workspaceKeyOf(ws);
      if (dirKey == null) return null;
      int? newest;
      for (final (entry, _) in session.taskDirectory.entriesFor(dirKey)) {
        if (newest == null || entry.lastActivityAt > newest) {
          newest = entry.lastActivityAt;
        }
      }
      return newest;
    }

    // Persisted activity fallback (design 11-01 §4): a cold-start card
    // whose sidecar sessions-index has not delivered yet keeps its previous
    // idle position instead of sinking to the bottom and jumping back up.
    int? persistedActivityOf(Map<String, dynamic> ws) {
      final dirKey = workspaceKeyOf(ws);
      if (dirKey == null) return null;
      return session.persistedWorkspaceActivity(dirKey);
    }

    final ordered = <(Map<String, dynamic>, int?, int?)>[
      for (final ws in session.workspaces)
        if (!_isConversationWorkspace(ws))
          (ws, activityOf(ws), persistedActivityOf(ws)),
    ];
    ordered.sort((a, b) {
      final (wsA, activityA, persistedA) = a;
      final (wsB, activityB, persistedB) = b;
      return compareWorkspaceCardsByActivity(
        wsA,
        activityA,
        wsB,
        activityB,
        now,
        fallbackActivityA: persistedA,
        fallbackActivityB: persistedB,
      );
    });
    return [for (final (ws, _, _) in ordered) ws];
  }

  // ------------------------------------------------- merged task data source
  //
  // One merged directory (see [TaskDirectory]): the relay overview carries
  // every workspace's tasks; the active workspace's live sessions-index
  // overrides it per task id. The page filters archived rows; notification
  // consumers keep them observable.

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= kDualPaneBreakpoint) {
          return _buildDualPane(context);
        }
        return _buildMobile(context);
      },
    );
  }

  Widget _buildMobile(BuildContext context) {
    final session = _session;
    final online =
        session != null &&
        session.status == DeviceStatus.connected &&
        !session.kicked &&
        (session.error?.isEmpty ?? true) &&
        session.lastWorkspaceOpenFailure == null;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr(context, 'tasks.banner.onlineTitle'),
                style: ZType.heading,
              ),
              Text(
                online
                    ? tr(context, 'tasks.banner.onlineSubtitle')
                    : deviceDisplayName(context, widget.device.label),
                style: ZType.sub.copyWith(
                  color:
                      online ? ZInk.pillSuccessBg(context) : ZInk.faint(context),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (widget.theme != null)
            IconButton(
              tooltip: tr(context, 'settings.theme'),
              icon: Icon(switch (widget.theme!.mode) {
                ThemeMode.dark => Icons.palette_outlined,
                ThemeMode.light => Icons.palette_outlined,
                _ => Icons.palette_outlined,
              }, size: 20),
              onPressed: widget.theme!.cycle,
            ),
          _overflowMenu(),
        ],
      ),
      body: _listBody(context),
    );
  }

  /// Desktop layout (≥768): IDE-style sidebar (新建/搜索/项目树)
  /// + 1px divider + rounded chat pane — not a shrunk mobile card list.
  Widget _buildDualPane(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark
          ? ZColors.darkBackground
          : ZColors.lightBackground,
      // Immersive cutout handling: SafeArea lives inside each column so the
      // sidebar color block and the divider extend behind the cutout / status
      // strip (no Scaffold-background color seam) while content still clears
      // the insets. left/right are explicitly interleaved false so each column
      // pads only its own screen edge — the pane stays flush against the
      // divider even when the far screen edge carries a cutout inset, and
      // vice versa.
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: kSidebarWidth,
            child: ColoredBox(
              color: isDark ? ZColors.darkSidebar : ZColors.lightSidebar,
              child: SafeArea(
                left: true,
                top: true,
                bottom: true,
                right: false,
                child: _desktopSidebar(context),
              ),
            ),
          ),
          Container(width: 1, color: const Color(0xFF333333)),
          Expanded(
            child: SafeArea(
              left: false,
              top: true,
              bottom: true,
              right: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: isDark
                        ? ZColors.darkBackground
                        : ZColors.lightBackground,
                    borderRadius: BorderRadius.circular(ZRadius.tile),
                    border: Border.all(color: ZInk.hairline(context)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(ZRadius.tile),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 320),
                      child: _chatPane(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// IDE sidebar: nav actions → projects tree → device footer.
  Widget _desktopSidebar(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.hub,
      builder: (context, _) {
        final session = _session;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    icon: const Icon(Icons.arrow_back, size: 18),
                    color: ZInk.muted(context),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text(
                      deviceDisplayName(context, widget.device.label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ZType.body.copyWith(
                        fontWeight: FontWeight.w600,
                        color: ZInk.solid(context),
                      ),
                    ),
                  ),
                  _overflowMenu(),
                ],
              ),
            ),
            _sidebarNavItem(
              context,
              icon: Icons.add,
              label: tr(context, 'tasks.sidebar.new'),
              shortcut: 'Ctrl+N',
              onTap: () => _startNewTask(),
            ),
            _sidebarNavItem(
              context,
              icon: Icons.search,
              label: tr(context, 'tasks.search'),
              shortcut: 'Ctrl+K',
              // D6: the command-search sheet retired — the sidebar entry
              // opens the unified search page on the actions tab.
              onTap: () => _openTaskSearch(TaskSearchTab.actions),
            ),
            _sidebarNavItem(
              context,
              icon: Icons.extension_outlined,
              label: tr(context, 'tasks.sidebar.plugins'),
              shortcut: '',
              onTap: () => _openPluginMarketplaceHint(),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr(context, 'tasks.projects'),
                      style: ZType.sub.copyWith(
                        fontWeight: FontWeight.w600,
                        color: ZInk.faint(context),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: tr(context, 'tasks.collapseAll'),
                    icon: const Icon(Icons.keyboard_double_arrow_up, size: 16),
                    color: ZInk.muted(context),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _collapseAllWorkspaces(_session),
                  ),
                  IconButton(
                    tooltip: tr(context, 'tasks.sidebar.filterSort'),
                    icon: const Icon(Icons.filter_list, size: 16),
                    color: ZInk.muted(context),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _showTidyPanel(context),
                  ),
                  IconButton(
                    tooltip: tr(context, 'tasks.sidebar.archive'),
                    icon: Icon(
                      _showArchived
                          ? Icons.inventory_2_outlined
                          : Icons.inventory_outlined,
                      size: 16,
                    ),
                    color: _showArchived ? ZColors.sky500 : ZInk.muted(context),
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        setState(() => _showArchived = !_showArchived),
                  ),
                ],
              ),
            ),
            // Same replace-window discipline as the mobile list: the sidebar
            // tree goes pointer-dead (with the same 2dp bar) while a reload
            // is in flight.
            if (_reloading) const _ReloadBar(),
            Expanded(
              child: session == null || session.workspaces.isEmpty
                  ? _fallback(context, session)
                  // Same replace-window discipline as the mobile list: the
                  // sidebar tree goes pointer-dead while a reload is in
                  // flight.
                  : IgnorePointer(
                      ignoring: _reloading,
                      child: ListView(
                        padding: zScreenPadding(context,
                            top: 0, bottom: 16, horizontal: 6),
                        children: [
                          ..._desktopPinned(context, session),
                          for (final ws in _orderedWorkspaces(session))
                            _desktopWorkspaceFolder(context, session, ws),
                        ],
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _sidebarNavItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String shortcut,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ZRadius.field),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: ZInk.muted(context)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: ZType.body.copyWith(color: ZInk.soft(context)),
              ),
            ),
            Text(
              shortcut,
              style: ZType.caption.copyWith(color: ZInk.ghost(context)),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _desktopPinned(BuildContext context, DeviceSession session) {
    final pinned = session.taskDirectory.pinnedEntries();
    if (pinned.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Text(
          tr(context, 'tasks.pinned'),
          style: ZType.caption.copyWith(
            fontWeight: FontWeight.w500,
            color: ZInk.ghost(context),
          ),
        ),
      ),
      for (final (e, key) in pinned)
        _desktopTaskRow(
          context,
          session,
          e,
          selected: e.sessionId == _paneSessionId,
          workspace: TaskDirectory.workspaceForKey(session.workspaces, e, key),
        ),
    ];
  }

  Widget _desktopWorkspaceFolder(
    BuildContext context,
    DeviceSession session,
    Map<String, dynamic> ws,
  ) {
    final isActive = _isWorkspaceActive(session, ws);
    final key = workspaceKeyOf(ws) ?? workspaceTitle(ws);
    final expanded = _isWorkspaceExpanded(key, isActive: isActive);
    // Merged directory view: the live index overrides the relay rows per
    // task id; the archive toggle picks its half. Same ordering as the
    // mobile card, including the dual-tier active row order — relay order
    // alone appends live-only rows at the tail.
    final dirKey = workspaceKeyOf(ws);
    final entries = dirKey == null
        ? const <SessionEntry>[]
        : _sortedEntries(
            [
              for (final (e, _) in session.taskDirectory
                  .entriesFor(dirKey, includeArchived: _showArchived))
                e,
            ],
            stabilizeActive: true,
          );
    // C2 parity: sidebar rows under a workspace folder carry the same
    // group palette dot the mobile card rows do (same grouped-view source;
    // a miss on older desktops keeps the plain rows).
    _ensureGroupedView(session);
    final groupDotOf = _groupDotOf(session);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(ZRadius.field),
          onTap: () => _toggleWorkspace(session, ws),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 16,
                  color: ZInk.ghost(context),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.folder_outlined,
                  size: 15,
                  color: ZInk.muted(context),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    workspaceTitle(ws),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZType.body.copyWith(
                      fontWeight: FontWeight.w500,
                      color: ZInk.soft(context),
                    ),
                  ),
                ),
                // Count on every folder (B7): 0 says the folder is empty.
                Text(
                  '${entries.length}',
                  style: ZType.caption.copyWith(color: ZInk.ghost(context)),
                ),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          for (final e in entries)
            _desktopTaskRow(
              context,
              session,
              e,
              selected: e.sessionId == _paneSessionId,
              indent: true,
              // Per-row resolution: conversation rows display in this
              // folder but still open under their own draft workspace.
              workspace:
                  TaskDirectory.workspaceForKey(session.workspaces, e, dirKey),
              groupDot: groupDotOf[e.sessionId],
            ),
          // Empty-group feedback (B7); the archive filter keeps its own copy.
          // A non-active folder whose rows are still in flight shows the
          // loading spinner instead of the false 「暂无任务」 (design 11-01
          // §3) — not for the archive filter, whose rows come from the relay
          // overview only.
          if (entries.isEmpty &&
              !_showArchived &&
              _cardRowsPending(session, dirKey))
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 4, 8, 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 2, 8, 6),
              child: Text(
                tr(
                  context,
                  _showArchived ? 'tasks.archive.empty' : 'tasks.empty',
                ),
                style: ZType.sub.copyWith(color: ZInk.ghost(context)),
              ),
            ),
        ],
      ],
    );
  }

  Widget _desktopTaskRow(
    BuildContext context,
    DeviceSession session,
    SessionEntry entry, {
    bool selected = false,
    bool indent = false,
    Map<String, dynamic>? workspace,
    Color? groupDot,
  }) {
    final title = entry.title.trim().isEmpty
        ? tr(context, 'tasks.untitled')
        : entry.title;
    final branch = _branchChipOf(session, entry);
    return Padding(
      padding: EdgeInsets.only(left: indent ? 12 : 0),
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(ZRadius.field),
        child: InkWell(
          borderRadius: BorderRadius.circular(ZRadius.field),
          onTap: () => _openWorkspaceTask(session, workspace, entry, title),
          onLongPress: () {
            final s = _session;
            if (s != null) _taskActions(context, s, entry);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                if (groupDot != null) ...[
                  Container(
                    width: ZListRow.dot,
                    height: ZListRow.dot,
                    decoration: BoxDecoration(
                      color: groupDot,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZType.body.copyWith(
                      fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                      color: ZInk.solid(context),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (branch != null) ...[
                  TaskBranchChip(branchName: branch),
                  const SizedBox(width: 6),
                ],
                Text(
                  relativeTimeShort(context, entry.lastActivityAt),
                  style: ZType.caption.copyWith(color: ZInk.ghost(context)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Right pane: the selected task's chat, or the empty placeholder.
  Widget _chatPane(BuildContext context) {
    final session = _session;
    final id = _paneSessionId;
    final title = _paneTitle;
    if (session == null || title == null) {
      return Center(
        child: Text(
          tr(context, 'tasks.paneHint'),
          style: ZType.body.copyWith(color: ZInk.faint(context)),
        ),
      );
    }
    return ChatPage(
      key: ValueKey('${id ?? 'draft'}-${_paneInitialComposerText ?? ''}'),
      host: session,
      sessionId: id,
      title: title,
      theme: widget.theme,
      embedded: true,
      initialComposerText: _paneInitialComposerText,
      initialPinned: _panePinned,
      draftWorkspacePath: id == null ? _paneDraftWorkspacePath : null,
      workspaceLabel: session.activeWorkspace != null
          ? workspaceTitle(session.activeWorkspace!)
          : null,
      onOpenUsage: () => _openUsage(session),
      offPeakHost: session,
      onOpenOffPeak: () => _openOffPeak(session),
    );
  }

  void _openUsage(DeviceSession session) {
    Navigator.of(context).push(
      zRoute((_) => DeviceUsagePage(session: session)),
    );
  }

  /// Off-peak tasks page — the chat queue card's "去到闲时任务" action (D2).
  void _openOffPeak(DeviceSession session) {
    Navigator.of(context).push(
      zRoute((_) => OffPeakPage(
            store: widget.store,
            hub: widget.hub,
            device: widget.device,
          )),
    );
  }

  /// Opens the unified search page (D6): three sources — actions
  /// (commands + skills, contains-matched, select pre-fills a new chat),
  /// tasks (directory filter with snippets) and files (probed; the page
  /// hides the tab itself when the desktop serves neither method).
  void _openTaskSearch([TaskSearchTab initialTab = TaskSearchTab.all]) {
    final session = _session;
    if (session == null || session.status != DeviceStatus.connected) return;
    Navigator.of(context).push(
      zRoute(
        (_) => TaskSearchPage(
          session: session,
          initialTab: initialTab,
          onOpenTask: (entry, ws) {
            final title = entry.title.trim().isEmpty
                ? tr(context, 'tasks.untitled')
                : entry.title;
            _openWorkspaceTask(session, ws, entry, title);
          },
          onOpenCommand: (item) {
            _openChat(
              title: tr(context, 'tasks.new'),
              initialComposerText: item.insert,
            );
          },
        ),
      ),
    );
  }

  /// Providers entry with the 3.12.3 capability gate (the desktop removed
  /// the `model-provider` channel): a failed probe disables the item and
  /// explains why — a placeholder beats a silently vanishing entry. The
  /// first menu open fires the probe fire-and-forget and answers "unknown"
  /// (tappable; the page itself degrades to its channel-unavailable view),
  /// the cached verdict shapes every later open. Never blocks the menu.
  /// Since 3.14 the desktop serves the `provider-settings` channel — a
  /// known ≥3.14 version always enables the entry, and an unknown version
  /// stays enabled (the page's runtime probe sorts it out).
  bool get _providersSupported {
    final session = _session;
    if (session == null) return false;
    return session.capabilities.providersEntryEnabled;
  }

  Widget _providersMenuItem() {
    final session = _session;
    // The probe answers the disabled-entry verdict for known pre-3.14
    // links (and primes the verdict an unknown version's route decision
    // consumes); a known ≥3.14 link would only log a doomed call.
    if (session != null && session.capabilities.shouldPrimeProviderProbe) {
      unawaited(session.probeModelProvider());
    }
    if (_providersSupported) {
      return Text(tr(context, 'tasks.menu.providers'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          tr(context, 'tasks.menu.providers'),
          style: ZType.body.copyWith(color: ZInk.faint(context)),
        ),
        const SizedBox(height: 2),
        Text(
          tr(context, 'tasks.menu.providersUnsupported'),
          style: ZType.caption.copyWith(color: ZInk.ghost(context)),
        ),
      ],
    );
  }

  Widget _overflowMenu() {
    return PopupMenuButton<String>(
      onSelected: _onMenu,
      itemBuilder: (c) => [
        PopupMenuItem(
          value: 'automations',
          child: Row(
            children: [
              const Icon(Icons.schedule_outlined, size: 18),
              const SizedBox(width: 8),
              Text(tr(context, 'tasks.menu.automations')),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'offPeak',
          child: Row(
            children: [
              const Icon(Icons.nights_stay_outlined, size: 18),
              const SizedBox(width: 8),
              Text(tr(context, 'tasks.menu.offPeak')),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'usage',
          child: Text(tr(context, 'tasks.menu.usage')),
        ),
        PopupMenuItem(
          value: 'providers',
          enabled: _providersSupported,
          child: _providersMenuItem(),
        ),
        PopupMenuItem(
          value: 'defaults',
          child: Row(
            children: [
              const Icon(Icons.tune, size: 18),
              const SizedBox(width: 8),
              Text(tr(context, 'tasks.menu.defaults')),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'archive',
          child: Row(
            children: [
              Icon(
                _showArchived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
              ),
              const SizedBox(width: 8),
              Text(
                tr(
                  context,
                  _showArchived
                      ? 'tasks.action.unarchiveView'
                      : 'tasks.action.archiveView',
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'web',
          child: Row(
            children: [
              const Icon(Icons.open_in_browser, size: 18),
              const SizedBox(width: 8),
              Text(tr(context, 'tasks.openWeb')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _listBody(BuildContext context) {
    // Stage copy (B-03) is consumed the project way: a merge of the hub (the
    // page's session conduit) with the live session itself, so a stage change
    // repaints even between hub forwarders. No state library.
    final session = _session;
    final animation = Listenable.merge([
      widget.hub,
      if (session != null) session,
    ]);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final session = _session;
        final banner = _ConnectionBanner(
          session: session,
          handoverBusy: _handoverBusy,
          onRetry: () async {
            final s = _session;
            if (s != null) await _reloadTasks(s);
          },
          onWeb: _openRemote,
        );
        // Lazy rows: widgets are cheap config
        // objects, ListView.builder only inflates what's near the viewport,
        // so collapse toggles never rebuild the whole list's elements.
        final rows = <Widget>[
          banner,
          const SizedBox(height: 12),
          _headerRow(context, session),
          const SizedBox(height: 12),
          if (session != null && _showArchived)
            ..._archiveView(context, session)
          else ...[
            if (session != null) ..._pinnedGroup(context, session),
            if (session == null || session.workspaces.isEmpty)
              _fallback(context, session)
            else if (_groupBy == 'timeline')
              ..._timelineGroups(context, session)
            else
              for (final ws in _orderedWorkspaces(session))
                Padding(
                  padding: const EdgeInsets.only(bottom: ZSpacing.cardGap),
                  child: _workspaceCard(context, session, ws),
                ),
          ],
        ];
        // The replace window: while a reload RPC is in flight the list is
        // pointer-dead (stale-row taps would act on rows about to reshuffle).
        // The 2dp bar above it is the only visible trace of that window — a
        // pointer-dead list with zero progress read as a hung page.
        return Column(
          children: [
            if (_reloading) const _ReloadBar(),
            Expanded(
              child: IgnorePointer(
                ignoring: _reloading,
                child: RefreshIndicator(
                  onRefresh: () async => session == null
                      ? widget.hub.ensure(widget.device)
                      : _reloadTasks(session),
                  child: ListView.builder(
                    // Always scrollable: a short list (one workspace, no
                    // tasks) must still accept the pull gesture for the
                    // refresh indicator.
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: zScreenPadding(
                        context, top: 12, bottom: 32, horizontal: 12),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => rows[i],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 插件市场: the marketplace is managed by the desktop app (the remote
  /// web button has no embedded view either) — surface that honestly.
  Future<void> _openPluginMarketplaceHint() {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) => zSheetScaffold(
        sheetCtx,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              ZSpacing.screen, 0, ZSpacing.screen, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(sheetCtx, 'tasks.sidebar.plugins'),
                style: ZType.heading,
              ),
              const SizedBox(height: 8),
              Text(
                tr(sheetCtx, 'tasks.sidebar.pluginsHint'),
                style: ZType.body.copyWith(
                  height: 1.6,
                  color: ZInk.faint(sheetCtx),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Section header + collapse / tidy / refresh.
  Widget _headerRow(BuildContext context, DeviceSession? session) {
    final workspaces = session?.workspaces.length ?? 0;
    final tasks = session == null ? 0 : session.taskDirectory.totalTaskCount;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(context, 'tasks.sectionTitle'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ZType.heading,
              ),
              const SizedBox(height: 2),
              Text(
                trP(context, 'tasks.stats', ['$workspaces', '$tasks']),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ZType.sub.copyWith(color: ZInk.faint(context)),
              ),
              if (_lastSyncAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    trP(context, 'tasks.lastSync', [_clockLabel(_lastSyncAt!)]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZType.caption.copyWith(color: ZInk.ghost(context)),
                  ),
                ),
            ],
          ),
        ),
        // Header actions: the collapse-all button keeps its label
        // and icon in every state (one-way collapse, like the web).
        IconButton(
          tooltip: tr(context, 'tasks.collapseAll'),
          icon: const Icon(Icons.keyboard_double_arrow_up),
          iconSize: 20,
          color: ZInk.muted(context),
          onPressed: () => _collapseAllWorkspaces(session),
        ),
        IconButton(
          tooltip: tr(context, 'tasks.tidy'),
          icon: const Icon(Icons.filter_list),
          iconSize: 20,
          color: ZInk.muted(context),
          onPressed: () => _showTidyPanel(context),
        ),
        IconButton(
          tooltip: tr(context, 'tasks.refreshAll'),
          icon: const Icon(Icons.refresh),
          iconSize: 20,
          color: ZInk.muted(context),
          onPressed: () {
            final s = _session;
            if (s != null) {
              _reloadTasks(s);
            } else {
              widget.hub.ensure(widget.device);
            }
          },
        ),
        // 搜索 (D6): the touchscreen entry — the official mobile home has
        // none; fourth sibling of the collapse / tidy / refresh row.
        IconButton(
          tooltip: tr(context, 'tasks.search'),
          icon: const Icon(Icons.search),
          iconSize: 20,
          color: ZInk.muted(context),
          onPressed: _openTaskSearch,
        ),
      ],
    );
  }

  /// 整理任务 panel: group (workspace / timeline), task-row sort
  /// (created / updated) and card order (activity / name A→Z / Z→A),
  /// radio-style like the web popover.
  ///
  /// The sheet is its own route: the page-level [setState] below never
  /// rebuilds it (the radio visuals froze on the first selection, B2), so a
  /// StatefulBuilder carries the sheet subtree while the page setState
  /// re-groups / re-sorts the list behind it.
  Future<void> _showTidyPanel(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => zSheetScaffold(
          sheetCtx,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  ZSpacing.screen, 0, ZSpacing.screen, 8),
              child: Text(
                tr(sheetCtx, 'tasks.tidy.groupLabel'),
                style: ZType.heading,
              ),
            ),
            RadioGroup<String>(
              groupValue: _groupBy,
              onChanged: (v) {
                setState(() => _groupBy = v ?? _groupBy);
                setSheetState(() {});
                _saveOrganizePrefs();
              },
              child: Column(
                children: [
                  for (final (value, label) in [
                    ('workspace', tr(context, 'tasks.tidy.group')),
                    ('timeline', tr(context, 'tasks.tidy.timeline')),
                  ])
                    RadioListTile<String>(
                      value: value,
                      title: Text(label),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                    ),
                ],
              ),
            ),
            const Divider(
                height: 1, indent: ZSpacing.screen, endIndent: ZSpacing.screen),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  ZSpacing.screen, 12, ZSpacing.screen, 4),
              child: Text(
                tr(sheetCtx, 'tasks.tidy.sortLabel'),
                style: ZType.sub.copyWith(
                  fontWeight: FontWeight.w600,
                  color: ZInk.faint(sheetCtx),
                ),
              ),
            ),
            RadioGroup<String>(
              groupValue: _sortBy,
              onChanged: (v) {
                setState(() => _sortBy = v ?? _sortBy);
                setSheetState(() {});
                _saveOrganizePrefs();
              },
              child: Column(
                children: [
                  for (final (value, label) in [
                    ('created', tr(context, 'tasks.tidy.sort.created')),
                    ('updated', tr(context, 'tasks.tidy.sort.updated')),
                  ])
                    RadioListTile<String>(
                      value: value,
                      title: Text(label),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                    ),
                ],
              ),
            ),
            const Divider(
                height: 1, indent: ZSpacing.screen, endIndent: ZSpacing.screen),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  ZSpacing.screen, 12, ZSpacing.screen, 4),
              child: Text(
                tr(sheetCtx, 'tasks.tidy.cardSortLabel'),
                style: ZType.sub.copyWith(
                  fontWeight: FontWeight.w600,
                  color: ZInk.faint(sheetCtx),
                ),
              ),
            ),
            RadioGroup<String>(
              groupValue: _cardSort,
              onChanged: (v) {
                setState(() => _cardSort = v ?? _cardSort);
                setSheetState(() {});
                _saveOrganizePrefs();
              },
              child: Column(
                children: [
                  for (final (value, label) in [
                    ('activity', tr(context, 'tasks.tidy.cardSort.activity')),
                    ('nameAsc', tr(context, 'tasks.tidy.cardSort.nameAsc')),
                    ('nameDesc', tr(context, 'tasks.tidy.cardSort.nameDesc')),
                  ])
                    RadioListTile<String>(
                      value: value,
                      title: Text(label),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          ),
        ),
      ),
    );
  }

  /// "已置顶" group above the workspace cards: one card per pinned
  /// task (title, workspace · time, phase pill).
  List<Widget> _pinnedGroup(BuildContext context, DeviceSession session) {
    final pinned = session.taskDirectory.pinnedEntries();
    if (pinned.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          tr(context, 'tasks.pinned'),
          style: ZType.bodyStrong.copyWith(
            fontWeight: FontWeight.w500,
            color: ZInk.ghost(context),
          ),
        ),
      ),
      for (final (e, key) in pinned)
        Padding(
          padding: const EdgeInsets.only(bottom: ZSpacing.cardGap),
          child: _pinnedCard(context, session, e, workspaceKey: key),
        ),
    ];
  }

  Widget _pinnedCard(
    BuildContext context,
    DeviceSession session,
    SessionEntry entry, {
    required String? workspaceKey,
  }) {
    final (phaseLabel, _) = _phaseVisual(entry.phase);
    final title = entry.title.trim().isEmpty
        ? tr(context, 'tasks.untitled')
        : entry.title;
    final branch = _branchChipOf(session, entry);
    // No activeWorkspace fallback here: a pinned task of a foreign workspace
    // must open under its OWN scope (the fallback-built map below), never
    // silently under whatever workspace happens to be active.
    final ws =
        TaskDirectory.workspaceForKey(session.workspaces, entry, workspaceKey);
    final subtitle = [
      if (ws != null) workspaceTitle(ws),
      relativeTimeShort(context, entry.lastActivityAt),
    ].join(' · ');
    return SwipeActionsRow(
      actions: _swipeActions(session, entry),
      trayRadius: ZRadius.tile,
      childRadius: ZRadius.tile,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openWorkspaceTask(session, ws, entry, title),
          onLongPress: () => _taskActions(context, session, entry),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ZType.bodyStrong.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (branch != null) ...[
                            const SizedBox(width: 6),
                            TaskBranchChip(branchName: branch),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ZType.sub.copyWith(color: ZInk.faint(context)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                PhasePill(label: phaseLabel, phase: entry.phase, solid: true),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 按时间线 grouping: day buckets (今天 / N 天前 / 上周 / 更早)
  /// with one row per task, each prefixed with its workspace name. Covers
  /// every workspace via the relay task list (web mobile-home semantics).
  /// 3.17.1 task groups (direct sqlite read) render as their own sections
  /// (色点 + 标题) above the day buckets; tasks in no group keep the buckets
  /// untouched.
  List<Widget> _timelineGroups(BuildContext context, DeviceSession session) {
    final pairs = session.taskDirectory.allEntries();
    final entries = _sortedEntries([for (final (e, _) in pairs) e]);
    final wsKeyOf = {for (final (e, key) in pairs) e.sessionId: key};
    if (entries.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              tr(context, 'tasks.empty'),
              style: ZType.body.copyWith(color: ZInk.faint(context)),
            ),
          ),
        ),
      ];
    }
    _ensureGroupedView(session);
    final grouped = identical(_groupedViewSession, session)
        ? _groupedView
        : null;
    final sections = <Widget>[];
    var claimed = const <String>{};
    if (grouped != null && grouped.groups.isNotEmpty) {
      final byId = {for (final e in entries) e.sessionId: e};
      sections.addAll(
        _groupSections(context, session, grouped, byId, wsKeyOf),
      );
      claimed = {
        // Bucket suppression mirrors the section membership judgment
        // (workspace-bearing join). Pinned members stay claimed on purpose:
        // their only rendering is the 已置顶 card, so a day bucket must not
        // repeat them.
        for (final g in grouped.groups)
          for (final m in grouped.membersOf(g.id))
            if (byId.containsKey(m.taskId) &&
                _memberMatchesDirectory(m, wsKeyOf))
              m.taskId,
      };
    }
    final now = DateTime.now();
    final buckets = <String, List<SessionEntry>>{};
    for (final e in entries) {
      if (claimed.contains(e.sessionId)) continue;
      buckets
          .putIfAbsent(
            _timelineBucketLabel(context, e.lastActivityAt, now),
            () => [],
          )
          .add(e);
    }
    return [
      ...sections,
      for (final bucket in buckets.entries) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
          child: Text(
            bucket.key,
            style: ZType.bodyStrong.copyWith(
              fontWeight: FontWeight.w500,
              color: ZInk.ghost(context),
            ),
          ),
        ),
        for (final e in bucket.value)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _directoryTaskRow(context, session, e, wsKeyOf[e.sessionId]),
          ),
      ],
    ];
  }

  /// One row resolved from the merged directory: the workspace map (listed
  /// match or fallback-built scope) feeds both the label prefix and the
  /// open path, so tapping re-points the bridge to the task's TRUE
  /// workspace.
  Widget _directoryTaskRow(
    BuildContext context,
    DeviceSession session,
    SessionEntry entry,
    String? workspaceKey,
  ) {
    final ws =
        TaskDirectory.workspaceForKey(session.workspaces, entry, workspaceKey);
    return _taskRow(
      context,
      session,
      entry,
      workspaceLabel: _rowWorkspaceLabel(session, ws),
      workspace: ws,
    );
  }

  /// Kick the grouped-view load when the session changed or the 30 s page
  /// TTL expired; the result lands via setState after the async read
  /// (a miss lands as null → flat view). The session stamp still guards
  /// against a stale answer landing on a different session.
  void _ensureGroupedView(DeviceSession session) {
    final loadedAt = _groupedViewLoadedAt;
    if (identical(_groupedViewSession, session) &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) < _groupedViewTtl) {
      return;
    }
    _groupedViewSession = session;
    _groupedViewLoadedAt = DateTime.now();
    session.groupedTaskView().then((view) {
      if (mounted && identical(_groupedViewSession, session)) {
        setState(() => _groupedView = view);
      }
    });
  }

  /// Group sections in desktop order (ascending sort_order, createdAt
  /// fallback), one header row + its member rows each. A member renders only
  /// when the directory has its row in the member's OWN workspace and the
  /// row is not pinned (desktop renderer: `!pinned && !archived`). Groups
  /// without a visible task render no header. Member rows reuse the shared
  /// task row (workspace prefix label from the member's workspace key).
  List<Widget> _groupSections(
    BuildContext context,
    DeviceSession session,
    GroupedTaskView view,
    Map<String, SessionEntry> byId,
    Map<String, String?> wsKeyOf,
  ) {
    final sections = <Widget>[];
    for (final group in view.orderedGroups()) {
      final members = [
        for (final m in view.membersOf(group.id))
          if (byId[m.taskId] != null &&
              _memberMatchesDirectory(m, wsKeyOf) &&
              // Desktop renderer: `!pinned && !archived`. A pinned task's
              // only rendering is its 已置顶 card (archived rows never enter
              // the directory set, so that half is already filtered).
              byId[m.taskId]!.raw['pinned'] != true)
            m,
      ];
      if (members.isEmpty) continue;
      sections.add(_groupHeader(context, group));
      for (final m in members) {
        sections.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _directoryTaskRow(
              context,
              session,
              byId[m.taskId]!,
              wsKeyOf[m.taskId],
            ),
          ),
        );
      }
    }
    return sections;
  }

  /// Group section header: desktop palette color dot + group title, same
  /// text style as the day-bucket headers.
  Widget _groupHeader(BuildContext context, TaskGroupInfo group) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
      child: Row(
        children: [
          Container(
            width: ZListRow.dot,
            height: ZListRow.dot,
            decoration: BoxDecoration(
              color: _groupColor(group.color),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _groupTitle(context, group),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.bodyStrong.copyWith(
                fontWeight: FontWeight.w500,
                color: ZInk.ghost(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Default-group title fallback (official `B3` @317021084): the cron /
  /// off-peak default groups (ids `zcode-default-group-cron` /
  /// `zcode-default-group-off-peak`, runtime @947235) resolve an empty or
  /// id-equal wire title through the lexicon — the wire title of a default
  /// group is not guaranteed localized, and the desktop itself falls back
  /// by id. Named groups render their wire title untouched.
  String _groupTitle(BuildContext context, TaskGroupInfo group) {
    if (group.title.isEmpty || group.title == group.id) {
      if (group.id == 'zcode-default-group-cron') {
        return tr(context, 'taskGroup.cronGroupName');
      }
      if (group.id == 'zcode-default-group-off-peak') {
        return tr(context, 'offPeak.sidebar.groupTitle');
      }
    }
    return group.title;
  }

  /// Desktop task-group palette (7 colors on the web; live frames observed
  /// 'purple'/'blue'/...). Unknown names fall back neutral.
  Color _groupColor(String? name) => switch (name) {
    'blue' => ZColors.sky500,
    'green' => ZColors.success,
    'red' => ZColors.danger,
    'yellow' => ZColors.warning,
    'orange' => ZColors.usageOrange,
    'purple' => ZColors.violet400,
    _ => ZColors.neutral400,
  };

  /// Whether a group member has a live directory row in its OWN workspace —
  /// the desktop joins members on `(workspace_key, task_id)`, not the task
  /// id alone. A dangling member (no desktop task row) can share its id
  /// with a real copy in another workspace; matching by id alone would
  /// render that copy twice. Both spellings normalize through
  /// [ProjectResolver.normalizeProjectRoot] (Windows path fold, POSIX
  /// case-sensitive; identity strings pass through verbatim).
  bool _memberMatchesDirectory(
    TaskGroupMember member,
    Map<String, String?> wsKeyOf,
  ) {
    final rowKey = wsKeyOf[member.taskId];
    if (rowKey == null) return false;
    return ProjectResolver.normalizeProjectRoot(rowKey) ==
        ProjectResolver.normalizeProjectRoot(member.workspaceKey);
  }

  /// B8: taskId → its task group's palette dot. The SAME grouped view the
  /// timeline headers render is the source, so a task grouped under the
  /// cron group (blue) carries the same blue dot in the workspace view —
  /// one membership judgment, both groupings. A member missing from the
  /// directory, sitting in another workspace, or pinned (the 已置顶 card
  /// carries no group dot) contributes nothing. Empty while the grouped
  /// read is in flight or unavailable (R4 silent degrade).
  Map<String, Color> _groupDotOf(DeviceSession session) {
    final grouped = identical(_groupedViewSession, session)
        ? _groupedView
        : null;
    if (grouped == null) return const {};
    final pairs = session.taskDirectory.allEntries();
    final byId = {for (final (e, _) in pairs) e.sessionId: e};
    final wsKeyOf = {for (final (e, key) in pairs) e.sessionId: key};
    final dots = <String, Color>{};
    for (final g in grouped.groups) {
      for (final m in grouped.membersOf(g.id)) {
        final row = byId[m.taskId];
        if (row == null || !_memberMatchesDirectory(m, wsKeyOf)) continue;
        if (row.raw['pinned'] == true) continue;
        dots[m.taskId] = _groupColor(g.color);
      }
    }
    return dots;
  }

  /// Row prefix label: the task's own workspace (timeline grouping), else
  /// the label handed down by the card.
  String? _rowWorkspaceLabel(DeviceSession session, Map<String, dynamic>? ws) {
    if (ws == null) return null;
    return workspaceTitle(ws);
  }

  /// Archive view (归档列表): every archived task on the device,
  /// from the merged task directory, grouped by workspace. Rows long-press
  /// into the shared action sheet (取消归档 / 删除 live there).
  List<Widget> _archiveView(BuildContext context, DeviceSession session) {
    final groups = _archiveGroups(session);
    final total = groups.fold<int>(0, (n, g) => n + g.$2.length);
    final widgets = <Widget>[
      // 「全部删除」entry (desktop 3.17.1 deleteArchivedTasks; the official
      // web's archive-delete-all is the same view-level destructive button).
      // Hidden below the capability gate — the method only ships in 3.17.1.
      if (session.capabilities.archivedDelete && total > 0)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: () => _clearArchiveDialog(session, groups),
                style: TextButton.styleFrom(
                  foregroundColor: ZInk.dangerTone(context),
                ),
                child: Text(tr(context, 'tasks.archive.deleteAll')),
              ),
            ],
          ),
        ),
    ];
    for (final (ws, entries) in groups) {
      final dirKey = workspaceKeyOf(ws);
      widgets
        ..add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
            child: Text(
              workspaceTitle(ws),
              style: ZType.bodyStrong.copyWith(
                fontWeight: FontWeight.w500,
                color: ZInk.ghost(context),
              ),
            ),
          ),
        )
        ..addAll([
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _taskRow(
                context,
                session,
                e,
                workspace:
                    TaskDirectory.workspaceForKey(session.workspaces, e, dirKey),
              ),
            ),
        ]);
    }
    if (total == 0) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Center(
            child: Text(
              tr(context, 'tasks.archive.empty'),
              style: ZType.body.copyWith(color: ZInk.faint(context)),
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  /// The archive view's workspace groups — one (workspace, sorted entries)
  /// per workspace holding archived rows. Shared by the view builder and
  /// the batch-delete dialog so the confirmation count and the wire batches
  /// can never drift apart. Same activity order as the cards: the key is
  /// the non-archived one, so a workspace whose live directory is empty
  /// (archived rows only) keeps the null key and sorts last — deliberate,
  /// so the archive view never contradicts the home card order. Conversation
  /// rows are keyed to the default group; their archived rows already
  /// surface under that group (no draft header) — [_orderedWorkspaces]
  /// filters those workspaces out.
  List<(Map<String, dynamic>, List<SessionEntry>)> _archiveGroups(
      DeviceSession session) {
    final groups = <(Map<String, dynamic>, List<SessionEntry>)>[];
    for (final ws in _orderedWorkspaces(session)) {
      final dirKey = workspaceKeyOf(ws);
      final entries = _sortedEntries(dirKey == null
          ? const <SessionEntry>[]
          : [
              for (final (e, _) in session.taskDirectory
                  .entriesFor(dirKey, includeArchived: true))
                e,
            ]);
      if (entries.isNotEmpty) groups.add((ws, entries));
    }
    return groups;
  }

  /// 「全部删除」entry of the archive view.
  ///
  /// ≥3.18.0 takes the three-phase path (design 11-11 §4): one dialog that
  /// previews every taskId in place (progress, cancellable), flips to the
  /// confirmation state (deletable count + per-task deleteItem lines), then
  /// executes one by one with the same counter. Aggregation is per-task
  /// status — deleted → succeeded, blocked → skipped, incomplete / throw →
  /// failed — reusing the official `archives.result` three-placeholder copy.
  ///
  /// Preview-phase degrade (unknown method) falls back to the pre-3.18.0
  /// per-workspace batch delete below; execute-phase failures NEVER fall
  /// back (already-deleted ids would be re-counted as skipped).
  Future<void> _clearArchiveDialog(
    DeviceSession session,
    List<(Map<String, dynamic>, List<SessionEntry>)> groups,
  ) async {
    final total = groups.fold<int>(0, (n, g) => n + g.$2.length);
    if (total == 0) return;
    if (!session.windowControllerAvailable) {
      await _clearArchiveAllLegacy(session, groups);
      return;
    }

    final titles = {
      for (final (_, entries) in groups)
        for (final e in entries)
          e.sessionId: e.title.trim().isEmpty
              ? tr(context, 'tasks.untitled')
              : e.title,
    };
    final outcome = await showDialog<_ArchiveClearOutcome>(
      context: context,
      useRootNavigator: false,
      builder: (_) => _ArchiveClearDialog(
        session: session,
        taskIds: [
          for (final (_, entries) in groups)
            for (final e in entries) e.sessionId,
        ],
        titles: titles,
      ),
    );
    if (!mounted || outcome == null) return;

    switch (outcome) {
      case _ArchiveClearDegraded():
        await _clearArchiveAllLegacy(session, groups);
      case _ArchiveClearUnavailable():
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_archiveFailureCopy(context, 'blocked', null)),
          ),
        );
      case _ArchiveClearDone(
          :final ok,
          :final failed,
          :final skipped,
          :final deletedIds,
        ):
        await _runOp(() async {
          await _reloadTasks(session);
          if (!mounted) return;
          if (deletedIds.contains(_paneSessionId)) {
            setState(() {
              _paneSessionId = null;
              _paneTitle = null;
            });
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                trP(context, 'tasks.archive.result', [
                  '$ok',
                  '$failed',
                  '$skipped',
                ]),
              ),
            ),
          );
        });
    }
  }

  /// Pre-3.18.0 batch delete (`deleteArchivedTasks`, desktop 3.17.1). One
  /// wire batch PER WORKSPACE group — the method addresses a single
  /// workspace scope (the official web splits by source the same way). The
  /// result toast follows the official archives.result copy.
  Future<void> _clearArchiveAllLegacy(
    DeviceSession session,
    List<(Map<String, dynamic>, List<SessionEntry>)> groups,
  ) async {
    final total = groups.fold<int>(0, (n, g) => n + g.$2.length);
    if (total == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(trP(dialogCtx, 'tasks.archive.deleteTitle', ['$total'])),
        content: Text(tr(dialogCtx, 'tasks.archive.deleteDesc')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(tr(dialogCtx, 'common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(tr(dialogCtx, 'tasks.archive.deleteAll')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runOp(() async {
      var ok = 0;
      var failed = 0;
      var skipped = 0;
      for (final (ws, entries) in groups) {
        final res = await session.deleteArchivedAll(
          [for (final e in entries) e.sessionId],
          scope: {
            'workspacePath': ws['workspacePath'],
            if (ws['workspaceIdentity'] != null)
              'workspaceIdentity': ws['workspaceIdentity'],
          },
        );
        // Unexpected answer shapes count as nothing — the reload below is
        // the ground truth for what actually went away.
        if (res is! Map) continue;
        ok += (res['deletedTaskIds'] as List?)?.length ?? 0;
        failed += (res['failedTaskIds'] as List?)?.length ?? 0;
        skipped += (res['skippedTaskIds'] as List?)?.length ?? 0;
      }
      await _reloadTasks(session);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            trP(context, 'tasks.archive.result', ['$ok', '$failed', '$skipped']),
          ),
        ),
      );
    });
  }

  /// Bucket labels (taskTimeline): today / yesterday /
  /// day-count / last week / earlier.
  String _timelineBucketLabel(BuildContext context, int millis, DateTime now) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    final diff = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(d.year, d.month, d.day)).inDays;
    if (diff <= 0) return tr(context, 'tasks.timeline.today');
    if (diff == 1) return tr(context, 'tasks.timeline.yesterday');
    if (diff <= 6) return trP(context, 'tasks.timeline.daysAgo', ['$diff']);
    if (diff <= 13) return tr(context, 'tasks.timeline.lastWeek');
    return tr(context, 'tasks.timeline.earlier');
  }

  /// One workspace card: name + 本地 badge, folder + path, updated-at, task
  /// count + chevron + new-task button; expanded shows the task rows.
  Widget _workspaceCard(
    BuildContext context,
    DeviceSession session,
    Map<String, dynamic> ws,
  ) {
    final isActive = _isWorkspaceActive(session, ws);
    final key = workspaceKeyOf(ws) ?? workspaceTitle(ws);
    final expanded = _isWorkspaceExpanded(key, isActive: isActive);

    final sessions = isActive ? session.sessions : null;
    // Active workspace: the merged directory view (the live sessions-index
    // with its richer phase/interaction overriding the relay rows per task
    // id). Others: relay rows — the web mobile home does the same.
    final dirKey = workspaceKeyOf(ws);
    var entries = dirKey == null
        ? const <SessionEntry>[]
        : [
            for (final (e, _) in session.taskDirectory.entriesFor(dirKey)) e,
          ];
    // Dual-tier active row order (10-31): several streaming rows must not
    // trade places on every output frame (see [_sortedEntries]).
    entries = _sortedEntries(entries, stabilizeActive: true);
    final lastActivity = entries.isEmpty
        ? null
        : entries.map((e) => e.lastActivityAt).reduce((a, b) => a > b ? a : b);
    // Highlight: the "current" task row (latest running, else the
    // most recently active) gets a rounded white/10 background.
    final current = _currentEntry(entries);
    // B8: the grouped-view read is kicked here too so workspace rows can
    // carry the group dot; a miss (missing tables / no home) keeps the
    // flat rows.
    _ensureGroupedView(session);
    final groupDotOf = _groupDotOf(session);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            // mobile home: expand/collapse only — opening happens on task taps
            onTap: () => _toggleWorkspace(session, ws, openIfInactive: false),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                workspaceTitle(ws),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ZType.bodyStrong,
                              ),
                            ),
                            const SizedBox(width: 6),
                            _kindBadge(context, ws),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // Path · activity, one caption line (R6): the folder
                        // icon and the separate 更新于 row are gone.
                        Text(
                          [
                            '${ws['workspacePath'] ?? ''}',
                            if (lastActivity != null)
                              relativeTimeShort(context, lastActivity),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ZType.caption.copyWith(
                            color: ZInk.faint(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Count on every card (B7): a 0-task workspace says so
                  // instead of going silent like a broken header.
                  Text(
                    trP(context, 'tasks.taskCount', ['${entries.length}']),
                    style: ZType.caption.copyWith(color: ZInk.faint(context)),
                  ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: ZTile.iconSize,
                    color: ZInk.ghost(context),
                  ),
                  const SizedBox(width: 4),
                  _newTaskButton(context, session, workspace: ws),
                ],
              ),
            ),
          ),
          if (expanded && (isActive ? sessions != null : true)) ...[
            Divider(height: 1, color: ZInk.hairline(context)),
            if ((isActive && sessions != null && !sessions.ready) ||
                (!isActive && entries.isEmpty &&
                    _cardRowsPending(session, dirKey)))
              // Loading gate (design 11-01 §3): the active index before its
              // first snapshot, and a non-active card whose sidecar/overview
              // has not landed yet. The empty-state copy below would claim
              // 「暂无任务」 while the rows are simply still in flight.
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: SizedBox(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (entries.isEmpty)
              // Empty-group feedback (B7): expanding a 0-task workspace
              // explains itself instead of showing a bare divider.
              Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: Text(
                    tr(context, 'tasks.empty'),
                    style: ZType.sub.copyWith(color: ZInk.faint(context)),
                  ),
                ),
              )
            else
              for (var i = 0; i < entries.length; i++)
                _taskRow(
                  context,
                  session,
                  entries[i],
                  highlight:
                      current != null &&
                      entries[i].sessionId == current.sessionId,
                  // Resolved per row: a conversation row displays in the
                  // default card but opens under its own draft workspace;
                  // normal rows resolve back to this card's workspace (the
                  // active-workspace identical check still skips the reopen).
                  workspace: TaskDirectory.workspaceForKey(
                    session.workspaces,
                    entries[i],
                    dirKey,
                  ),
                  groupDot: groupDotOf[entries[i].sessionId],
                ),
          ],
        ],
      ),
    );
  }

  /// The row the page highlights: the latest running task, falling
  /// back to the most recently active one.
  static SessionEntry? _currentEntry(List<SessionEntry> entries) {
    SessionEntry? current;
    for (final e in entries) {
      final running = e.phase == 'running' || e.phase == 'prewarming';
      if (running &&
          (current == null || e.lastActivityAt > current.lastActivityAt)) {
        current = e;
      }
    }
    if (current != null || entries.isEmpty) return current;
    return entries.reduce(
      (a, b) => a.lastActivityAt > b.lastActivityAt ? a : b,
    );
  }

  /// Workspace-kind badge (web `workspaceKind.local/conversation/remote`).
  Widget _kindBadge(BuildContext context, Map<String, dynamic> ws) {
    final kind = _isConversationWorkspace(ws)
        ? 'conversation'
        : (ws['kind'] == 'remote' ? 'remote' : 'local');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.mini),
      ),
      child: Text(
        tr(context, 'tasks.workspaceKind.$kind'),
        style: ZType.caption.copyWith(color: ZInk.faint(context)),
      ),
    );
  }

  /// Sidebar "new task": same cold-runtime rule as the card ＋ — a typed
  /// cold-runtime failure means the previous open failed, so re-point the
  /// active workspace first (a successful open clears the stale banner). No
  /// active workspace means there is nothing to re-point: a cold-runtime
  /// failure still explains the failure on the list; otherwise the
  /// pre-existing draft path runs.
  Future<void> _startNewTask() async {
    final session = _session;
    if (session != null) {
      final ws = session.activeWorkspace;
      if (ws == null) {
        final failure = session.lastWorkspaceOpenFailure;
        if (failure is WorkspaceOpenRuntimeNotRunning) {
          _showWorkspaceOpenFailure(failure);
          return;
        }
      } else if (_needsWorkspaceOpen(session, ws)) {
        final result = await session.openWorkspace(
          ws,
          purpose: WorkspaceOpenPurpose.chatNew,
        );
        if (result is! WorkspaceOpenOpened) {
          if (mounted) _showWorkspaceOpenFailure(result);
          return;
        }
      }
    }
    if (!mounted) return;
    await _openChat(title: tr(context, 'tasks.new'));
  }

  /// ➕ starts a draft chat (createSession fires on first send). In a
  /// non-active workspace card it re-points the bridge first so the draft
  /// lands in that workspace.
  Widget _newTaskButton(
    BuildContext context,
    DeviceSession session, {
    Map<String, dynamic>? workspace,
  }) {
    final newLabel = tr(context, 'tasks.new');
    Future<void> start() async {
      if (workspace != null && _needsWorkspaceOpen(session, workspace)) {
        final result = await session.openWorkspace(
          workspace,
          purpose: WorkspaceOpenPurpose.chatNew,
        );
        if (result is! WorkspaceOpenOpened) {
          if (mounted) _showWorkspaceOpenFailure(result);
          return;
        }
      }
      if (!mounted) return;
      await _openChat(title: newLabel);
    }

    return SizedBox(
      width: zTouchWidth,
      height: zTouchHeight,
      child: IconButton(
        tooltip: newLabel,
        padding: EdgeInsets.zero,
        icon: Icon(
          Icons.add_circle_outline,
          size: 20,
          color: ZInk.muted(context),
        ),
        onPressed: start,
      ),
    );
  }

  /// Branch chip label of [entry]: null unless the row belongs to a
  /// worktree AND the last refresh round cached a branch for its path.
  /// Archived rows never chip — the archive view reuses the shared row
  /// builder, and R2 keeps the chip off archived surfaces.
  String? _branchChipOf(DeviceSession session, SessionEntry entry) {
    if (entry.raw['archived'] == true) return null;
    return session.worktreeBranchFor(entry);
  }

  /// One task row: title + phase pill + relative time. No per-row overflow
  /// button — a long press opens the action sheet.
  /// The current (latest running / most recent) row gets the
  /// rounded white/10 highlight. Rows of other workspaces carry [workspace]
  /// so opening them re-points the bridge (web: workspace-bridge-open with
  /// taskId). Tags: 「等待确认」(pending interaction), 「对话」
  /// (conversation workspace) and the unread dot (`unreadAt`). [groupDot]
  /// marks a task-group member with its group's palette dot — the same
  /// marker the timeline headers render (B8).
  Widget _taskRow(
    BuildContext context,
    DeviceSession session,
    SessionEntry entry, {
    bool highlight = false,
    String? workspaceLabel,
    Map<String, dynamic>? workspace,
    Color? groupDot,
  }) {
    final (phaseLabel, _) = _phaseVisual(entry.phase);
    final title = entry.title.trim().isEmpty
        ? tr(context, 'tasks.untitled')
        : entry.title;
    final branch = _branchChipOf(session, entry);
    final subtitle = [
      if (workspaceLabel != null) workspaceLabel,
      relativeTimeShort(context, entry.lastActivityAt),
    ].join(' · ');
    final awaiting = entry.pendingInteraction != null;
    final unread = entry.raw['unreadAt'] != null;
    // Conversation rows merged into the default card (draft-* workspaces)
    // keep their own workspace map, so the row can name its type.
    final conversation =
        workspace != null && _isConversationWorkspace(workspace);
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: 8, vertical: ZListRow.gap),
      child: SwipeActionsRow(
        actions: _swipeActions(session, entry),
        trayRadius: ZRadius.field,
        childRadius: ZRadius.field,
        child: Material(
          color: highlight
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(ZRadius.field),
          child: InkWell(
            borderRadius: BorderRadius.circular(ZRadius.field),
            onTap: () => _openWorkspaceTask(session, workspace, entry, title),
            onLongPress: () => _taskActions(context, session, entry),
            // Row height follows the content: ZListRow.padding only (R5).
            child: Padding(
              padding: ZListRow.padding,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (groupDot != null) ...[
                              Container(
                                width: ZListRow.dot,
                                height: ZListRow.dot,
                                decoration: BoxDecoration(
                                  color: groupDot,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            if (unread) ...[
                              Container(
                                width: ZListRow.dot,
                                height: ZListRow.dot,
                                decoration: const BoxDecoration(
                                  color: ZColors.sky500,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ZType.bodyStrong,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            if (awaiting) ...[
                              _awaitingTag(context),
                              const SizedBox(width: 6),
                            ],
                            // Type (constant) after state (transient), and a
                            // neutral chip so it never competes with the
                            // awaiting warning tone.
                            if (conversation) ...[
                              _conversationTag(context),
                              const SizedBox(width: 6),
                            ],
                            // Read-only worktree branch (R2): display only,
                            // no tap target.
                            if (branch != null) ...[
                              TaskBranchChip(branchName: branch),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ZType.sub.copyWith(
                                  color: ZInk.faint(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  PhasePill(label: phaseLabel, phase: entry.phase, solid: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Left-swipe quick actions shared by the task rows: the same three verbs
  /// the long-press sheet offers for a fast pass over the list (归档 /
  /// 标记未读 / 删除). Delete keeps its confirmation dialog. Colors are
  /// FOREGROUND tones on the neutral tray: brand sky for archive (dark
  /// sky400 / light sky600), the sheet's neutral for read/unread, and the
  /// destructive tone for delete — same language as the sheet entries.
  ///
  /// C1 (10-05) draft awareness: a draft row (sessions-index only, no
  /// registry anchor) can never resolve a registry mutation, so the archive
  /// and unread actions are omitted entirely — unlike the sheet there is no
  /// disabled state to lean on, and a dead tap would only end in the
  /// matches=0 error. Delete stays (V4 deleteSession route). Same gate as
  /// the long-press sheet's four muted registry ops.
  List<SwipeAction> _swipeActions(DeviceSession session, SessionEntry entry) {
    final archived = entry.raw['archived'] == true;
    final unread = entry.raw['unreadAt'] != null;
    final isDraft =
        session.taskDirectory.sessionOnlyIds.contains(entry.sessionId);
    final archiveFg =
        ZInk.isDark(context) ? ZColors.sky400 : ZColors.sky600;
    return [
      if (!isDraft)
        SwipeAction(
          icon: archived ? Icons.unarchive_outlined : Icons.archive_outlined,
          label: tr(
            context,
            archived ? 'tasks.action.unarchive' : 'tasks.action.archive',
          ),
          fgColor: archiveFg,
          onTap: () => _runOp(() async {
            await session.setTaskArchived(entry.sessionId, !archived);
            await _reloadTasks(session);
          }),
        ),
      if (!isDraft)
        SwipeAction(
          icon: unread
              ? Icons.mark_email_read_outlined
              : Icons.mark_email_unread_outlined,
          label: tr(
            context,
            unread ? 'tasks.action.markRead' : 'tasks.action.markUnread',
          ),
          fgColor: ZInk.soft(context),
          onTap: () => _runOp(() async {
            await session.setTaskUnread(entry.sessionId, !unread);
            await _reloadTasks(session);
          }),
        ),
      SwipeAction(
        icon: Icons.delete_outline,
        label: tr(context, 'tasks.action.delete'),
        fgColor: ZInk.dangerTone(context),
        onTap: () => _deleteTaskDialog(session, entry),
      ),
    ];
  }

  /// `permissionTag`/`userInputTag`: 「等待确认」amber mini-pill.
  Widget _awaitingTag(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: ZColors.warning.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(ZRadius.mini),
      ),
      child: Text(
        tr(context, 'tasks.awaiting'),
        style: ZType.caption.copyWith(
          fontWeight: FontWeight.w500,
          color: ZInk.warningTone(context),
        ),
      ),
    );
  }

  /// Row-level 「对话」 chip for conversation (draft-*) sessions that the
  /// directory merges into the default card. Same neutral shape as the card
  /// header's [_kindBadge]: the row type is constant information, not a
  /// warning state.
  Widget _conversationTag(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.mini),
      ),
      child: Text(
        tr(context, 'tasks.workspaceKind.conversation'),
        style: ZType.caption.copyWith(color: ZInk.faint(context)),
      ),
    );
  }

  /// Opens a task row whatever workspace it lives in: tasks of the active
  /// workspace go straight to chat; others re-point the bridge first
  /// (workspace-bridge-open rides the taskId). The resolve → open decision
  /// is the state layer's ONE shared entry ([DeviceSession.prepareTaskOpen],
  /// also used by notification taps): null there means ownership is
  /// undeterminable — refuse to open instead of silently subscribing under
  /// the active workspace's scope, where the server rejects every command
  /// (proto.sessionNotFound dead page). An aborted open is not a failure and
  /// shows no copy.
  Future<void> _openWorkspaceTask(
    DeviceSession session,
    Map<String, dynamic>? workspace,
    SessionEntry entry,
    String title,
  ) async {
    if (workspace == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'tasks.scopeUnknown'))),
      );
      return;
    }
    final result = await session.prepareTaskOpen(entry.sessionId);
    if (result is WorkspaceOpenAborted) return;
    if (result is! WorkspaceOpenOpened) {
      if (!mounted) return;
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'tasks.scopeUnknown'))),
        );
        return;
      }
      _showWorkspaceOpenFailure(result);
      return;
    }
    if (!mounted) return;
    await _openChat(
      sessionId: entry.sessionId,
      title: title,
      pinned: entry.raw['pinned'] == true,
    );
  }

  /// The open failed: keep the user on the list instead of pushing a chat
  /// that would subscribe under the wrong scope, and say why in the locale.
  /// Only the [WorkspaceOpenRuntimeNotRunning] result means "bridge
  /// attached, runtime cold" — every other failure keeps the pre-existing
  /// unreachable copy (unclassified failures must not be re-labeled), and
  /// an [WorkspaceOpenAborted] open is not a failure: no copy at all.
  void _showWorkspaceOpenFailure(WorkspaceOpenResult result) {
    final key = switch (result) {
      WorkspaceOpenRuntimeNotRunning() => 'tasks.agentRuntimeNotRunning',
      WorkspaceOpenUnreachable() ||
      WorkspaceOpenTransportFailure() =>
        'tasks.workspaceUnreachable',
      WorkspaceOpenOpened() || WorkspaceOpenAborted() => null,
    };
    if (key == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, key))),
    );
  }

  /// Per-task token-usage cache accessor: the future is shared per task id
  /// until the next [_reloadTasks], so re-opening the sheet between reloads
  /// never re-issues the RPC.
  Future<TaskTokenUsage?> _tokenUsageOf(
    DeviceSession session,
    String taskId,
  ) =>
      _tokenUsage.putIfAbsent(taskId, () => session.taskTokenUsage(taskId));

  /// Token-usage line at the top of the task sheet (3.12.3, lazy one-shot
  /// read): total tokens compacted + model request count. Hidden while the
  /// fetch is empty (pre-3.12.3 desktops, no usage yet) — R4.
  Widget _tokenUsageLine(
    BuildContext sheetCtx,
    DeviceSession session,
    SessionEntry entry,
  ) {
    return FutureBuilder<TaskTokenUsage?>(
      future: _tokenUsageOf(session, entry.sessionId),
      builder: (context, snap) {
        final usage = snap.data;
        if (usage == null ||
            (usage.totalTokens <= 0 && usage.modelRequestCount <= 0)) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
          child: Text(
            trP(context, 'tasks.tokenUsageLine', [
              compactTokens(context, usage.totalTokens),
              '${usage.modelRequestCount}',
            ]),
            style: ZType.sub.copyWith(color: ZInk.faint(context)),
          ),
        );
      },
    );
  }

  /// Long-press action sheet, task-item menu:
  /// 停止/暂停/继续 (phase-gated) + 置顶 / 重命名 / 归档 / 标记未读 / 删除.
  /// Delete carries the confirm dialog (records cannot be
  /// recovered). Metadata ops run on the zcode-task channel and refresh the
  /// list (the relay also pushes workspace-list-updated).
  ///
  /// Multi-copy rows (registry pollution, design 10-16
  /// multi-copy-home-correction) additionally offer 归属纠正 just above
  /// delete — the user adjudication channel ([_correctHomeDialog]).
  ///
  /// C1 (10-05) draft awareness: a row that exists only in the live
  /// sessions-index (fork draft, no registry anchor) can never resolve a
  /// task mutation (matches=0, research.md R2) — the four registry ops are
  /// disabled (same mute style as the phase gates) while delete stays
  /// available and routes to the V4 session command (see
  /// [_deleteTaskDialog]). sessionOnlyIds is read fresh at sheet open, the
  /// same read point as every other directory view.
  Future<void> _taskActions(
    BuildContext context,
    DeviceSession session,
    SessionEntry entry,
  ) async {
    HapticFeedback.mediumImpact();
    final running = entry.phase == 'running' || entry.phase == 'prewarming';
    final paused = entry.phase.toLowerCase().contains('pause');
    final pinned = entry.raw['pinned'] == true;
    final archived = entry.raw['archived'] == true;
    final unread = entry.raw['unreadAt'] != null;
    final isDraft =
        session.taskDirectory.sessionOnlyIds.contains(entry.sessionId);
    // Copy count of the id (registry pollution, 10-16): > 1 gates the
    // 归属纠正 entry. Read at sheet open — the same read point as every
    // other directory view.
    final copyCount = session.relayTasks
        .where((t) => '${t['taskId'] ?? ''}' == entry.sessionId)
        .length;
    // B9 object title: which workspace the task belongs to, resolved from
    // the merged directory (the same source the grouped views use) with the
    // row's own origin fields as fallback.
    String? wsKey;
    for (final (e, key) in session.taskDirectory.allEntries()) {
      if (e.sessionId == entry.sessionId) {
        wsKey = key;
        break;
      }
    }
    final ws = TaskDirectory.workspaceForKey(session.workspaces, entry, wsKey);
    final sheetTitle = entry.title.trim().isEmpty
        ? tr(context, 'tasks.untitled')
        : entry.title;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Object title row (B9): the target task first, so a
              // long-press never acts on a guessed row. Same tier as the
              // delete dialog's title; workspace chip beside it.
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        sheetTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ZType.title,
                      ),
                    ),
                    if (ws != null) ...[
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        // Chip caps its share; a long workspace name
                        // ellipsizes instead of squeezing the title out.
                        constraints: const BoxConstraints(maxWidth: 96),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: ZInk.tile(sheetCtx),
                            borderRadius:
                                BorderRadius.circular(ZRadius.mini),
                          ),
                          child: Text(
                            workspaceTitle(ws),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ZType.caption
                                .copyWith(color: ZInk.faint(sheetCtx)),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _tokenUsageLine(sheetCtx, session, entry),
              // Error TraceID copy (D5, F7): the task-meta `lastError` is
              // the only wire carrier traceId has — the conversation
              // snapshot's status lastError has no such field. Defensive:
              // renders only when the row actually carries one.
              if (entry.lastErrorTraceId case final traceId?)
                ListTile(
                  leading: const Icon(Icons.tag_outlined),
                  title: Text(tr(sheetCtx, 'tasks.action.copyTraceId')),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    Clipboard.setData(ClipboardData(text: traceId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(tr(context, 'tasks.traceIdCopied')),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.stop_circle_outlined),
                title: Text(tr(sheetCtx, 'tasks.stop')),
                enabled: running,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _runOp(() => session.stopTask(entry.sessionId));
                },
              ),
              ListTile(
                leading: const Icon(Icons.pause_circle_outline),
                title: Text(tr(sheetCtx, 'tasks.pause')),
                enabled: running,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _runOp(() => session.pauseTask(entry.sessionId));
                },
              ),
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: Text(tr(sheetCtx, 'tasks.resume')),
                enabled: paused,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _runOp(() => session.resumeTask(entry.sessionId));
                },
              ),
              ListTile(
                leading: Icon(
                  pinned ? Icons.push_pin_outlined : Icons.push_pin_outlined,
                ),
                title: Text(
                  tr(
                    sheetCtx,
                    pinned ? 'tasks.action.unpin' : 'tasks.action.pin',
                  ),
                ),
                enabled: !isDraft,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _runOp(() async {
                    await session.setTaskPinned(entry.sessionId, !pinned);
                    await _reloadTasks(session);
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: Text(tr(sheetCtx, 'tasks.action.rename')),
                enabled: !isDraft,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _renameTaskDialog(session, entry);
                },
              ),
              ListTile(
                leading: archived
                    ? const Icon(Icons.unarchive_outlined)
                    : const Icon(Icons.archive_outlined),
                title: Text(
                  tr(
                    sheetCtx,
                    archived
                        ? 'tasks.action.unarchive'
                        : 'tasks.action.archive',
                  ),
                ),
                enabled: !isDraft,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _runOp(() async {
                    await session.setTaskArchived(entry.sessionId, !archived);
                    await _reloadTasks(session);
                  });
                },
              ),
              ListTile(
                leading: Icon(
                  unread
                      ? Icons.mark_email_read_outlined
                      : Icons.mark_email_unread_outlined,
                ),
                title: Text(
                  tr(
                    sheetCtx,
                    unread
                        ? 'tasks.action.markRead'
                        : 'tasks.action.markUnread',
                  ),
                ),
                enabled: !isDraft,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _runOp(() async {
                    await session.setTaskUnread(entry.sessionId, !unread);
                    await _reloadTasks(session);
                  });
                },
              ),
              if (copyCount > 1)
                ListTile(
                  leading: const Icon(Icons.home_work_outlined),
                  title: Text(tr(sheetCtx, 'tasks.action.correctHome')),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _correctHomeDialog(session, entry);
                  },
                ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: ZInk.dangerTone(sheetCtx),
                ),
                title: Text(
                  tr(sheetCtx, 'tasks.action.delete'),
                  style: TextStyle(color: ZInk.dangerTone(sheetCtx)),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _deleteTaskDialog(session, entry);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 归属纠正 (design 10-16 multi-copy-home-correction R2/层 3): the
  /// multi-copy id's rows are listed as radio candidates (workspace name +
  /// status + time). The row the list currently shows — the directory's
  /// anchored/cold pick, [DeviceSession.relayHomeRowOf] — is preselected
  /// AND tagged 当前显示 (one selection, two uses). Confirm writes the
  /// anchor (source ④, [DeviceSession.correctTaskHome]) and optionally
  /// deletes the other copies with their OWN per-copy scopes; the list
  /// reloads right after, like the other sheet flows.
  Future<void> _correctHomeDialog(
    DeviceSession session,
    SessionEntry entry,
  ) async {
    final candidates = [
      for (final task in session.relayTasks)
        if ('${task['taskId'] ?? ''}' == entry.sessionId) task,
    ];
    if (candidates.length < 2) return; // sheet was opened on a stale count
    // Locate the shown row among the candidates by copy identity
    // (workspacePath+workspaceIdentity field equality) — NOT by comparing
    // candidate keys against the group key: relay row keys are
    // path-spelled while the group key may be canonical workspaceKeyOf
    // spelling, so a raw comparison never matches (design P2-7).
    final shownRow = session.relayHomeRowOf(entry.sessionId);
    var shownIndex = 0;
    if (shownRow != null) {
      for (var i = 0; i < candidates.length; i++) {
        if (_sameRelayCopy(candidates[i], shownRow)) {
          shownIndex = i;
          break;
        }
      }
    }
    // Workspace display name: the listed workspace matched by
    // workspacePath, else [workspaceTitle]'s own fallback chain (path last
    // segment → identity).
    String candidateTitle(Map<String, dynamic> task) {
      for (final ws in session.workspaces) {
        if (task['workspacePath'] != null &&
            ws['workspacePath'] == task['workspacePath']) {
          return workspaceTitle(ws);
        }
      }
      return workspaceTitle(task);
    }

    var chosen = shownIndex;
    var deleteCopies = false;
    final result = await showDialog<(int, bool)>(
      context: context,
      useRootNavigator: false,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          title: Text(tr(dialogCtx, 'tasks.correctHome.title')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioGroup<int>(
                  groupValue: chosen,
                  onChanged: (v) =>
                      setDialogState(() => chosen = v ?? chosen),
                  child: Column(
                    children: [
                      for (var i = 0; i < candidates.length; i++)
                        RadioListTile<int>(
                          value: i,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  candidateTitle(candidates[i]),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (i == shownIndex)
                                Text(
                                  tr(dialogCtx, 'tasks.correctHome.current'),
                                  style: ZType.caption
                                      .copyWith(color: ZInk.faint(dialogCtx)),
                                ),
                            ],
                          ),
                          subtitle: Text(
                            _copySubtitle(dialogCtx, candidates[i]),
                            style: ZType.caption
                                .copyWith(color: ZInk.faint(dialogCtx)),
                          ),
                        ),
                    ],
                  ),
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  value: deleteCopies,
                  onChanged: (v) =>
                      setDialogState(() => deleteCopies = v ?? false),
                  title: Text(
                    tr(dialogCtx, 'tasks.correctHome.deleteCopies'),
                    style: ZType.sub.copyWith(color: ZInk.faint(dialogCtx)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: Text(tr(dialogCtx, 'common.cancel')),
            ),
            FilledButton(
              // Danger style once the destructive option is on (the delete
              // dialog's recipe): copy deletion cannot be recovered.
              style: deleteCopies
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(dialogCtx).colorScheme.error,
                    )
                  : null,
              onPressed: () =>
                  Navigator.of(dialogCtx).pop((chosen, deleteCopies)),
              child: Text(tr(dialogCtx, 'common.save')),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await _runOp(() async {
      await session.correctTaskHome(
        entry.sessionId,
        candidates[result.$1],
        deleteOtherCopies: result.$2,
      );
      await _reloadTasks(session);
    });
  }

  /// Whether two relay task maps address the SAME registry copy — the
  /// (workspacePath, workspaceIdentity) pair the mutation scope triple
  /// uses. Field equality, never `identical`: the overview rebuilds every
  /// relay map on each landing, so the dialog's picked instance can be
  /// stale by confirm time (check P1-1).
  static bool _sameRelayCopy(Map<String, dynamic> a, Map<String, dynamic> b) =>
      '${a['workspacePath'] ?? ''}' == '${b['workspacePath'] ?? ''}' &&
      '${a['workspaceIdentity'] ?? ''}' == '${b['workspaceIdentity'] ?? ''}';

  /// One correction-candidate line's subtitle: the list rows' own
  /// formatters — the phase-pill vocabulary (mapped off displayStatus) +
  /// the compact relative time.
  String _copySubtitle(BuildContext ctx, Map<String, dynamic> task) {
    final e = SessionEntry.fromRelayTask(task);
    return '${_phaseVisual(e.phase).$1}'
        ' · ${relativeTimeShort(ctx, e.lastActivityAt)}';
  }

  /// Task-rename flow (inline on web; modal here) — placeholder
  /// 「任务名称」.
  Future<void> _renameTaskDialog(
    DeviceSession session,
    SessionEntry entry,
  ) async {
    final controller = TextEditingController(text: entry.title);
    final title = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(tr(dialogCtx, 'tasks.action.rename')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: tr(dialogCtx, 'tasks.renamePlaceholder'),
          ),
          onSubmitted: (v) => Navigator.of(dialogCtx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(tr(dialogCtx, 'common.cancel')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogCtx).pop(controller.text.trim()),
            child: Text(tr(dialogCtx, 'common.save')),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty || title == entry.title) return;
    await _runOp(() async {
      await session.renameTask(entry.sessionId, title);
      await _reloadTasks(session);
    });
  }

  /// Delete confirmation:
  /// 「删除这个任务？…会从当前工作区移除，现有记录无法恢复。」
  ///
  /// C1 (10-05) routing: a draft row (sessions-only, no registry anchor)
  /// goes straight to the V4 session command — the task mutation can never
  /// resolve it (research-emulator.md A-1/A-2). Registered rows keep
  /// deleteTask, with ONE fallback to the session command when the registry
  /// resolve comes back empty at delete time (the draft-materialize edge,
  /// design D4). The draft verdict is re-read at delete time, not carried
  /// over from the sheet — the directory can change while the dialog is up.
  ///
  /// Archived rows (≥3.17.1) take the three-phase permanent delete
  /// (design 11-11): preview → confirmed execute. Below 3.17.1 the archived
  /// bit still routes to deleteTask, exactly as before.
  Future<void> _deleteTaskDialog(
    DeviceSession session,
    SessionEntry entry,
  ) async {
    final title = entry.title.trim().isEmpty
        ? tr(context, 'tasks.untitled')
        : entry.title;
    final viaArchivedDelete =
        entry.raw['archived'] == true && session.capabilities.archivedDelete;
    if (viaArchivedDelete) {
      await _archivedDeleteDialog(session, entry, title);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(tr(dialogCtx, 'tasks.action.deleteTitle')),
        content: Text(trP(dialogCtx, 'tasks.action.deleteDesc', [title])),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(tr(dialogCtx, 'common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(tr(dialogCtx, 'tasks.action.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final isDraft =
        session.taskDirectory.sessionOnlyIds.contains(entry.sessionId);
    // Archived rows route through the restricted 3.17.1 delete (the official
    // web's archive view does the same — delete-archived kind); the desktop
    // refuses live rows there, so only the archived bit decides.
    await _runOp(() async {
      if (isDraft) {
        await session.deleteSession(entry.sessionId);
      } else {
        try {
          await session.deleteTask(entry.sessionId);
        } catch (e) {
          if (!isTaskResolveFailure(e)) rethrow;
          await session.deleteSession(entry.sessionId);
        }
      }
      await _reloadTasks(session);
      if (_paneSessionId == entry.sessionId) {
        setState(() {
          _paneSessionId = null;
          _paneTitle = null;
        });
      }
    });
  }

  /// Three-phase permanent delete of one archived row (design 11-11 §4).
  ///
  /// ONE dialog, two states (official shape: prepare/update in place, no
  /// second window): it opens in the checking state (confirmation disabled,
  /// `archives.checking`), the preview runs behind it, then it flips to the
  /// confirmation state. A blocked preview closes the dialog into the
  /// official `archives.reason.*` toast instead of ever letting the user
  /// confirm a doomed delete. An unknown-method reply degrades to the
  /// pre-3.18.0 [deleteArchived] path — same dialog and copy as before.
  Future<void> _archivedDeleteDialog(
    DeviceSession session,
    SessionEntry entry,
    String title,
  ) async {
    final outcome = await showDialog<_ArchivedDeleteOutcome>(
      context: context,
      useRootNavigator: false,
      builder: (_) => _ArchivedDeleteDialog(
        session: session,
        taskId: entry.sessionId,
        title: title,
      ),
    );
    if (!mounted || outcome == null) return;
    switch (outcome) {
      case _ArchivedDeleteDegraded():
        await _deleteArchivedLegacy(session, entry, title);
      case _ArchivedDeleteBlocked(:final reason):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_archiveFailureCopy(context, 'blocked', reason)),
          ),
        );
      case _ArchivedDeleteConfirmed(:final preview):
        await _executeArchivedDelete(session, entry, preview);
    }
  }

  /// Execute step of the three-phase delete: only `status == "deleted"`
  /// counts as success; blocked/incomplete surface the reason toast. The
  /// right pane clears when a DELETED id (cascade included) is what it shows.
  Future<void> _executeArchivedDelete(
    DeviceSession session,
    SessionEntry entry,
    ArchivalDeletionPreview preview,
  ) {
    final deletedIds = <String>{};
    return _runOp(() async {
      final ArchivalDeletionResult res;
      try {
        res = await session.executeArchiveDeletion(preview, entry.sessionId);
      } on ArchivalPreviewUnavailable {
        // Both methods ship together on 3.18.0; a degrade here is a
        // cross-version race at worst. Count it as this task's failure and
        // stop — never re-fall-back to the batch/legacy delete.
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'tasks.archive.incomplete'))),
        );
        return;
      }
      if (res.status == 'deleted') {
        deletedIds.addAll(res.sessionIds);
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_archiveFailureCopy(context, res.status, res.reason)),
          ),
        );
      }
      await _reloadTasks(session);
      if (deletedIds.contains(_paneSessionId)) {
        setState(() {
          _paneSessionId = null;
          _paneTitle = null;
        });
      }
    });
  }

  /// Pre-3.18.0 archived-row delete: confirmation dialog + `deleteArchived`
  /// (unchanged behavior — the degrade path).
  Future<void> _deleteArchivedLegacy(
    DeviceSession session,
    SessionEntry entry,
    String title,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(tr(dialogCtx, 'tasks.action.deleteTitle')),
        content: Text(trP(dialogCtx, 'tasks.action.deleteDesc', [title])),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(tr(dialogCtx, 'common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(tr(dialogCtx, 'tasks.action.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runOp(() async {
      final res = await session.deleteArchived(entry.sessionId);
      if (res == null) {
        // The row changed underneath (unarchived / deleted elsewhere):
        // nothing was deleted — surface the skip and refresh so the row's
        // true state replaces the stale archived bit.
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr(context, 'tasks.archive.deleteSkipped')),
          ),
        );
        await _reloadTasks(session);
        return;
      }
      await _reloadTasks(session);
      if (_paneSessionId == entry.sessionId) {
        setState(() {
          _paneSessionId = null;
          _paneTitle = null;
        });
      }
    });
  }

  /// Opens a task chat. On ≥768px the chat lands in the right pane (the
  /// native connection STAYS live — one sid, one terminal, and we are it);
  /// on phones it pushes the full-screen page. Falls back to the WebView
  /// deep link when no protocol session exists.
  Future<void> _openChat({
    String? sessionId,
    required String title,
    String? initialComposerText,
    bool pinned = false,
  }) async {
    final session = _session;
    if (session == null || session.status == DeviceStatus.disconnected) {
      await _openRemote(targetSessionId: sessionId, targetTitle: title);
      return;
    }
    await widget.store.touch(widget.device.id);
    if (!mounted) return;
    if (MediaQuery.sizeOf(context).width >= kDualPaneBreakpoint) {
      setState(() {
        _paneSessionId = sessionId;
        _paneTitle = title;
        _paneInitialComposerText = initialComposerText;
        _panePinned = pinned;
        _paneDraftWorkspacePath =
            sessionId == null ? session.workspacePath : null;
      });
      return;
    }
    await Navigator.of(context).push(
      zRoute(
        (_) => ChatPage(
          host: session,
          sessionId: sessionId,
          title: title,
          theme: widget.theme,
          initialComposerText: initialComposerText,
          initialPinned: pinned,
          draftWorkspacePath: sessionId == null ? session.workspacePath : null,
          workspaceLabel: session.activeWorkspace != null
              ? workspaceTitle(session.activeWorkspace!)
              : null,
          onOpenUsage: () => _openUsage(session),
          offPeakHost: session,
          onOpenOffPeak: () => _openOffPeak(session),
        ),
      ),
    );
  }

  /// WebView fallback (overflow menu): suspend the native connection, open
  /// the remote page deep-linked to a session, resume ~1s after it pops.
  ///
  /// B-01: the suspend wait is visible ([_handoverBusy] drives the banner
  /// progress and swallows re-entry) and a failed suspend only toasts — the
  /// push is skipped so a WebView that cannot pair never opens.
  Future<void> _openRemote({
    String? targetSessionId,
    String? targetTitle,
  }) async {
    if (_handoverBusy) return;
    var ready = false;
    setState(() => _handoverBusy = true);
    try {
      await widget.store.touch(widget.device.id);
      await widget.hub.suspend(widget.device.id);
      ready = true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'remote.handoverFailed'))),
        );
      }
    } finally {
      if (mounted) setState(() => _handoverBusy = false);
    }
    if (!ready || !mounted) return;
    await Navigator.of(context).push(
      zRoute(
        (_) => RemotePage(
          device: widget.device,
          targetSessionId: targetSessionId,
          targetTitle: targetTitle,
        ),
      ),
    );
    widget.hub.scheduleResume(widget.device);
  }

  /// Unified reload entry: every [DeviceSession.reloadTasks] call on this
  /// page goes through here so the replace window (the RPC round-trip)
  /// flips [_reloading] in and out — the list bodies key their
  /// IgnorePointer off it. Also drops the per-task token-usage futures: a
  /// refresh must re-issue the query (a running task's numbers grow, and a
  /// first-fetch miss deserves another chance) instead of pinning the
  /// first answer for the page's lifetime.
  Future<void> _reloadTasks(DeviceSession session) async {
    _tokenUsage.clear();
    setState(() => _reloading = true);
    try {
      await session.reloadTasks();
    } finally {
      if (mounted) setState(() => _reloading = false);
    }
  }

  Future<void> _runOp(Future<void> Function() op) async {
    // Read the locale before the async gap: [businessErrorCopy] takes the
    // UiSettings locale tag, and must not receive a BuildContext.
    final locale = UiSettingsProvider.of(context)?.locale ?? 'zh-CN';
    try {
      await op();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            // A suspended deleteSession is still owned by the ledger: the
            // entry keeps its tasks.opFailed prefix but announces the
            // pending confirmation, never the raw sentinel (task 11-13).
            e is CommandSuspendedException
                ? trP(context, 'tasks.opFailed', [
                    tr(context, 'chat.suspend.pending'),
                  ])
                // Same humanized-error chain as chat's _run: classify the
                // raw message (resolve-failure / busy) before falling back
                // to the generic prefix.
                : businessErrorCopy('$e', locale) ??
                      trP(context, 'tasks.opFailed', ['$e']),
          ),
        ),
      );
    }
  }

  void _onMenu(String v) {
    final session = _session;
    switch (v) {
      case 'archive':
        setState(() => _showArchived = !_showArchived);
      case 'deskSet':
        if (session == null) return;
        Navigator.of(context).push(zRoute(
          (_) => DesktopSettingsPage(session: session),
        ));
      case 'defaults':
        if (session == null) return;
        Navigator.of(context).push(zRoute(
          (_) => NewTaskDefaultsPage(session: session),
        ));
      case 'usage':
        if (session == null) return;
        Navigator.of(context).push(
          zRoute((_) => DeviceUsagePage(session: session)),
        );
      case 'providers':
        if (session == null) return;
        Navigator.of(context).push(
          zRoute(
            (_) => ModelProvidersPage(session: session),
          ),
        );
      case 'automations':
        Navigator.of(context).push(
          zRoute(
            (_) => AutomationsPage(
              store: widget.store,
              hub: widget.hub,
              initialDeviceId: widget.device.id,
            ),
          ),
        );
      case 'offPeak':
        Navigator.of(context).push(
          zRoute(
            (_) => OffPeakPage(
              store: widget.store,
              hub: widget.hub,
              device: widget.device,
            ),
          ),
        );
      case 'web':
        _openRemote();
    }
  }

  Widget _fallback(BuildContext context, DeviceSession? session) {
    final connecting =
        session != null &&
        session.status != DeviceStatus.error &&
        session.status != DeviceStatus.disconnected &&
        (session.status == DeviceStatus.connecting || session.openingWorkspace);
    if (connecting) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Column(
            children: [
              const CircularProgressIndicator(strokeWidth: 2),
              const SizedBox(height: 16),
              Text(
                tr(context, 'tasks.loading'),
                style: ZType.body.copyWith(color: ZInk.faint(context)),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.cloud_off, size: 44, color: ZInk.ghost(context)),
            const SizedBox(height: 16),
            Text(
              tr(context, 'tasks.fallback.title'),
              style: ZType.heading.copyWith(color: ZInk.solid(context)),
            ),
            const SizedBox(height: 8),
            Text(
              _errorCopy(context, session),
              textAlign: TextAlign.center,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: ZType.body.copyWith(color: ZInk.faint(context)),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _openRemote(),
              child: Text(tr(context, 'tasks.openWeb')),
            ),
          ],
        ),
      ),
    );
  }

  (String, Color) _phaseVisual(String phase) {
    switch (phase) {
      case 'running':
        return (tr(context, 'phase.running'), ZColors.sky500);
      case 'prewarming':
        return (tr(context, 'phase.prewarming'), ZColors.sky400);
      case 'completedSuccess':
        return (tr(context, 'phase.completedSuccess'), ZColors.success);
      case 'completedInterrupted':
        return (tr(context, 'phase.completedInterrupted'), ZColors.neutral500);
      case 'error':
        return (tr(context, 'phase.error'), ZColors.danger);
      case 'draft':
        return (tr(context, 'phase.draft'), ZColors.neutral400);
      case 'idle':
        return (tr(context, 'phase.idle'), ZColors.neutral400);
      default:
        if (phase.toLowerCase().contains('pause')) {
          return (tr(context, 'phase.paused'), ZColors.neutral500);
        }
        return (phase, ZColors.neutral400);
    }
  }
}

/// Degraded-link copy. First available source wins: the app-error reason
/// (`remote.failure.*`) → the typed workspace-open failure → the raw
/// session error text → the generic fallback body.
String _errorCopy(BuildContext context, DeviceSession? session) {
  final reason = session?.failureReason;
  if (reason != null) {
    final localized = tr(context, 'remote.failure.$reason');
    if (localized != 'remote.failure.$reason') return localized;
  }
  final failure = session?.lastWorkspaceOpenFailure;
  switch (failure) {
    case WorkspaceOpenRuntimeNotRunning():
      return tr(context, 'tasks.agentRuntimeNotRunning');
    case WorkspaceOpenUnreachable():
      return tr(context, 'tasks.workspaceUnreachable');
    case WorkspaceOpenTransportFailure(:final error):
      return '$error';
    case WorkspaceOpenOpened():
    case WorkspaceOpenAborted():
    case null:
      return session?.error ?? tr(context, 'tasks.fallback.body');
  }
}

/// Thin indeterminate bar over the pointer-dead replace window (B-02): the
/// same 2dp shape the composer's upload bar uses, on the shared progress
/// tokens.
class _ReloadBar extends StatelessWidget {
  const _ReloadBar();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 2,
      child: LinearProgressIndicator(
        minHeight: 2,
        backgroundColor: ZInk.barTrack(context),
        valueColor: AlwaysStoppedAnimation(ZInk.usageBlue(context)),
      ),
    );
  }
}

/// Connection status card at the top of the list (mobile layout).
/// Always visible: the healthy link shows the green online state plus the
/// explanation copy; degraded states add retry + web fallback actions.
class _ConnectionBanner extends StatelessWidget {
  final DeviceSession? session;

  /// WebView handover in flight (B-01): the fallback button reports the wait
  /// instead of accepting a second tap.
  final bool handoverBusy;

  /// Retry rides the page's unified reload entry (token-cache drop +
  /// replace window), not a bare `session.reloadTasks()`.
  final Future<void> Function() onRetry;
  final Future<void> Function() onWeb;

  const _ConnectionBanner({
    required this.session,
    required this.handoverBusy,
    required this.onRetry,
    required this.onWeb,
  });

  /// Failure-state copy: the app-error/close-code reason (the same
  /// localized text the web page shows), else the typed open failure, else
  /// the raw session error — see [_errorCopy].
  static String _failureBody(BuildContext context, DeviceSession s) =>
      _errorCopy(context, s);

  bool get _online =>
      session != null &&
      session!.status == DeviceStatus.connected &&
      !session!.kicked &&
      // A live stage outranks the healthy-looking status: a post-drop redial
      // keeps `connected` on purpose (the link is not torn down), and showing
      // the green "all good" card through it would hide the reconnect.
      session!.connectionStage == null &&
      (session!.error?.isEmpty ?? true) &&
      session!.lastWorkspaceOpenFailure == null;

  @override
  Widget build(BuildContext context) {
    if (_online) return _onlineCard(context);
    return _degradedCard(context);
  }

  /// Online state: explanation card only (title + green subtitle
  /// already live in the mobile AppBar).
  Widget _onlineCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZSpacing.card),
        child: Text(
          tr(context, 'tasks.banner.onlineDesc'),
          style: ZType.body.copyWith(height: 1.6, color: ZInk.faint(context)),
        ),
      ),
    );
  }

  Widget _degradedCard(BuildContext context) {
    final s = session;
    String title;
    String body;
    IconData icon;
    Color color;
    if (s == null) {
      title = tr(context, 'status.offline');
      body = tr(context, 'tasks.banner.nativeOff');
      icon = Icons.cloud_off;
      color = ZColors.neutral400;
    } else if (s.kicked) {
      title = tr(context, 'status.kicked');
      body = tr(context, 'tasks.banner.kicked');
      icon = Icons.phonelink_erase_outlined;
      color = ZInk.dangerTone(context);
    } else if (s.connectionStage != null) {
      // B-03/V4: the stage wins over the coarse status — the production shapes
      // of the three stages do NOT sit on `status == connecting` (a drop
      // redial keeps `connected`, a forced rebuild suspends to `disconnected`),
      // so gating on that status hid every one of them. `kicked` above stays
      // first: the terminal state must never be papered over by a stage.
      final stage = s.connectionStage;
      title = tr(context, 'status.stage.$stage');
      body = tr(context, 'status.stage.$stage.body');
      icon = Icons.sync;
      color = ZColors.sky400;
    } else if (s.status == DeviceStatus.connecting) {
      title = tr(context, 'status.connecting');
      body = tr(context, 'tasks.banner.connecting');
      icon = Icons.sync;
      color = ZColors.sky400;
    } else {
      title = tr(context, 'tasks.fallback.title');
      body = _failureBody(context, s);
      icon = Icons.cloud_off;
      color = ZInk.dangerTone(context);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZSpacing.card),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: ZType.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: ZInk.solid(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: ZType.sub.copyWith(color: ZInk.faint(context)),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Flexible(
                        child: FilledButton.tonal(
                          onPressed: onRetry,
                          child: Text(
                            tr(context, 'tasks.retry'),
                            style: ZType.sub,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: TextButton(
                          // B-01: the handover suspends the link first; the
                          // button reports that wait and refuses re-entry.
                          onPressed: handoverBusy ? null : onWeb,
                          child: handoverBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : Text(
                                  tr(context, 'tasks.openWeb'),
                                  style: ZType.sub,
                                ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Copy for a non-deleted outcome — ONE fallback function shared by the
/// preview `blockedReason` (six-value enum) and the execute `reason` (free
/// string). Unknown or null values fall back to `unavailable` for blocked
/// outcomes; incomplete outcomes take the official `archives.incomplete`
/// retry copy regardless of the free-form reason (design 11-11 §4).
String _archiveFailureCopy(
  BuildContext context,
  String status,
  String? reason,
) {
  if (status == 'incomplete') {
    return tr(context, 'tasks.archive.incomplete');
  }
  const known = {
    'running',
    'in-use',
    'not-found',
    'not-archived',
    'changed',
    'unavailable',
  };
  final key = known.contains(reason) ? reason! : 'unavailable';
  return tr(context, 'tasks.archive.reason.$key');
}

/// Outcome of [_ArchivedDeleteDialog.show]: the dialog either confirmed with
/// a preview, found the delete blocked, or discovered the desktop lacks the
/// controller methods (degrade).
sealed class _ArchivedDeleteOutcome {
  const _ArchivedDeleteOutcome();
}

class _ArchivedDeleteConfirmed extends _ArchivedDeleteOutcome {
  const _ArchivedDeleteConfirmed(this.preview);
  final ArchivalDeletionPreview preview;
}

class _ArchivedDeleteBlocked extends _ArchivedDeleteOutcome {
  const _ArchivedDeleteBlocked(this.reason);

  /// `blockedReason`, already trimmed to the six-value enum by the desktop.
  final String? reason;
}

class _ArchivedDeleteDegraded extends _ArchivedDeleteOutcome {
  const _ArchivedDeleteDegraded();
}

/// One archived-row permanent-delete dialog that evolves in place (design
/// 11-11 §4): the checking state is the dialog itself, preview runs while it
/// is up, and the content flips to the confirmation state when the answer
/// lands. Popping the dialog while checking abandons the operation — the
/// preview result is discarded and no execute runs.
class _ArchivedDeleteDialog extends StatefulWidget {
  const _ArchivedDeleteDialog({
    required this.session,
    required this.taskId,
    required this.title,
  });

  final DeviceSession session;
  final String taskId;
  final String title;

  @override
  State<_ArchivedDeleteDialog> createState() => _ArchivedDeleteDialogState();
}

class _ArchivedDeleteDialogState extends State<_ArchivedDeleteDialog> {
  ArchivalDeletionPreview? _preview;

  @override
  void initState() {
    super.initState();
    unawaited(_runPreview());
  }

  Future<void> _runPreview() async {
    try {
      final preview =
          await widget.session.previewArchiveDeletion(widget.taskId);
      if (!mounted) return;
      if (preview.blockedReason != null) {
        Navigator.of(context)
            .pop(_ArchivedDeleteBlocked(preview.blockedReason));
        return;
      }
      setState(() => _preview = preview);
    } on ArchivalPreviewUnavailable {
      if (!mounted) return;
      Navigator.of(context).pop(const _ArchivedDeleteDegraded());
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        SnackBar(
          // The controller's session-data.unavailable refusal maps to the
          // official archives.reason.unavailable copy (design 11-11 §2 —
          // the legacy soft-delete path must NOT take over); every other
          // failure keeps the generic degraded-link chain.
          content: Text(
            isArchiveDeletionUnavailableError(e)
                ? _archiveFailureCopy(context, 'blocked', null)
                : _errorCopy(context, widget.session),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    if (preview == null) {
      // Checking state: the dialog is already up, the confirmation cannot be
      // pressed yet (official archives.checking).
      return AlertDialog(
        title: Text(tr(context, 'tasks.action.deleteTitle')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(trP(context, 'tasks.archive.checking', ['1', '1'])),
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr(context, 'common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: null,
            child: Text(tr(context, 'tasks.action.delete')),
          ),
        ],
      );
    }
    final children = preview.sessionIds.length - 1;
    return AlertDialog(
      title: Text(tr(context, 'tasks.action.deleteTitle')),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(trP(
              context,
              'tasks.archive.deleteItem',
              // $0/$1/$2 = title / children / files (official order).
              [widget.title, '$children', '${preview.deletedFiles}'],
            )),
            if (preview.incomplete) ...[
              const SizedBox(height: 8),
              Text(tr(context, 'tasks.archive.incomplete')),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr(context, 'common.cancel')),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () =>
              Navigator.of(context).pop(_ArchivedDeleteConfirmed(preview)),
          child: Text(tr(context, 'tasks.action.delete')),
        ),
      ],
    );
  }
}

/// Outcome of [_ArchiveClearDialog]: preview-degraded (unknown method → the
/// legacy batch path), controller unavailable for another reason
/// (`session-data.unavailable` → official unavailable toast), or a completed
/// run with the three per-status counters plus the deleted id set.
sealed class _ArchiveClearOutcome {
  const _ArchiveClearOutcome();
}

class _ArchiveClearDegraded extends _ArchiveClearOutcome {
  const _ArchiveClearDegraded();
}

class _ArchiveClearUnavailable extends _ArchiveClearOutcome {
  const _ArchiveClearUnavailable();
}

class _ArchiveClearDone extends _ArchiveClearOutcome {
  const _ArchiveClearDone({
    required this.ok,
    required this.failed,
    required this.skipped,
    required this.deletedIds,
  });

  final int ok;
  final int failed;
  final int skipped;
  final Set<String> deletedIds;
}

/// One dialog for「全部删除」that previews every taskId in place, then flips
/// to confirmation, then executes one by one updating the same counter
/// (design 11-11 §4; the official flow does the same per task, only the
/// shell is one dialog instead of N).
///
/// - Popping while previewing abandons the operation (no execute runs).
/// - All-blocked preview (nothing deletable) skips confirmation entirely and
///   reports the all-skipped aggregate straight into the existing
///   `archives.result` toast.
/// - An execute that throws counts as that task's FAILED and stops the loop
///   — never falls back to the legacy batch (already-deleted ids would be
///   double-counted).
class _ArchiveClearDialog extends StatefulWidget {
  const _ArchiveClearDialog({
    required this.session,
    required this.taskIds,
    required this.titles,
  });

  final DeviceSession session;
  final List<String> taskIds;
  final Map<String, String> titles;

  @override
  State<_ArchiveClearDialog> createState() => _ArchiveClearDialogState();
}

class _ArchiveClearDialogState extends State<_ArchiveClearDialog> {
  /// taskId → preview for the tasks that passed the precheck.
  final Map<String, ArchivalDeletionPreview> _previews = {};
  final Set<String> _skippedIds = {};
  final Set<String> _deletedIds = {};
  int _checked = 0;
  bool _confirming = false;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    unawaited(_runPreview());
  }

  Future<void> _runPreview() async {
    for (final id in widget.taskIds) {
      if (!mounted) return;
      try {
        final preview = await widget.session.previewArchiveDeletion(id);
        if (!mounted) return;
        if (preview.blockedReason != null) {
          _skippedIds.add(id);
        } else {
          _previews[id] = preview;
        }
      } on ArchivalPreviewUnavailable {
        if (!mounted) return;
        Navigator.of(context).pop(const _ArchiveClearDegraded());
        return;
      } catch (_) {
        if (!mounted) return;
        Navigator.of(context).pop(const _ArchiveClearUnavailable());
        return;
      }
      _checked++;
      setState(() {});
    }
    if (!mounted) return;
    if (_previews.isEmpty) {
      // Nothing deletable: no confirmation, report the all-skipped aggregate
      // straight away (the official shape counts blocked rows as skipped).
      Navigator.of(context).pop(_ArchiveClearDone(
        ok: 0,
        failed: 0,
        skipped: widget.taskIds.length,
        deletedIds: const {},
      ));
      return;
    }
    setState(() => _confirming = true);
  }

  Future<void> _runExecute() async {
    setState(() => _running = true);
    var ok = 0;
    var failed = 0;
    for (final id in _previews.keys.toList()) {
      if (!mounted) return;
      try {
        final res =
            await widget.session.executeArchiveDeletion(_previews[id]!, id);
        if (!mounted) return;
        switch (res.status) {
          case 'deleted':
            ok++;
            _deletedIds.addAll(res.sessionIds);
          case 'blocked':
            // Preview said deletable but the desktop refused: a skip.
            _skippedIds.add(id);
          default:
            failed++;
        }
      } on ArchivalPreviewUnavailable {
        // Cross-version race at worst: count this task as failed and STOP.
        failed++;
        break;
      } catch (_) {
        failed++;
        break;
      }
      setState(() {});
    }
    if (!mounted) return;
    Navigator.of(context).pop(_ArchiveClearDone(
      ok: ok,
      failed: failed,
      skipped: _skippedIds.length,
      deletedIds: _deletedIds,
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!_confirming) {
      // Preview state: EVERY taskId gets checked before the user can
      // confirm; popping abandons the whole operation.
      return AlertDialog(
        title: Text(trP(
          context,
          'tasks.archive.deleteTitle',
          ['${widget.taskIds.length}'],
        )),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(trP(
                context,
                'tasks.archive.checking',
                ['$_checked', '${widget.taskIds.length}'],
              )),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: widget.taskIds.isEmpty
                    ? 0
                    : _checked / widget.taskIds.length,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr(context, 'common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: null,
            child: Text(tr(context, 'tasks.archive.deleteAll')),
          ),
        ],
      );
    }

    // Confirmation state: deletable count + one deleteItem line per task
    // ($0/$1/$2 = title / children / files in the official order).
    final lines = _previews.entries.toList();
    return AlertDialog(
      title: Text(trP(
        context,
        'tasks.archive.deleteTitle',
        ['${_previews.length}'],
      )),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < lines.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                child: Text(trP(
                  context,
                  'tasks.archive.deleteItem',
                  [
                    widget.titles[lines[i].key] ?? '',
                    '${lines[i].value.sessionIds.length - 1}',
                    '${lines[i].value.deletedFiles}',
                  ],
                )),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _running ? null : () => Navigator.of(context).pop(),
          child: Text(tr(context, 'common.cancel')),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: _running ? null : _runExecute,
          child: Text(
            _running
                ? trP(context, 'tasks.archive.checking',
                    ['$_checked', '${widget.taskIds.length}'])
                : tr(context, 'tasks.archive.deleteAll'),
          ),
        ),
      ],
    );
  }
}
