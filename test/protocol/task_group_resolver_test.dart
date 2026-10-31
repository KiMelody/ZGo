import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:zgo/protocol/task_group_resolver.dart';

/// Direct read of the desktop `task_group_*` tables (desktop 3.17.1 removed
/// the RPC). The fixture databases are built with package:sqlite3 (dev
/// dependency only; the resolver is pure Dart page reading).
///
/// The ordering assertions are the load-bearing part: the desktop sorts
/// ASCENDING on both axes (research-group-tables §3.7) — the retired wire
/// convention was descending and must not come back.
void main() {
  const home = 'C:/Users/Melody';

  TaskGroupResolver resolverFor(
    _FakeIndex index, {
    String? Function()? homeOf,
    int maxPages = 64,
    Duration cacheTtl = const Duration(seconds: 30),
    DateTime Function()? clock,
    void Function(String)? onLog,
  }) =>
      TaskGroupResolver(
        homeOf: homeOf ?? () => home,
        readRange: index.read,
        maxPages: maxPages,
        cacheTtl: cacheTtl,
        clock: clock,
        onLog: onLog,
      );

  test('groups, members and order rows assemble with desktop ascending '
      'order', () async {
    final index = _FakeIndex(_fixture(
      groups: [
        {'id': 'g2', 'title': 'B', 'color': 'blue', 'createdAt': 40},
        {'id': 'g1', 'title': 'A', 'color': 'purple', 'createdAt': 30},
        {'id': 'g4', 'title': 'D', 'color': 'gray', 'createdAt': 10},
        {'id': 'g3', 'title': 'C', 'color': 'red', 'createdAt': 20},
      ],
      members: [
        {
          'groupId': 'g1',
          'workspaceKey': 'k1',
          'taskId': 't1',
          'sortOrder': null,
          'addedAt': 500,
        },
        {
          'groupId': 'g1',
          'workspaceKey': 'k2',
          'taskId': 't2',
          'sortOrder': 0,
          'addedAt': 10,
        },
        {
          'groupId': 'g1',
          'workspaceKey': 'k3',
          'taskId': 't3',
          'sortOrder': 2,
          'addedAt': 5,
        },
        {
          'groupId': 'g2',
          'workspaceKey': 'k1',
          'taskId': 't4',
          'sortOrder': 1,
          'addedAt': 1,
        },
        {
          'groupId': 'g2',
          'workspaceKey': 'k1',
          'taskId': 't5',
          'sortOrder': null,
          'addedAt': 100,
        },
        // A dangling membership (group no longer in task_groups) is kept;
        // the consumer filters against its task directory.
        {
          'groupId': 'ghost',
          'workspaceKey': 'k9',
          'taskId': 't9',
          'sortOrder': 0,
          'addedAt': 0,
        },
      ],
      orders: [
        {'type': 'group', 'key': 'g2', 'sortOrder': 3},
        {'type': 'group', 'key': 'g1', 'sortOrder': 1},
        // Order row naming a deleted group: ignored.
        {'type': 'group', 'key': 'gone', 'sortOrder': 0},
        // Task rows order ungrouped tasks on the desktop; not consumed.
        {'type': 'task', 'key': '["k1","t1"]', 'sortOrder': -5},
      ],
    ));
    final logs = <String>[];
    final resolver = resolverFor(index, onLog: logs.add);

    final view = await resolver.load();
    expect(view, isNotNull);
    expect(
      [for (final g in view!.orderedGroups()) g.id],
      ['g1', 'g2', 'g4', 'g3'],
      reason: 'manual sort_order ascending first; groups without an order '
          'row appended by (createdAt, id)',
    );
    final byId = {for (final g in view.groups) g.id: g};
    expect(byId['g1']!.title, 'A');
    expect(byId['g1']!.color, 'purple');
    expect(byId['g4']!.createdAt, 10);

    expect(
      [for (final m in view.membersOf('g1')) m.taskId],
      ['t1', 't2', 't3'],
      reason: 'coalesce(sort_order, -added_at) ascending: the never-sorted '
          'member added last (-500) leads',
    );
    expect(
      [for (final m in view.membersOf('g2')) m.taskId],
      ['t5', 't4'],
    );
    expect(
      [for (final m in view.membersOf('g1')) m.workspaceKey],
      ['k1', 'k2', 'k3'],
      reason: 'the desktop workspace_key rides on every member',
    );
    expect(view.membersByGroup['ghost'], isNotEmpty,
        reason: 'dangling members survive the resolver');
    expect(view.groupSortOrder, {'g2': 3, 'g1': 1, 'gone': 0},
        reason: 'only group rows are read; task rows are ignored');
    expect(index.paths.toSet(),
        {r'C:/Users/Melody\.zcode\v2\tasks-index.sqlite'},
        reason: 'the task-group tables live in the same index ProjectResolver '
            'reads — one shared path derivation');
    expect(resolver.lastPagesRead, lessThanOrEqualTo(20),
        reason: 'three small tables stay far inside the page budget');
    expect(logs.join('\n'), contains('pages'));
  });

  test('missing table answers null deterministically', () async {
    final index = _FakeIndex(_fixture(createOrders: false));
    final logs = <String>[];
    final resolver = resolverFor(index, onLog: logs.add);

    expect(await resolver.load(), isNull);
    final reads = index.calls;
    expect(await resolver.load(), isNull);
    expect(index.calls, reads,
        reason: 'a missing table will not appear without a desktop schema '
            'change — cached for the connection');
    expect(logs.join('\n'), contains('missing task_group tables'));
  });

  test('a column-contract mismatch answers null and stays cached', () async {
    final index = _FakeIndex(_fixture(
      narrowGroups: true,
      groups: [
        {'id': 'g1', 'title': 'A', 'color': 'gray', 'createdAt': 1},
      ],
    ));
    final logs = <String>[];
    final resolver = resolverFor(index, onLog: logs.add);

    expect(await resolver.load(), isNull);
    final reads = index.calls;
    expect(await resolver.load(), isNull);
    expect(index.calls, reads);
    expect(logs.join('\n'), contains('task_groups column contract'));
  });

  test('empty tables answer an empty view, not a failure', () async {
    final resolver = resolverFor(_FakeIndex(_fixture()));

    final view = await resolver.load();
    expect(view, isNotNull);
    expect(view!.groups, isEmpty);
    expect(view.orderedGroups(), isEmpty);
    expect(view.membersOf('whatever'), isEmpty);
  });

  test('a successful view is cached for the TTL and re-read after it',
      () async {
    var now = DateTime(2026, 10, 30, 12);
    final index = _FakeIndex(_fixture(
      groups: [
        {'id': 'g1', 'title': 'A', 'color': 'blue', 'createdAt': 1},
      ],
    ));
    final resolver = resolverFor(index, clock: () => now);

    final first = await resolver.load();
    expect(first, isNotNull);
    final reads = index.calls;
    expect(await resolver.load(), same(first));
    expect(index.calls, reads, reason: 'inside the 30s TTL');

    now = now.add(const Duration(seconds: 29));
    expect(await resolver.load(), same(first));
    expect(index.calls, reads, reason: 'still inside the TTL');

    now = now.add(const Duration(seconds: 2));
    final refreshed = await resolver.load();
    expect(refreshed, isNotNull);
    expect(index.calls, greaterThan(reads),
        reason: 'the TTL expired — the panel-open read re-pulls');
    expect(refreshed, isNot(same(first)));
  });

  test('a transient read failure is not cached', () async {
    final index = _FakeIndex(_fixture(
      groups: [
        {'id': 'g1', 'title': 'A', 'color': 'blue', 'createdAt': 1},
      ],
    ));
    var failures = 1;
    final resolver = TaskGroupResolver(
      homeOf: () => home,
      readRange: (path, offset, length) async {
        if (failures > 0) {
          failures--;
          throw TimeoutException('bridge swing', const Duration(seconds: 30));
        }
        return index.read(path, offset, length);
      },
    );

    expect(await resolver.load(), isNull,
        reason: 'the affected panel open degrades to flat');
    expect(await resolver.load(), isNotNull,
        reason: 'a transient failure is NOT cached — the next open retries');
  });

  test('a moved change counter triggers exactly one retry', () async {
    final index = _FakeIndex(_fixture(
      groups: [
        {'id': 'g1', 'title': 'A', 'color': 'blue', 'createdAt': 1},
      ],
    ));
    // The second 100-byte header read is the closing checkpoint read.
    index.flipOnHeaderRead = 2;
    final logs = <String>[];
    final resolver = resolverFor(index, onLog: logs.add);

    final view = await resolver.load();
    expect(view, isNotNull);
    expect(index.headerReads, 4,
        reason: 'open+close, then one retried open+close');
    expect(logs.join('\n'), contains('retrying once'));
  });

  test('a still-unstable second read uses its answer', () async {
    final index = _FakeIndex(_fixture(
      groups: [
        {'id': 'g1', 'title': 'A', 'color': 'blue', 'createdAt': 1},
      ],
    ));
    // Every closing header read sees a new counter: both attempts are
    // unstable; the second attempt's answer is still delivered.
    index.flipEveryPostRead = true;
    final resolver = resolverFor(index);

    final view = await resolver.load();
    expect(view, isNotNull);
    expect(view!.groups.single.id, 'g1');
    expect(index.headerReads, 4, reason: 'exactly one retry, never a loop');
  });

  test('the page budget bounds a pathological database', () async {
    final index = _FakeIndex(_fixture(
      groups: [
        for (var i = 0; i < 120; i++)
          {
            'id': 'g$i',
            'title': 'x' * 4000,
            'color': 'gray',
            'createdAt': i,
          },
      ],
    ));
    final logs = <String>[];
    final resolver = resolverFor(index, onLog: logs.add);

    expect(await resolver.load(), isNull);
    final reads = index.calls;
    expect(await resolver.load(), isNull);
    expect(index.calls, reads,
        reason: 'the budget failure is deterministic (cached null)');
    expect(logs.join('\n'), contains('page budget'));
  });

  test('no known desktop home answers null without touching the file',
      () async {
    final index = _FakeIndex(_fixture());
    final resolver = resolverFor(index, homeOf: () => null);

    expect(await resolver.load(), isNull);
    expect(await resolver.load(), isNull);
    expect(index.calls, 0);
  });

  test('a throwing home seam degrades instead of throwing', () async {
    final index = _FakeIndex(_fixture());
    final resolver = resolverFor(
      index,
      homeOf: () => throw StateError('boom'),
    );

    expect(await resolver.load(), isNull);
    expect(index.calls, 0);
  });

  test('a non-sqlite file degrades and stays cached', () async {
    final index = _FakeIndex(
      Uint8List.fromList('definitely not sqlite'.codeUnits),
    );
    final resolver = resolverFor(index);

    expect(await resolver.load(), isNull);
    expect(await resolver.load(), isNull);
    expect(index.calls, 1,
        reason: 'bad magic answers from the 100-byte header alone and is '
            'cached for the connection');
  });
}

