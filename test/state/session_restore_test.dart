import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/ipc_codec.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';

import '../helpers/fake_device_session.dart';

/// Cross-workspace orphan restore (task 11-08 session-restore-on-return).
///
/// Group 1 drives the REAL [DeviceSession] over a scripted client: the
/// revoke generation, the resume no-op and both `sessionNotFound`-refusal
/// write entries (initial subscribe + terminal broadcast).
/// Group 2 drives [FakeDeviceSession] for the open-chain outcomes
/// (aborted rerun / classified failures / ownership dead end) that only the
/// open result can express.

const _fastTimings = StallTimings(
  healthyWaitTimeout: Duration(milliseconds: 40),
  rpcTimeout: Duration(milliseconds: 200),
  dialTimeout: Duration(milliseconds: 60),
  listReadyTimeout: Duration(seconds: 300),
  minRebuildInterval: Duration(milliseconds: 5),
  retryBackoff: Duration(milliseconds: 60),
);

RemoteConnectionParams _params(String appVersion) =>
    RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=m'
      '&app_version=$appVersion',
    )!;

Map<String, dynamic> _ws(String path) => {'workspacePath': path};

/// The desktop's authoritative refusal wording (channel_client markers).
ChannelRpcError _sessionNotFound(String id) => ChannelRpcError(
      'Session is not active and not persisted: $id '
      '(fault.subscribe.sessionNotFound)',
      {'code': 'fault.subscribe.sessionNotFound'},
    );

typedef _OpenCall = ({
  String key,
  String? taskId,
  Map<String, dynamic>? project,
  String? taskHostId,
});

/// Records opens and hands out scripted bridges.
class _ScriptedClient extends RemoteClient {
  _ScriptedClient(super.params);

  final opens = <_OpenCall>[];
  Future<BridgeSession> Function(_OpenCall call)? handler;
  List<Map<String, dynamic>> bootstrapWorkspaces = const [];
  List<Map<String, dynamic>> bootstrapTasks = const [];
  String? desktopAppVersion;

  @override
  Future<void> connect() => Future.value();

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() async => {
        'workspaces': bootstrapWorkspaces,
        'tasks': bootstrapTasks,
        if (desktopAppVersion != null) 'desktopAppVersion': desktopAppVersion!,
      };

  @override
  Future<BridgeSession> openBridge(
    String workspaceKey, {
    String? taskId,
    Map<String, dynamic>? project,
    String? taskHostId,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final call = (
      key: workspaceKey,
      taskId: taskId,
      project: project,
      taskHostId: taskHostId,
    );
    opens.add(call);
    final h = handler;
    if (h == null) throw StateError('openBridge is not scripted');
    return h(call);
  }

  @override
  Future<void> dispose() => Future.value();
}

/// Live bridge stand-in: answers the V4 handshake, the sessions-index
/// subscribe, and the conversation subscribe (ack, or a scripted refusal).
class _FakeBridge implements BridgeSession {
  _FakeBridge();

  @override
  String? workspaceKey;

  /// When set, `subscribeConversationV4` answers this 202 error map instead
  /// of an ack (the sessionNotFound refusal shape).
  Map<String, dynamic>? conversationError;

  /// Every (sessionId) the conversation subscribe carried, in order.
  final List<String> conversationSubscribes = [];

  @override
  late final ChannelClient channels = _buildChannels();

