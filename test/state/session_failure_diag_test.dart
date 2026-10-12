import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';

/// Diagnostic outbound sanitizer (task 10-11-acceptance-fix-batch R3):
/// the D3 mobile-diagnostic channel is a closed set and the wire
/// `failureReason` must stay inside the desktop's 11-value enum. The
/// relay KICKED path's internal 'kicked' maps to its semantic desktop
/// equivalent 'session-conflict' on this outbound line ONLY —
/// `RelayFailure.reason` and the kicked state machine keep the original
/// value (hard constraint).
RemoteConnectionParams paramsOf() => RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
    )!;

/// Relay-backed client replaced wholesale (same手法 as
/// device_session_stall_test.dart): every network step answers locally so
/// the session state machine runs against a controlled link.
class StubRemoteClient extends RemoteClient {
  StubRemoteClient(super.params);

  @override
  Future<void> connect() => Future.value();

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() => Future.value({
        'workspaces': [
          {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
        ],
      });

  @override
  Future<BridgeSession> openBridge(
    String workspaceKey, {
    String? taskId,
    Duration timeout = const Duration(seconds: 30),
  }) => Future.error(StateError('workspace-bridge-error: stub has no bridges'));

  @override
  Future<void> dispose() => Future.value();
}

Future<(DeviceSession, StubRemoteClient)> connectedSession() async {
  late StubRemoteClient stubRef;
  final session = DeviceSession(
    deviceId: 'd1',
    params: paramsOf(),
    clientFactory: () => stubRef = StubRemoteClient(paramsOf()),
  );
  await session.connect();
  return (session, stubRef);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('relay KICKED reaches the kicked state machine but leaves the wire '
      'as session-conflict', () async {
    final (session, stub) = await connectedSession();
    final relayFailures = <String>[];
    stub.relay.failures.listen((f) => relayFailures.add(f.reason));
    final captured = <Map<String, dynamic>>[];
    stub.relay.debugDiagnosticSink = captured.add;

    stub.relay.debugHandleRelayError('KICKED', 'another terminal took over');
    // Broadcast streams deliver asynchronously — let the failure land in
    // both listeners before asserting.
    await pumpEventQueue();

    // Internal value intact (hard constraint): the failure stream, the
    // kicked flag and the UI-facing reason all keep 'kicked'.
    expect(relayFailures, ['kicked']);
    expect(session.kicked, isTrue);
    expect(session.failureReason, 'kicked');

    // Wire value mapped: D3 closure keeps failureReason in the enum.
    final diag = captured.singleWhere((p) => p['event'] == 'failure');
    expect(diag['failureReason'], 'session-conflict');
    expect(diag['failureMessage'], 'another terminal took over');

    await session.dispose();
  });

  test('in-enum failure reasons pass through untouched', () async {
    final (session, stub) = await connectedSession();
    final captured = <Map<String, dynamic>>[];
    stub.relay.debugDiagnosticSink = captured.add;

    // debugDropSocket on an unpaired client surfaces 'relay-unavailable'
    // — one of the desktop's 11 enum values, must not be rewritten.
    await stub.relay.debugDropSocket();
    await pumpEventQueue();

    final diag = captured.singleWhere((p) => p['event'] == 'failure');
    expect(diag['failureReason'], 'relay-unavailable');
    expect(session.failureReason, 'relay-unavailable');

    await session.dispose();
  });
}
