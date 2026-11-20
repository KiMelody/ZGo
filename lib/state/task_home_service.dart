import 'package:clock/clock.dart';

import '../protocol/conversation_state.dart';
import 'sidecar_index_manager.dart';
import 'task_directory.dart';
import 'task_home_store.dart';

/// The task-home assembly of one device (design 10-29 §2): owns every input
/// of the merged task directory — relay rows, both key-alias tables, the
/// live snapshot cache, the cross-terminal tombstone set and the tombstone
/// diff baseline — plus the six wiring pieces that used to live on
/// `DeviceSession`.
///
/// The service is a PUSH sink, not a pull source: the session calls the
/// explicit entry points at its existing call sites, so the two live-frame
/// orders (design §0.6) and the 30s overview cadence stay visible and
/// auditable. It never implements [Listenable] and never notifies: the
/// session stays the single notify owner ([onActiveFrameApplied] for active
/// frames, the sidecar manager's `onChanged` for its own changes).
class TaskHomeService {
  TaskHomeService({
    required this.store,
    required this.sidecars,
    required this.conversationGroupKey,
    required this.fallbackScope,
    required this.deleteCopy,
    required this.onActiveFrameApplied,
    required this.onChanged,
    required this.onDirectoryChanged,
    required this.log,
  });

  /// Persisted anchors + local delete tombstones. Created and owned by the
  /// session; the service only reads the live views and writes through the
  /// public store methods (never `load` / `dispose`).
  final TaskHomeStore store;

  /// Sidecar subscription manager (owned by the session): the sidecar live
  /// layers are read through [SidecarIndexManager.indexes], and overview
  /// landings re-diff the set via [SidecarIndexManager.reconcile].
  final SidecarIndexManager sidecars;

  /// The synthetic conversation group key (`conversationsWorkspaceKey`) used
  /// when no listed workspace is the default group.
  final String conversationGroupKey;

  /// Fallback mutation scope when a task id has no relay row — the active
  /// workspace's `{workspacePath, workspaceIdentity?}` (the former
  /// `_taskMutationScope` fallback; never null).
  final Map<String, dynamic> Function() fallbackScope;

  /// Deletes one registry copy with ITS OWN scope (`taskCommands.delete`).
  final Future<void> Function(String taskId, Map<String, dynamic> scope)
      deleteCopy;

  /// The session's per-active-frame callback: watchdog reset + the single
  /// notify. Called once per active sessions-index notification, including
  /// not-ready ones (the old `_onSessionsChanged` shape).
  final void Function() onActiveFrameApplied;

  /// The session's guarded notify for the home-adjudication anchor write
  /// (the former `correctTaskHome` notify).
  final void Function() onChanged;

  /// Fires once per actual directory invalidation ([_bump]) — the task list
  /// page's narrow listenable (2026-11-19 scroll-perf). Not a notifier of
  /// its own: the session stays the single notify owner; this callback is
  /// the directory-scoped slice of it, aligned point-for-point with the
  /// invalidation matrix (spec/state/session-lifecycle.md §10.2).
  final void Function() onDirectoryChanged;

  final void Function(String line) log;

  List<Map<String, dynamic>> _relayTasks = const [];

  /// Relay task overview (raw `Dg` maps, normalized by the session on write).
  List<Map<String, dynamic>> get relayTasks => _relayTasks;

  /// Workspace key aliases (path spelling → canonical key). Only
  /// [setWorkspaces] recomputes this table.
  Map<String, String> _keyAliases = const {};

  /// Group-key aliases (row ownership key → display group). Rebuilt with
  /// [_keyAliases] — the two must never diverge in time.
  Map<String, String> _groupAliases = const {};

  /// Identity of the last pushed workspace list (stale-projection defence;
  /// the list itself stays owned by the session).
  int _workspacesIdentity = 0;

  /// The last pushed workspace list, kept by reference for
  /// [workspaceOfTask]'s list matching only (the list stays owned by the
  /// session; [setWorkspaces] is the single push point).
  List<Map<String, dynamic>> _workspaces = const [];

