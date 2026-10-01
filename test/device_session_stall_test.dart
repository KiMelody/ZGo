import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/ipc_codec.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';

/// Shrunken defence timings: lets the stall policy run against REAL
/// (millisecond) delays instead of a fake clock, whose microtask drainage
/// proved unreliable for suspend/dispose chains.
const StallTimings fastTimings = StallTimings(
  healthyWaitTimeout: Duration(milliseconds: 40),
  rpcTimeout: Duration(milliseconds: 70),
  dialTimeout: Duration(milliseconds: 60),
  listReadyTimeout: Duration(seconds: 300), // keep the watchdog out of the way
  minRebuildInterval: Duration(milliseconds: 5),
  retryBackoff: Duration(milliseconds: 60),
);

/// Relay-backed client replaced wholesale: every network step answers from
/// local knobs so the session policy (timeouts, escalation, rebuilds) can be
/// observed deterministically.
class StubRemoteClient extends RemoteClient {
  StubRemoteClient(super.params);

  bool hangConnect = false;
  bool failBootstrapOnce = false;
  int bootstrapCalls = 0;
  int disposeCount = 0;

  /// When non-null, openBridge answers from this factory instead of the
  /// no-bridges error — the send-path tests ride a real workspace open.
  BridgeSession Function(String workspaceKey)? bridgeOverride;

  @override
  Future<void> connect() {
    if (hangConnect) return Completer<void>().future;
    return Future.value();
  }

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() {
    bootstrapCalls += 1;
    if (failBootstrapOnce) {
      failBootstrapOnce = false;
      throw StateError('bootstrap exploded');
    }
    return Future.value({
      'workspaces': [
        {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
      ],
    });
  }

  @override
  Future<BridgeSession> openBridge(
    String workspaceKey, {
    String? taskId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final bridge = bridgeOverride;
    if (bridge != null) return bridge(workspaceKey);
    throw StateError('workspace-bridge-error: stub has no bridges');
  }

  @override
  Future<void> dispose() {
    disposeCount += 1;
    // Skips RemoteClient.dispose on purpose: nothing real was ever opened.
    return Future.value();
  }
}

/// Gate standing in for the live workspace bridge.
class FakeGate implements WorkspaceGate {
  FakeGate({required this.healthy});

  /// When false, waitHealthy throws TimeoutException (simulating an expiry)
  /// immediately; when true RPCs are accepted but never answered.
  final bool healthy;

  /// Optional per-call outcome: thrown errors fail the RPC, any other
  /// value completes it; while null the bridge stays deaf (healthy but
  /// never answering, so the caller's rpcTimeout fires).
  Object? Function(String channel, String method)? respond;
  int calls = 0;

  @override
  Future<void> waitHealthy({required Duration timeout}) {
    if (!healthy) {
      return Future.error(TimeoutException('degraded', timeout));
    }
    return Future.value();
  }

  @override
  Future<dynamic> call(String channel, String method, List<Object?> args) {
    calls += 1;
    final respond = this.respond;
    if (respond == null) return Completer<dynamic>().future;
    return Future.sync(() => respond(channel, method));
  }
}

RemoteConnectionParams paramsOf() => RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
    )!;

/// Bridge stand-in for the send-path tests: a real channel client whose
/// every RPC is answered synchronously from [_respond] (a throw becomes a
/// resPromiseError frame — the desktop's channel rejection shape), a
/// controllable health gate, and a [conversation] building the transport
/// with whatever link hooks the session passes.
class _SendPathBridge implements BridgeSession {
  _SendPathBridge(this._respond);

  final Object? Function(String channel, String method, List<Object?> args)
      _respond;

  /// When true the health gate throws immediately — the bridge-level tier
  /// ([BridgeSession.waitHealthy] expiry) without the 45s wall.
  bool gateTimeout = false;

  @override
  late final ChannelClient channels = _buildChannels();

