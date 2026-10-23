import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/ipc_codec.dart';
import 'package:zgo/protocol/remote_client.dart' show BridgeSession;

/// 3.16.2 createSession project attribution (design 10-21 Part 2): the
/// projectId rides the OUTER channel parameters (sibling of workspacePath,
/// outside the envelope) and only on createSession. A `project.*` refusal
/// retries once without the field so creation can never fail because of a
/// stale mapping.
///
/// Hand-written fakes only (the createSelectionSideSession harness pattern):
/// a fake bridge answers RPCs from a programmed closure and the sent channel
/// parameters are captured verbatim.
void main() {
  test('projectId rides beside workspacePath, outside the envelope', () async {
    final wire = _Wire(
      (_) => _accepted,
      projectIdFor: (_) async => 'proj-1',
    );

    final id = await wire.transport.createSession(
      'ws-1',
      firstText: 'hello',
      config: const {'model': 'glm-5.2'},
    );

    expect(id, 'sess_new');
    final args = wire.channelArgs();
    expect(args['workspacePath'], r'F:\ZLinker');
    expect(args['projectId'], 'proj-1');
    final envelope = args['envelope'] as Map;
    expect(envelope.containsKey('projectId'), isFalse);
    expect(envelope['type'], 'createSession');
    expect(envelope['sessionId'], isNull);
    expect(envelope['payload'], {
      'workspaceId': 'ws-1',
      'firstInput': {'text': 'hello'},
      'config': {'model': 'glm-5.2'},
    });
  });

  test('no projectId key when the resolver has no mapping', () async {
    final wire = _Wire((_) => _accepted, projectIdFor: (_) async => null);

    await wire.transport.createSession('ws-1', firstText: 'hello');

    expect(wire.channelArgs().containsKey('projectId'), isFalse);
  });

  test('resolver failure is swallowed — creation proceeds unchanged', () async {
    final wire = _Wire(
      (_) => _accepted,
      projectIdFor: (_) async => throw StateError('resolver boom'),
    );

    expect(
      await wire.transport.createSession('ws-1', firstText: 'hello'),
      'sess_new',
    );
    expect(wire.channelArgs().containsKey('projectId'), isFalse);
  });

  test('other v4 commands never carry the outer projectId', () async {
    var lookups = 0;
    final wire = _Wire(
      (_) => _accepted,
      projectIdFor: (_) async {
        lookups++;
        return 'proj-1';
      },
    );

    await wire.transport.sendCommand(null, 'sendText', {
      'sessionId': 'sess_new',
      'text': 'hi',
    });

    expect(lookups, 0, reason: 'only createSession consults the resolver');
    expect(wire.channelArgs().containsKey('projectId'), isFalse);
    final envelope = wire.channelArgs()['envelope'] as Map;
    expect(envelope['type'], 'sendText');
  });

  test('project.* rejection retries once without projectId', () async {
    var attempts = 0;
    final wire = _Wire(
      (method) {
        attempts++;
        return attempts == 1
            ? const {
                'status': 'rejected',
                'reasonCode': 'project.cwd-not-in-roots',
                'message': 'workspace is not in the project roots',
              }
            : _accepted;
      },
      projectIdFor: (_) async => 'proj-stale',
    );

    expect(
      await wire.transport.createSession('ws-1', firstText: 'hello'),
      'sess_new',
    );

    final sends = wire.createSessionArgs();
    expect(sends, hasLength(2));
    expect(sends[0]['projectId'], 'proj-stale');
    expect(sends[1].containsKey('projectId'), isFalse,
        reason: 'the retry drops the stale mapping');
  });

  test('a second project.* rejection is final (the error propagates)',
      () async {
    final wire = _Wire(
      (_) => const {
        'status': 'rejected',
        'reasonCode': 'project.cwd-not-in-roots',
      },
      projectIdFor: (_) async => 'proj-stale',
    );

    await expectLater(
      wire.transport.createSession('ws-1', firstText: 'hello'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('project.cwd-not-in-roots'),
        ),
      ),
    );
    expect(wire.createSessionArgs(), hasLength(2));
  });

  test('non-project rejections do not retry', () async {
    final wire = _Wire(
      (_) => const {
        'status': 'rejected',
        'reasonCode': 'guard.readOnly',
      },
      projectIdFor: (_) async => 'proj-1',
    );

    await expectLater(
      wire.transport.createSession('ws-1', firstText: 'hello'),
      throwsA(isA<StateError>()),
    );
    expect(wire.createSessionArgs(), hasLength(1));
  });

  test('a thrown project.* channel error also retries without projectId',
      () async {
    var attempts = 0;
    final wire = _Wire(
      (_) {
        attempts++;
        if (attempts == 1) throw StateError('project.creation-unavailable');
        return _accepted;
      },
      projectIdFor: (_) async => 'proj-1',
    );

    expect(
      await wire.transport.createSession('ws-1', firstText: 'hello'),
      'sess_new',
    );
    final sends = wire.createSessionArgs();
    expect(sends, hasLength(2));
    expect(sends[0]['projectId'], 'proj-1');
    expect(sends[1].containsKey('projectId'), isFalse);
  });

  test("the ack-retry's own project.* failure is final (no third send)",
      () async {
    var attempts = 0;
    final wire = _Wire(
      (_) {
        attempts++;
        return attempts == 1
            ? const {
                'status': 'rejected',
                'reasonCode': 'project.cwd-not-in-roots',
              }
            : throw StateError('project.creation-unavailable');
      },
      projectIdFor: (_) async => 'proj-stale',
    );

    // The resend without the field already lacks the offending key — a
    // further resend of the same payload cannot help, so its error is final.
    await expectLater(
      wire.transport.createSession('ws-1', firstText: 'hello'),
      throwsA(
        predicate<Object>(
          (e) => '$e'.contains('project.creation-unavailable'),
          'project error propagates as-is',
        ),
      ),
    );
    expect(wire.createSessionArgs(), hasLength(2));
  });
}