  SessionsIndexState? _activeSessions;
  int Function() _generation = () => 0;
  String? Function() _frameKind = () => null;

  /// Last live sessions-index snapshot per workspace key (design 10-15
  /// live-snapshot cache): the merge layer's gap filler.
  final Map<String, List<SessionEntry>> _liveSnapshots = {};

  /// Cross-terminal deletion tombstones (`SessionTruthPort.isSessionDeleted`).
  /// Add-only in memory; preserved across [clear] like the pre-extraction
  /// session (chat pages own their reader-recovery).
  final Set<String> _deletedSessionIds = <String>{};

  /// Diff baseline of [recordVanishedSessions], tagged with the workspace
  /// key and subscription generation.
  ({String? key, int gen, Set<String> snapshotIds, Set<String> seenIds})?
      _indexDiffBase;

  int _revision = 0;
  /// Bumps the materialized-view revision and reports the invalidation to
  /// the session (the task list page's directory listenable). Every matrix
  /// write point funnels through here, so the narrow notify cannot drift
  /// from the cache.
  void _bump() {
    _revision++;
    onDirectoryChanged();
  }

  TaskDirectoryView? _view;
  String? _viewFingerprint;

  /// Materialized merge construction count (test gate: one per dirty
  /// revision, not one per read).
  int get materializations => _materializations;
  int _materializations = 0;

  /// Canonicalizes a raw key through the workspace alias table (anchor /
  /// scope normalization — the former `_workspaceKeyAliases` reads).
  String normalizeKey(String rawKey) => _keyAliases[rawKey] ?? rawKey;

  /// Replaces the relay overview rows (the single write point besides
  /// [applyRelayOverview]).
  void setRelayTasks(List<Map<String, dynamic>> tasks) {
    _relayTasks = tasks;
    _bump();
  }

  /// Workspace-list change (the ONLY push point): recomputes BOTH alias
  /// tables together and invalidates the projection.
  void setWorkspaces(List<Map<String, dynamic>> workspaces) {
    _workspacesIdentity = identityHashCode(workspaces);
    _workspaces = workspaces;
    var groupKey = conversationGroupKey;
    for (final ws in workspaces) {
      if (isConversationWorkspace(ws)) continue;
      if (ws['label'] == 'default') {
        final key = workspaceKeyOf(ws);
        if (key != null) {
          groupKey = key;
          break;
        }
      }
    }
    final keyAliases = <String, String>{};
    final groupAliases = <String, String>{};
    for (final ws in workspaces) {
      final key = workspaceKeyOf(ws);
      if (key == null) continue;
      final path = ws['workspacePath'];
      final isConversation = isConversationWorkspace(ws);
      keyAliases[key] = isConversation ? groupKey : key;
      if (path is String && path.isNotEmpty) {
        keyAliases[path] = keyAliases[key]!;
        if (isConversation) groupAliases[path] = groupKey;
      }
      if (isConversation) groupAliases[key] = groupKey;
    }
    keyAliases.putIfAbsent(conversationGroupKey, () => groupKey);
    groupAliases.putIfAbsent(conversationGroupKey, () => groupKey);
    _keyAliases = keyAliases;
    _groupAliases = groupAliases;
    _bump();
  }

  /// Attaches (or detaches, with null) the active sessions-index listener.
  /// [generation] / [frameKind] are read at frame time from the subscription
  /// object, so a bridge-swing resubscribe is reflected without re-wiring.
  void setActiveSessions(
    SessionsIndexState? state, {
    required int Function() generation,
    required String? Function() frameKind,
  }) {
    _activeSessions?.removeListener(_onActiveChanged);
    _activeSessions = state;
    _generation = generation;
    _frameKind = frameKind;
    state?.addListener(_onActiveChanged);
    _bump();
  }