  ChannelClient _buildChannels() {
    late final ChannelClient client;
    client = ChannelClient(sendBody: (body) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      final arg = decodeValue(reader);
      final id = header[1] as int;
      Object? payload;
      var type = ChannelClient.resPromiseSuccess;
      try {
        payload = _respond(
          '${header[2]}',
          '${header[3]}',
          arg is List ? arg : <Object?>[arg],
        );
      } catch (e) {
        type = ChannelClient.resPromiseError;
        payload = {'message': '$e'};
      }
      final w = ValueWriter();
      encodeValue(w, [type, id]);
      encodeValue(w, payload);
      client.handleMessage(w.toBytes());
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
  }) {
    if (gateTimeout) {
      return Future.error(
        TimeoutException('bridge recovery timed out: stub'),
      );
    }
    return Future.value();
  }

  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
    void Function(String channel, Object error)? onLinkLevelFailure,
    void Function(String channel)? onChannelSuccess,
  }) {
    return ConversationTransport(
      session: this,
      scope: scope,
      onLog: onLog,
      onLinkLevelFailure: onLinkLevelFailure,
      onChannelSuccess: onChannelSuccess,
    );
  }

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> until(bool Function() condition,
        {int maxMs = 2500, String? because}) =>
    () async {
      var waited = 0;
      while (!condition()) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        waited += 10;
        if (waited > maxMs) break;
      }
      if (because != null && !condition()) {
        fail('condition not met within ${maxMs}ms: $because');
      }
    }();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hung relay dial is bounded and the failure retried', () async {
    var created = 0;
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        created += 1;
        return StubRemoteClient(paramsOf())..hangConnect = true;
      },
    );
    unawaited(session.connect().catchError((Object _) {}));
    // Until dialTimeout the session parks in `connecting`; then the bound
    // converts the black-holed dial into a retryable failure and the backoff
    // dials a fresh client, which hangs and errors again.
    await until(() => session.status == DeviceStatus.error,
        because: 'first hung dial must time out');
    expect(created, 1);
    await until(() => created == 2, because: 'retry must redial');
    await until(() => session.status == DeviceStatus.error);
    await session.dispose();
  });

  test('unhealthy bridge stalls turn one channel call into a full rebuild',
      () async {
    var created = 0;
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        created += 1;
        return StubRemoteClient(paramsOf());
      },
    );
    final badGate = FakeGate(healthy: false);
    session.debugAttachGateForTest(badGate);
    unawaited(session.connect());
    await until(() => session.status == DeviceStatus.connected);

    // The RPC surfaces its own TimeoutException; the session schedules one
    // suspension + fresh-connect behind the scenes.
    final before = created;
    unawaited(session
        .callChannel('zcode-agent', 'listAllAutomations')
        .catchError((Object _) {}));
    // Parallel duplicate failures must NOT stack rebuilds: this one lands
    // while the first rebuild is already in flight / debounced.
    unawaited(session
        .callChannel('off-peak-task', 'run')
        .catchError((Object _) {}));
    await until(() => created == before + 1, because: 'stall must rebuild');
    await until(() => session.status == DeviceStatus.connected);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(created, before + 1);
    await session.dispose();
  });

  test('repeat reload failures escalate into a connection rebuild', () async {
    final stubs = <StubRemoteClient>[];
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        final stub = StubRemoteClient(paramsOf());
        stubs.add(stub);
        return stub;
      },
    );
    unawaited(session.connect());
    await until(() => session.status == DeviceStatus.connected);

    // First failing reload stays soft (error banner only, same client).
    stubs.first.failBootstrapOnce = true;
    unawaited(session.reloadTasks());
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(stubs, hasLength(1));
    expect(session.status, DeviceStatus.connected);

    // Second consecutive failure escalates: full rebuild with a brand-new
    // client (the fix for "retry does nothing" over a wedged link).
    stubs.first.failBootstrapOnce = true;
    unawaited(session.reloadTasks());
    await until(() => stubs.length == 2, because: 'escalation must rebuild');
    await until(() => session.status == DeviceStatus.connected);
    await session.dispose();
  });

  test('healthy-but-deaf bridge RPC timeouts rebuild only on the third strike',
      () async {
    var created = 0;
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        created += 1;
        return StubRemoteClient(paramsOf());
      },
    );
    final gate = FakeGate(healthy: true);
    session.debugAttachGateForTest(gate);
    unawaited(session.connect());
    await until(() => session.status == DeviceStatus.connected);
    expect(gate.calls, 0);

    final before = created;
    // First two deaf RPCs time out as channel-level failures: counted, but
    // the link must NOT be rebuilt (dead-channel isolation).
    for (var i = 0; i < 2; i++) {
      await expectLater(
        session.callChannel('usage-stats', 'overview'),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(created, before,
        reason: 'RPC timeouts below the threshold must not rebuild');

    // The third consecutive timeout escalates into the full rebuild.
    await expectLater(
      session.callChannel('usage-stats', 'overview'),
      throwsA(isA<TimeoutException>()),
    );
    await until(() => created == before + 1,
        because: 'third consecutive timeout must rebuild');
    await until(() => session.status == DeviceStatus.connected);
    await session.dispose();
  });

  test('a single dead-channel error does not rebuild the link', () async {
    var created = 0;
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        created += 1;
        return StubRemoteClient(paramsOf());
      },
    );
    final gate = FakeGate(healthy: true)
      ..respond = (channel, method) =>
          throw ChannelRpcError(
              "Channel name '$channel' timed out after 1000ms", null);
    session.debugAttachGateForTest(gate);
    unawaited(session.connect());
    await until(() => session.status == DeviceStatus.connected);

    // The 2026-09-13 outage shape: model-provider answers with the
    // channel-missing error. It must surface, but the link stays up.
    final before = created;
    await expectLater(
      session.callChannel('model-provider', 'getAll'),
      throwsA(isA<ChannelRpcError>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(gate.calls, 1);
    expect(created, before,
        reason: 'one dead channel must not take the whole link down');
    expect(session.status, DeviceStatus.connected);
    await session.dispose();
  });

  test('the third consecutive dead-channel failure rebuilds the link once',
      () async {
    var created = 0;
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        created += 1;
        return StubRemoteClient(paramsOf());
      },
    );
    final gate = FakeGate(healthy: true)
      ..respond = (channel, method) =>
          throw ChannelRpcError(
              "Channel name '$channel' timed out after 1000ms", null);
    session.debugAttachGateForTest(gate);
    unawaited(session.connect());
    await until(() => session.status == DeviceStatus.connected);

    final before = created;
    for (var i = 0; i < 3; i++) {
      await expectLater(
        session.callChannel('model-provider', 'getAll'),
        throwsA(isA<ChannelRpcError>()),
      );
    }
    await until(() => created == before + 1,
        because: 'third consecutive failure must rebuild once');
    await until(() => session.status == DeviceStatus.connected);

    // Post-rebuild the streak restarts: further failures of the same dead
    // channel must not immediately rebuild again.
    await expectLater(
      session.callChannel('model-provider', 'getAll'),
      throwsA(isA<ChannelRpcError>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(created, before + 1);
    await session.dispose();
  });

  test('deterministic RPC errors never count toward the tri-strike',
      () async {
    var created = 0;
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        created += 1;
        return StubRemoteClient(paramsOf());
      },
    );
    final gate = FakeGate(healthy: true)
      ..respond = (channel, method) =>
          throw ChannelRpcError("RPC method '$method' not found", null);
    session.debugAttachGateForTest(gate);
    unawaited(session.connect());
    await until(() => session.status == DeviceStatus.connected);

    // method-not-found is a deterministic answer — neither the RPC timeout
    // nor the channel-missing shape — so no matter how often it repeats it
    // must not feed the per-channel streak (ADR-0009).
    final before = created;
    for (var i = 0; i < 5; i++) {
      await expectLater(
        session.callChannel('model-provider', 'getAll'),
        throwsA(isA<ChannelRpcError>()),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(created, before, reason: 'deterministic errors must not rebuild');
    expect(session.status, DeviceStatus.connected);
    await session.dispose();
  });

  test('a successful call resets the per-channel failure streak', () async {
    var created = 0;
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        created += 1;
        return StubRemoteClient(paramsOf());
      },
    );
    var fail = true;
    final gate = FakeGate(healthy: true)
      ..respond = (channel, method) {
        if (fail) {
          throw ChannelRpcError(
              "Channel name '$channel' timed out after 1000ms", null);
        }
        return const [];
      };
    session.debugAttachGateForTest(gate);
    unawaited(session.connect());
    await until(() => session.status == DeviceStatus.connected);

    final before = created;
    // Two failures: below the threshold, no rebuild.
    for (var i = 0; i < 2; i++) {
      await expectLater(
        session.callChannel('model-provider', 'getAll'),
        throwsA(isA<ChannelRpcError>()),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(created, before);

    // One success clears the streak...
    fail = false;
    expect(await session.callChannel('model-provider', 'getAll'), const []);

    // ...so two more failures stay below the threshold too.
    fail = true;
    for (var i = 0; i < 2; i++) {
      await expectLater(
        session.callChannel('model-provider', 'getAll'),
        throwsA(isA<ChannelRpcError>()),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(created, before,
        reason: 'a reset streak must need a fresh run to the threshold');
    await session.dispose();
  });

  test('sendCommand channel-level failures join the same tri-strike',
      () async {
    var created = 0;
    var fail = true;
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        created += 1;
        return StubRemoteClient(paramsOf())
          ..bridgeOverride = (key) => _SendPathBridge((channel, method, args) {
                if (method == 'helloConversationV4') {
                  return {'connectionId': 'c1'};
                }
                if (method == 'subscribeSessionsIndexV4') {
                  return {
                    'ack': {'subscriptionId': 'sub1'},
                  };
                }
                if (method == 'sendConversationCommandV4') {
                  if (fail) {
                    throw ChannelRpcError(
                        "Channel name '$channel' timed out after 1000ms",
                        null);
                  }
                  return {'status': 'accepted'};
                }
                return const {};
              });
      },
    );
    session.debugAttachGateForTest(
        FakeGate(healthy: true)..respond = (channel, method) => const []);
    unawaited(session.connect());
    await until(() => session.status == DeviceStatus.connected);
    await until(() => session.conversation != null,
        because: 'workspace auto-open must expose the transport');

    // Same ledger, chat send path: the dead zcode-agent channel answer is
    // counted per channel. Below the threshold nothing rebuilds.
    final before = created;
    for (var i = 0; i < 2; i++) {
      await expectLater(
        session.conversation!.sendCommand('s1', 'sendText', const {}),
        throwsA(isA<ChannelRpcError>()),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(created, before,
        reason: 'send failures below the threshold must not rebuild');

    // One success over the same path clears the streak...
    fail = false;
    expect(
      await session.conversation!.sendCommand('s1', 'sendText', const {}),
      {'status': 'accepted'},
    );

    // ...so two further failures stay below the threshold, and only the
    // third consecutive one escalates into the full rebuild.
    fail = true;
    for (var i = 0; i < 2; i++) {
      await expectLater(
        session.conversation!.sendCommand('s1', 'sendText', const {}),
        throwsA(isA<ChannelRpcError>()),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(created, before,
        reason: 'a reset streak must need a fresh run to the threshold');
    await expectLater(
      session.conversation!.sendCommand('s1', 'sendText', const {}),
      throwsA(isA<ChannelRpcError>()),
    );
    await until(() => created == before + 1,
        because: 'third consecutive sendCommand failure must rebuild');
    await until(() => session.status == DeviceStatus.connected);
    await session.dispose();
  });

  test('the conversation bridge gate expiry escalates immediately', () async {
    var created = 0;
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        created += 1;
        return StubRemoteClient(paramsOf())
          ..bridgeOverride = (key) => _SendPathBridge((channel, method, args) {
                if (method == 'helloConversationV4') {
                  return {'connectionId': 'c1'};
                }
                if (method == 'subscribeSessionsIndexV4') {
                  return {
                    'ack': {'subscriptionId': 'sub1'},
                  };
                }
                return {'status': 'accepted'};
              });
      },
    );
    session.debugAttachGateForTest(
        FakeGate(healthy: true)..respond = (channel, method) => const []);
    unawaited(session.connect());
    await until(() => session.status == DeviceStatus.connected);
    await until(() => session.conversation != null,
        because: 'workspace auto-open must expose the transport');

    // The bridge-health gate timing out is bridge-level: ONE failed send
    // escalates, without any tri-strike counting (same semantics as the
    // callChannel gate).
    final before = created;
    (session.conversation!.session as _SendPathBridge).gateTimeout = true;
    await expectLater(
      session.conversation!.sendCommand('s1', 'sendText', const {}),
      throwsA(isA<TimeoutException>()),
    );
    await until(() => created == before + 1,
        because: 'gate expiry must escalate on first sight');
    await until(() => session.status == DeviceStatus.connected);
    await session.dispose();
  });

  test('deterministic sendCommand errors never reach the ledger', () async {
    var created = 0;
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        created += 1;
        return StubRemoteClient(paramsOf())
          ..bridgeOverride = (key) => _SendPathBridge((channel, method, args) {
                if (method == 'helloConversationV4') {
                  return {'connectionId': 'c1'};
                }
                if (method == 'subscribeSessionsIndexV4') {
                  return {
                    'ack': {'subscriptionId': 'sub1'},
                  };
                }
                if (method == 'sendConversationCommandV4') {
                  throw ChannelRpcError(
                      "RPC method 'sendConversationCommandV4' not found", null);
                }
                return const {};
              });
      },
    );
    session.debugAttachGateForTest(
        FakeGate(healthy: true)..respond = (channel, method) => const []);
    unawaited(session.connect());
    await until(() => session.status == DeviceStatus.connected);
    await until(() => session.conversation != null,
        because: 'workspace auto-open must expose the transport');

    // method-not-found is a deterministic answer — no matter how often it
    // repeats over the send path it must not feed the ledger (ADR-0009).
    final before = created;
    for (var i = 0; i < 5; i++) {
      await expectLater(
        session.conversation!.sendCommand('s1', 'sendText', const {}),
        throwsA(isA<ChannelRpcError>()),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(created, before, reason: 'deterministic errors must not rebuild');
    expect(session.status, DeviceStatus.connected);
    await session.dispose();
  });
}
