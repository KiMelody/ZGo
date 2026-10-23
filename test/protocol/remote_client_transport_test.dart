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
      'result': {
        'workspaces': [
          {'workspacePath': '/repo'},
        ],
      },
    });
    final result = await future;
    expect(result['workspaces'], hasLength(1));

    // sendMobileDiagnostic is relay-layer telemetry, forwarded verbatim.
    client.sendMobileDiagnostic('state-transition', {'state': 'paired'});
    expect(fake.diagnostics.single['event'], 'state-transition');
    expect(fake.diagnostics.single['state'], 'paired');

    await client.dispose();
  });
}
