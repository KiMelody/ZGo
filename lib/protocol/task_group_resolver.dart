import 'project_resolver.dart' show ProjectResolver;
import 'sqlite_pages.dart';
import 'task_groups.dart';

/// Reads the desktop task groups from `tasks-index.sqlite` — the native
/// replacement for the grouped-task RPC the desktop removed in 3.17.1
/// (research-group-tables: the renderer derives groups from the
/// `task_group_*` tables in the same database `ProjectResolver` already
/// reads).
///
/// Only three tables are walked (groups / members / view_node_orders): the
/// admissions ledger, the workspace bootstraps and a `tasks` join are not
/// needed — ZGo matches members against its own task directory.
///
/// Contract:
/// - ordering is the DESKTOP's, ascending on both axes (see
///   [GroupedTaskView.orderedGroups] / [GroupedTaskView.membersOf]);
/// - groups are global (no workspace column): the group itself is never
///   filtered by the current workspace;
/// - a missing table or a column-contract mismatch is DETERMINISTIC: cached
///   as null for the connection's lifetime (the desktop does not migrate
///   schema under us);
/// - channel failures (timeout / bridge swing) are TRANSIENT: not cached,
///   the next [load] retries;
/// - a successful answer is cached for [cacheTtl] (the panel opens read the
///   cache; the page re-pulls after the TTL, there is no push surface for
///   group writes);
/// - the page budget guards against a pathological database: a walk over
///   [maxPages] pages is treated as unusable (deterministic null).
///
/// WAL freshness (research §5.3, phase 1): the main file is read while the
/// desktop keeps writing in WAL. The 100-byte header's change counter is
/// captured before the walk and re-read after it; a mismatch (a checkpoint
/// wrote pages underneath the read) triggers exactly ONE retry, and a still
/// mismatching second read is used as-is (the window is tiny and a stale
/// group order self-heals on the next panel open).
class TaskGroupResolver {
  TaskGroupResolver({
    required String? Function() homeOf,
    required SqliteRangeRead readRange,
    void Function(String line)? onLog,
    int maxPages = 64,
    Duration cacheTtl = const Duration(seconds: 30),
    DateTime Function()? clock,
  })  : _homeOf = homeOf,
        _readRange = readRange,
        _log = onLog,
        _maxPages = maxPages,
        _cacheTtl = cacheTtl,
        _now = clock ?? DateTime.now;

  final String? Function() _homeOf;
  final SqliteRangeRead _readRange;
  final void Function(String line)? _log;
  final int _maxPages;
  final Duration _cacheTtl;
  final DateTime Function() _now;

  /// Last successful answer; [GroupedTaskView] is immutable enough to share.
  GroupedTaskView? _cached;

  /// When [_cached] was read (null = nothing cached).
  DateTime? _cachedAt;

  /// The last attempt answered a DETERMINISTIC outcome (success, no home, or
  /// an unusable database). Keeps missing tables from re-reading on every
  /// panel build; a successful answer still re-reads after [cacheTtl].
  bool _deterministicNull = false;

  /// Concurrent loads share one read (the same in-flight dedup pattern as
  /// [ProjectResolver.mapping]).
  Future<GroupedTaskView?>? _inFlight;

  int _lastPagesRead = 0;

  /// Pages touched by the last successful read — the page-budget guard's
  /// visible count (the acceptance bound is ~15 pages for the live index).
  int get lastPagesRead => _lastPagesRead;

