import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/relay_client.dart';
import 'package:zgo/protocol/relay_transport.dart';
import 'package:zgo/protocol/relay_v2.dart';
import 'package:zgo/protocol/remote_client.dart';

/// Fake transport for payload-layer smoke tests — no sockets, no timers.
class FakeRelayTransport implements RelayTransport {
  final _payloads = StreamController<Map<String, dynamic>>.broadcast();
  final _failures = StreamController<RelayFailure>.broadcast();
  final stateNotifier = ValueNotifier<RelayState>(RelayState.paired);
  final sent = <Map<String, dynamic>>[];
  final diagnostics = <Map<String, dynamic>>[];
  bool started = false;

  @override
  Stream<Map<String, dynamic>> get payloads => _payloads.stream;

  @override
  ValueListenable<RelayState> get stateListenable => stateNotifier;

  @override
  RelayState get state => stateNotifier.value;

  @override
  Stream<RelayFailure> get failures => _failures.stream;

  @override
  Future<void> start() async => started = true;

  @override
  void sendPayload(Map<String, dynamic> payload) => sent.add(payload);

  @override
  void sendMobileDiagnostic(String event, [Map<String, dynamic>? fields]) {
    diagnostics.add({'event': event, ...?fields});
  }

  void deliver(Map<String, dynamic> payload) => _payloads.add(payload);

  @override
  Future<void> dispose() async {
    await _payloads.close();
    await _failures.close();
    stateNotifier.dispose();
  }
}

RemoteConnectionParams paramsOf(String query) =>
    RemoteConnectionParams.parse('https://zcode.z.ai/remote/v4?$query')!;

