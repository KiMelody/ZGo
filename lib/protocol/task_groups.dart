/// Models of the desktop task-group surface and the per-task token usage.
///
/// Grouped view (一期, read-only): the desktop 3.17.1 removed its
/// grouped-task RPC; the same data now lives in the `task_group_*` tables
/// of `tasks-index.sqlite`, which `TaskGroupResolver` reads directly.
/// Callers treat any miss (no home, missing tables, desktop too old) as
/// "feature absent" and keep the flat views (R4 silent degrade).
///
/// Ordering is the DESKTOP's, not the retired wire convention: ascending
/// everywhere (group order rows ascending; unordered groups appended by
/// `(createdAt, id)` ascending; members by their effective sort ascending —
/// see [TaskGroupMember.effectiveSort]).
///
/// [TaskTokenUsage] remains a wire parse of `zcode-task.getTaskTokenUsage`
/// (live-probed 2026-09-18).
///
/// Widget-free: plain models.
library;

/// One task group (`task_groups` row).
class TaskGroupInfo {
  const TaskGroupInfo({
    required this.id,
    required this.title,
    this.color,
    this.createdAt = 0,
  });

  final String id;
  final String title;
  final String? color;
  final int createdAt;
}

/// One membership row (`task_group_members`): a task inside a group.
class TaskGroupMember {
  const TaskGroupMember({
    required this.groupId,
    required this.workspaceKey,
    required this.taskId,
    required this.effectiveSort,
  });

  final String groupId;

  /// The desktop's `workspace_key` in its native spelling — the match key
  /// between a membership and the task directory across workspaces.
  final String workspaceKey;

  final String taskId;

  /// The desktop's ordering value: `coalesce(sort_order, -added_at)` —
  /// never-manually-sorted members (NULL `sort_order`) sort by newest
  /// `added_at` first once ascending order is applied.
  final int effectiveSort;
}

/// The grouped task view: groups, their members and the top-level manual
/// ordering. Built by `TaskGroupResolver` from the index database; callers
/// keep the flat lists when it is null.
class GroupedTaskView {
  GroupedTaskView({
    required this.groups,
    required this.membersByGroup,
    this.groupSortOrder = const {},
  });

  final List<TaskGroupInfo> groups;
  final Map<String, List<TaskGroupMember>> membersByGroup;

  /// `sort_order` of the `node_type: 'group'` rows in
  /// `task_group_view_node_orders`; `node_type: 'task'` rows (the
  /// ungrouped tasks' top-level order) are not consumed.
  final Map<String, int> groupSortOrder;

  /// Render order of the groups, ascending (desktop `children()` +
  /// renderer): groups carrying an order row sort by
  /// `(sort_order, group id)`; order rows naming a deleted group are
  /// ignored; groups with no order row are appended by `(createdAt, id)`.
  List<TaskGroupInfo> orderedGroups() {
    final byId = {for (final g in groups) g.id: g};
    final ordered = <TaskGroupInfo>[];
    final seen = <String>{};
    final entries = groupSortOrder.entries.toList()
      ..sort((a, b) {
        final bySort = a.value.compareTo(b.value);
        return bySort != 0 ? bySort : a.key.compareTo(b.key);
      });
    for (final entry in entries) {
      final group = byId[entry.key];
      if (group != null && seen.add(group.id)) ordered.add(group);
    }
    final rest = [
      for (final g in groups)
        if (!seen.contains(g.id)) g,
    ]..sort((a, b) {
        final byCreated = a.createdAt.compareTo(b.createdAt);
        return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
      });
    return [...ordered, ...rest];
  }

  /// Members of [groupId] in render order: [TaskGroupMember.effectiveSort]
  /// ascending, ties broken by `(workspaceKey, taskId)` — the desktop's
  /// `ORDER BY sort_order, workspace_key, task_id`.
  List<TaskGroupMember> membersOf(String groupId) {
    final list = [...(membersByGroup[groupId] ?? const <TaskGroupMember>[])];
    list.sort((a, b) {
      final bySort = a.effectiveSort.compareTo(b.effectiveSort);
      if (bySort != 0) return bySort;
      final byWorkspace = a.workspaceKey.compareTo(b.workspaceKey);
      return byWorkspace != 0 ? byWorkspace : a.taskId.compareTo(b.taskId);
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
