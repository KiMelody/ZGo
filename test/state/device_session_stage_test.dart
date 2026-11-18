import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/relay_transport.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';

/// Millisecond-grade defences (the house rule: real delays, never a fake
/// clock — suspend/dispose microtask drainage is unreliable under one).
const StallTimings fastTimings = StallTimings(
  healthyWaitTimeout: Duration(milliseconds: 40),
  rpcTimeout: Duration(milliseconds: 70),
  dialTimeout: Duration(milliseconds: 60),
  listReadyTimeout: Duration(seconds: 300), // keep the watchdog out of the way
  minRebuildInterval: Duration(milliseconds: 5),
  retryBackoff: Duration(milliseconds: 60),
);

RemoteConnectionParams paramsOf() => RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
    )!;

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

/// Relay whose state the test owns: flipping [stateNotifier] runs the
/// session's real `_onRelayState` consumer.
class _FakeRelay implements RelayTransport {
  final _failures = StreamController<RelayFailure>.broadcast();
  final _payloads = StreamController<Map<String, dynamic>>.broadcast();
  final stateNotifier = ValueNotifier<RelayState>(RelayState.waiting);

  @override
  Stream<Map<String, dynamic>> get payloads => _payloads.stream;

  @override
  ValueListenable<RelayState> get stateListenable => stateNotifier;

  @override
  RelayState get state => stateNotifier.value;

  @override
  Stream<RelayFailure> get failures => _failures.stream;

  @override
  Future<void> start() => Future.value();

  @override
  void sendPayload(Map<String, dynamic> payload) {}

  @override
  void sendMobileDiagnostic(String event, [Map<String, dynamic>? fields]) {}

  void fail(RelayFailure failure) => _failures.add(failure);

  @override
  Future<void> dispose() async {
    await _failures.close();
    await _payloads.close();
    stateNotifier.dispose();
  }
}

/// Client wired to [_FakeRelay]. `waitPaired` parks until the test flips the
/// relay to `paired`, so the pairing window is observable.
class _StubClient extends RemoteClient {
  _StubClient(super.params, this._relay)
      : super(transportFactory: (_) => _relay);

  final _FakeRelay _relay;
  int disposeCount = 0;

  @override
  Future<void> connect() => Future.value();

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) {
    final completer = Completer<void>();
    void listener() {
      if (_relay.state == RelayState.paired && !completer.isCompleted) {
        completer.complete();
      }
    }

    _relay.stateListenable.addListener(listener);
    listener();
    return completer.future.then((_) {
      _relay.stateListenable.removeListener(listener);
    });
  }

  @override
  Future<Map<String, dynamic>> bootstrap() async => const {
        'workspaces': <Object>[],
        'tasks': <Object>[],
      };

  @override
  Future<void> dispose() {
    disposeCount += 1;
    // Skips RemoteClient.dispose on purpose: nothing real was opened.
    return Future.value();
  }
}