/// Byte-view read seam: answers exactly the requested slice (the page
/// reader's offset/length arithmetic exercised as on the wire). The data is
/// mutable so tests can move the change counter between reads.
class _FakeIndex {
  _FakeIndex(this.data);

  Uint8List data;
  int calls = 0;
  int headerReads = 0;
  final List<String> paths = [];

  /// Flip the file change counter when this 1-based header read happens.
  int? flipOnHeaderRead;

  /// Flip the file change counter on every closing header read (2nd, 4th…).
  bool flipEveryPostRead = false;

  Future<Uint8List> read(String path, int offset, int length) async {
    calls++;
    paths.add(path);
    if (offset == 0 && length == 100) {
      headerReads++;
      if (flipOnHeaderRead == headerReads ||
          (flipEveryPostRead && headerReads.isEven)) {
        // Offset 27 is the low byte of the 4-byte change counter.
        data[27] ^= 1;
      }
    }
    if (offset >= data.length) return Uint8List(0);
    final end = offset + length > data.length ? data.length : offset + length;
    return Uint8List.sublistView(data, offset, end);
  }
}

const _groupsDdl = '''
CREATE TABLE task_groups (
  group_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  color TEXT NOT NULL DEFAULT 'gray',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)''';

const _membersDdl = '''
CREATE TABLE task_group_members (
  group_id TEXT NOT NULL,
  workspace_key TEXT NOT NULL,
  workspace_path TEXT NOT NULL,
  workspace_identity TEXT,
  task_id TEXT NOT NULL,
  sort_order INTEGER,
  added_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (workspace_key, task_id)
)''';

