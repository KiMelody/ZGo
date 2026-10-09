import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/ipc_codec.dart';
import 'package:zgo/protocol/remote_client.dart' show BridgeSession;

/// Wire-shape matrix for [ConversationTransport.createSelectionSideSession]
/// (task parity-reference D1). The payload schema is
/// `{firstInput?: {text, modelSelection?}}` (runtime @1440615 neighbouring
/// schema — the only payload field; the side chat's selection history is
/// derived server-side and never travels). The ack union is
/// `{status, result:{type:'createSelectionSideSession', sessionId}}`, both
/// `accepted` and `duplicate` carrying the result (fork-isomorphic).
///
/// Hand-written fakes only (no sockets, no mockito): the transport rides a
/// fake bridge whose channel client answers each RPC from a programmed table,
/// and the sent envelope is captured from the `sendConversationCommandV4`
/// call.
void main() {
  test('empty payload when firstText is null — the create-empty shape',
      () async {
    final wire = _Wire((channel, method, args) => _acceptedAck);
    final id = await wire.transport.createSelectionSideSession('sess_parent');
    expect(id, 'sess_side');

    final envelope = wire.lastEnvelope();
    expect(envelope['type'], 'createSelectionSideSession');
    expect(envelope['sessionId'], 'sess_parent');
    expect(envelope['payload'], <String, dynamic>{});
  });

  test('blank firstText omits firstInput too (schema text is trim().min(1))',
      () async {
    final wire = _Wire((channel, method, args) => _acceptedAck);
    await wire.transport.createSelectionSideSession('sess_parent', firstText: '   ');
    expect(wire.lastEnvelope()['payload'], <String, dynamic>{});
  });

  test('firstInput carries the trimmed direct-ask text', () async {
    final wire = _Wire((channel, method, args) => _acceptedAck);
    await wire.transport.createSelectionSideSession('sess_parent',
        firstText: '  为什么这里会失败  ');
    expect(wire.lastEnvelope()['payload'], {
      'firstInput': {'text': '为什么这里会失败'},
    });
  });

  test('firstInput carries modelSelection when supplied', () async {
    final wire = _Wire((channel, method, args) => _acceptedAck);
    await wire.transport.createSelectionSideSession(
      'sess_parent',
      firstText: '换个模型问',
      modelSelection: const {'providerId': 'p1', 'model': 'glm-5.2'},
    );
    expect(wire.lastEnvelope()['payload'], {
      'firstInput': {
        'text': '换个模型问',
        'modelSelection': {'providerId': 'p1', 'model': 'glm-5.2'},
      },
    });
  });

  test('modelSelection without text is ignored (no firstInput at all)',
      () async {
    final wire = _Wire((channel, method, args) => _acceptedAck);
    await wire.transport.createSelectionSideSession('sess_parent',
        modelSelection: const {'model': 'glm-5.2'});
    expect(wire.lastEnvelope()['payload'], <String, dynamic>{});
  });

  test('accepted ack returns result.sessionId', () async {
    final wire = _Wire((channel, method, args) => const {
          'status': 'accepted',
          'result': {'type': 'createSelectionSideSession', 'sessionId': 'sess_side'},
        });
    expect(
      await wire.transport.createSelectionSideSession('sess_parent'),
      'sess_side',
    );
  });

  test('duplicate ack (commandId dedupe replay) returns result.sessionId too',
      () async {
    final wire = _Wire((channel, method, args) => const {
          'status': 'duplicate',
          'result': {'type': 'createSelectionSideSession', 'sessionId': 'sess_side'},
        });
    expect(
      await wire.transport.createSelectionSideSession('sess_parent'),
      'sess_side',
    );
  });

  test('rejected ack throws a StateError carrying the reasonCode', () async {
    final wire = _Wire((channel, method, args) => const {
          'status': 'rejected',
          'reasonCode': 'guard.subagentReadOnly',
        });
    await expectLater(
      wire.transport.createSelectionSideSession('sess_child'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('guard.subagentReadOnly'),
        ),
      ),
    );
  });

  test('accepted ack without a usable sessionId throws', () async {
    final wire = _Wire((channel, method, args) =>
        const {'status': 'accepted', 'result': <String, dynamic>{}});
    await expectLater(
      wire.transport.createSelectionSideSession('sess_parent'),
      throwsA(isA<StateError>()),
    );
  });
}

/// The pass ack carrying the new id — create-empty and firstInput payload
/// tests only need the command to complete, so they answer with this.
const _acceptedAck = {
  'status': 'accepted',
  'result': {'type': 'createSelectionSideSession', 'sessionId': 'sess_side'},
};

/// Capturing harness: a [ConversationTransport] over a fake bridge whose
/// channel client answers every RPC from [respond], recording the envelopes.
class _Wire {
  _Wire(Object? Function(String channel, String method, List<Object?> args) respond) {
    final calls = <(String, String, List<Object?>)>[];
    transport = ConversationTransport(
      session: _FakeBridgeSession(
        _channelClient((channel, method, args) {
          calls.add((channel, method, args));
          return respond(channel, method, args);
        }),
      ),
      scope: const {'workspacePath': '/repo'},
    );
    _calls = calls;
  }

  late final ConversationTransport transport;
  late final List<(String, String, List<Object?>)> _calls;

  Map<String, dynamic> lastEnvelope() {
    final arg = _calls
        .lastWhere((c) => c.$2 == 'sendConversationCommandV4')
        .$3
        .single;
    return (arg as Map)['envelope'] as Map<String, dynamic>;
  }
}

/// Channel client that resolves every `call` synchronously out of [respond];
/// a throw becomes a resPromiseError frame (channel rejection).
ChannelClient _channelClient(
  Object? Function(String channel, String method, List<Object?> args) respond,
) {
  late final ChannelClient client;
  client = ChannelClient(sendBody: (body) {
    final reader = ValueReader(body);
    final header = decodeValue(reader) as List;
    final arg = decodeValue(reader);
    final id = header[1] as int;
    Object? payload;
    var type = ChannelClient.resPromiseSuccess;
    try {
      payload = respond(
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

/// Bridge stand-in for transport-level RPC tests: only [channels],
/// [recovered], [degraded] and [waitHealthy] (used by the transport's
/// constructor and send gate) are real.
class _FakeBridgeSession implements BridgeSession {
  _FakeBridgeSession(this.channels);

  @override
  final ChannelClient channels;

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
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