void main() {
  test('V1 link constructs the proof RelayClient', () async {
    final client = RemoteClient(paramsOf('sid=s&hash=h&t=1&mid=m'));
    expect(client.relay, isA<RelayClient>());
    await client.dispose();
  });

  test('V2 link constructs the account-JWT RelayV2Transport', () async {
    final client = RemoteClient(
      paramsOf('sid=s&mid=m'),
      jwtProvider: () async => 'jwt',
    );
    expect(client.relay, isA<RelayV2Transport>());
    await client.dispose();
  });

  test('bootstrap rides a fake transport unchanged (payload passthrough)',
      () async {
    final fake = FakeRelayTransport();
    final client = RemoteClient(
      paramsOf('sid=s&mid=m'),
      transportFactory: (_) => fake,
    );
    expect(identical(client.relay, fake), isTrue);

    final future = client.bootstrap();
    await Future<void>.delayed(Duration.zero);
    final request = fake.sent.single;
    expect(request['zcode_type'], 'bootstrap-request');
    final requestId = request['requestId'] as String;

    fake.deliver({
      'zcode_type': 'bootstrap-response',
      'requestId': requestId,
      // Live desktop version: frame top level, outside `result` (3.16.3).
      'desktopAppVersion': '3.16.3',
      'result': {
        'workspaces': [
          {'workspacePath': '/repo'},
        ],
      },
    });
    final result = await future;
    expect(result['workspaces'], hasLength(1));
    expect(result['desktopAppVersion'], '3.16.3',
        reason: 'the live version must survive the result unwrap');

    // sendMobileDiagnostic is relay-layer telemetry, forwarded verbatim.
    client.sendMobileDiagnostic('state-transition', {'state': 'paired'});
    expect(fake.diagnostics.single['event'], 'state-transition');
    expect(fake.diagnostics.single['state'], 'paired');

    await client.dispose();
  });

  group('bridge recovery failure memory', () {
    late FakeRelayTransport fake;
    late List<String> logs;
    late RemoteClient client;

    setUp(() {
      fake = FakeRelayTransport();
      logs = [];
      client = RemoteClient(
        paramsOf('sid=s&mid=m'),
        onLog: logs.add,
        transportFactory: (_) => fake,
      );
    });

    tearDown(() async => client.dispose());

    /// Recovery runs on unawaited stream listeners, so tests wait on the
    /// observable wire traffic instead of a future.
    Future<void> settle(bool Function() condition, String description) async {
      for (var i = 0; i < 500; i++) {
        if (condition()) return;
        await Future<void>.delayed(Duration.zero);
      }
      fail('timed out waiting for $description');
    }

    int sentCount(String type, {String? key}) => fake.sent
        .where((p) =>
            p['zcode_type'] == type &&
            (key == null || p['workspaceKey'] == key))
        .length;

    Map<String, dynamic> lastSent(String type, {String? key}) =>
        fake.sent.lastWhere((p) =>
            p['zcode_type'] == type &&
            (key == null || p['workspaceKey'] == key));

    void deliverBridgeReady(Map<String, dynamic> request, String key) {
      fake.deliver({
        'zcode_type': 'workspace-bridge-ready',
        'bridgeSessionId': request['bridgeSessionId'],
        'bridge': {
          'bridgeSessionId': request['bridgeSessionId'],
          'bridgeGeneration': request['bridgeGeneration'],
          'workspaceKey': key,
          'recoveryId': 'recovery-$key',
        },
      });
    }

    Future<BridgeSession> open(String key) async {
      final future = client.openBridge(key);
      await settle(
        () => sentCount('workspace-bridge-open', key: key) == 1,
        'bridge-open for $key',
      );
      deliverBridgeReady(
        lastSent('workspace-bridge-open', key: key),
        key,
      );
      return future;
    }

    void degrade(BridgeSession session) {
      fake.deliver({
        'zcode_type': 'bridge-degraded',
        'bridgeSessionId': session.bridge['bridgeSessionId'],
        'reason': 'rpc-transport-fault',
      });
    }

    void answerReconnect(
      Map<String, dynamic> request, {
      required bool success,
      String? error,
    }) {
      fake.deliver({
        'zcode_type': 'workspace-reconnect-response',
        'requestId': request['requestId'],
        'workspaceKey': request['workspaceKey'],
        'success': success,
        if (error != null) 'error': error,
      });
    }

    test('window-missed key skips reconnect-request on the next recovery',
        () async {
      final session = await open('draft-a');

      degrade(session);
      await settle(
        () => sentCount('workspace-reconnect-request') == 1,
        'first reconnect-request',
      );
      answerReconnect(
        lastSent('workspace-reconnect-request'),
        success: false,
        error: '远程 workspace 不在当前窗口中，无法重连: /draft/a',
      );
      await settle(
        () => sentCount('workspace-bridge-open', key: 'draft-a') == 2,
        'reopen after the window miss',
      );
      deliverBridgeReady(lastSent('workspace-bridge-open', key: 'draft-a'),
          'draft-a');
      await settle(() => session.degraded.value == null, 'first recovery');

      degrade(session);
      await settle(
        () => sentCount('workspace-bridge-open', key: 'draft-a') == 3,
        'direct reopen for the remembered workspace',
      );
      expect(
        sentCount('workspace-reconnect-request'),
        1,
        reason: 'a remembered window miss must not pay the doomed round-trip',
      );
      expect(
        logs,
        contains(
            '[bridge] skip reconnect (window-missed remembered): draft-a'),
      );

      deliverBridgeReady(lastSent('workspace-bridge-open', key: 'draft-a'),
          'draft-a');
      await settle(() => session.degraded.value == null, 'second recovery');
      expect(session.recovered.value, 2);
    });

    test('other reconnect failures are not remembered', () async {
      final session = await open('draft-b');

      degrade(session);
      await settle(
        () => sentCount('workspace-reconnect-request') == 1,
        'first reconnect-request',
      );
      answerReconnect(
        lastSent('workspace-reconnect-request'),
        success: false,
        error: 'workspace connect failed',
      );
      await settle(
        () => sentCount('workspace-bridge-open', key: 'draft-b') == 2,
        'reopen after a non-deterministic failure',
      );
      deliverBridgeReady(lastSent('workspace-bridge-open', key: 'draft-b'),
          'draft-b');
      await settle(() => session.degraded.value == null, 'first recovery');

      degrade(session);
      await settle(
        () => sentCount('workspace-reconnect-request') == 2,
        'reconnect-request retried on the next recovery',
      );
      expect(
        logs.where((l) => l.contains('window-missed remembered')),
        isEmpty,
      );
      answerReconnect(lastSent('workspace-reconnect-request'), success: true);
      await settle(() => session.degraded.value == null, 'second recovery');
      expect(
        sentCount('workspace-bridge-open', key: 'draft-b'),
        2,
        reason: 'a successful reconnect does not reopen',
      );
    });

    test('memory is scoped to the workspace key', () async {
      final a = await open('draft-a');
      final b = await open('draft-b');

      degrade(a);
      await settle(
        () => sentCount('workspace-reconnect-request', key: 'draft-a') == 1,
        'reconnect-request for draft-a',
      );
      answerReconnect(
        lastSent('workspace-reconnect-request', key: 'draft-a'),
        success: false,
        error: '远程 workspace 不在当前窗口中，无法重连: /draft/a',
      );
      await settle(
        () => sentCount('workspace-bridge-open', key: 'draft-a') == 2,
        'reopen of draft-a',
      );
      deliverBridgeReady(lastSent('workspace-bridge-open', key: 'draft-a'),
          'draft-a');
      await settle(() => a.degraded.value == null, 'recovery of draft-a');

      // Degrading b recovers every active bridge; a must skip its
      // reconnect-request while b still sends one.
      degrade(b);
      await settle(
        () => sentCount('workspace-reconnect-request', key: 'draft-b') == 1,
        'reconnect-request for draft-b',
      );
      expect(
        sentCount('workspace-reconnect-request', key: 'draft-a'),
        1,
        reason: 'draft-a stays on the reopen path',
      );
      await settle(
        () => sentCount('workspace-bridge-open', key: 'draft-a') == 3,
        'reopen of draft-a while draft-b recovers',
      );

      answerReconnect(
        lastSent('workspace-reconnect-request', key: 'draft-b'),
        success: true,
      );
      deliverBridgeReady(lastSent('workspace-bridge-open', key: 'draft-a'),
          'draft-a');
      await settle(
        () => a.degraded.value == null && b.degraded.value == null,
        'both bridges healthy',
      );
    });
  });
}