  void _onActiveChanged() {
    final state = _activeSessions;
    if (state == null) return;
    if (state.ready) {
      applyLiveFrame(
        state,
        generation: _generation(),
        frameKind: _frameKind(),
      );
    }
    // Unconditionally, like the old listener: a not-ready notification must
    // still repaint (and reset the watchdog).
    onActiveFrameApplied();
  }

  /// Relay overview landing: replace rows, run the anchor reconcile, then
  /// re-diff the sidecar set (design 10-28). No notify of its own — the
  /// session's existing landing points notify.
  void applyRelayOverview(List<Map<String, dynamic>> tasks) {
    setRelayTasks(tasks);
    reconcileTaskHomes();
    sidecars.reconcile();
  }

  /// Listener-order entry (the old `_onSessionsChanged`):
  /// `recordVanishedSessions → confirmLiveHomes → snapshotSessionsIntoCache`.
  ///
  /// The tombstone diff runs FIRST: the notify that follows flips the chat
  /// page's banner, so the vanished set must already hold the ids.
  void applyLiveFrame(
    SessionsIndexState state, {
    required int generation,
    String? frameKind,
  }) {
    recordVanishedSessions(state, generation: generation, frameKind: frameKind);
    confirmLiveHomes();
    snapshotSessionsIntoCache(state);
    _bump();
  }

  /// Open-path catch-up order (the old `_openWorkspaceNow`):
  /// `confirmLiveHomes → snapshotSessionsIntoCache → recordVanishedSessions`.
  ///
  /// Deliberately a SECOND entry even though the two orders are
  /// output-equivalent today (open resets the diff baseline first, confirm
  /// never reads it, the snapshot reads only store tombstones): keeping the
  /// production order explicit prevents a future change from treating the
  /// equivalence as a license to merge the entries (design §0.6).
  void applyWorkspaceOpenedCatchUp(
    SessionsIndexState state, {
    required int generation,
    String? frameKind,
  }) {
    confirmLiveHomes();
    snapshotSessionsIntoCache(state);
    recordVanishedSessions(state, generation: generation, frameKind: frameKind);
    _bump();
  }

  /// Confirms live sessions-index membership into the persisted home
  /// anchors — design 10-15 §1.1 write sources ②/③: single relay copy →
  /// establish/follow/flip; multi-copy (or no row yet) → an agreeing
  /// confirmation only refreshes the timestamp. Anti-pollution gate.
  void confirmLiveHomes() {
    final state = _activeSessions;
    if (state == null || !state.ready) return;
    final aliases = _keyAliases;
    for (final entry in state.list) {
      final raw = TaskDirectory.liveKeyOf(entry, state.subscribedWorkspaceKey);
      if (raw == null) continue;
      // 键规范化：锚一律写 workspaceKeyOf 规范拼写。
      final key = aliases[raw] ?? raw;
      final id = entry.sessionId;
      var copies = 0;
      // The possibly-stale in-memory overview: inside a lag window a
      // single-copy view can anchor an actually-multi-copy id — that is
      // exactly what the App rendered at the time (check P2-5).
      for (final task in _relayTasks) {
        if ('${task['taskId'] ?? ''}' == id) copies++;
      }
      if (copies == 1) {
        store.anchorHome(id, key, now: clock.now());
      } else if (store.homeKeys[id] == key) {
        store.refreshHome(id, now: clock.now());
      }
    }
  }

  /// Snapshots a ready live sessions-index into [_liveSnapshots] under its
  /// subscription key: probe-deleted ids and locally-confirmed tombstones
  /// are filtered at this write point (the merge re-checks the local set at
  /// its read point).
  void snapshotSessionsIntoCache(SessionsIndexState state) {
    final cacheKey = state.subscribedWorkspaceKey;
    if (cacheKey == null || cacheKey.isEmpty || !state.ready) return;
    final probeDeleted = state.deletedTaskIds;
    final localDeleted = store.locallyDeletedTaskIds;
    final rows = [
      for (final e in state.list)
        if (!probeDeleted.contains(e.sessionId) &&
            !localDeleted.contains(e.sessionId))
          e,
    ];
    final previous = _liveSnapshots[cacheKey];
    // Diagnostic: only log content CHANGES — the write rides every frame.
    if (previous == null || _snapshotChanged(previous, rows)) {
      log('[session] live snapshot cached: key=$cacheKey '
          'rows=${rows.length} (was ${previous?.length ?? 'none'})');
    }
    _liveSnapshots[cacheKey] = rows;
    _bump();
  }

