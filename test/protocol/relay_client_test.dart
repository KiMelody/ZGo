import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/relay_client.dart';
import 'package:zgo/protocol/relay_kernel.dart';

class FakeV1Socket implements RelaySocket {
  final _incoming = StreamController<dynamic>.broadcast();
  final sent = <String>[];
  int closeCount = 0;

  @override
  Future<void> get ready => Future.value();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCount += 1;
    closeCode = code;
    closeReason = reason;
    if (!_incoming.isClosed) await _incoming.close();
  }

  void inject(Map<String, dynamic> frame) {
    if (!_incoming.isClosed) _incoming.add(jsonEncode(frame));
  }

  List<Map<String, dynamic>> get frames => [
        for (final raw in sent) (jsonDecode(raw) as Map).cast<String, dynamic>(),
      ];
}

RemoteConnectionParams paramsOf() => RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test'
      '&app_version=3.16.2',
    )!;

Future<void> pump([int ms = 10]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('V1 production timings stay at 10/30/30/20', () {
    expect(RelayClient.heartbeatInterval, const Duration(seconds: 10));
    expect(RelayClient.heartbeatAckTimeout, const Duration(seconds: 30));
    expect(RelayClient.waitingTimeout, const Duration(seconds: 30));
    expect(RelayClient.reconnectWaitTimeout, const Duration(seconds: 20));
  });

  test('auth_init carries the V1 proof handshake shape', () async {
    final socket = FakeV1Socket();
    final client =
        RelayClient(paramsOf(), webSocketFactory: (_) => socket);
    await client.start();
    await pump();

    expect(client.state, RelayState.authenticating);
    final init = socket.frames.single;
    expect(init['type'], 'auth_init');
    expect(init['role'], 'terminal');
    expect(init['device_sid'], 's');
    expect((init['meta'] as Map)['version'], '3.16.2');
    expect(init['client_ts'], isA<int>());

    socket.inject({'type': 'auth_challenge', 'nonce': 'abc'});
    await pump();
    final response = socket.frames.last;
    expect(response['type'], 'auth_response');
    expect(response['device_sid'], 's');
    expect(response['proof'], isA<String>());
    expect(response['proof'], isNotEmpty);
    expect(response['client_ts'], isA<int>());
    await client.dispose();
  });

  test('waiting gates diagnostics, matched flushes data with client_ts',
      () async {
    final socket = FakeV1Socket();
    final client =
        RelayClient(paramsOf(), webSocketFactory: (_) => socket);
    await client.start();
    await pump();

    client.sendMobileDiagnostic('failure', {'failureReason': 'x'});
    expect(socket.frames.where((f) => f['type'] == 'data'), isEmpty,
        reason: 'the diagnostic gate stays closed before the first pair status');

    socket.inject({'type': 'auth_ack', 'pair_status': 'waiting'});
    await pump();
    expect(client.state, RelayState.waiting);

    client.sendMobileDiagnostic('failure', {'failureReason': 'x'});
    final diag = socket.frames.where((f) => f['type'] == 'data').last;
    expect((diag['payload'] as Map)['zcode_type'], 'mobile-diagnostic');
    expect(diag['client_ts'], isA<int>());

    client.sendPayload({'zcode_type': 'q1'});
    client.sendPayload({'zcode_type': 'q2'});
    expect(
        socket.frames.where(
            (f) => (f['payload'] as Map?)?['zcode_type'] == 'q1'),
        isEmpty,
        reason: 'payloads queue while waiting');

    socket.inject({'type': 'auth_ack', 'pair_status': 'matched'});
    await pump();
    expect(client.state, RelayState.paired);
    final queued = socket.frames
        .where((f) =>
            f['type'] == 'data' &&
            {'q1', 'q2'}.contains((f['payload'] as Map)['zcode_type']))
        .toList();
    expect(queued.map((f) => (f['payload'] as Map)['zcode_type']), ['q1', 'q2']);
    expect(queued.every((f) => f['client_ts'] is int), isTrue,
        reason: 'V1 data frames carry client_ts (regenerated on flush)');
    await client.dispose();
  });

  test('KICKED reaches kicked + failure', () async {
    final socket = FakeV1Socket();
    final client =
        RelayClient(paramsOf(), webSocketFactory: (_) => socket);
    final failures = <RelayFailure>[];
    client.failures.listen(failures.add);
    await client.start();
    socket.inject({'type': 'auth_ack', 'pair_status': 'matched'});
    await pump();
    socket.inject({'type': 'error', 'code': 'KICKED', 'message': 'taken'});
    await pump();
    expect(client.state, RelayState.kicked);
    expect(failures.single.reason, 'kicked');
    expect(socket.closeCount, 1);
    await client.dispose();
  });

  test('an unpaired close surfaces relay-unavailable', () async {
    final socket = FakeV1Socket();
    final client =
        RelayClient(paramsOf(), webSocketFactory: (_) => socket);
    final failures = <RelayFailure>[];
    client.failures.listen(failures.add);
    await client.start();
    await socket.close(1006, 'drop');
    await pump();
    expect(client.state, RelayState.error);
    expect(failures.last.reason, 'relay-unavailable');
    await client.dispose();
  });
}
