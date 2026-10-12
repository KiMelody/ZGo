// Subscription-level tests for conversation_subscription.dart — the
// resubscribe failure paths (10-11): the sessionNotFound terminal failure
// and the exponential retry backoff. Transport-level wire tests stay in
// conversation_test.dart (barrel-named); this file mirrors the lib file
// that owns the subscription lifecycle.
//
// Real timers, no fake_async (spec/protocol/protocol-guidelines.md §7):
// the backoff is shrunk through the transport's injectable
// [ConversationTransport.resubscribeBackoff] (same seam as
// subscribeAckTimeout), so every wait here is milliseconds.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/ipc_codec.dart';
import 'package:zgo/protocol/remote_client.dart';

void main() {
  group('resubscribeBackoff schedule', () {
    test('stock transport: 3s → 6s → 12s, capped at 12s (10-11 R2)', () {
      final transport = ConversationTransport(
        session: _FakeBridgeSession(_autoChannels()),
        scope: {'workspacePath': '/repo'},
      );
      expect(transport.resubscribeBackoff(0), const Duration(seconds: 3));
      expect(transport.resubscribeBackoff(1), const Duration(seconds: 6));
      expect(transport.resubscribeBackoff(2), const Duration(seconds: 12));
      // Third failure onwards stays at the cap.
      expect(transport.resubscribeBackoff(3), const Duration(seconds: 12));
      expect(transport.resubscribeBackoff(99), const Duration(seconds: 12));
    });
  });

  group('resubscribe failure handling (10-11)', () {
    late _ManualChannels channels;
    late List<String> logs;
    late _FastBackoffTransport transport;

    /// Backoff schedule of the test transport: 40/80/160ms.
    Duration scheduled(int failedAttempts) =>
        Duration(milliseconds: 40 << failedAttempts.clamp(0, 2));

    setUp(() {
      logs = [];
      channels = _ManualChannels();
      transport = _FastBackoffTransport(
        session: _FakeBridgeSession(channels.client),
        scope: {'workspacePath': '/repo'},
        onLog: logs.add,
      );
    });

    /// Deadline-bounded wait (the parked channel drives everything else
    /// deterministically; timers never fire early so the lower bounds hold).
    Future<void> pumpUntil(
      bool Function() test, {
      Duration timeout = const Duration(seconds: 5),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (!test()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('pumpUntil: condition not met within $timeout');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    void answerSubscribe(String subscriptionId) => channels.answer(
          'subscribeConversationV4',
          {
            'ack': {'subscriptionId': subscriptionId, 'logEpoch': 'e1'},
          },
        );

    test('sessionNotFound refusal: retry queue stops, terminal failure '
        'surfaces to the upper layer', () async {
      final terminal = <Object?>[];
      final done = transport.subscribe('s1');
      await pumpUntil(() => channels.count('subscribeConversationV4') == 1);
      answerSubscribe('sub-1');
      final sub = await done;
      final errors = sub.terminalFailures.listen(terminal.add);

      // Bridge swing → resubscribe → the desktop authoritatively refuses.
      transport.session.recovered.value++;
      await pumpUntil(() => channels.count('subscribeConversationV4') == 2);
      channels.fail(
        'subscribeConversationV4',
        'Session is not active and not persisted: s1 '
        '(fault.subscribe.sessionNotFound)',
      );

      // The refusal is classified as terminal and surfaces upstream.
      await pumpUntil(() => terminal.isNotEmpty);
      final refusal = terminal.single as ChannelRpcError;
      expect(
        refusal.message,
        contains('Session is not active and not persisted'),
      );
      expect(
        logs.join('\n'),
        contains('subscribe refused (session not found)'),
      );

      // Well past where a retry timer WOULD have fired (base 40ms): no
      // new subscribe — the deterministic error must not churn retries.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(channels.count('subscribeConversationV4'), 2);

      await errors.cancel();
      await sub.dispose();
    });

    test('refused INITIAL subscribe: error classifies as-is and the failed '
        'subscription is disposed (no recovery-wave resurrection)', () async {
      final done = transport.subscribe('s1');
      await pumpUntil(() => channels.count('subscribeConversationV4') == 1);
      channels.fail(
        'subscribeConversationV4',
        'Session is not active and not persisted: s1 '
            '(fault.subscribe.sessionNotFound)',
      );
      Object? caught;
      try {
        await done;
      } catch (e) {
        caught = e;
      }
      // The refusal surfaces to the caller unchanged — DeviceSession's
      // initial-open record rides this same predicate.
      expect(caught, isA<ChannelRpcError>());
      expect(isSessionNotFoundError(caught!), isTrue);

      // The failed initial subscription must be disposed by the transport:
      // a leaked (undisposed) one would still sit on the bridge-recovery
      // hook (armed by its constructor) and fire one more subscribe on
      // the next wave — plus its 30s fragment-cleanup timer, forever.
      transport.session.recovered.value++;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(channels.count('subscribeConversationV4'), 1);
    });

    test('terminal failure is NOT resurrected by a bridge recovery wave',
        () async {
      final done = transport.subscribe('s1');
      await pumpUntil(() => channels.count('subscribeConversationV4') == 1);
      answerSubscribe('sub-1');
      final sub = await done;

      transport.session.recovered.value++;
      await pumpUntil(() => channels.count('subscribeConversationV4') == 2);
      channels.fail(
        'subscribeConversationV4',
        'Session is not active and not persisted: s1 '
        '(fault.subscribe.sessionNotFound)',
      );
      await pumpUntil(
        () => logs.any((l) => l.contains('session not found')),
      );

      // Another bridge rebuild after the terminal failure: the refusal is
      // a fact about the SESSION, not the link — recovery must not sweep
      // it back into the retry loop.
      transport.session.recovered.value++;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(channels.count('subscribeConversationV4'), 2);

      await sub.dispose();
    });

    test('other errors: intervals grow 40→80→160ms; a success resets the '
        'counter to the base delay', () async {
      final done = transport.subscribe('s1');
      await pumpUntil(() => channels.count('subscribeConversationV4') == 1);
      answerSubscribe('sub-1');
      final sub = await done;

      // Failure episode, round 1 (attempt 0 → 40ms backoff).
      transport.session.recovered.value++;
      await pumpUntil(() => channels.count('subscribeConversationV4') == 2);
      channels.fail('subscribeConversationV4', 'bridge blip');
      await Future<void>.delayed(scheduled(0) * 0.5);
      expect(channels.count('subscribeConversationV4'), 2,
          reason: 'before the 40ms backoff no retry may fire');
      await pumpUntil(
        () => channels.count('subscribeConversationV4') == 3,
        timeout: scheduled(0) * 4,
      );

      // Round 2 (attempt 1 → 80ms).
      channels.fail('subscribeConversationV4', 'bridge blip');
      await Future<void>.delayed(scheduled(1) * 0.5);
      expect(channels.count('subscribeConversationV4'), 3,
          reason: 'before the 80ms backoff no retry may fire');
      await pumpUntil(
        () => channels.count('subscribeConversationV4') == 4,
        timeout: scheduled(1) * 4,
      );

      // Round 3 (attempt 2 → 160ms), then the retry ACKS — the episode
      // ends and the counter resets.
      channels.fail('subscribeConversationV4', 'bridge blip');
      await Future<void>.delayed(scheduled(2) * 0.5);
      expect(channels.count('subscribeConversationV4'), 4,
          reason: 'before the 160ms backoff no retry may fire');
      await pumpUntil(
        () => channels.count('subscribeConversationV4') == 5,
        timeout: scheduled(2) * 4,
      );
      answerSubscribe('sub-5');
      await pumpUntil(() => sub.subscriptionId == 'sub-5');

      // Fresh failure after a success: back to the BASE delay (40ms), not
      // the 160ms the pre-success streak had reached.
      transport.session.recovered.value++;
      await pumpUntil(() => channels.count('subscribeConversationV4') == 6);
      final beforeReset = channels.subscribeAt[5];
      channels.fail('subscribeConversationV4', 'bridge blip');
      await Future<void>.delayed(scheduled(0) * 0.5);
      expect(channels.count('subscribeConversationV4'), 6,
          reason: 'reset counter: before the base 40ms no retry may fire');
      await pumpUntil(
        () => channels.count('subscribeConversationV4') == 7,
        timeout: scheduled(0) * 4,
      );
      expect(channels.subscribeAt[6].difference(beforeReset),
          lessThan(scheduled(1)),
          reason: 'post-success retry must be back at the base delay');

      await sub.dispose();
    });
  });
}

/// Test transport with a shrunk backoff schedule (40/80/160ms) — same
/// injectable-seam pattern as subscribeAckTimeout shrinking.
class _FastBackoffTransport extends ConversationTransport {
  _FastBackoffTransport({
    required super.session,
    required super.scope,
    super.onLog,
  });

  @override
  Duration resubscribeBackoff(int failedAttempts) {
    final step = failedAttempts.clamp(0, 2).toInt();
    return Duration(milliseconds: 40 << step);
  }
}

/// Channel client with test-driven responses: handshake (and unsubscribe)
/// calls answer immediately; every other call parks as (method, id) until
/// [answer] / [fail] completes the [at]-th parked call of that method.
/// Subscribe-call send timestamps land in [subscribeAt] for backoff-gap
/// assertions.
class _ManualChannels {
  final parked = <(String, int)>[];

  /// Every call handed to [ChannelClient] (parked or auto-answered).
  final sent = <String>[];

  /// Wall clock of every `subscribeConversationV4` send, in call order.
  final subscribeAt = <DateTime>[];

  late final ChannelClient client;

  _ManualChannels() {
    late final ChannelClient c;
    c = ChannelClient(sendBody: (body) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      final method = '${header[3]}';
      final id = header[1] as int;
      if ((header[0] as num).toInt() == ChannelClient.reqEventListen) {
        return;
      }
      sent.add(method);
      if (method == 'subscribeConversationV4') {
        subscribeAt.add(DateTime.now());
      }
      switch (method) {
        case 'helloConversationV4':
          _reply(c, id, {'connectionId': 'conn-test'});
        case 'initializeConversationV4':
        case 'unsubscribeConversationV4':
          _reply(c, id, const {'status': 'accepted'});
        default:
          parked.add((method, id));
      }
    });
    final init = ValueWriter();
    encodeValue(init, [ChannelClient.resInitialize, 0]);
    c.handleMessage(init.toBytes());
    client = c;
  }

  void _reply(
    ChannelClient c,
    int id,
    Object? payload, {
    bool error = false,
  }) {
    final w = ValueWriter();
    encodeValue(
      w,
      [
        error ? ChannelClient.resPromiseError : ChannelClient.resPromiseSuccess,
        id,
      ],
    );
    encodeValue(w, payload);
    c.handleMessage(w.toBytes());
  }

  void answer(String method, Object? payload, {int at = 0}) =>
      _complete(method, payload, at: at);

  /// Rejects the [at]-th parked call of [method] as a channel error whose
  /// message is [message] (the desktop's PromiseError shape).
  void fail(String method, String message, {int at = 0}) =>
      _complete(method, {'message': message}, at: at, error: true);

  void _complete(
    String method,
    Object? payload, {
    int at = 0,
    bool error = false,
  }) {
    var seen = 0;
    for (var i = 0; i < parked.length; i++) {
      if (parked[i].$1 != method) continue;
      if (seen++ != at) continue;
      final (_, id) = parked.removeAt(i);
      _reply(client, id, payload, error: error);
      return;
    }
    throw StateError('no parked call #$at for $method');
  }

  int count(String method) => sent.where((m) => m == method).length;
}

/// Synchronously-answering channel client for transports that never
/// subscribe in the test body (schedule assertions only).
ChannelClient _autoChannels() {
  late final ChannelClient c;
  c = ChannelClient(sendBody: (body) {
    final reader = ValueReader(body);
    final header = decodeValue(reader) as List;
    if ((header[0] as num).toInt() == ChannelClient.reqEventListen) return;
    final w = ValueWriter();
    encodeValue(w, [ChannelClient.resPromiseSuccess, header[1] as int]);
    encodeValue(w, const {'status': 'accepted'});
    c.handleMessage(w.toBytes());
  });
  final init = ValueWriter();
  encodeValue(init, [ChannelClient.resInitialize, 0]);
  c.handleMessage(init.toBytes());
  return c;
}

/// Bridge stand-in: only [channels], [recovered], [degraded],
/// [lastDegradedAt] and [waitHealthy] are real; anything else fails loud
/// via noSuchMethod (same contract as conversation_test.dart's fake).
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
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