  /// Content fingerprint for the snapshot-cache diagnostic: id →
  /// lastActivityAt (positional compare would false-positive on equal
  /// timestamps; the list sort is unstable).
  static bool _snapshotChanged(List<SessionEntry> a, List<SessionEntry> b) {
    if (a.length != b.length) return true;
    final byId = {for (final e in b) e.sessionId: e.lastActivityAt};
    for (final e in a) {
      if (byId[e.sessionId] != e.lastActivityAt) return true;
    }
    return false;
  }

  /// Anchor reconciliation + lifecycle (design 10-15 §1.1), run after every
  /// relay overview application: tombstoned ids drop their anchors,
  /// anchored ids absent from live whose relay set collapsed to one foreign
  /// copy follow the relay, tombstones past TTL and anchors absent for the
  /// absence window are pruned.
  void reconcileTaskHomes() {
    final liveIds = _activeSessions?.sessions.keys.toSet() ?? const <String>{};
    final copyCounts = <String, int>{};
    final singleKeys = <String, String?>{};
    for (final task in _relayTasks) {
      final id = '${task['taskId'] ?? ''}';
      if (id.isEmpty) continue;
      copyCounts[id] = (copyCounts[id] ?? 0) + 1;
      singleKeys[id] =
          copyCounts[id] == 1 ? TaskDirectory.relayKeyOf(task) : null;
    }
    final aliases = _keyAliases;
    final tombstoned = store.locallyDeletedTaskIds;
    for (final id in store.homeKeys.keys.toList()) {
      if (tombstoned.contains(id)) {
        store.dropAnchor(id);
        continue;
      }
      if (liveIds.contains(id)) continue;
      if (copyCounts[id] == 1) {
        final raw = singleKeys[id];
        final key = raw == null ? null : (aliases[raw] ?? raw);
        if (key != null && key != store.homeKeys[id]) {
          store.anchorHome(id, key, now: clock.now());
        }
      }
    }
    store.pruneExpiredTombstones(now: clock.now());
    store.pruneAbsent({...liveIds, ...copyCounts.keys}, now: clock.now());
    _bump();
  }

  /// Records cross-terminal deletion tombstones from a live index frame
  /// (task 10-06 chat tombstone): conservative diffing within one
  /// subscription generation + workspace key; delta frames diff [seenIds]
  /// (only an explicit `session.removed` drops an id), snapshots diff
  /// [snapshotIds] and refresh both sets.
  void recordVanishedSessions(
    SessionsIndexState state, {
    required int generation,
    String? frameKind,
  }) {
    if (!state.ready) return;
    final current = state.sessions.keys.toSet();
    final base = _indexDiffBase;
    final fresh = base == null ||
        base.key != state.subscribedWorkspaceKey ||
        base.gen != generation;
    final delta = frameKind == 'deltas';
    if (!fresh) {
      if (delta) {
        _deletedSessionIds.addAll(base.seenIds.difference(current));
      } else {
        _deletedSessionIds.addAll(base.snapshotIds.difference(current));
      }
    }
    if (fresh || !delta) {
      _indexDiffBase = (
        key: state.subscribedWorkspaceKey,
        gen: generation,
        snapshotIds: current,
        seenIds: current,
      );
    } else {
      _indexDiffBase = (
        key: base.key,
        gen: generation,
        snapshotIds: base.snapshotIds,
        seenIds: current,
      );
    }
  }

  /// A fresh workspace subscription starts a new diff baseline (the first
  /// ready frame only establishes it — a workspace switch must never read
  /// the previous workspace's ids as mass deletions).
  void onWorkspaceOpened() {
    _indexDiffBase = null;
  }

