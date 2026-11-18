import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/crc32.dart';
import 'package:zgo/protocol/rpc_transport.dart';

void main() {
  late List<Map<String, dynamic>> sent;
  late RpcFrameTransport transport;
  late List<Uint8List> received;

  setUp(() {
    sent = [];
    received = [];
    transport = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: (p) => sent.add(p),
    );
    transport.messages.listen((msg) => received.add(msg));
  });

  tearDown(() {
    transport.dispose();
  });

  test('send single-fragment message and receive via acceptPayload', () async {
    final received = <Uint8List>[];
    final transport = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: (_) {},
    );
    transport.messages.listen((msg) => received.add(msg));

    final payload = Uint8List.fromList([1, 2, 3, 4, 5]);

    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'seq': 1,
      'messageSeq': 1,
      'fragmentIndex': 0,
      'fragmentCount': 1,
      'messageBytes': 5,
      'dataBase64': base64.encode(payload),
    });
    await Future.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(received[0], [1, 2, 3, 4, 5]);
    await transport.dispose();
  });

  test('multi-fragment message roundtrip', () async {
    final sent = <Map<String, dynamic>>[];
    final received = <Uint8List>[];
    final transport = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: (p) => sent.add(p),
    );
    transport.messages.listen((msg) => received.add(msg));

    final payload = Uint8List(1024 * 1024 + 100);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = (i % 256);
    }
    transport.sendMessage(payload);
    expect(sent, hasLength(3)); // 2 full + 1 partial fragment

    final frames = List<Map<String, dynamic>>.from(sent.reversed);
    for (final frame in frames) {
      transport.acceptPayload(frame);
    }
    await Future.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(received[0], payload);
    await transport.dispose();
  });

  test('rpc-frame-ack is consumed', () {
    expect(
      transport.acceptPayload({
        'zcode_type': 'rpc-frame-ack',
        'bridgeSessionId': 'bridge-1',
      }),
      isTrue,
    );
  });

  test('non-rpc-frame passes through unconsumed', () {
    expect(
      transport.acceptPayload({'zcode_type': 'workspace-list-updated'}),
      isFalse,
    );
  });

  test('mismatched bridgeSessionId is not consumed', () {
    expect(
      transport.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'other-bridge',
      }),
      isFalse,
    );
  });

  test('invalid base64 data is handled gracefully', () {
    expect(
      transport.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'bridge-1',
        'messageSeq': 1,
        'fragmentIndex': 0,
        'fragmentCount': 1,
        'messageBytes': 5,
        'dataBase64': '!!!not-valid-base64!!!',
      }),
      isTrue,
    );
    expect(received, isEmpty);
  });

  test('missing required fields returns consumed without crash', () {
    expect(
      transport.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'bridge-1',
      }),
      isTrue,
    );
    expect(received, isEmpty);
  });

  test('checksum mismatch does not emit message', () {
    final payload = Uint8List.fromList([1, 2, 3]);

    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'messageSeq': 1,
      'fragmentIndex': 0,
      'fragmentCount': 1,
      'messageBytes': 3,
      'dataBase64': base64.encode(payload),
      'checksum': {'algorithm': 'crc32', 'value': '00000000'},
    });
    expect(received, isEmpty);
  });

  test('ack is sent on successful assembly', () {
    final payload = Uint8List.fromList([7, 8, 9]);
    final checksum = Crc32.hexOf(payload);

    sent.clear();
    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'messageSeq': 1,
      'fragmentIndex': 0,
      'fragmentCount': 1,
      'messageBytes': 3,
      'dataBase64': base64.encode(payload),
      'checksum': {'algorithm': 'crc32', 'value': checksum},
    });

    final ack = sent.firstWhere(
      (p) => p['zcode_type'] == 'rpc-frame-ack',
      orElse: () => <String, dynamic>{},
    );
    expect(ack['zcode_type'], 'rpc-frame-ack');
    expect(ack['ackMessageSeq'], 1);
    expect(ack['bridgeSessionId'], 'bridge-1');
  });

  test('sendMessage throws on empty payload', () {
    expect(
      () => transport.sendMessage(Uint8List(0)),
      throwsA(isA<StateError>()),
    );
  });

  test('reassembly with out-of-order fragments', () async {
    final received = <Uint8List>[];
    final transport = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: (_) {},
    );
    transport.messages.listen((msg) => received.add(msg));

    final payload = Uint8List.fromList(List.generate(200, (i) => i % 256));

    // Simulate two fragments arriving out of order
    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'messageSeq': 1,
      'fragmentIndex': 1,
      'fragmentCount': 2,
      'messageBytes': 200,
      'dataBase64': base64.encode(Uint8List.sublistView(payload, 100, 200)),
    });
    expect(received, isEmpty); // not complete yet

    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'messageSeq': 1,
      'fragmentIndex': 0,
      'fragmentCount': 2,
      'messageBytes': 200,
      'dataBase64': base64.encode(Uint8List.sublistView(payload, 0, 100)),
    });
    await Future.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(received[0], payload);
    await transport.dispose();
  });

  test('identity includes bridgeGeneration and recoveryId', () {
    final t = RpcFrameTransport(
      bridgeSessionId: 'b1',
      bridgeGeneration: 5,
      recoveryId: 'rec-99',
      sendPayload: (_) {},
    );
    expect(t.bridgeGeneration, 5);
    expect(t.recoveryId, 'rec-99');
    t.dispose();
  });

  test('server bridge generation bump fires onServerBridgeRebuilt (09-21)',
      () async {
    var rebuilt = 0;
    final t = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: (_) {},
      onServerBridgeRebuilt: () => rebuilt++,
    );
    void frame(int? generation, int messageSeq) =>
        t.acceptPayload({
          'zcode_type': 'rpc-frame',
          'bridgeSessionId': 'bridge-1',
          if (generation != null) 'bridgeGeneration': generation,
          'messageSeq': messageSeq,
          'fragmentIndex': 0,
          'fragmentCount': 1,
          'messageBytes': 1,
          'dataBase64': base64.encode(Uint8List.fromList([1])),
        });

    // The first frame sets the baseline: the server's counter already
    // sits above the client's, which must not read as a rebuild (a fresh
    // transport after a client-side reopen would otherwise false-fire).
    frame(7, 1);
    frame(7, 2);
    expect(rebuilt, 0);

    // The desktop rebuilt its bridge instance — bump fires once.
    frame(8, 3);
    expect(rebuilt, 1);
    // Same generation repeats / an out-of-order lower one: no re-fire.
    frame(8, 4);
    frame(7, 5);
    expect(rebuilt, 1);
    // A later rebuild fires again.
    frame(9, 6);
    expect(rebuilt, 2);
    // Frames without a generation (older servers) never fire.
    frame(null, 7);
    expect(rebuilt, 2);
    await t.dispose();
  });

  test('ack carries the full bridge identity', () {
    final sent = <Map<String, dynamic>>[];
    final t = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      bridgeGeneration: 5,
      recoveryId: 'rec-99',
      sendPayload: sent.add,
    );

    t.acceptPayload(completeFrame(1, [1, 2, 3], generation: 5));

    final ack = sent.single;
    // Exactly the identity keys shared with outbound rpc-frame: the
    // desktop zod is `.strict()` and an undeclared key is a terminal
    // `remote.rpcFrame.invalidPayload`, so the set is load-bearing.
    expect(ack.keys.toSet(), {
      'zcode_type',
      'bridgeSessionId',
      'bridgeGeneration',
      'recoveryId',
      'ackMessageSeq',
    });
    expect(ack['bridgeSessionId'], 'bridge-1');
    expect(ack['bridgeGeneration'], 5);
    expect(ack['recoveryId'], 'rec-99');
    expect(ack['ackMessageSeq'], 1);
    t.dispose();
  });

  test('ack omits identity fields the transport does not have', () {
    final sent = <Map<String, dynamic>>[];
    final t = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: sent.add,
    );

    t.acceptPayload(completeFrame(1, [4, 5, 6]));

    final ack = sent.single;
    expect(ack.keys.toSet(), {
      'zcode_type',
      'bridgeSessionId',
      'ackMessageSeq',
    });
    expect(ack.containsKey('bridgeGeneration'), isFalse);
    expect(ack.containsKey('recoveryId'), isFalse);
    t.dispose();
  });

  test('ack carries generation but no recoveryId (ZGo wire shape)', () {
    final sent = <Map<String, dynamic>>[];
    final t = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      bridgeGeneration: 3,
      sendPayload: sent.add,
    );

    t.acceptPayload(completeFrame(1, [7], generation: 3));

    final ack = sent.single;
    expect(ack.keys.toSet(), {
      'zcode_type',
      'bridgeSessionId',
      'bridgeGeneration',
      'ackMessageSeq',
    });
    expect(ack['bridgeGeneration'], 3);
    expect(ack.containsKey('recoveryId'), isFalse);
    t.dispose();
  });

  test('generation bump drops the old generation partial assembly', () async {
    final messages = <Uint8List>[];
    final sent = <Map<String, dynamic>>[];
    var rebuilt = 0;
    final t = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: sent.add,
      onServerBridgeRebuilt: () => rebuilt++,
    );
    t.messages.listen(messages.add);

    Map<String, dynamic> fragment(int generation, int fragmentIndex) => {
          'zcode_type': 'rpc-frame',
          'bridgeSessionId': 'bridge-1',
          'bridgeGeneration': generation,
          'messageSeq': 1,
          'fragmentIndex': fragmentIndex,
          'fragmentCount': 2,
          'messageBytes': 200,
          'dataBase64': base64.encode(
            Uint8List.fromList(List.generate(100, (i) => i)),
          ),
        };

    // Baseline generation 7: first fragment of a two-fragment message.
    t.acceptPayload(fragment(7, 0));
    expect(rebuilt, 0);
    expect(messages, isEmpty);

    // A generation 8 frame is the rebuild signal (no message fields, so
    // the bump itself must not emit or ack anything).
    t.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'bridgeGeneration': 8,
    });
    expect(rebuilt, 1);

    // The trailing fragment still says generation 7: the dropped assembly
    // must not complete, and the frame must not be acked.
    t.acceptPayload(fragment(7, 1));
    await Future<void>.delayed(Duration.zero);
    expect(messages, isEmpty);
    expect(sent.where((p) => p['zcode_type'] == 'rpc-frame-ack'), isEmpty);
    expect(rebuilt, 1);
    await t.dispose();
  });

  test('generation bump clears the old generation assembly (same messageSeq)',
      () async {
    final messages = <Uint8List>[];
    final sent = <Map<String, dynamic>>[];
    var rebuilt = 0;
    final t = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: sent.add,
      onServerBridgeRebuilt: () => rebuilt++,
    );
    t.messages.listen(messages.add);

    // Generation 7, two-fragment message: only the first fragment arrives.
    t.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'bridgeGeneration': 7,
      'messageSeq': 5,
      'fragmentIndex': 0,
      'fragmentCount': 2,
      'messageBytes': 8,
      'dataBase64': base64.encode(Uint8List.fromList([0xA0, 0xA1, 0xA2, 0xA3])),
    });
    expect(rebuilt, 0);
    expect(messages, isEmpty);
    expect(sent, isEmpty);

    // A generation 8 frame bumps the baseline and must drop the
    // half-built assembly.
    t.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'bridgeGeneration': 8,
    });
    expect(rebuilt, 1);

    // Same messageSeq 5, now a complete single-fragment generation 8
    // message. Without the clear, putIfAbsent would reuse the old
    // two-fragment assembly (one fragment received), so the frame would
    // never complete: no message, no ack.
    final gen8 = Uint8List.fromList([0xB0, 0xB1, 0xB2, 0xB3]);
    t.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'bridgeGeneration': 8,
      'messageSeq': 5,
      'fragmentIndex': 0,
      'fragmentCount': 1,
      'messageBytes': gen8.length,
      'dataBase64': base64.encode(gen8),
    });
    await Future<void>.delayed(Duration.zero);
    expect(messages, hasLength(1));
    expect(messages.single, gen8);
    final acks = sent.where((p) => p['zcode_type'] == 'rpc-frame-ack');
    expect(acks, hasLength(1));
    expect(acks.single['ackMessageSeq'], 5);
    expect(rebuilt, 1);
    await t.dispose();
  });

  test('frames from a superseded generation are ignored after a bump',
      () async {
    final messages = <Uint8List>[];
    final sent = <Map<String, dynamic>>[];
    final t = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: sent.add,
    );
    t.messages.listen(messages.add);

    // Establish generation 7 as the baseline, then bump to 8.
    t.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'bridgeGeneration': 7,
    });
    t.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'bridgeGeneration': 8,
    });

    // A complete old-generation message must not assemble or ack.
    t.acceptPayload(completeFrame(1, [1, 2, 3], generation: 7));
    await Future<void>.delayed(Duration.zero);
    expect(messages, isEmpty);
    expect(sent, isEmpty);
    await t.dispose();
  });

  test('frames without a generation still assemble and ack', () async {
    final messages = <Uint8List>[];
    final sent = <Map<String, dynamic>>[];
    final t = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: sent.add,
    );
    t.messages.listen(messages.add);

    t.acceptPayload(completeFrame(1, [9, 9]));
    await Future<void>.delayed(Duration.zero);
    expect(messages, hasLength(1));
    expect(sent.single.keys.toSet(), {
      'zcode_type',
      'bridgeSessionId',
      'ackMessageSeq',
    });
    await t.dispose();
  });
}

Map<String, dynamic> completeFrame(
  int messageSeq,
  List<int> bytes, {
  int? generation,
}) =>
    {
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      if (generation != null) 'bridgeGeneration': generation,
      'messageSeq': messageSeq,
      'fragmentIndex': 0,
      'fragmentCount': 1,
      'messageBytes': bytes.length,
      'dataBase64': base64.encode(bytes),
    };
