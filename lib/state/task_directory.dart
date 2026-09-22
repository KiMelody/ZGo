import '../protocol/conversation.dart';

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

  const TaskDirectory({
    this.relayTasks = const [],
    this.sessions,
  });

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
  /// mirror-row-corrected relay pick key (2026-09-23 emulator acceptance:
  /// inheriting that key could keep a desktop mirror key, leaving the
  /// session viewable in the wrong group but unoperable). Live-only rows
  /// (not yet in the relay overview) key off their own fields first, then
  /// the same subscription identity
  /// ([SessionsIndexState.subscribedWorkspaceKey]) — recorded at subscribe
  /// time, the data self-certifies its home and stays immune to the
  /// page-level switch / re-subscribe drift window.
  List<(SessionEntry, String?, bool)> _rows() {
    final byId = <String, (SessionEntry, String?, bool)>{};
    for (final task in relayTasks) {
      final entry = SessionEntry.fromRelayTask(task);
      if (entry.sessionId.isEmpty) continue;
      final key = relayKeyOf(task);
      final existing = byId[entry.sessionId];
      // Duplicate relay rows (desktop mirror rows) resolve deterministically
      // — see [_relayRowBeats]; frame order must never decide the group.
      if (existing != null &&
          !_relayRowBeats(entry, key, existing.$1, existing.$2)) {
        continue;
      }
      byId[entry.sessionId] = (entry, key, task['archived'] == true);
    }
    if (sessions?.ready == true) {
      for (final entry in sessions!.list) {
        // Deleted-task tombstones: the live index still lists tasks the
        // user deleted on the desktop, and relay has no anchor row for
        // them — without this filter the live merge resurrects them
        // (Addendum 2, 2026-09-23 device report: default 12 → 22).
        if (sessions!.deletedTaskIds.contains(entry.sessionId)) continue;
        byId[entry.sessionId] = (
          entry,
          liveKeyOf(entry, sessions!.subscribedWorkspaceKey),
          byId[entry.sessionId]?.$3 ?? false,
        );
      }
    }
    return byId.values.toList();
  }

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

  /// Whether a duplicate relay row for one task id displaces the row already
  /// kept. The desktop registry mirrors every task into remote-enabled
  /// workspaces — two active rows per id, same-millisecond created, and the
  /// bootstrap frame order varies between snapshots (Addendum 2026-09-23,
  /// device-verified). The greater `updatedAt` wins: the real row keeps
  /// receiving activity updates while the mirror freezes at registration;
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
  /// win per task id and keep a pinned live task even when archived (page
  /// parity).
  List<(SessionEntry, String?)> pinnedEntries() {
    final byId = <String, (SessionEntry, String?)>{};
    for (final task in relayTasks) {
      if (task['pinned'] != true || task['archived'] == true) continue;
      final entry = SessionEntry.fromRelayTask(task);
      if (entry.sessionId.isEmpty) continue;
      final key = relayKeyOf(task);
      final existing = byId[entry.sessionId];
      // Same duplicate-row rule as [_rows] — see [_relayRowBeats].
      if (existing != null &&
          !_relayRowBeats(entry, key, existing.$1, existing.$2)) {
        continue;
      }
      byId[entry.sessionId] = (entry, key);
    }
    if (sessions?.ready == true) {
      for (final entry in sessions!.list) {
        // Same tombstone rule as [_rows] — deleted live rows never pin.
        if (sessions!.deletedTaskIds.contains(entry.sessionId)) continue;
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

  /// Task count for the official summary line: all non-archived relay
  /// tasks, falling back to the live index when no overview has arrived.
  int get totalTaskCount {
    final relay = relayTasks.where((t) => t['archived'] != true).length;
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
