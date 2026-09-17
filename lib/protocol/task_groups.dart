/// Parsed wire models of the 3.12.3 task-list additions on the
/// `zcode-task` channel — `listGroupedTaskViewStructure` and
/// `getTaskTokenUsage` (live-probed 2026-09-18, shapes and version gate in
/// task `internal-task/notes.md`).
///
/// Read-only 一期: the app renders group titles/colors/ordering and the
/// per-task token total; write operations (create/rename/recolor/reorder)
/// stay desktop-side. Both sources are pure增量 reads — callers treat any
/// miss (pre-3.12.3 desktops reject the methods) as "feature absent" and
/// keep the flat views (R4 silent degrade).
///
/// Widget-free: plain parsing of the raw maps the session's channel RPC
/// returns.
library;

/// One task group (`groups[]` row of the grouped view).
class TaskGroupInfo {
  final String id;
  final String title;
  final String? color;
  final int createdAt;

  TaskGroupInfo.fromMap(Map<dynamic, dynamic> raw)
    : id = '${raw['id'] ?? ''}',
      title = '${raw['title'] ?? ''}',
      color = raw['color'] as String?,
      createdAt = (raw['createdAt'] as num?)?.toInt() ?? 0;
}

/// One membership row (`members[]`): a task inside a group.
class TaskGroupMember {
  final String groupId;
  final String taskId;
  final int? sortOrder;
  final int addedAt;

  TaskGroupMember.fromMap(Map<dynamic, dynamic> raw)
    : groupId = '${raw['groupId'] ?? ''}',
      taskId = '${raw['taskId'] ?? ''}',
      sortOrder = (raw['sortOrder'] as num?)?.toInt(),
      addedAt = (raw['addedAt'] as num?)?.toInt() ?? 0;
}

/// The grouped task view: groups, their members and the top-level manual
/// ordering. Malformed payloads parse to null — the caller then renders the
/// flat list.
class GroupedTaskView {
  final List<TaskGroupInfo> groups;
  final Map<String, List<TaskGroupMember>> membersByGroup;

  /// `sortOrder` of the `type: 'group'` rows in `topLevelOrders` (manual
  /// top-level order; `type: 'task'` rows are ignored — ungrouped tasks
  /// keep the page's own ordering).
  final Map<String, int> groupSortOrder;

  GroupedTaskView._(this.groups, this.membersByGroup, this.groupSortOrder);

  static GroupedTaskView? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final rawGroups = raw['groups'];
    final rawMembers = raw['members'];
    if (rawGroups is! List || rawMembers is! List) return null;
    final membersByGroup = <String, List<TaskGroupMember>>{};
    for (final m in rawMembers) {
      if (m is! Map) continue;
      final member = TaskGroupMember.fromMap(m);
      if (member.groupId.isEmpty || member.taskId.isEmpty) continue;
      membersByGroup.putIfAbsent(member.groupId, () => []).add(member);
    }
    final groupSortOrder = <String, int>{};
    final orders = raw['topLevelOrders'];
    if (orders is List) {
      for (final o in orders) {
        if (o is! Map || o['type'] != 'group') continue;
        final id = o['groupId'];
        final sort = (o['sortOrder'] as num?)?.toInt();
        if (id is String && id.isNotEmpty && sort != null) {
          groupSortOrder[id] = sort;
        }
      }
    }
    return GroupedTaskView._(
      [
        for (final g in rawGroups) if (g is Map) TaskGroupInfo.fromMap(g),
      ],
      membersByGroup,
      groupSortOrder,
    );
  }

  /// Render order of the groups: manual `sortOrder` descending (the wire's
  /// top-level convention); groups without an order entry — and only those
  /// — fall back to `createdAt` descending, always after the ordered ones.
  List<TaskGroupInfo> orderedGroups() {
    int compare(TaskGroupInfo a, TaskGroupInfo b) {
      final sa = groupSortOrder[a.id];
      final sb = groupSortOrder[b.id];
      if (sa != null && sb != null) return sb.compareTo(sa);
      if (sa != null) return -1;
      if (sb != null) return 1;
      return b.createdAt.compareTo(a.createdAt);
    }

    return [...groups]..sort(compare);
  }

  /// Members of [groupId] in render order: manual `sortOrder` descending;
  /// never-manually-sorted members (null) by `addedAt` descending.
  List<TaskGroupMember> membersOf(String groupId) {
    final list = [...(membersByGroup[groupId] ?? const <TaskGroupMember>[])];
    list.sort((a, b) {
      final sa = a.sortOrder;
      final sb = b.sortOrder;
      if (sa != null && sb != null) return sb.compareTo(sa);
      if (sa != null) return -1;
      if (sb != null) return 1;
      return b.addedAt.compareTo(a.addedAt);
    });
    return list;
  }
}

/// Parsed `getTaskTokenUsage` — the fields the task sheet shows. The wire
/// carries more (input/output/cache splits, error counts, per-source
/// baselines); added here only when a surface needs them.
class TaskTokenUsage {
  final int totalTokens;
  final int modelRequestCount;

  TaskTokenUsage.fromMap(Map<dynamic, dynamic> raw)
    : totalTokens = (raw['totalTokens'] as num?)?.toInt() ?? 0,
      modelRequestCount = (raw['modelRequestCount'] as num?)?.toInt() ?? 0;
}
