import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';

/// Millisecond timings (same pattern as the overview-refresh tests); the
/// list watchdog is parked far out of the way.
const _fastTimings = StallTimings(
  healthyWaitTimeout: Duration(milliseconds: 40),
  rpcTimeout: Duration(milliseconds: 200),
  dialTimeout: Duration(milliseconds: 60),
  listReadyTimeout: Duration(seconds: 300),
  minRebuildInterval: Duration(milliseconds: 5),
  retryBackoff: Duration(milliseconds: 60),
);

/// Bootstraps from local tables; openBridge fails on purpose (the tests
/// never need a live bridge — the channel leg rides the debug gate).
class _OverviewStubClient extends RemoteClient {
  _OverviewStubClient(super.params);

  Map<String, dynamic> bootstrapResult = {
    'workspaces': [
      {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
    ],
    'tasks': [
      {
        'taskId': 'boot-1',
        'title': 'from bootstrap',
        'workspacePath': '/repo',
        'workspaceIdentity': 'repo-id',
        'displayStatus': 'idle',
        'updatedAt': 1,
        'pinned': true,
      },
    ],
  };

  @override
  Future<void> connect() => Future.value();

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() async => bootstrapResult;

  /// Relay push frames (`workspace-list-updated`).
  final workspaceUpdates = StreamController<dynamic>.broadcast();

  @override
  Stream<dynamic> get workspaceListUpdated => workspaceUpdates.stream;

  @override
  Future<BridgeSession> openBridge(
    String workspaceKey, {
    String? taskId,
    Map<String, dynamic>? project,
    String? taskHostId,
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      throw StateError('openBridge is not expected in this test');

  @override
  Future<void> dispose() => Future.value();
}

class _FakeGate implements WorkspaceGate {
  final calls = <(String, String, List<Object?>)>[];

  Future<dynamic> Function(String method, List<Object?> args)? handler;

  @override
  Future<void> waitHealthy({required Duration timeout}) => Future.value();

  @override
  Future<dynamic> call(String channel, String method, List<Object?> args) {
    calls.add((channel, method, List<Object?>.from(args)));
    final h = handler;
    if (h == null) throw StateError('no handler for $channel.$method');
    return h(method, args);
  }
}

RemoteConnectionParams _params() => RemoteConnectionParams.parse(
  'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=m&app_version=3.16.2',
)!;

Future<DeviceSession> _connected(_OverviewStubClient stub) async {
  final session = DeviceSession(
    deviceId: 'd1',
    params: _params(),
    timings: _fastTimings,
    clientFactory: () => stub,
  );
  await session.connect();
  return session;
}

/// A real 3.16.2 `listTaskList` item: the wire row carries NO
/// `pinned`/`archived` bits (asar rowToTaskListItem + live ITEM0).
Map<String, dynamic> _legResponse({
  required String taskId,
  String? title,
  String workspacePath = '/repo',
  String status = 'completed',
}) =>
    {
      'items': [
        {
          'taskId': taskId,
          'title': title ?? 'from $taskId',
          'workspacePath': workspacePath,
          'createdAt': 10,
          'updatedAt': 20,
          'status': status,
          'target': null,
        },
      ],
      'total': 1,
      'hasMore': false,
    };

Map<String, dynamic> _emptyLegResponse() => {
      'items': <Object>[],
      'total': 0,
      'hasMore': false,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bootstrap tasks leg wins when present (legacy desktop)', () async {
    final stub = _OverviewStubClient(_params());
    final session = await _connected(stub);
    final gate = _FakeGate();
    session.debugAttachGateForTest(gate);

    await session.refreshTaskOverview();

    expect(session.relayTasks.single['taskId'], 'boot-1');
    expect(
      gate.calls.where((c) => c.$2 == 'listTaskList'),
      isEmpty,
      reason: 'the legacy bootstrap leg must not call the 3.16 method',
    );
    await session.dispose();
  });

  test('no bootstrap tasks -> three listTaskList legs merged + tagged',
      () async {
    final stub = _OverviewStubClient(_params());
    stub.bootstrapResult = {
      'workspaces': [
        {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
      ],
    };
    final session = await _connected(stub);
    final gate = _FakeGate()
      ..handler = (method, args) async {
        if (method == 'listTaskList') {
          final arg = args.single as Map;
          expect(arg['workspaceScopes'], [
            {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
          ]);
          final kind = arg['kind'];
          if (kind == 'timeline') return _legResponse(taskId: 'tl-1');
          if (kind == 'pinned') return _legResponse(taskId: 'pin-1');
          if (kind == 'archived') return _legResponse(taskId: 'arc-1');
          throw StateError('unexpected kind $kind');
        }
        if (method == 'listPinnedTaskIds') return ['pin-1'];
        throw StateError('unexpected $method');
      };
    session.debugAttachGateForTest(gate);

    await session.refreshTaskOverview();

    expect(
      session.relayTasks.map((r) => r['taskId']).toList(),
      ['tl-1', 'pin-1', 'arc-1'],
      reason: 'timeline, pinned and archived rows all reach the overview',
    );
    // The wire rows carry no bits: the leg itself is the evidence.
    expect(session.relayTasks[1]['pinned'], isTrue,
        reason: 'the pinned leg tags its rows on merge');
    expect(session.relayTasks[2]['archived'], isTrue,
        reason: 'the archived leg tags its rows on merge');
    expect(session.relayTasks[0]['pinned'], isFalse,
        reason: 'listPinnedTaskIds overrides the merged flags');
    expect(session.relayTasks[0]['workspaceIdentity'], 'repo-id',
        reason: 'identity is reverse-looked-up by workspacePath');

    // Archived rows belong to the archive view only.
    final directory = session.taskDirectory;
    expect(
      directory
          .entriesFor('repo-id', includeArchived: true)
          .map((e) => e.$1.sessionId)
          .toList(),
      ['arc-1'],
    );
    final activeIds =
        directory.allEntries().map((e) => e.$1.sessionId).toList();
    expect(activeIds, isNot(contains('arc-1')));
    expect(activeIds, containsAll(['tl-1', 'pin-1']));
    expect(directory.totalTaskCount, 2,
        reason: 'archived rows must not count as active tasks');

    final kinds = gate.calls
        .where((c) => c.$2 == 'listTaskList')
        .map((c) => (c.$3.single as Map)['kind'])
        .toSet();
    expect(kinds, {'timeline', 'pinned', 'archived'});
    expect(gate.calls.last.$2, 'listPinnedTaskIds');
    await session.dispose();
  });

  test('any failing leg keeps the previous rows (no timeline-only overwrite)',
      () async {
    final stub = _OverviewStubClient(_params());
    stub.bootstrapResult = {
      'workspaces': [
        {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
      ],
    };
    final session = await _connected(stub);
    var failPinned = false;
    final gate = _FakeGate()
      ..handler = (method, args) async {
        if (method == 'listPinnedTaskIds') return ['pin-1'];
        final kind = (args.single as Map)['kind'];
        if (kind == 'pinned') {
          if (failPinned) throw ChannelRpcError('desktop exploded', null);
          return _legResponse(taskId: 'pin-1');
        }
        if (kind == 'archived') {
          return _legResponse(taskId: 'arc-1');
        }
        return _legResponse(taskId: 'tl-1');
      };
    session.debugAttachGateForTest(gate);

    await session.refreshTaskOverview();
    expect(
      session.relayTasks.map((r) => r['taskId']).toList(),
      ['tl-1', 'pin-1', 'arc-1'],
    );

    failPinned = true;
    await session.refreshTaskOverview();

    expect(
      session.relayTasks.map((r) => r['taskId']).toList(),
      ['tl-1', 'pin-1', 'arc-1'],
      reason: 'a failing leg must keep the whole previous overview',
    );
    await session.dispose();
  });

  test('a successful empty pinned leg clears stale pinned rows', () async {
    final stub = _OverviewStubClient(_params());
    stub.bootstrapResult = {
      'workspaces': [
        {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
      ],
    };
    final session = await _connected(stub);
    var pinnedIds = ['pin-1'];
    var pinnedRows = true;
    final gate = _FakeGate()
      ..handler = (method, args) async {
        if (method == 'listPinnedTaskIds') return pinnedIds;
        final kind = (args.single as Map)['kind'];
        if (kind == 'pinned') {
          return pinnedRows
              ? _legResponse(taskId: 'pin-1')
              : _emptyLegResponse();
        }
        if (kind == 'archived') {
          return _legResponse(taskId: 'arc-1');
        }
        return _legResponse(taskId: 'tl-1');
      };
    session.debugAttachGateForTest(gate);

    await session.refreshTaskOverview();
    expect(
      session.relayTasks.map((r) => r['taskId']).toList(),
      ['tl-1', 'pin-1', 'arc-1'],
    );

    // Unpinned on the desktop: the empty pinned leg is authoritative.
    pinnedRows = false;
    pinnedIds = [];
    await session.refreshTaskOverview();

    expect(
      session.relayTasks.map((r) => r['taskId']).toList(),
      ['tl-1', 'arc-1'],
    );
    expect(session.relayTasks.first['pinned'], isFalse);
    await session.dispose();
  });

  test('a task repeated across legs keeps one row (timeline wins)', () async {
    final stub = _OverviewStubClient(_params());
    stub.bootstrapResult = {
      'workspaces': [
        {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
      ],
    };
    final session = await _connected(stub);
    final gate = _FakeGate()
      ..handler = (method, args) async {
        if (method == 'listPinnedTaskIds') return ['dup-1'];
        final kind = (args.single as Map)['kind'];
        if (kind == 'timeline') {
          return _legResponse(taskId: 'dup-1', title: 'from timeline');
        }
        if (kind == 'pinned') {
          return _legResponse(taskId: 'dup-1', title: 'from pinned');
        }
        return _emptyLegResponse();
      };
    session.debugAttachGateForTest(gate);

    await session.refreshTaskOverview();

    expect(session.relayTasks, hasLength(1));
    expect(session.relayTasks.single['title'], 'from timeline',
        reason: 'the first leg to carry the triple wins');
    expect(session.relayTasks.single['pinned'], isTrue);
    await session.dispose();
  });

  test('a successful empty archived leg clears stale archived rows',
      () async {
    final stub = _OverviewStubClient(_params());
    stub.bootstrapResult = {
      'workspaces': [
        {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
      ],
    };
    final session = await _connected(stub);
    var archivedRows = true;
    final gate = _FakeGate()
      ..handler = (method, args) async {
        if (method == 'listPinnedTaskIds') return <String>[];
        final kind = (args.single as Map)['kind'];
        if (kind == 'timeline') return _legResponse(taskId: 'tl-1');
        if (kind == 'archived') {
          return archivedRows
              ? _legResponse(taskId: 'arc-1')
              : _emptyLegResponse();
        }
        return _emptyLegResponse();
      };
    session.debugAttachGateForTest(gate);

    await session.refreshTaskOverview();
    expect(
      session.relayTasks.map((r) => r['taskId']).toList(),
      ['tl-1', 'arc-1'],
    );

    // Unarchived on the desktop: the empty archived leg is authoritative.
    archivedRows = false;
    await session.refreshTaskOverview();

    expect(
      session.relayTasks.map((r) => r['taskId']).toList(),
      ['tl-1'],
    );
    expect(
      session.taskDirectory
          .entriesFor('repo-id', includeArchived: true)
          .map((e) => e.$1.sessionId)
          .toList(),
      isEmpty,
      reason: 'the stale archived row must leave the archive view too',
    );
    await session.dispose();
  });

  test('an empty-scopes round never leaks the in-flight task refresh',
      () async {
    final stub = _OverviewStubClient(_params());
    stub.bootstrapResult = {'workspaces': <Object>[]};
    final session = await _connected(stub);
    final gate = _FakeGate()
      ..handler = (method, args) async {
        if (method == 'listPinnedTaskIds') return <String>[];
        final kind = (args.single as Map)['kind'];
        return kind == 'timeline'
            ? _legResponse(taskId: 'tl-1')
            : _emptyLegResponse();
      };
    session.debugAttachGateForTest(gate);

    await session.refreshTaskOverview();
    expect(gate.calls, isEmpty,
        reason: 'empty scopes skip the desktop call');

    stub.bootstrapResult = {
      'workspaces': [
        {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
      ],
    };
    await session.refreshTaskOverview();

    expect(
      gate.calls.where((c) => c.$2 == 'listTaskList'),
      hasLength(3),
      reason: 'the second round must dial instead of joining a finished '
          'future parked in the dedup field',
    );
    expect(session.relayTasks.single['taskId'], 'tl-1');
    await session.dispose();
  });

  test('an empty overview never leaks the in-flight pinned merge', () async {
    final stub = _OverviewStubClient(_params());
    stub.bootstrapResult = {
      'workspaces': [
        {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
      ],
    };
    final session = await _connected(stub);
    var hasRows = false;
    final gate = _FakeGate()
      ..handler = (method, args) async {
        if (method == 'listPinnedTaskIds') {
          return hasRows ? ['tl-1'] : <String>[];
        }
        final kind = (args.single as Map)['kind'];
        if (!hasRows) return _emptyLegResponse();
        return kind == 'timeline'
            ? _legResponse(taskId: 'tl-1')
            : _emptyLegResponse();
      };
    session.debugAttachGateForTest(gate);

    await session.refreshTaskOverview();
    expect(session.relayTasks, isEmpty);
    expect(gate.calls.where((c) => c.$2 == 'listPinnedTaskIds'), isEmpty,
        reason: 'nothing to pin on an empty overview');

    hasRows = true;
    await session.refreshTaskOverview();

    expect(
      gate.calls.where((c) => c.$2 == 'listPinnedTaskIds'),
      hasLength(1),
      reason: 'the pinned merge must not stay disabled by a finished future',
    );
    expect(session.relayTasks.single['pinned'], isTrue);
    await session.dispose();
  });

  test('all channel legs failing keeps the previous rows', () async {
    final stub = _OverviewStubClient(_params());
    final session = await _connected(stub);
    expect(session.relayTasks.single['taskId'], 'boot-1');

    // 3.16.2 shape: no tasks key. Every kind answers like an old desktop
    // reporting Method not found.
    stub.bootstrapResult = {
      'workspaces': [
        {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
      ],
    };
    final gate = _FakeGate()
      ..handler = (method, args) async =>
          throw ChannelRpcError('Method not found', null);
    session.debugAttachGateForTest(gate);

    await session.refreshTaskOverview();

    expect(session.relayTasks.single['taskId'], 'boot-1',
        reason: 'a failing channel leg must never clear the overview');
    await session.dispose();
  });

  test('empty scopes skip listTaskList entirely (desktop would throw)',
      () async {
    final stub = _OverviewStubClient(_params());
    stub.bootstrapResult = {'workspaces': <Object>[]};
    final session = await _connected(stub);
    final gate = _FakeGate()
      ..handler = (method, args) async =>
          throw StateError('must not be called with empty scopes');
    session.debugAttachGateForTest(gate);

    await session.refreshTaskOverview();

    expect(gate.calls, isEmpty);
    expect(session.relayTasks, isEmpty);
    await session.dispose();
  });

  test('legacy leg keeps row pinned values, never asks listPinnedTaskIds',
      () async {
    final stub = _OverviewStubClient(_params());
    final session = await _connected(stub);
    expect(session.relayTasks.single['pinned'], isTrue);

    final gate = _FakeGate();
    session.debugAttachGateForTest(gate);

    await session.refreshTaskOverview();

    expect(session.relayTasks.single['taskId'], 'boot-1');
    expect(session.relayTasks.single['pinned'], isTrue,
        reason: 'legacy rows carry their own pinned bit');
    expect(gate.calls, isEmpty,
        reason: 'the cross-workspace pinned authority is 3.16.2-only');
    await session.dispose();
  });

  test('legacy push frame keeps its pinned bit, no listPinnedTaskIds',
      () async {
    final stub = _OverviewStubClient(_params());
    final session = await _connected(stub);
    final gate = _FakeGate();
    session.debugAttachGateForTest(gate);

    stub.workspaceUpdates.add({
      'workspaces': [
        {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
      ],
      'tasks': [
        {
          'taskId': 'push-1',
          'title': 'pushed',
          'workspacePath': '/repo',
          'workspaceIdentity': 'repo-id',
          'displayStatus': 'idle',
          'updatedAt': 2,
          'pinned': false,
        },
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(session.relayTasks.single['taskId'], 'push-1');
    expect(session.relayTasks.single['pinned'], isFalse,
        reason: 'a legacy push row keeps the pinned value it carried');
    expect(gate.calls, isEmpty,
        reason: 'no cross-workspace pinned merge on the legacy push path');
    await session.dispose();
  });
}