  /// Suspend/teardown: snapshots, relay rows, both alias tables and the
  /// active listener are cleared; the tombstone diff baseline is reset. The
  /// cross-terminal tombstone set is PRESERVED (pre-extraction behavior —
  /// chat pages own their reader-recovery).
  void clear() {
    _activeSessions?.removeListener(_onActiveChanged);
    _activeSessions = null;
    _generation = () => 0;
    _frameKind = () => null;
    _relayTasks = const [];
    _keyAliases = const {};
    _groupAliases = const {};
    _workspaces = const [];
    if (_liveSnapshots.isNotEmpty) {
      log('[session] live snapshots cleared (${_liveSnapshots.length} keys)');
    }
    _liveSnapshots.clear();
    _indexDiffBase = null;
    _bump();
  }

  /// The materialized merged view (design §2.4): one [TaskDirectoryView] per
  /// dirty revision. O(1) + O(#sidecars) staleness check; identical reads
  /// return the SAME instance.
  TaskDirectory get directory {
    final fingerprint = _fingerprint();
    final view = _view;
    if (view != null && fingerprint == _viewFingerprint) return view;
    final next = TaskDirectoryView(
      relayTasks: _relayTasks,
      sessions: _activeSessions,
      sidecarIndexes: sidecars.indexes,
      locallyDeletedTaskIds: store.locallyDeletedTaskIds,
      confirmedHomeKeys: store.homeKeys,
      keyAliases: _keyAliases,
      groupKeyAliases: _groupAliases,
      cachedSessions: _liveSnapshots,
    );
    _view = next;
    _viewFingerprint = fingerprint;
    _materializations++;
    return next;
  }

  /// Full input fingerprint. The explicit revision and the store revision
  /// are the primary invalidation; the identity/sequence fields are the
  /// defensive layer (a write point that forgot to bump still cannot serve
  /// a stale view after a direct state/list swap in tests).
  String _fingerprint() {
    final buffer = StringBuffer()
      ..write(_revision)
      ..write('|')
      ..write(store.revision)
      ..write('|')
      ..write(identityHashCode(_relayTasks))
      ..write('|')
      ..write(_workspacesIdentity)
      ..write('|');
    _writeStateFingerprint(buffer, _activeSessions);
    buffer
      ..write('|')
      ..write(identityHashCode(sidecars.indexes));
    final keys = sidecars.indexes.keys.toList()..sort();
    for (final key in keys) {
      buffer
        ..write('|')
        ..write(key)
        ..write(':');
      _writeStateFingerprint(buffer, sidecars.indexes[key]);
    }
    return buffer.toString();
  }

  static void _writeStateFingerprint(
    StringBuffer buffer,
    SessionsIndexState? state,
  ) {
    if (state == null) {
      buffer.write('null');
      return;
    }
    final deleted = state.deletedTaskIds;
    buffer
      ..write(identityHashCode(state))
      ..write(',')
      ..write(state.seq)
      ..write(',')
      ..write(state.ready)
      ..write(',')
      ..write(state.subscribedWorkspaceKey)
      ..write(',')
      ..write(identityHashCode(deleted))
      ..write(',')
      ..write(deleted.length);
  }

  /// Mutation scope of [taskId] — the layed home relay row's own workspace
  /// (`bestRelayRow`, same pick the visible row uses), falling back to the
  /// active workspace scope.
  Map<String, dynamic> taskScopeFor(String taskId) {
    final row = TaskDirectory.bestRelayRow(
      _relayTasks,
      taskId,
      homeKeys: store.homeKeys,
      keyAliases: _keyAliases,
    );
    if (row == null) return fallbackScope();
    return {
      'workspacePath': row['workspacePath'],
      if (row['workspaceIdentity'] != null)
        'workspaceIdentity': row['workspaceIdentity'],
    };
  }

  /// The relay home row of [taskId] as the merged directory shows it.
  Map<String, dynamic>? relayHomeRowOf(String taskId) =>
      TaskDirectory.bestRelayRow(
        _relayTasks,
        taskId,
        homeKeys: store.homeKeys,
        keyAliases: _keyAliases,
      );