  /// The grouped view, or null when it cannot be read (callers keep the
  /// flat list). Never throws.
  Future<GroupedTaskView?> load() {
    if (_deterministicNull) return Future.value(null);
    final at = _cachedAt;
    if (at != null && _now().difference(at) < _cacheTtl) {
      return Future.value(_cached);
    }
    final pending = _inFlight;
    if (pending != null) return pending;
    final future = _read();
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  Future<GroupedTaskView?> _read() async {
    final home = _home();
    if (home == null) {
      _log?.call('[taskGroup] no desktop home known — groups unavailable');
      // Deterministic: the workspace list will not grow a `.zcode/workspace`
      // entry without a reconnect.
      _deterministicNull = true;
      return null;
    }
    final path = ProjectResolver.indexPath(home);
    try {
      var attempt = await _readAttempt(path);
      if (!attempt.stable) {
        _log?.call('[taskGroup] change counter moved during the read '
            '(${attempt.pages} pages) — retrying once');
        attempt = await _readAttempt(path);
      }
      _lastPagesRead = attempt.pages;
      _cached = attempt.view;
      _cachedAt = _now();
      _log?.call('[taskGroup] groups loaded: ${attempt.view.groups.length} '
          'group(s), ${attempt.view.membersByGroup.length} group(s) with '
          'members (${attempt.pages} pages)');
      return attempt.view;
    } on SqliteFormatError catch (e) {
      // Missing tables / bad magic / column drift / page budget: the file
      // will not heal while this connection lives — cache the degraded
      // answer.
      _log?.call('[taskGroup] tasks-index task-group tables unusable ($e) — '
          'groups disabled');
      _cached = null;
      _cachedAt = null;
      _deterministicNull = true;
      return null;
    } catch (e) {
      // Transient (timeout / bridge swing / channel error): degrade THIS
      // open only; the next load retries.
      _log?.call('[taskGroup] tasks-index group read failed ($e) — will '
          'retry');
      return null;
    }
  }

  /// One full read of the three tables. [stable] is false when the file
  /// header's change counter moved between the opening header read and the
  /// closing one.
  Future<
      ({
        GroupedTaskView view,
        bool stable,
        int pages,
      })> _readAttempt(String path) async {
    final reader = await SqlitePageReader.open(path, _readRange);
    final before = changeCounterOf(reader.header);

    // sqlite_master: (type, name, tbl_name, rootpage, sql).
    int? groupsRoot;
    int? membersRoot;
    int? ordersRoot;
    for (final row in await reader.scanTable(1)) {
      if (row.length < 4 || row[0] != 'table') continue;
      final root = row[3];
      if (root is! int || root <= 0) continue;
      switch (row[1]) {
        case 'task_groups':
          groupsRoot = root;
        case 'task_group_members':
          membersRoot = root;
        case 'task_group_view_node_orders':
          ordersRoot = root;
      }
    }
    if (groupsRoot == null || membersRoot == null || ordersRoot == null) {
      throw const SqliteFormatError('missing task_group tables');
    }

    // task_groups: 0=group_id, 1=title, 2=color, 3=created_at,
    // 4=updated_at.
    final groups = <TaskGroupInfo>[];
    for (final row in await reader.scanTable(groupsRoot)) {
      if (row.length < 5) {
        throw const SqliteFormatError('task_groups column contract');
      }
      final id = row[0];
      if (id is! String || id.isEmpty) continue;
      final title = row[1];
      final color = row[2];
      final createdAt = row[3];
      groups.add(
        TaskGroupInfo(
          id: id,
          title: title is String ? title : '',
          color: color is String && color.isNotEmpty ? color : 'gray',
          createdAt: createdAt is int ? createdAt : 0,
        ),
      );
    }

    // task_group_members: 0=group_id, 1=workspace_key, 2=workspace_path,
    // 3=workspace_identity, 4=task_id, 5=sort_order, 6=added_at. The
    // effective order is the desktop's coalesce(sort_order, -added_at).
    // Dangling members are kept — the UI filters against the task
    // directory (pinned/archived/missing rows never render).
    final membersByGroup = <String, List<TaskGroupMember>>{};
    for (final row in await reader.scanTable(membersRoot)) {
      if (row.length < 7) {
        throw const SqliteFormatError('task_group_members column contract');
      }
      final groupId = row[0];
      final workspaceKey = row[1];
      final taskId = row[4];
      if (groupId is! String || groupId.isEmpty) continue;
      if (workspaceKey is! String || workspaceKey.isEmpty) continue;
      if (taskId is! String || taskId.isEmpty) continue;
      final sortOrder = row[5];
      final addedAt = row[6];
      final effectiveSort = sortOrder is int
          ? sortOrder
          : -(addedAt is int ? addedAt : 0);
      membersByGroup.putIfAbsent(groupId, () => []).add(
            TaskGroupMember(
              groupId: groupId,
              workspaceKey: workspaceKey,
              taskId: taskId,
              effectiveSort: effectiveSort,
            ),
          );
    }

    // task_group_view_node_orders: 0=node_type, 1=node_key, 2=sort_order.
    // Only `group` rows matter; `task` rows order ungrouped tasks in the
    // desktop's own top-level list, which ZGo does not consume.
    final groupSortOrder = <String, int>{};
    for (final row in await reader.scanTable(ordersRoot)) {
      if (row.length < 3) {
        throw const SqliteFormatError(
            'task_group_view_node_orders column contract');
      }
      if (row[0] != 'group') continue;
      final key = row[1];
      final sort = row[2];
      if (key is String && key.isNotEmpty && sort is int) {
        groupSortOrder[key] = sort;
      }
    }

    if (reader.pagesRead > _maxPages) {
      throw SqliteFormatError(
          'task group page budget exceeded (${reader.pagesRead} > $_maxPages)');
    }

    // WAL freshness: the closing header read detects a checkpoint that
    // wrote pages while the walk was in flight.
    final after = await _readRange(path, 0, SqlitePageReader.headerBytes);
    final stable = changeCounterOf(after) == before;

    return (
      view: GroupedTaskView(
        groups: groups,
        membersByGroup: membersByGroup,
        groupSortOrder: groupSortOrder,
      ),
      stable: stable,
      pages: reader.pagesRead,
    );
  }

  /// The home seam never throws into the resolver.
  String? _home() {
    try {
      return _homeOf();
    } catch (e) {
      _log?.call('[taskGroup] home lookup failed ($e)');
      return null;
    }
  }
}
