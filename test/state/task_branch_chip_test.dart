import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/conversation_state.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';

/// Millisecond timings (same pattern as the overview-refresh tests).
StallTimings _timings(Duration rpcTimeout) => StallTimings(
  healthyWaitTimeout: const Duration(milliseconds: 40),
  rpcTimeout: rpcTimeout,
  dialTimeout: const Duration(milliseconds: 60),
  listReadyTimeout: const Duration(seconds: 300),
  minRebuildInterval: const Duration(milliseconds: 5),
  retryBackoff: const Duration(milliseconds: 60),
);

/// Bootstraps from local tables; openBridge fails on purpose (the branch
/// round rides the debug gate, not a live bridge).
class _StubClient extends RemoteClient {
  _StubClient(super.params);

  Map<String, dynamic> bootstrapResult = {
    'workspaces': [
      {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
    ],
  };

  @override
  Future<void> connect() => Future.value();

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() async => bootstrapResult;

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

class _ChipGate implements WorkspaceGate {
  final calls = <(String, String, List<Object?>)>[];

  Future<dynamic> Function(String channel, String method, List<Object?> args)?
      handler;

  @override
  Future<void> waitHealthy({required Duration timeout}) => Future.value();

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration? timeout,
  }) {
    calls.add((channel, method, List<Object?>.from(args)));
    final h = handler;
    if (h == null) throw StateError('no handler for $channel.$method');
    return h(channel, method, args);
  }

  int get gitCalls => calls.where((c) => c.$1 == Channels.git).length;
}

RemoteConnectionParams _params() => RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=m&app_version=3.16.2',
    )!;

Future<DeviceSession> _connectedWith(
  List<_StubClient> stubs,
  _ChipGate gate, {
  Duration rpcTimeout = const Duration(milliseconds: 200),
  void Function()? onClientCreated,
}) async {
  var index = 0;
  final session = DeviceSession(
    deviceId: 'd1',
    params: _params(),
    timings: _timings(rpcTimeout),
    clientFactory: () {
      onClientCreated?.call();
      return stubs[index < stubs.length ? index++ : stubs.length - 1];
    },
    overviewRefreshThrottle: Duration.zero,
  );
  await session.connect();
  session.debugAttachGateForTest(gate);
  return session;
}

Future<DeviceSession> _connected(
  _StubClient stub,
  _ChipGate gate, {
  void Function()? onClientCreated,
}) =>
    _connectedWith([stub], gate, onClientCreated: onClientCreated);

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'condition not reached in 2s');
}

/// A 3.16.2 `listTaskList` item carrying the 3.18.0 worktree placement.
Map<String, dynamic> _worktreeTask(
  String id, {
  String? worktreeRoot = '/repo/.worktrees/feat',
  String? cwd = '/repo/.worktrees/feat',
  bool pinned = false,
}) =>
    {
      'taskId': id,
      'title': id,
      'workspacePath': '/repo',
      'createdAt': 1,
      'updatedAt': 2,
      'status': 'idle',
      if (worktreeRoot != null) 'worktreeRoot': worktreeRoot,
      if (cwd != null) 'cwd': cwd,
      if (pinned) 'pinned': true,
    };

/// Overview legs + one programmable git answer.
Future<dynamic> Function(String, String, List<Object?>)
    _responder({
  required List<Map<String, dynamic>> tasks,
  required Future<dynamic> Function(String path) git,
}) =>
        (channel, method, args) async {
          if (channel == Channels.zcodeTask) {
            if (method == 'listTaskList') {
              final arg = args.single as Map;
              if (arg['kind'] == 'timeline') {
                return {
                  'items': tasks,
                  'total': tasks.length,
                  'hasMore': false,
                };
              }
              return {'items': <Object>[], 'total': 0, 'hasMore': false};
            }
            if (method == 'listPinnedTaskIds') return <String>[];
          }
          if (channel == Channels.git) {
            final arg = args.single as Map;
            return git(arg['workspacePath'] as String);
          }
          throw StateError('unexpected $channel.$method');
        };