  /// The workspace [taskId] belongs to — the ONE ownership resolution the
  /// open paths share (task list rows and notification taps). Returns the
  /// LISTED workspace map (same object the session's `workspaces` carries)
  /// or a minimal origin scope when the key names no listed workspace;
  /// null only when ownership is undeterminable (the caller must then not
  /// open a chat under a guessed scope — design D1).
  ///
  /// Two layers, in the directory's own precedence (design D3):
  /// - a relay row wins — the overview covers EVERY workspace, so its key
  ///   is the scope. It never falls back to the active workspace: doing so
  ///   is exactly the 「sessionNotFound dead page」 bug (an overview row of
  ///   another workspace opened under the active scope);
  /// - otherwise the row is live-only (no surviving relay anchor): the
  ///   merged layer's attribution key (index subscription identity /
  ///   carried origin fields) names the workspace. A live index streams
  ///   the workspace it was subscribed to, so a key that matches no listed
  ///   entry still resolves to [activeKey]'s workspace — the row was
  ///   streamed by the active index by construction.
  Map<String, dynamic>? workspaceOfTask(String taskId, {String? activeKey}) {
    final row = relayHomeRowOf(taskId);
    if (row != null) {
      // The row's OWN key (design D3): no active-workspace fallback — the
      // overview covers every workspace, so falling back is exactly the
      // wrong-scope bug. [workspaceForKey] supplies the origin-field scope
      // when the key names no listed workspace.
      return TaskDirectory.workspaceForKey(
        _workspaces,
        SessionEntry.fromRelayTask(row),
        TaskDirectory.relayKeyOf(row),
      );
    }
    final active = activeKey == null ? null : normalizeKey(activeKey);
    for (final (entry, key, _) in directory.mergedRows().rows) {
      if (entry.sessionId != taskId) continue;
      final mergedKey = key == null ? active : normalizeKey(key);
      return TaskDirectory.workspaceForKey(_workspaces, entry, mergedKey) ??
          _listedWorkspace(active);
    }
    return null;
  }

  /// The listed workspace carrying [key], or null (workspace-list lookup
  /// without the origin-field fallback of [TaskDirectory.workspaceForKey]).
  Map<String, dynamic>? _listedWorkspace(String? key) {
    if (key == null) return null;
    for (final w in _workspaces) {
      if (workspaceKeyOf(w) == key) return w;
    }
    return null;
  }

  /// User home adjudication (anchor write source ④): write the canonical
  /// anchor, then optionally delete every OTHER registry copy with its own
  /// per-copy scope — keep deleting past failures, throw the first one.
  Future<void> adjudicate(
    String taskId,
    Map<String, dynamic> homeCopy, {
    bool deleteOtherCopies = false,
  }) async {
    final rawKey = TaskDirectory.relayKeyOf(homeCopy);
    if (rawKey != null) {
      store.anchorHome(taskId, normalizeKey(rawKey), now: clock.now());
    }
    onChanged();
    if (!deleteOtherCopies) return;
    Object? firstError;
    // NOT identical(): every overview landing rebuilds the relay maps, so
    // the map the dialog picked may be stale by confirm time. Compare
    // fields instead: same path+identity = same copy.
    final homePath = '${homeCopy['workspacePath'] ?? ''}';
    final homeIdentity = '${homeCopy['workspaceIdentity'] ?? ''}';
    for (final task in List.of(_relayTasks)) {
      if ('${task['taskId'] ?? ''}' != taskId) continue;
      if ('${task['workspacePath'] ?? ''}' == homePath &&
          '${task['workspaceIdentity'] ?? ''}' == homeIdentity) {
        continue;
      }
      final path = task['workspacePath'];
      if (path is! String || path.isEmpty) continue; // unaddressable copy
      try {
        await deleteCopy(taskId, {
          'workspacePath': path,
          if (task['workspaceIdentity'] != null)
            'workspaceIdentity': task['workspaceIdentity'],
        });
      } catch (e) {
        firstError ??= e; // keep deleting the rest, surface the first failure
      }
    }
    if (firstError != null) throw firstError;
  }

