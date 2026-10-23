import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/relay_transport.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';

RemoteConnectionParams v2Params() => RemoteConnectionParams.parse(
  'https://zcode.z.ai/remote/v4?sid=s&mid=m&name=desk&app_version=3.16.2',
)!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('V2 session without a jwtProvider fails fast as auth-required', () async {
    final session = DeviceSession(
      deviceId: 'd1',
      params: v2Params(),
    );

    await session.connect();

    expect(session.status, DeviceStatus.error);
    expect(session.failureReason, 'auth-required');
    expect(session.kicked, isFalse);
    expect(session.error, contains('auth-required'));
    await session.dispose();
  });

  test('V2 session whose provider has no token surfaces auth-required',
      () async {
    final session = DeviceSession(
      deviceId: 'd2',
      params: v2Params(),
      jwtProvider: () async => null,
    );

    await session.connect().timeout(const Duration(seconds: 5));
    // The failure arrives on the relay's broadcast stream just after the
    // throwing start() — let it land.
    await pumpEventQueue();

    expect(session.status, DeviceStatus.error);
    expect(session.failureReason, 'auth-required');
    expect(session.kicked, isFalse);
    await session.dispose();
  });

  test('V1 session keeps working without the V2 seam', () async {
    // A V1 link never touches jwtProvider: a stub client proves the
    // pre-check only fires for params.v2.
    final params = RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=m',
    )!;
    var created = 0;
    final session = DeviceSession(
      deviceId: 'd3',
      params: params,
      clientFactory: () {
        created += 1;
        return _NoopClient(params);
      },
    );
    await session.connect();
    expect(created, 1);
    expect(session.failureReason, isNot('auth-required'));
    await session.dispose();
  });

  test('auth-required supersedes an earlier retryable failure reason',
      () async {
    // The transport's reconnect loop reports relay-unavailable first and
    // only later escalates to auth-required (token-endpoint circuit
    // breaker); the banner and the login self-heal must see the terminal
    // reason, not the stale retryable one.
    final relay = _FakeRelay();
    final params = v2Params();
    final session = DeviceSession(
      deviceId: 'd4',
      params: params,
      clientFactory: () => _FakeClient(relay),
    );
    await session.connect();
    expect(session.status, DeviceStatus.connected);

    relay.fail(const RelayFailure('relay-unavailable', 'token request failed'));
    await pumpEventQueue();
    expect(session.failureReason, 'relay-unavailable');

    relay.fail(const RelayFailure('auth-required', 'credential expired'));
    await pumpEventQueue();
    expect(session.failureReason, 'auth-required');

    // Invariant: the terminal reason must not be demoted back to a retryable
    // one by a later failure report.
    relay.fail(const RelayFailure('relay-unavailable', 'connection reset'));
    await pumpEventQueue();
    expect(session.failureReason, 'auth-required');

    await session.dispose();
  });
}

/// Minimal client whose relay is fully controllable from the test.
class _FakeClient extends RemoteClient {
  _FakeClient(RelayTransport relay)
      : super(_params, transportFactory: (_) => relay);

  static final _params = v2Params();

  @override
  Future<void> connect() => Future.value();

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() async => const {
    'workspaces': <Object>[],
    'tasks': <Object>[],
  };
}

class _FakeRelay implements RelayTransport {
  final _failures = StreamController<RelayFailure>.broadcast();
  final _payloads = StreamController<Map<String, dynamic>>.broadcast();
  final _state = ValueNotifier<RelayState>(RelayState.paired);

  void fail(RelayFailure failure) => _failures.add(failure);

  @override
  Stream<Map<String, dynamic>> get payloads => _payloads.stream;

  @override
  ValueListenable<RelayState> get stateListenable => _state;

  @override
  RelayState get state => _state.value;

  @override
  Stream<RelayFailure> get failures => _failures.stream;

  @override
  Future<void> start() => Future.value();

  @override
  void sendPayload(Map<String, dynamic> payload) {}

  @override
  void sendMobileDiagnostic(String event, [Map<String, dynamic>? fields]) {}

  @override
  Future<void> dispose() async {
    await _failures.close();
    await _payloads.close();
    _state.dispose();
  }
}

/// Minimal V1 client: connect/waits answer immediately; bootstrap returns an
/// empty overview so connect's auto-open is skipped.
class _NoopClient extends RemoteClient {
  _NoopClient(super.params);

  @override
  Future<void> connect() => Future.value();

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() async => const {
    'workspaces': <Object>[],
    'tasks': <Object>[],
  };

  @override
  Future<void> dispose() => Future.value();
}