const _accepted = {
  'status': 'accepted',
  'result': {'type': 'createSession', 'sessionId': 'sess_new'},
};

/// Capturing harness: a [ConversationTransport] over a fake bridge whose
/// channel client answers every RPC from [respond], recording the calls.
class _Wire {
  _Wire(
    Object? Function(String method) respond, {
    Future<String?> Function(String workspacePath)? projectIdFor,
  }) {
    final calls = <(String, String, List<Object?>)>[];
    transport = ConversationTransport(
      session: _FakeBridgeSession(
        _channelClient((channel, method, args) {
          calls.add((channel, method, args));
          // Handshake RPCs answer a benign map; only the v4 command carries
          // the programmed answer (attempt counters must count commands,
          // never the hello/initialize pair).
          if (method != 'sendConversationCommandV4') {
            return const {'connectionId': 'conn-test'};
          }
          return respond(method);
        }),
      ),
      scope: const {'workspacePath': r'F:\ZLinker'},
      projectIdFor: projectIdFor,
    );
    _calls = calls;
  }

  late final ConversationTransport transport;
  late final List<(String, String, List<Object?>)> _calls;

  /// Channel parameters of the last `sendConversationCommandV4` call.
  Map<String, dynamic> channelArgs() {
    final arg = _calls
        .lastWhere((c) => c.$2 == 'sendConversationCommandV4')
        .$3
        .single;
    return arg as Map<String, dynamic>;
  }

  /// Channel parameters of every createSession send, in call order.
  List<Map<String, dynamic>> createSessionArgs() => [
        for (final c in _calls)
          if (c.$2 == 'sendConversationCommandV4' &&
              (c.$3.single as Map)['envelope'] is Map &&
              ((c.$3.single as Map)['envelope'] as Map)['type'] ==
                  'createSession')
            c.$3.single as Map<String, dynamic>,
      ];
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
/// [recovered], [degraded] and [waitHealthy] are real.
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