  /// Anchor write source ① (phone created the session = App is the source of
  /// truth): canonical-key anchor on the active workspace. The alias
  /// canonicalization keeps a conversation workspace on its DISPLAY group
  /// key (a raw draft-path spelling would fail bestRelayRow's canonicalized
  /// anchor matching until the next reconcile).
  void anchorCreatedTask(String taskId, String? workspaceKey) {
    if (workspaceKey == null) return;
    store.anchorHome(taskId, normalizeKey(workspaceKey), now: clock.now());
    // Store writes carry no notify of their own (§10.2 row "store 写点");
    // the session-level create flow notifies broadly, but the task list
    // page hears only the directory slice.
    _bump();
  }

  /// Records a confirmed local delete: the id enters the persisted tombstone
  /// set and its home anchor (if any) drops at once.
  void rememberLocalDelete(String sessionId) {
    store.addLocalDelete(sessionId);
    store.dropAnchor(sessionId);
    _bump();
  }

  bool isSessionDeleted(String sessionId) =>
      _deletedSessionIds.contains(sessionId);

  void forgetDeletedSession(String sessionId) {
    _deletedSessionIds.remove(sessionId);
  }
}

/// The materialized merge of one dirty revision (design §2.4): the full
/// [TaskDirectory.mergedRows] pass runs once, and every read method is a
/// pure filter over that record (memoized per query shape). No read ever
/// triggers another `_merge()` — the pinned projection is the only second
/// traversal, and it is lazy and once-per-view.
class TaskDirectoryView extends TaskDirectory {
  TaskDirectoryView({
    super.relayTasks,
    super.sessions,
    super.sidecarIndexes,
    super.locallyDeletedTaskIds,
    super.confirmedHomeKeys,
    super.keyAliases,
    super.groupKeyAliases,
    super.cachedSessions,
  }) {
    _merged = super.mergedRows();
  }

  late final ({
    List<(SessionEntry, String?, bool)> rows,
    Set<String> sessionOnlyIds,
  }) _merged;

  List<(SessionEntry, String?)>? _pinned;
  List<(SessionEntry, String?)>? _all;
  List<SessionEntry>? _notificationAll;
  List<SessionEntry>? _notificationVisible;
  final Map<(String, bool), List<(SessionEntry, String?)>> _entries = {};

  @override
  List<(SessionEntry, String?)> entriesFor(
    String workspaceKey, {
    bool includeArchived = false,
  }) =>
      _entries.putIfAbsent(
        (workspaceKey, includeArchived),
        () => [
          for (final (entry, key, archived) in _merged.rows)
            if (key == workspaceKey && archived == includeArchived)
              (entry, key),
        ],
      );

  @override
  List<(SessionEntry, String?)> allEntries() => _all ??= [
        for (final (entry, key, archived) in _merged.rows)
          if (!archived) (entry, key),
      ];

  @override
  Set<String> get sessionOnlyIds => _merged.sessionOnlyIds;

  /// Serves the materialized record itself — hot on the per-host-notify
  /// path (`DeviceSession.taskLastError`), where a base-class call would
  /// re-run the full `_merge()` on every notification.
  @override
  ({List<(SessionEntry, String?, bool)> rows, Set<String> sessionOnlyIds})
      mergedRows() => _merged;

  @override
  List<(SessionEntry, String?)> pinnedEntries() => _pinned ??= super.pinnedEntries();

  @override
  List<SessionEntry> notificationRows({bool includeArchived = true}) {
    if (includeArchived) {
      return _notificationAll ??= [
        for (final (entry, _, _) in _merged.rows) entry,
      ];
    }
    return _notificationVisible ??= [
      for (final (entry, _, archived) in _merged.rows)
        if (!archived) entry,
    ];
  }
}
