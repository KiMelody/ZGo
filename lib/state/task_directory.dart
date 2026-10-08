import '../protocol/conversation.dart';

/// Workspace key:
/// key = workspaceIdentity?.trim() || workspacePath.
String? workspaceKeyOf(Map<String, dynamic> w) {
  final identity = w['workspaceIdentity'];
  if (identity is String && identity.trim().isNotEmpty) {
    return identity.trim();
  }
  final path = w['workspacePath'];
  if (path is String && path.isNotEmpty) return path;
  for (final key in const ['workspaceKey', 'key', 'id']) {
    final v = w[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

/// Merged view of every task on one device — the one home of the
/// 「relay 任务总览打底、live 会话索引按 Task id 胜出；同 id 多行（桌面
/// 镜像行）按 updatedAt 择优、平级按 workspaceKey 字典序」rule (CONTEXT.md
/// 「Task Directory」). Live rows whose id is in the deleted-tombstone set
/// ([SessionsIndexState.deletedTaskIds]) are skipped — the desktop's live
/// index still lists tasks the user deleted (its session-library view has
/// no deleted concept) while the relay overview omits them, so unfiltered
/// they resurrect. Previously coded twice (task list page +
/// notification hub) with diverging archived handling; consumers now read
/// this projection instead.
///
/// Stateless: every read recomputes from the inputs, nothing is cached —
/// rows are tens, not thousands, and rebuilds already re-invoke the readers.
class TaskDirectory {
  /// Relay task overview (`Dg` maps from bootstrap /
  /// `workspace-list-updated`): every workspace's tasks.
  final List<Map<String, dynamic>> relayTasks;

  /// Live sessions-index of the subscribed workspace (null until subscribed).
  final SessionsIndexState? sessions;

  /// Locally-confirmed deletes (design 10-02 Step 3): task ids whose
  /// delete RPC returned success on this device. Unlike the probe-derived
  /// [SessionsIndexState.deletedTaskIds] — which guards the live loops
  /// only so a relay base row survives — this set filters BOTH sources:
  /// a successful delete is definitive, while the relay overview row can
  /// lag in memory when a reloadTasks response is swallowed by a bridge
  /// reopen. Owned by the session and add-only, so it is aliased here
  /// without copying and re-reads see every new tombstone.
  final Set<String> locallyDeletedTaskIds;

  /// Live-confirmed workspace homes (design 10-02 sticky home): task id →
  /// workspace key as recorded by the session's live sessions-index
  /// ([DeviceSession.confirmLiveHomes]). The relay pick phase still
  /// resolves duplicate rows with the raw relay keys, but the surviving
  /// row's grouping key is pinned to the confirmed home — a bridge
  /// swing's resubscribe window (live coverage down, rows fall back to
  /// the relay pick) can no longer flip a confirmed row's group. Aliased
  /// without copying, like [locallyDeletedTaskIds]; a cold start passes
  /// the empty map and keeps the pure relay-pick behavior.
  final Map<String, String> confirmedHomeKeys;

  const TaskDirectory({
    this.relayTasks = const [],
    this.sessions,
    this.locallyDeletedTaskIds = const {},
    this.confirmedHomeKeys = const {},
  });

  /// Merged rows plus the source marker of the live rows
  /// ([sessionOnlyIds]) — one pass so the marker can never drift from the
  /// merge itself. The pick / override rules below are unchanged by the
  /// marker; it only observes which live rows found no surviving relay
  /// anchor.
  ///
  /// Merged rows: relay base, live override per task id. Each row carries
  /// its workspace key and the archived flag read off the RELAY map only —
  /// the relay `archived` field is the sole authority (live-probed
  /// bootstrap frame; live sessions-index frames carry no reliable
  /// `archived` field, so the old `entry.raw['archived']` fallback is gone
  /// — R1, 2026-09-17). Unarchive propagates back via
  /// workspace-list-updated. Rows without a task id are dropped — nothing
  /// can address them.
  ///
  /// Live rows attribute by the INDEX's subscription identity
  /// ([liveKeyOf]): the live sessions-index is the product of
  /// `listSessions(directory = workspace)`, so membership in it IS the
  /// ground truth of a session's home — it outranks even the
  /// corrected relay pick key (2026-09-23 emulator acceptance:
  /// inheriting that key could keep a desktop copy's key, leaving the
  /// session viewable in the wrong group but unoperable). Live-only rows
  /// (not yet in the relay overview) key off their own fields first, then
  /// the same subscription identity
  /// ([SessionsIndexState.subscribedWorkspaceKey]) — recorded at subscribe
  /// time, the data self-certifies its home and stays immune to the
  /// page-level switch / re-subscribe drift window.
  ({List<(SessionEntry, String?, bool)> rows, Set<String> sessionOnlyIds})
      _merge() {
    final byId = <String, (SessionEntry, String?, bool)>{};
    final sessionOnlyIds = <String>{};
    for (final task in relayTasks) {
      final entry = SessionEntry.fromRelayTask(task);
      if (entry.sessionId.isEmpty) continue;
      // Locally-confirmed delete: drop the relay row too — the overview
      // in memory may be stale (see [locallyDeletedTaskIds]).
      if (locallyDeletedTaskIds.contains(entry.sessionId)) continue;
      final key = relayKeyOf(task);
      final existing = byId[entry.sessionId];
      // Duplicate relay rows (desktop copies) resolve deterministically
      // — see [_relayRowBeats]; frame order must never decide the group.
      if (existing != null &&
          !_relayRowBeats(entry, key, existing.$1, existing.$2)) {
        continue;
      }
      byId[entry.sessionId] = (entry, key, task['archived'] == true);
    }
    // Sticky homes (design 10-02): pin the surviving rows to their
    // live-confirmed group. Applied AFTER the pick so [_relayRowBeats]
    // keeps comparing raw relay keys — the row selection semantics are
    // unchanged, only the final grouping key is overridden. The live loop
    // below still outranks a pinned key whenever the index is ready (and
    // the same snapshot overwrote the cache, so they agree anyway).
    for (final id in byId.keys) {
      final home = confirmedHomeKeys[id];
      if (home != null) {
        final (entry, _, archived) = byId[id]!;
        byId[id] = (entry, home, archived);
      }
    }
    if (sessions?.ready == true) {
      for (final entry in sessions!.list) {
        // Deleted-task tombstones: the live index still lists tasks the
        // user deleted on the desktop, and relay has no anchor row for
        // them — without this filter the live merge resurrects them
        // (Addendum 2, 2026-09-23 device report: default 12 → 22). The
        // local set covers deletes this device confirmed while the
        // desktop index (and its probe) lag behind.
        if (sessions!.deletedTaskIds.contains(entry.sessionId) ||
            locallyDeletedTaskIds.contains(entry.sessionId)) {
          continue;
        }
        // Source marker (C1-D2): no surviving relay anchor above → the
        // row exists only in the live sessions-index.
        if (!byId.containsKey(entry.sessionId)) {
          sessionOnlyIds.add(entry.sessionId);
        }
        byId[entry.sessionId] = (
          entry,
          liveKeyOf(entry, sessions!.subscribedWorkspaceKey),
          byId[entry.sessionId]?.$3 ?? false,
        );
      }
    }
    return (rows: byId.values.toList(), sessionOnlyIds: sessionOnlyIds);
  }

  List<(SessionEntry, String?, bool)> _rows() => _merge().rows;

  /// Ids of rows that exist ONLY in the live sessions-index — no
  /// surviving task-registry (relay) anchor behind them (design C1-D2).
  /// The desktop parks fork drafts in the session library with
  /// `persistence:'deferred'`, deliberately skipping the task index
  /// (createZCodeDeferredDraftRegistry, research.md R2): these rows have
  /// no registry row, so registry mutations (deleteTask…) can never
  /// resolve them — consumers route them to session commands instead.
  /// Recomputed with the merge like every other read (stateless class);
  /// a late relay row unmarks the id on the next read, mirroring how the
  /// row itself gains its anchor.
  Set<String> get sessionOnlyIds => _merge().sessionOnlyIds;

  /// Workspace key of a LIVE sessions-index row (not yet in the relay
  /// overview): its own fields under the same rule as [relayKeyOf], then
  /// the index's subscription identity ([SessionsIndexState
  /// .subscribedWorkspaceKey]).
  static String? liveKeyOf(SessionEntry entry, String? fallback) {
    final identity = entry.raw['workspaceIdentity'];
    if (identity is String && identity.trim().isNotEmpty) {
      return identity.trim();
    }
    final path = entry.raw['workspacePath'];
    if (path is String && path.isNotEmpty) return path;
    return fallback;
  }

  /// Workspace key of a relay task (`Dg.workspaceIdentity ?? workspacePath`,
  /// same rule as `workspaceKeyOf`).
  static String? relayKeyOf(Map<String, dynamic> task) {
    final identity = task['workspaceIdentity'];
    if (identity is String && identity.trim().isNotEmpty) {
      return identity.trim();
    }
    final path = task['workspacePath'];
    if (path is String && path.isNotEmpty) return path;
    return null;
  }

  /// The workspace behind a directory key: the listed workspace whose
  /// [workspaceKeyOf] matches, else a minimal scope built from the task
  /// row's own origin fields (`workspacePath`/`workspaceIdentity` — relay
  /// overview and sessions-index rows carry them). The fallback covers the
  /// key divergence between the overview and the workspace list: without
  /// it, opening a foreign task silently reused the active workspace's
  /// scope and the server rejected every command (proto.sessionNotFound —
  /// the "can see, can't act" dead page). Only fields the row actually
  /// carries go into the map (path required — every scoped wire call needs
  /// it); null means ownership is undeterminable and the caller must not
  /// open the chat.
  static Map<String, dynamic>? workspaceForKey(
    List<Map<String, dynamic>> workspaces,
    SessionEntry entry,
    String? key,
  ) {
    for (final ws in workspaces) {
      if (key != null && workspaceKeyOf(ws) == key) return ws;
    }
    // No directory anchor (archived rows are filtered out of allEntries,
    // session-only rows never had one): the row's own origin fields still
    // say where it belongs — cross-workspace rows keep their chip.
    final path = entry.raw['workspacePath'];
    if (path is! String || path.isEmpty) return null;
    return {
      'workspacePath': path,
      if (entry.raw['workspaceIdentity'] != null)
        'workspaceIdentity': entry.raw['workspaceIdentity'],
    };
  }

  /// Whether a duplicate relay row for one task id displaces the row already
  /// kept. The desktop registry copies every task into remote-enabled
  /// workspaces — two active rows per id, same-millisecond created, and the
  /// bootstrap frame order varies between snapshots (Addendum 2026-09-23,
  /// device-verified). The greater `updatedAt` wins: the real row keeps
  /// receiving activity updates while the copy freezes at registration;
  /// a tie falls back to the lexicographically smaller workspace key, so
  /// the result is a pure function of the row set — never of frame order.
  static bool _relayRowBeats(
    SessionEntry candidate,
    String? candidateKey,
    SessionEntry incumbent,
    String? incumbentKey,
  ) {
    if (candidate.lastActivityAt != incumbent.lastActivityAt) {
      return candidate.lastActivityAt > incumbent.lastActivityAt;
    }
    return (candidateKey ?? '').compareTo(incumbentKey ?? '') < 0;
  }

  /// Entries of one workspace, merged; archived rows in or out per
  /// [includeArchived].
  List<(SessionEntry, String?)> entriesFor(
    String workspaceKey, {
    bool includeArchived = false,
  }) =>
      [
        for (final (entry, key, archived) in _rows())
          if (key == workspaceKey && archived == includeArchived)
            (entry, key),
      ];

  /// Every non-archived task of the device — the page-wide set (timeline
  /// grouping et al).
  List<(SessionEntry, String?)> allEntries() =>
      [
        for (final (entry, key, archived) in _rows())
          if (!archived) (entry, key),
      ];

  /// Pinned tasks across the device, most recently active first. Live rows
  /// win per task id and keep a pinned live task even when archived.
  /// Archived live tasks remain pinned.
  List<(SessionEntry, String?)> pinnedEntries() {
    final byId = <String, (SessionEntry, String?)>{};
    for (final task in relayTasks) {
      if (task['pinned'] != true || task['archived'] == true) continue;
      final entry = SessionEntry.fromRelayTask(task);
      if (entry.sessionId.isEmpty) continue;
      // Same locally-deleted rule as [_rows] — a confirmed delete never
      // pins, whatever the stale overview says.
      if (locallyDeletedTaskIds.contains(entry.sessionId)) continue;
      final key = relayKeyOf(task);
      final existing = byId[entry.sessionId];
      // Same duplicate-row rule as [_rows] — see [_relayRowBeats].
      if (existing != null &&
          !_relayRowBeats(entry, key, existing.$1, existing.$2)) {
        continue;
      }
      byId[entry.sessionId] = (entry, key);
    }
    // Same sticky-home rule as [_rows] — the pinned rows group by their
    // live-confirmed home, after the pick so its raw-key tie-break stays
    // frame-order independent.
    for (final id in byId.keys) {
      final home = confirmedHomeKeys[id];
      if (home != null) {
        final (entry, _) = byId[id]!;
        byId[id] = (entry, home);
      }
    }
    if (sessions?.ready == true) {
      for (final entry in sessions!.list) {
        // Same tombstone rules as [_rows] — deleted live rows never pin.
        if (sessions!.deletedTaskIds.contains(entry.sessionId) ||
            locallyDeletedTaskIds.contains(entry.sessionId)) {
          continue;
        }
        if (entry.raw['pinned'] == true) {
          byId[entry.sessionId] = (
            entry,
            liveKeyOf(entry, sessions!.subscribedWorkspaceKey),
          );
        }
      }
    }
    final list = byId.values.toList()
      ..sort((a, b) => b.$1.lastActivityAt.compareTo(a.$1.lastActivityAt));
    return list;
  }

  /// Task count for the summary line: all non-archived relay
  /// tasks, falling back to the live index when no overview has arrived.
  /// Locally-confirmed deletes come off the relay count (the live
  /// fallback stays raw — same accepted over-count as the probe
  /// tombstones, task-registry-semantics §4).
  int get totalTaskCount {
    final relay = relayTasks
        .where(
          (t) =>
              t['archived'] != true &&
              !locallyDeletedTaskIds.contains(t['taskId']),
        )
        .length;
    if (relay > 0) return relay;
    return sessions?.list.where((e) => e.raw['archived'] != true).length ?? 0;
  }

  /// Merged rows for phase diffing (the notification hub's view). Archived
  /// tasks STAY in the notification scope — a task archived mid-run must
  /// still report its completion — and the default makes that ruling
  /// explicit in the signature instead of a comment (Q3a).
  List<SessionEntry> notificationRows({bool includeArchived = true}) => [
        for (final (entry, _, archived) in _rows())
          if (includeArchived || !archived) entry,
      ];
}
