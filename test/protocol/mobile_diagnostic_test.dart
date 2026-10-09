import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/relay_client.dart';

/// D3 mobile-diagnostic: the relay-level funnel that the session/relay state
/// machines report through. Payload schema is the official union
/// (`zcode_type`/`event`/`timestamp` required, everything else optional —
/// app.asar @270011219 / @312316910).
RemoteConnectionParams paramsOf() => RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
    )!;

void main() {
  test('seven event shapes carry the official required fields', () {
    final client = RelayClient(paramsOf());
    final captured = <Map<String, dynamic>>[];
    client.debugDiagnosticSink = captured.add;

    client.sendMobileDiagnostic(
        'state-transition', {'state': 'paired', 'previousState': 'connecting'});
    client.sendMobileDiagnostic('socket-close', {
      'closeCode': 1006,
      'closeReason': 'drop',
      'wasClean': false,
      'wasPaired': true,
    });
    client.sendMobileDiagnostic('socket-error', {'failureMessage': 'boom'});
    client.sendMobileDiagnostic('recover-start', {'state': 'reconnecting'});
    client.sendMobileDiagnostic('recover-scheduled', {'state': 'waiting'});
    client.sendMobileDiagnostic(
        'pair-status', {'pairStatus': 'matched', 'state': 'waiting'});
    client.sendMobileDiagnostic(
        'failure', {'failureReason': 'kicked', 'failureMessage': 'm'});

    const events = [
      'state-transition',
      'socket-close',
      'socket-error',
      'recover-start',
      'recover-scheduled',
      'pair-status',
      'failure',
    ];
    expect(captured, hasLength(events.length));
    for (var i = 0; i < events.length; i++) {
      final payload = captured[i];
      expect(payload['zcode_type'], 'mobile-diagnostic');
      expect(payload['event'], events[i]);
      expect(payload['timestamp'], isA<int>());
      // Web-environment fields are omitted (ZGo is a native client, OQ4).
      expect(payload.containsKey('visibilityState'), isFalse);
      expect(payload.containsKey('online'), isFalse);
      expect(payload.containsKey('hiddenDurationMs'), isFalse);
    }
    expect(captured[0]['state'], 'paired');
    expect(captured[0]['previousState'], 'connecting');
    expect(captured[1]['closeCode'], 1006);
    expect(captured[1]['wasClean'], isFalse);
    expect(captured[1]['wasPaired'], isTrue);
    expect(captured[4]['state'], 'waiting');
    expect(captured[5]['pairStatus'], 'matched');
    expect(captured[6]['failureReason'], 'kicked');
  });

  test('dropped while the relay is not connected (nothing hits the wire)', () {
    final logs = <String>[];
    final client = RelayClient(paramsOf(), onLog: logs.add);
    client.sendMobileDiagnostic('socket-close', {'closeCode': 1006});
    client.sendMobileDiagnostic('failure', {'failureReason': 'kicked'});
    expect(logs.where((line) => line.contains('>>')), isEmpty);
  });

  test('send failures are swallowed (never surface to the caller)', () {
    final client = RelayClient(paramsOf());
    client.debugDiagnosticSink = (_) => throw StateError('sink boom');
    expect(
      () => client.sendMobileDiagnostic('failure', {'failureReason': 'x'}),
      returnsNormally,
    );
  });

  test('pair-status is transition-driven (repeated acks do not re-report)',
      () async {
    final client = RelayClient(paramsOf());
    final captured = <Map<String, dynamic>>[];
    client.debugDiagnosticSink = captured.add;

    client.debugApplyPairStatus('waiting');
    client.debugApplyPairStatus('waiting'); // heartbeat re-entry, same status
    client.debugApplyPairStatus('matched');
    client.debugApplyPairStatus('matched'); // same status again

    final reported = captured
        .where((p) => p['event'] == 'pair-status')
        .map((p) => p['pairStatus'])
        .toList();
    expect(reported, ['waiting', 'matched']);

    await client.dispose();
  });

  test('waiting state-transition is not re-reported per ack', () async {
    final client = RelayClient(paramsOf());
    final captured = <Map<String, dynamic>>[];
    client.debugDiagnosticSink = captured.add;

    client.debugApplyPairStatus('waiting');
    client.debugApplyPairStatus('waiting');
    client.debugApplyPairStatus('waiting');

    final transitions = captured
        .where((p) => p['event'] == 'state-transition')
        .toList();
    expect(transitions, hasLength(1));
    expect(transitions.single['state'], 'waiting');
    expect(transitions.single['previousState'], 'idle');

    await client.dispose();
  });

  test('wire gate opens on the first pair status of a socket', () async {
    // Live-verified 2026-10-09: the relay hard-fails auth when a data frame
    // precedes the handshake, so the gate must start closed on a fresh
    // client and open only once a pair status has been applied.
    final client = RelayClient(paramsOf());
    expect(client.debugDiagGateOpen, isFalse);
    client.debugApplyPairStatus('waiting');
    expect(client.debugDiagGateOpen, isTrue);
    await client.dispose();
  });
}
