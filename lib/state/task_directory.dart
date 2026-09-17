import '../protocol/conversation.dart';

/// Merged view of every task on one device — the one home of the
/// 「relay 任务总览打底、live 会话索引按 Task id 胜出」rule (CONTEXT.md
/// 「Task Directory」). Previously coded twice (task list page +
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

  /// Workspace key of the subscribed workspace; live rows attribute here.
  final String? activeWorkspaceKey;

  const TaskDirectory({
    this.relayTasks = const [],
    this.sessions,
    this.activeWorkspaceKey,
  });

  /// Merged rows: relay base, live override per task id. Each row carries
  /// its workspace key and the archived flag read off the RELAY map only —
  /// the relay `archived` field is the sole authority (live-probed
  /// bootstrap frame; live sessions-index frames carry no reliable
  /// `archived` field, so the old `entry.raw['archived']` fallback is gone
  /// — R1, 2026-09-17). Unarchive propagates back via
  /// workspace-list-updated. Rows without a task id are dropped — nothing
  /// can address them.
  List<(SessionEntry, String?, bool)> _rows() {
    final byId = <String, (SessionEntry, String?, bool)>{};
    for (final task in relayTasks) {
      final entry = SessionEntry.fromRelayTask(task);
      if (entry.sessionId.isEmpty) continue;
      byId[entry.sessionId] = (entry, relayKeyOf(task), task['archived'] == true);
    }
    if (sessions?.ready == true) {
      for (final entry in sessions!.list) {
        byId[entry.sessionId] = (
          entry,
          activeWorkspaceKey,
          byId[entry.sessionId]?.$3 ?? false,
        );
      }
    }
    return byId.values.toList();
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
      byId[entry.sessionId] = (entry, relayKeyOf(task));
    }
    if (sessions?.ready == true) {
      for (final entry in sessions!.list) {
        if (entry.raw['pinned'] == true) {
          byId[entry.sessionId] = (entry, activeWorkspaceKey);
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