const _ordersDdl = '''
CREATE TABLE task_group_view_node_orders (
  node_type TEXT NOT NULL,
  node_key TEXT NOT NULL,
  sort_order INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (node_type, node_key)
)''';

/// Builds a real SQLite file in a temp dir and returns its bytes — the same
/// shape the resolver gets off the wire (main db file only; a plain rollback
/// journal leaves no -wal sidecar). The DDLs are the measured 3.17.1
/// schemas (research-group-tables §3).
Uint8List _fixture({
  bool createGroups = true,
  bool createMembers = true,
  bool createOrders = true,
  bool narrowGroups = false,
  List<Map<String, Object?>> groups = const [],
  List<Map<String, Object?>> members = const [],
  List<Map<String, Object?>> orders = const [],
}) {
  final dir = Directory.systemTemp.createTempSync('zgo_group_fixture_');
  final path = '${dir.path}${Platform.pathSeparator}index.sqlite';
  final db = sqlite3.open(path);
  try {
    if (createGroups) {
      if (narrowGroups) {
        db.execute('CREATE TABLE task_groups('
            'group_id TEXT, title TEXT, color TEXT, created_at INTEGER)');
      } else {
        db.execute(_groupsDdl);
      }
      for (final g in groups) {
        if (narrowGroups) {
          db.execute(
            'INSERT INTO task_groups(group_id,title,color,created_at) '
            'VALUES(?,?,?,?)',
            [g['id'], g['title'], g['color'], g['createdAt']],
          );
        } else {
          db.execute(
            'INSERT INTO task_groups('
            'group_id,title,color,created_at,updated_at) VALUES(?,?,?,?,?)',
            [
              g['id'],
              g['title'],
              g['color'] ?? 'gray',
              g['createdAt'],
              g['createdAt'],
            ],
          );
        }
      }
    }
    if (createMembers) {
      db.execute(_membersDdl);
      for (final m in members) {
        db.execute(
          'INSERT INTO task_group_members('
          'group_id,workspace_key,workspace_path,workspace_identity,task_id,'
          'sort_order,added_at,created_at,updated_at) '
          'VALUES(?,?,?,?,?,?,?,?,?)',
          [
            m['groupId'],
            m['workspaceKey'] ?? 'w',
            m['workspacePath'] ?? 'p',
            m['workspaceIdentity'],
            m['taskId'],
            m['sortOrder'],
            m['addedAt'] ?? 0,
            0,
            0,
          ],
        );
      }
    }
    if (createOrders) {
      db.execute(_ordersDdl);
      for (final o in orders) {
        db.execute(
          'INSERT INTO task_group_view_node_orders('
          'node_type,node_key,sort_order,created_at,updated_at) '
          'VALUES(?,?,?,?,?)',
          [o['type'] ?? 'group', o['key'], o['sortOrder'], 0, 0],
        );
      }
    }
  } finally {
    db.dispose();
  }
  final bytes = File(path).readAsBytesSync();
  dir.deleteSync(recursive: true);
  return bytes;
}