  ChannelClient _buildChannels() {
    late final ChannelClient client;
    client = ChannelClient(sendBody: (body) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      final args = decodeValue(reader);
      final type = (header[0] as num).toInt();
      final id = header[1] as int;
      if (type == ChannelClient.reqEventListen ||
          type == ChannelClient.reqEventDispose) {
        return;
      }
      final method = '${header[3]}';
      var resType = ChannelClient.resPromiseSuccess;
      Object? payload;
      switch (method) {
        case 'helloConversationV4':
          payload = <String, dynamic>{'connectionId': 'conn-1'};
        case 'subscribeSessionsIndexV4':
          payload = <String, dynamic>{
            'ack': <String, dynamic>{'subscriptionId': 'idx-1'},
          };
        case 'subscribeConversationV4':
          final sid = args is List && args.isNotEmpty && args.first is Map
              ? '${(args.first as Map)['sessionId'] ?? ''}'
              : '';
          conversationSubscribes.add(sid);
          final err = conversationError;
          if (err != null) {
            resType = ChannelClient.resPromiseError;
            payload = err;
          } else {
            payload = <String, dynamic>{
              'ack': <String, dynamic>{
                'subscriptionId': 'conv-${conversationSubscribes.length}',
              },
            };
          }
        default:
          payload = <String, dynamic>{};
      }
      final writer = ValueWriter();
      encodeValue(writer, [resType, id]);
      encodeValue(writer, payload);
      client.handleMessage(writer.toBytes());
    });
    final init = ValueWriter();
    encodeValue(init, [ChannelClient.resInitialize, 0]);
    client.handleMessage(init.toBytes());
    return client;
  }

  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);

  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);

  @override
  DateTime? lastDegradedAt;

  @override
  void markDegraded(String reason) {
    lastDegradedAt = DateTime.now();
    degraded.value = reason;
  }

  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) =>
      Future.value();

  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
    void Function(String channel, Object error)? onLinkLevelFailure,
    void Function(String channel)? onChannelSuccess,
    Future<String?> Function(String workspacePath)? projectIdFor,
  }) =>
      ConversationTransport(
        session: this,
        scope: scope,
        onLog: onLog,
        onLinkLevelFailure: onLinkLevelFailure,
        onChannelSuccess: onChannelSuccess,
        projectIdFor: projectIdFor,
      );

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Two-workspace desktop: task ids carry their home in the relay overview so
/// ownership resolution has an answer independent of the live index.
class _Harness {
  _Harness({List<String> homeOfTaskA = const ['/repo/a']}) {
    client = _ScriptedClient(_params('3.16.3'))
      ..desktopAppVersion = '3.16.3'
      ..bootstrapWorkspaces = [_ws('/repo/a'), _ws('/repo/b')]
      ..bootstrapTasks = [
        for (final id in homeOfTaskA)
          {'taskId': 'sA', 'workspacePath': id, 'updatedAt': 10},
        {'taskId': 'sB', 'workspacePath': '/repo/b', 'updatedAt': 9},
      ]
      ..handler = (_) async {
        final bridge = _FakeBridge();
        bridges.add(bridge);
        return bridge;
      };
  }

  late final _ScriptedClient client;
  final bridges = <_FakeBridge>[];
  late final DeviceSession session;

  Future<void> start() async {
    session = DeviceSession(
      deviceId: 'd1',
      params: client.params,
      timings: _fastTimings,
      clientFactory: () => client,
    );
    await session.connect();
    await settle();
  }