/// Gate standing in for the live workspace bridge: unhealthy fails at once,
/// which drives the stall → forced-rebuild escalation.
class _FakeGate implements WorkspaceGate {
  @override
  Future<void> waitHealthy({required Duration timeout}) =>
      Future.error(TimeoutException('degraded', timeout));

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration? timeout,
  }) =>
      Completer<dynamic>().future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stage is null at rest and on a settled link', () async {
    final relay = _FakeRelay()..stateNotifier.value = RelayState.paired;
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () => _StubClient(paramsOf(), relay),
    );
    expect(session.connectionStage, isNull);

    await session.connect();
    expect(session.status, DeviceStatus.connected);
    expect(session.connectionStage, isNull);
    expect(session.kicked, isFalse);

    await session.dispose();
  });

  test('a re-waiting relay reads as pairing; paired clears it', () async {
    final relay = _FakeRelay()..stateNotifier.value = RelayState.paired;
    final session = DeviceSession(
      deviceId: 'd6',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () => _StubClient(paramsOf(), relay),
    );
    await session.connect();
    expect(session.connectionStage, isNull);

    // The desktop going away mid-link lands the relay back in `waiting`.
    relay.stateNotifier.value = RelayState.waiting;
    await until(() => session.connectionStage == 'pairing',
        because: 'relay waiting must read as pairing');

    relay.stateNotifier.value = RelayState.paired;
    await until(() => session.connectionStage == null);
    expect(session.status, DeviceStatus.connected);

    await session.dispose();
  });

  test('a relay reconnecting state reads as reconnecting; paired clears it',
      () async {
    final relay = _FakeRelay()..stateNotifier.value = RelayState.paired;
    final session = DeviceSession(
      deviceId: 'd2',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () => _StubClient(paramsOf(), relay),
    );
    await session.connect();
    expect(session.status, DeviceStatus.connected);
    expect(session.connectionStage, isNull);

    relay.stateNotifier.value = RelayState.reconnecting;
    await until(() => session.connectionStage == 'reconnecting',
        because: 'a post-drop redial must read as reconnecting');

    relay.stateNotifier.value = RelayState.paired;
    await until(() => session.connectionStage == null);
    expect(session.status, DeviceStatus.connected);

    await session.dispose();
  });

  test('a forced rebuild reports rebuilding and never flashes disconnected',
      () async {
    final relay = _FakeRelay()..stateNotifier.value = RelayState.paired;
    final session = DeviceSession(
      deviceId: 'd3',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () => _StubClient(paramsOf(), relay),
    );
    await session.connect();
    session.debugAttachGateForTest(_FakeGate());

    final seen = <String?>[];
    session.addListener(() => seen.add(session.connectionStage));

    unawaited(session
        .callChannel('zcode-agent', 'listAllAutomations')
        .catchError((Object _) {}));
    await until(() => seen.contains('rebuilding'),
        because: 'the rebuild window must be visible as a stage');
    expect(seen, isNot(contains('disconnected')),
        reason: 'suspend inside the rebuild must not demote the stage');
    await until(() => session.status == DeviceStatus.connected);
    expect(session.connectionStage, isNull);

    await session.dispose();
  });

  test('a stage change notifies once; an unchanged stage never notifies',
      () async {
    final relay = _FakeRelay()..stateNotifier.value = RelayState.paired;
    final session = DeviceSession(
      deviceId: 'd4',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () => _StubClient(paramsOf(), relay),
    );
    await session.connect();
    expect(session.connectionStage, isNull);

    var notifies = 0;
    session.addListener(() => notifies++);

    // `connected → reconnecting` changes the stage without changing the
    // status, so this notify can only come from the stage writer — the exact
    // path that used to leave the copy stale.
    relay.stateNotifier.value = RelayState.reconnecting;
    await until(() => session.connectionStage == 'reconnecting',
        because: 'the drop must surface as a stage');
    expect(notifies, 1,
        reason: 'one stage change must repaint exactly once');

    // Re-entering the same relay state is a same-value write: no repaint.
    relay.stateNotifier.value = RelayState.reconnecting;
    await pumpEventQueue();
    expect(session.connectionStage, 'reconnecting');
    expect(notifies, 1,
        reason: 'a same-value stage write must not repaint');

    // Back to no stage: again exactly one notify.
    relay.stateNotifier.value = RelayState.paired;
    await until(() => session.connectionStage == null);
    expect(notifies, 2,
        reason: 'clearing the stage is one repaint, not a storm');

    await session.dispose();
  });

  test('the relay `connecting` transient is a no-op for status and stage',
      () async {
    final relay = _FakeRelay()..stateNotifier.value = RelayState.paired;
    final session = DeviceSession(
      deviceId: 'd7',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () => _StubClient(paramsOf(), relay),
    );
    await session.connect();
    expect(session.status, DeviceStatus.connected);

    var notifies = 0;
    session.addListener(() => notifies++);
    // While connected the relay's transient `connecting` branch writes
    // neither status nor stage: it must not emit a notify.
    relay.stateNotifier.value = RelayState.connecting;
    await pumpEventQueue();
    expect(session.status, DeviceStatus.connected);
    expect(session.connectionStage, isNull);
    expect(notifies, 0,
        reason: 'a same-value stage write must not repaint');

    await session.dispose();
  });

  test('kicked short-circuits the rebuild: the stage never turns rebuilding',
      () async {
    final relay = _FakeRelay()..stateNotifier.value = RelayState.paired;
    var created = 0;
    final session = DeviceSession(
      deviceId: 'd5',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        created += 1;
        return _StubClient(paramsOf(), relay);
      },
    );
    await session.connect();
    expect(session.status, DeviceStatus.connected);

    relay.fail(const RelayFailure('kicked', 'other terminal took over'));
    await until(() => session.kicked, because: 'the kick must land');
    expect(session.connectionStage, isNull,
        reason: 'kicked is not a stage; it stays on the kicked getter');

    final before = created;
    session.debugAttachGateForTest(_FakeGate());
    unawaited(session
        .callChannel('zcode-agent', 'listAllAutomations')
        .catchError((Object _) {}));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(created, before,
        reason: 'the kicked short-circuit must still stop the rebuild');
    expect(session.connectionStage, isNot('rebuilding'));

    await session.dispose();
  });
}