Map<String, dynamic> _branchAnswer(String? branch) => {
      'kind': 'linked-worktree',
      'isRepository': true,
      'branchName': branch,
      'headRefType': branch == null ? 'detached' : 'branch',
    };

typedef _Git = Future<dynamic> Function(String method, String path);

/// Like [_responder], but the git answer is re-read per call: the
/// late-answer tests swap the closure mid-round (old link parked, new link
/// healthy without the old round noticing).
Future<dynamic> Function(String, String, List<Object?>) _gitResponder({
  required List<Map<String, dynamic>> tasks,
  required _Git Function() git,
}) =>
    (channel, method, args) async {
      if (channel == Channels.zcodeTask) {
        if (method == 'listTaskList') {
          final arg = args.single as Map;
          if (arg['kind'] == 'timeline') {
            return {'items': tasks, 'total': tasks.length, 'hasMore': false};
          }
          return {'items': <Object>[], 'total': 0, 'hasMore': false};
        }
        if (method == 'listPinnedTaskIds') return <String>[];
      }
      if (channel == Channels.git) {
        final arg = args.single as Map;
        return git()(method, arg['workspacePath'] as String);
      }
      throw StateError('unexpected $channel.$method');
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one refresh round resolves each worktree path once and the rows '
      'read the cached branch without more RPCs', () async {
    final stub = _StubClient(_params());
    final gate = _ChipGate();
    gate.handler = _responder(
      tasks: [_worktreeTask('t1'), _worktreeTask('t2')],
      git: (path) async {
        expect(path, '/repo/.worktrees/feat',
            reason: 'the official precedence prefers cwd over worktreeRoot');
        return _branchAnswer('feat/login');
      },
    );
    final session = await _connected(stub, gate);

    await session.refreshTaskOverview();

    expect(gate.gitCalls, 1,
        reason: 'two rows share one path — one git RPC in the round');
    final rows = session.taskDirectory.allEntries();
    expect(rows, hasLength(2));
    for (final (entry, _) in rows) {
      expect(session.worktreeBranchFor(entry), 'feat/login');
    }
    // The accessor is pure cache: reading it never dials.
    session.worktreeBranchFor(rows.first.$1);
    session.worktreeBranchFor(rows.last.$1);
    expect(gate.gitCalls, 1);
    await session.dispose();
  });

  test('the branch round runs AFTER the task rows land (same refresh)',
      () async {
    final stub = _StubClient(_params());
    final gate = _ChipGate();
    gate.handler = _responder(
      tasks: [_worktreeTask('t1')],
      git: (_) async => _branchAnswer('feat/login'),
    );
    final session = await _connected(stub, gate);

    await session.refreshTaskOverview();

    final lastListTaskList =
        gate.calls.lastIndexWhere((c) => c.$2 == 'listTaskList');
    final firstGit = gate.calls.indexWhere((c) => c.$1 == Channels.git);
    expect(firstGit, greaterThan(lastListTaskList),
        reason: 'the lookup needs the landed rows to know the worktree paths');
    await session.dispose();
  });

  test('a branch name is refreshed per cycle and cleared by suspend',
      () async {
    final stub = _StubClient(_params());
    final gate = _ChipGate()
      ..handler = _responder(
        tasks: [_worktreeTask('t1')],
        git: (_) async => _branchAnswer('feat/login'),
      );
    final session = await _connected(stub, gate);

    await session.refreshTaskOverview();
    final entry = session.taskDirectory.allEntries().single.$1;
    expect(session.worktreeBranchFor(entry), 'feat/login');

    await session.refreshTaskOverview();
    expect(gate.gitCalls, 2,
        reason: 'each cadence round re-reads the worktree branch');
    expect(session.worktreeBranchFor(entry), 'feat/login');

    await session.suspend();
    expect(session.worktreeBranchFor(entry), isNull,
        reason: 'a reconnect must not show the old link\'s branch');
    await session.dispose();
  });

  test('connect clears branch evidence left from a previous episode',
      () async {
    final stub = _StubClient(_params());
    final gate = _ChipGate()
      ..handler = _responder(
        tasks: [_worktreeTask('t1')],
        git: (_) async => _branchAnswer('feat/login'),
      );
    final session = await _connected(stub, gate);
    final probe = SessionEntry.fromRelayTask(_worktreeTask('t1'));

    await session.refreshTaskOverview();
    expect(session.worktreeBranchFor(probe), 'feat/login');

    await session.suspend();
    // A retry-style reconnect does not pass through suspend in production;
    // seed the residual cache so connect's OWN clear is the thing under test.
    session.debugSeedTaskBranch('/repo/.worktrees/feat', 'feat/stale');
    await session.connect();
    expect(session.worktreeBranchFor(probe), isNull,
        reason: 'connect starts a new episode with no branch evidence');
    await session.dispose();
  });

  test('a new connection retries a lookup the old one disabled', () async {
    final stub = _StubClient(_params());
    final gate = _ChipGate()
      ..handler = _responder(
        tasks: [_worktreeTask('t1')],
        git: (_) async =>
            throw ChannelRpcError('no such method: getRepositorySummary', null),
      );
    final session = await _connected(stub, gate);
    final probe = SessionEntry.fromRelayTask(_worktreeTask('t1'));

    await session.refreshTaskOverview();
    final afterMissing = gate.gitCalls;
    expect(afterMissing, greaterThan(0));

    await session.suspend();
    await session.connect();
    gate.handler = _responder(
      tasks: [_worktreeTask('t1')],
      git: (_) async => _branchAnswer('feat/new'),
    );
    await session.refreshTaskOverview();

    expect(gate.gitCalls, greaterThan(afterMissing),
        reason: 'the deterministic-miss negative cache is per connection');
    expect(session.worktreeBranchFor(probe), 'feat/new');
    await session.dispose();
  });

  test('a late branch answer from a suspended link never lands in the cache',
      () async {
    final gate = _ChipGate();
    final parked = Completer<dynamic>();
    _Git git = (_, __) => parked.future;
    gate.handler = _gitResponder(tasks: [_worktreeTask('t1')], git: () => git);
    final session = await _connectedWith(
      [_StubClient(_params()), _StubClient(_params())],
      gate,
    );
    final probe = SessionEntry.fromRelayTask(_worktreeTask('t1'));

    final roundA = session.refreshTaskOverview();
    await _until(() => gate.gitCalls == 1);
    await session.suspend();
    parked.complete(_branchAnswer('feat/late'));
    await roundA;

    expect(session.worktreeBranchFor(probe), isNull,
        reason: 'the old link\'s late answer must not repopulate the cache');

    git = (_, __) async => _branchAnswer('feat/new');
    await session.connect();
    await session.refreshTaskOverview();
    expect(session.worktreeBranchFor(probe), 'feat/new');
    await session.dispose();
  });

  test('a late missing-method failure must not poison the new connection\'s '
      'negative cache', () async {
    final gate = _ChipGate();
    final parked = Completer<dynamic>();
    var parkedOnce = false;
    _Git git = (method, _) {
      if (!parkedOnce) {
        parkedOnce = true;
        return parked.future;
      }
      throw ChannelRpcError('no such method: $method', null);
    };
    gate.handler = _gitResponder(tasks: [_worktreeTask('t1')], git: () => git);
    final session = await _connectedWith(
      [_StubClient(_params()), _StubClient(_params())],
      gate,
    );
    final probe = SessionEntry.fromRelayTask(_worktreeTask('t1'));

    final roundA = session.refreshTaskOverview();
    await _until(() => gate.gitCalls == 1);
    await session.suspend();
    await session.connect(); // new link: the negative cache resets here
    parked.completeError(
        ChannelRpcError('no such method: getRepositorySummary', null));
    await roundA; // the OLD round's catch block runs against the NEW link

    git = (_, __) async => _branchAnswer('feat/new');
    final before = gate.gitCalls;
    await session.refreshTaskOverview();
    expect(gate.gitCalls, greaterThan(before),
        reason: 'the new link must still dial git');
    expect(session.worktreeBranchFor(probe), 'feat/new');
    await session.dispose();
  });

  test('a late timeout must not erase the branch the new round just cached',
      () async {
    final gate = _ChipGate();
    final never = Completer<dynamic>();
    _Git git = (_, __) => never.future;
    gate.handler = _gitResponder(tasks: [_worktreeTask('t1')], git: () => git);
    final session = await _connectedWith(
      [_StubClient(_params()), _StubClient(_params())],
      gate,
      // Long enough that round B can cache before round A's timeout fires.
      rpcTimeout: const Duration(seconds: 1),
    );
    final probe = SessionEntry.fromRelayTask(_worktreeTask('t1'));

    final roundA = session.refreshTaskOverview(); // times out at ~+1s
    await _until(() => gate.gitCalls == 1);
    await session.suspend();
    git = (_, __) async => _branchAnswer('feat/new');
    await session.connect();
    await session.refreshTaskOverview(); // round B (suspend nulled the join)
    expect(session.worktreeBranchFor(probe), 'feat/new',
        reason: 'precondition: round B cached before round A timed out');

    await roundA; // the old round's TimeoutException lands now
    expect(session.worktreeBranchFor(probe), 'feat/new',
        reason: 'a late timeout of the old link must not touch the new cache');
    await session.dispose();
  });

  test('non-worktree rows never touch the git channel', () async {
    final stub = _StubClient(_params());
    final gate = _ChipGate();
    final session = await _connected(stub, gate);
    gate.handler = _responder(
      tasks: [_worktreeTask('t1', worktreeRoot: null, cwd: null)],
      git: (_) async => fail('git must not be called'),
    );

    await session.refreshTaskOverview();

    expect(gate.gitCalls, 0);
    final entry = session.taskDirectory.allEntries().single.$1;
    expect(entry.raw['worktreeRoot'], isNull);
    expect(session.worktreeBranchFor(entry), isNull);
    await session.dispose();
  });

  test('a detached HEAD (null branchName) shows no chip', () async {
    final stub = _StubClient(_params());
    final gate = _ChipGate()
      ..handler = _responder(
        tasks: [_worktreeTask('t1')],
        git: (_) async => _branchAnswer(null),
      );
    final session = await _connected(stub, gate);

    await session.refreshTaskOverview();

    final entry = session.taskDirectory.allEntries().single.$1;
    expect(entry.raw['worktreeRoot'], '/repo/.worktrees/feat');
    expect(session.worktreeBranchFor(entry), isNull);
    await session.dispose();
  });

  test('missing method: silent, negative-cached; the next refresh dials '
      'nothing', () async {
    final stub = _StubClient(_params());
    final gate = _ChipGate()
      ..handler = _responder(
        tasks: [_worktreeTask('t1')],
        git: (_) async =>
            throw ChannelRpcError('no such method: getRepositorySummary', null),
      );
    final session = await _connected(stub, gate);

    await session.refreshTaskOverview();
    final entry = session.taskDirectory.allEntries().single.$1;
    expect(session.worktreeBranchFor(entry), isNull);
    final afterFirst = gate.gitCalls;
    expect(afterFirst, greaterThan(0),
        reason: 'the probe tries its candidate table once');

    await session.refreshTaskOverview();
    expect(gate.gitCalls, afterFirst,
        reason: 'a deterministic method miss is remembered per connection');
    await session.dispose();
  });

  test('missing git channel: silent, negative-cached; the next refresh dials '
      'nothing', () async {
    final stub = _StubClient(_params());
    final gate = _ChipGate()
      ..handler = _responder(
        tasks: [_worktreeTask('t1')],
        git: (_) async => throw ChannelRpcError(
            "Channel name 'git' timed out after 1000ms", null),
      );
    final session = await _connected(stub, gate);

    await session.refreshTaskOverview();
    final entry = session.taskDirectory.allEntries().single.$1;
    expect(session.worktreeBranchFor(entry), isNull);
    final afterFirst = gate.gitCalls;

    await session.refreshTaskOverview();
    expect(gate.gitCalls, afterFirst,
        reason: 'the channel miss is remembered per connection');
    await session.dispose();
  });

  test('timeout: at most one per round, never connection-cached', () async {
    final stub = _StubClient(_params());
    final gate = _ChipGate()
      ..handler = _responder(
        // Distinct paths: with one shared path the Set dedupe would mask
        // whether the first timeout aborts the REMAINING paths (P2-2).
        tasks: [
          _worktreeTask('t1'),
          _worktreeTask(
            't2',
            worktreeRoot: '/repo/.worktrees/other',
            cwd: '/repo/.worktrees/other',
          ),
        ],
        git: (_) async =>
            throw TimeoutException('git rpc timed out', const Duration(seconds: 1)),
      );
    final session = await _connected(stub, gate);

    await session.refreshTaskOverview();
    expect(gate.gitCalls, 1,
        reason: 'the first timeout aborts the remaining paths of the round');
    final entry = session.taskDirectory.allEntries().first.$1;
    expect(session.worktreeBranchFor(entry), isNull);

    await session.refreshTaskOverview();
    expect(gate.gitCalls, 2,
        reason: 'timeouts are NOT negative-cached: the next round retries '
            'once');
    await session.dispose();
  });

  test('the refresh only ever issues read-only git methods (no worktree '
      'or git writes)', () async {
    final stub = _StubClient(_params());
    final gate = _ChipGate()
      ..handler = _responder(
        tasks: [_worktreeTask('t1')],
        git: (_) async => _branchAnswer('feat/login'),
      );
    final session = await _connected(stub, gate);

    await session.refreshTaskOverview();

    final gitMethods = gate.calls
        .where((c) => c.$1 == Channels.git)
        .map((c) => c.$2)
        .toList();
    expect(gitMethods, isNotEmpty);
    // The branch round only resolves a repository summary; every write verb
    // of GitPort (and the managed-worktrees surface this task deliberately
    // dropped) must stay untouched.
    expect(
      gitMethods.toSet().difference(const {
        'getRepositorySummary',
        'getWorkspaceRepositoryInfo',
        'getStatus',
      }),
      isEmpty,
    );
    const writeMethods = {
      'switchBranch',
      'stagePaths',
      'unstagePaths',
      'commit',
      'push',
      'generateCommitMessage',
      'discardPaths',
      'listWorktrees',
    };
    expect(
      gate.calls.where(
        (c) => c.$1 == 'managed-worktrees' || writeMethods.contains(c.$2),
      ),
      isEmpty,
      reason: 'the task-row chip is strictly read-only',
    );
    await session.dispose();
  });

  test('branch failures never feed the link supervisor (no rebuild across '
      'three timeout rounds)', () async {
    var created = 0;
    final stub = _StubClient(_params());
    final gate = _ChipGate()
      ..handler = _responder(
        tasks: [_worktreeTask('t1')],
        git: (_) async =>
            throw TimeoutException('git rpc timed out', const Duration(seconds: 1)),
      );
    final session = await _connected(stub, gate,
        onClientCreated: () => created++);

    for (var i = 0; i < 3; i++) {
      await session.refreshTaskOverview();
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(created, 1,
        reason: 'using callChannel would tri-strike the git channel into a '
            'rebuild; the chip must ride _callChannelQuiet');
    expect(session.status, DeviceStatus.connected);
    expect(gate.gitCalls, 3, reason: 'one timeout attempt per round');
    await session.dispose();
  });
}