  _FakeBridge get activeBridge => bridges.last;
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'condition never became true');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('orphan generation (host revoke only)', () {
    test('a workspace switch revokes the old handle; a fresh subscription '
        'starts home and not revoked', () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);
      expect(h.session.activeWorkspace?['workspacePath'], '/repo/a');

      final first = await h.session.subscribe('sA');
      expect(first.generation, 0);
      expect(first.isRevoked, isFalse);

      final switched = await h.session.openWorkspace(_ws('/repo/b'));
      expect(switched, isA<WorkspaceOpenOpened>());
      await settle();

      expect(first.isRevoked, isTrue,
          reason: 'the host tore the subscription down behind the reader');

      final second = await h.session.subscribe('sA');
      await settle();
      expect(second.isRevoked, isFalse,
          reason: 'a fresh subscription carries the live generation — the '
              'page must not see a stale revoke');
      expect(second.generation, 1);
    });

    test('the page\'s own close does not advance the generation', () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);

      final handle = await h.session.subscribe('sA');
      await handle.close();
      await settle();

      expect(handle.isRevoked, isFalse,
          reason: 'a normal page close needs no recovery — only the host '
              'revoke path advances the counter');
    });

    test('AC3 terminal shape: a foreign-scope refusal answers a READY handle '
        '(no missing marker, no error)', () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);
      await h.session.openWorkspace(_ws('/repo/b'));
      await settle();
      h.activeBridge.conversationError = {
        'message': _sessionNotFound('sA').message,
        'code': 'fault.subscribe.sessionNotFound',
      };

      // Write entry ① path: subscribe throws sessionNotFound under a foreign
      // scope. The page must get a settled handle back, not an error.
      final handle = await h.session.subscribe('sA');
      await settle();
      // The resumed subscription now lives on the A bridge; feed a snapshot
      // so `state.ready` is observable exactly like the page's AC3 terminal
      // check.
      h.activeBridge.conversationError = null;
      handle.state.applyFrame({
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'sessionId': 'sA',
            'logEpoch': 'e1',
            'revision': 1,
            'rows': {'window': const [], 'totalCount': 0},
          },
        },
      }, onGap: () {});

      expect(handle.state.ready, isTrue,
          reason: 'AC3: the page converges to state.ready');
      expect(h.session.isSessionMissing('sA'), isFalse,
          reason: 'AC3: no missing banner, no sticky marker');
    });

    test('suspend (WebView handover) also revokes the reader', () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);
      final handle = await h.session.subscribe('sA');

      await h.session.suspend();
      await settle();

      expect(handle.isRevoked, isTrue);
    });
  });

  group('resumeSessionOnReturn — real session', () {
    test('same workspace with a live subscription is a no-op', () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);
      final first = await h.session.subscribe('sA');
      final opensBefore = h.client.opens.length;

      final resumed = await h.session.resumeSessionOnReturn('sA');
      await settle();

      expect(resumed.state, same(first.state));
      expect(resumed.isRevoked, isFalse);
      expect(h.client.opens.length, opensBefore,
          reason: 'already home: zero open RPC');
    });

    test('a revoked session re-points the bridge home and re-subscribes',
        () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);
      final first = await h.session.subscribe('sA');

      await h.session.openWorkspace(_ws('/repo/b'));
      await settle();
      expect(first.isRevoked, isTrue);
      final opensBefore = h.client.opens.length;

      final resumed = await h.session.resumeSessionOnReturn('sA');
      await settle();

      expect(resumed.isRevoked, isFalse);
      expect(resumed.state, isNot(same(first.state)));
      expect(h.client.opens.length, opensBefore + 1,
          reason: 'exactly one open back to the owning workspace');
      expect(h.client.opens.last.key, '/repo/a');
      expect(h.session.activeWorkspace?['workspacePath'], '/repo/a');
      expect(h.session.isSessionMissing('sA'), isFalse);
      expect(h.activeBridge.conversationSubscribes, contains('sA'));
    });

    test('A→B→A→B round trip: every return recovers exactly once and no '
        'state accumulates', () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);
      var handle = await h.session.subscribe('sA');

      for (var round = 0; round < 2; round++) {
        // Leave A for B (the user opens a task of the other workspace).
        final opened = await h.session.openWorkspace(_ws('/repo/b'));
        expect(opened, isA<WorkspaceOpenOpened>());
        await settle();
        expect(handle.isRevoked, isTrue,
            reason: 'round $round: the switch revoked the visible page');

        // Return to A: one resume = one open back + one fresh handle.
        final opensBefore = h.client.opens.length;
        handle = await h.session.resumeSessionOnReturn('sA');
        await settle();
        expect(handle.isRevoked, isFalse, reason: 'round $round');
        expect(h.client.opens.length, opensBefore + 1, reason: 'round $round');
        expect(h.session.activeWorkspace?['workspacePath'], '/repo/a');

        // A second resume in the same state is the documented no-op.
        final again = await h.session.resumeSessionOnReturn('sA');
        expect(again.state, same(handle.state), reason: 'round $round');
        expect(h.client.opens.length, opensBefore + 1,
            reason: 'round $round: no duplicate open');
        expect(h.session.isSessionMissing('sA'), isFalse);
      }
    });

    test('concurrent resumes for one id share one open + one subscribe',
        () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);
      await h.session.subscribe('sA');
      await h.session.openWorkspace(_ws('/repo/b'));
      await settle();
      final opensBefore = h.client.opens.length;
      final subscribesBefore =
          h.bridges.fold<int>(0, (n, b) => n + b.conversationSubscribes.length);

      final results = await Future.wait([
        h.session.resumeSessionOnReturn('sA'),
        h.session.resumeSessionOnReturn('sA'),
      ]);
      await settle();

      expect(results[0].state, same(results[1].state),
          reason: 'in-flight merge: one subscription, one state');
      expect(h.client.opens.length, opensBefore + 1);
      final subscribes = h.bridges
          .fold<int>(0, (n, b) => n + b.conversationSubscribes.length);
      expect(subscribes, subscribesBefore + 1);
    });
  });

  group('sessionNotFound write entries (ownership rerouting)', () {
    test('entry 1 — a foreign-scope refusal reroutes instead of marking the '
        'session missing', () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);
      // Move to B, then ask for the A-owned session under B's scope: the
      // desktop refuses with sessionNotFound (a SCOPE answer).
      await h.session.openWorkspace(_ws('/repo/b'));
      await settle();
      h.activeBridge.conversationError = {
        'message': _sessionNotFound('sA').message,
        'code': 'fault.subscribe.sessionNotFound',
      };
      final opensBefore = h.client.opens.length;

      final handle = await h.session.subscribe('sA');
      await settle();

      expect(h.session.isSessionMissing('sA'), isFalse,
          reason: 'a foreign-scope refusal is not an authoritative '
              '"session does not exist" verdict');
      expect(h.session.activeWorkspace?['workspacePath'], '/repo/a',
          reason: 'the reroute pointed the bridge at the owner');
      expect(h.client.opens.length, opensBefore + 1);
      expect(handle.isRevoked, isFalse);
    });

    test('entry 1 — a true missing session in the ACTIVE workspace still '
        'enters the sticky set', () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);
      // 'sGhost' has no owner anywhere → ownership is undeterminable, so the
      // refusal can only be about the session itself.
      h.activeBridge.conversationError = {
        'message': _sessionNotFound('sGhost').message,
        'code': 'fault.subscribe.sessionNotFound',
      };

      await expectLater(
        h.session.subscribe('sGhost'),
        throwsA(isA<ChannelRpcError>()),
      );
      expect(h.session.isSessionMissing('sGhost'), isTrue);
    });

    test('entry 2 — a terminal refusal under a foreign scope reroutes and '
        'never marks the session missing', () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);
      // Live subscription under A, then switch to B and subscribe sA there
      // (the live row makes ownership A) — then make the next resubscribe
      // answer the authoritative refusal.
      await h.session.openWorkspace(_ws('/repo/b'));
      await settle();
      final handle = await h.session.subscribe('sA');
      await settle();
      h.activeBridge.conversationError = {
        'message': _sessionNotFound('sA').message,
        'code': 'fault.subscribe.sessionNotFound',
      };
      final opensBefore = h.client.opens.length;

      // Bridge recovery wave = the resubscribe trigger.
      h.activeBridge.recovered.value += 1;
      await pumpUntil(() => h.client.opens.length == opensBefore + 1);
      await settle();

      expect(h.session.isSessionMissing('sA'), isFalse);
      expect(h.session.activeWorkspace?['workspacePath'], '/repo/a');
      expect(handle.isRevoked, isTrue,
          reason: 'the reader was revoked so the page re-binds on return');
      // The resumed subscription is live again: a further subscribe shares
      // it (no extra conversation subscribe on the fresh bridge).
      final live = await h.session.resumeSessionOnReturn('sA');
      expect(live.isRevoked, isFalse);
    });

    test('entry 2 — a terminal refusal at HOME still marks the session '
        'missing', () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);
      final handle = await h.session.subscribe('sA');
      await settle();
      h.activeBridge.conversationError = {
        'message': _sessionNotFound('sA').message,
        'code': 'fault.subscribe.sessionNotFound',
      };

      h.activeBridge.recovered.value += 1;
      await pumpUntil(() => h.session.isSessionMissing('sA'));

      expect(h.session.isSessionMissing('sA'), isTrue,
          reason: 'the bridge is home and the desktop still refused: the '
              'session really is gone');
      expect(handle.isRevoked, isFalse,
          reason: 'a missing session is not an orphan — no resume loop');
    });
  });

  group('resumeSessionOnReturn — open-chain outcomes', () {
    final params = _params('3.16.3');

    FakeDeviceSession fake({
      List<Map<String, dynamic>> relayTasks = const [],
      List<Map<String, dynamic>> workspaces = const [],
    }) =>
        FakeDeviceSession(
          deviceId: 'd1',
          params: params,
          workspaces: workspaces,
          relayTasks: relayTasks,
        );

    test('same-workspace no-op: subscribe only, zero opens', () async {
      final session = fake(
        workspaces: [_ws('/repo/a')],
        relayTasks: [
          {'taskId': 'sA', 'workspacePath': '/repo/a', 'updatedAt': 1},
        ],
      );
      addTearDown(session.dispose);

      final handle = await session.resumeSessionOnReturn('sA');

      expect(handle, isNotNull);
      expect(session.openWorkspaceCalls, isEmpty);
      expect(session.chatSubscribes, ['sA']);
    });

    test('a foreign owner re-points the bridge with the openTask purpose',
        () async {
      final session = fake(
        workspaces: [_ws('/repo/b'), _ws('/repo/a')],
        relayTasks: [
          {'taskId': 'sA', 'workspacePath': '/repo/a', 'updatedAt': 1},
        ],
      );
      addTearDown(session.dispose);
      expect(session.activeWorkspace?['workspacePath'], '/repo/b');

      await session.resumeSessionOnReturn('sA');

      expect(session.openWorkspaceCalls, hasLength(1));
      expect(session.openWorkspaceCalls.single.$1['workspacePath'], '/repo/a');
      expect(session.openWorkspacePurposes.single,
          WorkspaceOpenPurpose.openTask);
      expect(session.chatSubscribes, ['sA']);
    });

    test('a superseded open is re-run once in place', () async {
      final session = _AbortThenSucceed(
        deviceId: 'd1',
        params: params,
        workspaces: [_ws('/repo/b'), _ws('/repo/a')],
        relayTasks: [
          {'taskId': 'sA', 'workspacePath': '/repo/a', 'updatedAt': 1},
        ],
      );
      addTearDown(session.dispose);

      final handle = await session.resumeSessionOnReturn('sA');

      expect(handle, isNotNull);
      expect(session.openWorkspaceCalls, hasLength(2),
          reason: 'aborted is re-run ONCE (the TaskOpenPage rule)');
      expect(session.chatSubscribes, ['sA']);
    });

    test('a second abort is a classified failure, not a silent hang',
        () async {
      final session = fake(
        workspaces: [_ws('/repo/b'), _ws('/repo/a')],
        relayTasks: [
          {'taskId': 'sA', 'workspacePath': '/repo/a', 'updatedAt': 1},
        ],
      )..openWorkspaceSucceeds = false;
      session.openWorkspaceFailure = const WorkspaceOpenAborted();
      addTearDown(session.dispose);

      await expectLater(
        session.resumeSessionOnReturn('sA'),
        throwsA(
          isA<SessionResumeException>().having(
            (e) => e.failure,
            'failure',
            SessionResumeFailure.openAborted,
          ),
        ),
      );
      expect(session.openWorkspaceCalls, hasLength(2));
      expect(session.chatSubscribes, isEmpty);
    });

    test('an unreachable owner is a foreignWorkspace failure', () async {
      final session = fake(
        workspaces: [_ws('/repo/b'), _ws('/repo/a')],
        relayTasks: [
          {'taskId': 'sA', 'workspacePath': '/repo/a', 'updatedAt': 1},
        ],
      )..openWorkspaceSucceeds = false;
      session.openWorkspaceFailure = const WorkspaceOpenUnreachable('gate');
      addTearDown(session.dispose);

      await expectLater(
        session.resumeSessionOnReturn('sA'),
        throwsA(
          isA<SessionResumeException>()
              .having((e) => e.failure, 'failure',
                  SessionResumeFailure.foreignWorkspace)
              .having((e) => e.cause, 'cause',
                  isA<WorkspaceOpenUnreachable>()),
        ),
      );
      expect(session.chatSubscribes, isEmpty,
          reason: 'no subscribe under a scope the open never reached');
    });

    test('undeterminable ownership is a classified dead end', () async {
      final session = fake(workspaces: [_ws('/repo/a')]);
      addTearDown(session.dispose);

      await expectLater(
        session.resumeSessionOnReturn('sNowhere'),
        throwsA(
          isA<SessionResumeException>().having(
            (e) => e.failure,
            'failure',
            SessionResumeFailure.scopeUnknown,
          ),
        ),
      );
      expect(session.openWorkspaceCalls, isEmpty);
      expect(session.chatSubscribes, isEmpty);
    });
  });
}

/// [FakeDeviceSession] whose first open is superseded (aborted) and whose
/// second one succeeds — the `_openChain` last-wins race.
class _AbortThenSucceed extends FakeDeviceSession {
  _AbortThenSucceed({
    required super.deviceId,
    required super.params,
    super.workspaces,
    super.relayTasks,
  });

  bool _abortedOnce = false;

  @override
  Future<WorkspaceOpenResult> openWorkspace(
    Map<String, dynamic> workspace, {
    String? taskId,
    WorkspaceOpenPurpose? purpose,
  }) {
    if (!_abortedOnce) {
      _abortedOnce = true;
      openWorkspaceCalls.add((workspace, taskId));
      openWorkspacePurposes.add(purpose);
      return Future.value(const WorkspaceOpenAborted());
    }
    return super.openWorkspace(workspace, taskId: taskId, purpose: purpose);
  }
}
