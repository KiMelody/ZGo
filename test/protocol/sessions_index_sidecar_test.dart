// Sidecar sessions-index subscriptions (design 10-28): the protocol-layer
// pieces that let several index subscriptions share one bridge/channel —
// per-subscription scope addressing, per-topic frame routing, replay
// dedup by logicalFrameId, and the resubscribe failure hook the state
// layer classifies (benign cold runtime vs link trouble).
//
// Real timers, no fake_async (spec/protocol/protocol-guidelines.md §7):
// the backoff is shrunk through the transport's injectable
// [ConversationTransport.resubscribeBackoff].
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/ipc_codec.dart';
import 'package:zgo/protocol/remote_client.dart';

void main() {
  group('cold-runtime classification', () {
    test('the desktop refusal phrase classifies as benign, case-insensitively',
        () {
      expect(
        isAgentRuntimeNotRunningError(
          ChannelRpcError(
            'ZCode Agent runtime is not running for workspace /repo',
            null,
          ),
        ),
        isTrue,
      );
      expect(
        isAgentRuntimeNotRunningError(Exception('RUNTIME IS NOT RUNNING')),
        isTrue,
      );
    });

    test('link-shaped failures do not classify as the benign answer', () {
      expect(
        isAgentRuntimeNotRunningError(TimeoutException('bridge gate')),
        isFalse,
      );
      expect(
        isAgentRuntimeNotRunningError(
          ChannelRpcError('Channel name \'zcode-agent\' timed out', null),
        ),
        isFalse,
      );
    });

    test('the structured runtime-unavailable code matches without the phrase',
        () {
      // Desktop 3.16.3 sets ZCODE_AGENT_RUNTIME_UNAVAILABLE on
      // createRuntimeUnavailableError; the ChannelServer 202 whitelist keeps
      // `code` on the wire, so the code alone must be enough (a desktop
      // re-wording its English message must not break the classification).
      expect(
        isAgentRuntimeNotRunningError(
          ChannelRpcError(
            'boom',
            {'code': 'ZCODE_AGENT_RUNTIME_UNAVAILABLE'},
          ),
        ),
        isTrue,
      );
    });

    test('provider-not-ready is a different failure, never the cold runtime',
        () {
      // Static lock (10-28 research §5.3): the provider gate answers
      // ZCODE_AGENT_PROVIDER_NOT_READY with Chinese copy. Misclassifying it
      // would tell the user to open the workspace instead of configuring a
      // model.
      expect(
        isAgentRuntimeNotRunningError(
          ChannelRpcError(
            '当前没有可用的模型供应商和模型，请先登录或配置 API Key。',
            {'code': 'ZCODE_AGENT_PROVIDER_NOT_READY'},
          ),
        ),
        isFalse,
      );
    });
  });

  group('scope-addressed subscriptions on one channel', () {
    late _SidecarChannels channels;
    late List<String> logs;
    late _FastBackoffTransport transport;

    setUp(() {
      logs = [];
      channels = _SidecarChannels();
      transport = _FastBackoffTransport(
        session: _FakeBridgeSession(channels.client),
        scope: {'workspacePath': '/active'},
        onLog: logs.add,
      );
    });

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

    Future<SessionsIndexSubscription> subscribe(
      Map<String, dynamic> scope,
      String subscriptionId,
    ) async {
      final expected = channels.count('subscribeSessionsIndexV4') + 1;
      final done = transport.subscribeSessionsIndex(scope: scope);
      await pumpUntil(
        () => channels.count('subscribeSessionsIndexV4') == expected,
      );
      channels.answer('subscribeSessionsIndexV4', {
        'ack': {'subscriptionId': subscriptionId},
      });
      return done;
    }

    test('the subscribe and the event listen carry the overridden scope',
        () async {
      final sub = await subscribe(
        {'workspacePath': '/other', 'workspaceIdentity': 'other-id'},
        'sub-other',
      );
      final sentScope = channels.argsFor('subscribeSessionsIndexV4').single;
      expect(sentScope, {
        'workspacePath': '/other',
        'workspaceIdentity': 'other-id',
        'runtimePolicy': 'existing-only',
      });
      // The EventListen arg is the subscription's own scope too — the
      // desktop filters/addresses pushes by it.
      expect(channels.listenArgs, [
        {'workspacePath': '/other', 'workspaceIdentity': 'other-id'},
      ]);
      // Topic = sessions-index/<workspaceIdentity ?? workspacePath>.
      channels.fire(
        'onDynamicSessionsIndexFrame',
        _completeFrame(
          topic: 'sessions-index/other-id',
          subscriptionId: 'sub-other',
          logicalFrameId: 'lf-1',
          sessions: [
            {'sessionId': 's1', 'title': 'other', 'phase': 'running'},
          ],
        ),
      );
      expect(sub.state.sessions.keys, ['s1']);
      await sub.dispose();
    });

    test('frames route by topic: a sibling subscription state never sees them',
        () async {
      final subA = await subscribe({'workspacePath': '/a'}, 'sub-a');
      final subB = await subscribe({'workspacePath': '/b'}, 'sub-b');
      channels.fire(
        'onDynamicSessionsIndexFrame',
        _completeFrame(
          topic: 'sessions-index//a',
          subscriptionId: 'sub-a',
          logicalFrameId: 'lf-a',
          sessions: [
            {'sessionId': 'sa', 'title': 'a', 'phase': 'running'},
          ],
        ),
      );
      expect(subA.state.sessions.keys, ['sa']);
      expect(subB.state.sessions, isEmpty);
      expect(subB.state.ready, isFalse);
      await subA.dispose();
      await subB.dispose();
    });

    test('a replayed logicalFrameId is applied once (R4 duplicate snapshot)',
        () async {
      final sub = await subscribe({'workspacePath': '/b'}, 'sub-b');
      var notifies = 0;
      sub.state.addListener(() => notifies++);
      final frame = _completeFrame(
        topic: 'sessions-index//b',
        subscriptionId: 'sub-b',
        logicalFrameId: 'lf-dup',
        sessions: [
          {'sessionId': 's1', 'title': 'first', 'phase': 'running'},
        ],
      );
      channels.fire('onDynamicSessionsIndexFrame', frame);
      expect(notifies, 1);
      // The replay carries a DIFFERENT body under the same logical id — if
      // the dedup were missing, s2 would appear and the state notifier
      // would fire again.
      channels.fire(
        'onDynamicSessionsIndexFrame',
        _completeFrame(
          topic: 'sessions-index//b',
          subscriptionId: 'sub-b',
          logicalFrameId: 'lf-dup',
          sessions: [
            {'sessionId': 's1', 'title': 'first', 'phase': 'running'},
            {'sessionId': 's2', 'title': 'replayed', 'phase': 'running'},
          ],
        ),
      );
      expect(notifies, 1);
      expect(sub.state.sessions.keys, ['s1']);
      expect(logs.join('\n'), contains('dropped replayed frame lf-dup'));
      await sub.dispose();
    });

    test('a normal next frame (new logicalFrameId) still applies', () async {
      final sub = await subscribe({'workspacePath': '/b'}, 'sub-b');
      channels.fire(
        'onDynamicSessionsIndexFrame',
        _completeFrame(
          topic: 'sessions-index//b',
          subscriptionId: 'sub-b',
          logicalFrameId: 'lf-1',
          sessions: [
            {'sessionId': 's1', 'title': 'first', 'phase': 'running'},
          ],
        ),
      );
      channels.fire(
        'onDynamicSessionsIndexFrame',
        _completeFrame(
          topic: 'sessions-index//b',
          subscriptionId: 'sub-b',
          logicalFrameId: 'lf-2',
          sessions: [
            {'sessionId': 's1', 'title': 'first', 'phase': 'completedSuccess'},
          ],
        ),
      );
      expect(sub.state.sessions['s1']!.phase, 'completedSuccess');
      await sub.dispose();
    });

    test('fragments of one logical frame never dedupe at the ingress, but a '
        'replayed assembly is dropped (check P2-3)', () async {
      final sub = await subscribe({'workspacePath': '/b'}, 'sub-b');
      var notifies = 0;
      sub.state.addListener(() => notifies++);
      final body = jsonEncode({
        'topic': 'sessions-index//b',
        'subscriptionId': 'sub-b',
        'fromSeq': 1,
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': 'ws-b',
            'sessions': [
              {'sessionId': 's1', 'title': 'first', 'phase': 'running'},
            ],
          },
        },
      });
      final bytes = utf8.encode(body);
      final half = bytes.length ~/ 2;
      void fireFragment(int index, List<int> part) => channels.fire(
            'onDynamicSessionsIndexFrame',
            _fragmentFrame(
              topic: 'sessions-index//b',
              subscriptionId: 'sub-b',
              logicalFrameId: 'lf-frag',
              index: index,
              count: 2,
              bytes: part,
            ),
          );
      fireFragment(0, bytes.sublist(0, half));
      expect(notifies, 0, reason: 'an incomplete assembly applies nothing');
      fireFragment(1, bytes.sublist(half));
      expect(notifies, 1);
      expect(sub.state.sessions.keys, ['s1']);

      // The sibling listen replays the whole logical frame fragment by
      // fragment — same id, so the assembly completes and must be dropped.
      fireFragment(0, bytes.sublist(0, half));
      fireFragment(1, bytes.sublist(half));
      expect(notifies, 1,
          reason: 'dedup runs on the assembled frame, not per fragment');
      expect(logs.join('\n'), contains('dropped replayed frame lf-frag'));
      await sub.dispose();
    });

    test('a new subscription generation re-accepts a repeated '
        'logicalFrameId (check P2-4)', () async {
      final sub = await subscribe({'workspacePath': '/b'}, 'sub-b');
      channels.fire(
        'onDynamicSessionsIndexFrame',
        _completeFrame(
          topic: 'sessions-index//b',
          subscriptionId: 'sub-b',
          logicalFrameId: 'lf-1',
          sessions: [
            {'sessionId': 's1', 'title': 'first', 'phase': 'running'},
          ],
        ),
      );
      expect(sub.state.sessions['s1']!.title, 'first');

      // Bridge swing → a fresh subscriptionId. The desktop may restart its
      // logicalFrameId sequence, so the replay window must reset with the
      // generation or the new generation's first frame dies silently.
      transport.session.recovered.value++;
      await pumpUntil(() => channels.count('subscribeSessionsIndexV4') == 2);
      channels.answer('subscribeSessionsIndexV4', {
        'ack': {'subscriptionId': 'sub-b2'},
      });
      await pumpUntil(() => sub.subscriptionId == 'sub-b2');
      channels.fire(
        'onDynamicSessionsIndexFrame',
        _completeFrame(
          topic: 'sessions-index//b',
          subscriptionId: 'sub-b2',
          logicalFrameId: 'lf-1',
          sessions: [
            {'sessionId': 's1', 'title': 'reborn', 'phase': 'running'},
          ],
        ),
      );
      expect(sub.state.sessions['s1']!.title, 'reborn');
      await sub.dispose();
    });

    test('dispose unsubscribes with the sidecar own scope', () async {
      final sub = await subscribe(
        {'workspacePath': '/other', 'workspaceIdentity': 'other-id'},
        'sub-other',
      );
      await sub.dispose();
      expect(channels.argsFor('unsubscribeSessionsIndexV4').single, {
        'workspacePath': '/other',
        'workspaceIdentity': 'other-id',
        'subscriptionId': 'sub-other',
        'runtimePolicy': 'existing-only',
      });
    });
  });

  group('subscribe failures (design 10-28 red lines)', () {
    late _SidecarChannels channels;
    late List<String> ledger;
    late List<Object> subscribeFailures;

    setUp(() {
      channels = _SidecarChannels();
      ledger = [];
      subscribeFailures = [];
    });

    /// The LINK-level ledger hook the state layer feeds from send paths —
    /// subscribe traffic bypasses it on purpose. Reported here means the
    /// cold-runtime exemption is broken.
    _FastBackoffTransport transport() => _FastBackoffTransport(
          session: _FakeBridgeSession(channels.client),
          scope: {'workspacePath': '/active'},
          onLinkLevelFailure: (channel, error) => ledger.add('$error'),
        );

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

    test('a cold-runtime INITIAL refusal rethrows, classifies benign, feeds '
        'no ledger, and leaves no live subscription', () async {
      final t = transport();
      final done = t.subscribeSessionsIndex(
        scope: {'workspacePath': '/cold'},
        onSubscribeFailure: subscribeFailures.add,
      );
      await pumpUntil(() => channels.count('subscribeSessionsIndexV4') == 1);
      channels.fail(
        'subscribeSessionsIndexV4',
        'ZCode Agent runtime is not running for workspace /cold',
      );
      Object? caught;
      try {
        await done;
      } catch (e) {
        caught = e;
      }
      expect(isAgentRuntimeNotRunningError(caught!), isTrue);
      expect(subscribeFailures, isEmpty,
          reason: 'initial failures rethrow to the caller, not the hook');
      expect(ledger, isEmpty, reason: 'subscribe paths never feed the ledger');

      // The failed subscription was disposed: a bridge rebuild cannot
      // resurrect it.
      t.session.recovered.value++;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(channels.count('subscribeSessionsIndexV4'), 1);
    });

    test('a cold-runtime RESUBSCRIBE failure reaches the hook and the retry '
        'queue stops', () async {
      final t = transport();
      final done = t.subscribeSessionsIndex(
        scope: {'workspacePath': '/cold'},
        onSubscribeFailure: subscribeFailures.add,
      );
      await pumpUntil(() => channels.count('subscribeSessionsIndexV4') == 1);
      channels.answer('subscribeSessionsIndexV4', {
        'ack': {'subscriptionId': 'sub-cold'},
      });
      final sub = await done;

      // Bridge swing → resubscribe → the workspace's runtime is gone.
      t.session.recovered.value++;
      await pumpUntil(() => channels.count('subscribeSessionsIndexV4') == 2);
      channels.fail(
        'subscribeSessionsIndexV4',
        'ZCode Agent runtime is not running for workspace /cold',
      );
      await pumpUntil(() => subscribeFailures.isNotEmpty);
      expect(isAgentRuntimeNotRunningError(subscribeFailures.single), isTrue);
      expect(ledger, isEmpty, reason: 'subscribe paths never feed the ledger');

      // The caller's hook is expected to dispose the subscription (the
      // DeviceSession sidecar manager does); it never retries on its own
      // otherwise. Here the test disposes like that caller would.
      await sub.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(channels.count('subscribeSessionsIndexV4'), 2,
          reason: 'no retry storm past the failure hook');
    });

    test('a generic resubscribe failure keeps the built-in retry', () async {
      final t = transport();
      final done = t.subscribeSessionsIndex(
        scope: {'workspacePath': '/b'},
        onSubscribeFailure: subscribeFailures.add,
      );
      await pumpUntil(() => channels.count('subscribeSessionsIndexV4') == 1);
      channels.answer('subscribeSessionsIndexV4', {
        'ack': {'subscriptionId': 'sub-b'},
      });
      final sub = await done;

      t.session.recovered.value++;
      await pumpUntil(() => channels.count('subscribeSessionsIndexV4') == 2);
      channels.fail('subscribeSessionsIndexV4', 'bridge blip');
      await pumpUntil(() => subscribeFailures.isNotEmpty);
      expect(isAgentRuntimeNotRunningError(subscribeFailures.single), isFalse);
      // Built-in backoff (40ms base here) retries on its own.
      await pumpUntil(() => channels.count('subscribeSessionsIndexV4') == 3);
      await sub.dispose();
    });
  });
}

/// A complete wire frame as `_handleWireFrame` receives it: the outer
/// envelope carries the routing fields, the inner logical frame the stream
/// data.
Map<String, dynamic> _completeFrame({
  required String topic,
  required String subscriptionId,
  required String logicalFrameId,
  required List<Map<String, dynamic>> sessions,
}) =>
    {
      'wireVersion': 3,
      'kind': 'complete',
      'topic': topic,
      'subscriptionId': subscriptionId,
      'logicalFrameId': logicalFrameId,
      'frame': {
        'topic': topic,
        'subscriptionId': subscriptionId,
        'fromSeq': 1,
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {'workspaceId': topic, 'sessions': sessions},
        },
      },
    };

/// One fragment of a logical frame as `_handleWireFrame` receives it: the
/// envelope carries the routing/assembly fields, [bytes] is a slice of the
/// base64-encoded logical frame body.
Map<String, dynamic> _fragmentFrame({
  required String topic,
  required String subscriptionId,
  required String logicalFrameId,
  required int index,
  required int count,
  required List<int> bytes,
}) =>
    {
      'wireVersion': 3,
      'kind': 'fragment',
      'topic': topic,
      'subscriptionId': subscriptionId,
      'logicalFrameId': logicalFrameId,
      'fragmentIndex': index,
      'fragmentCount': count,
      'dataBase64': base64.encode(bytes),
    };

/// Test transport with a 40/80/160ms backoff (same injectable seam as
/// conversation_subscription_test.dart's).
class _FastBackoffTransport extends ConversationTransport {
  _FastBackoffTransport({
    required super.session,
    required super.scope,
    super.onLog,
    super.onLinkLevelFailure,
  });

  @override
  Duration resubscribeBackoff(int failedAttempts) {
    final step = failedAttempts.clamp(0, 2).toInt();
    return Duration(milliseconds: 40 << step);
  }
}

/// Channel client recording EVERY EventListen registration (a real
/// ChannelClient fans the same event message out to all of them — the
/// fan-out the topic gate + replay dedup defend against) and answering the
/// handshake immediately; upgrades/subscribes park until [answer] / [fail].
class _SidecarChannels {
  final sent = <String>[];
  final _args = <(String, Object?)>[];
  final parked = <(String, int)>[];
  final listenIds = <int>[];
  final listenArgs = <Map>[];

  late final ChannelClient client;

  _SidecarChannels() {
    late final ChannelClient c;
    c = ChannelClient(sendBody: (body) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      final method = '${header[3]}';
      final id = header[1] as int;
      final type = (header[0] as num).toInt();
      if (type == ChannelClient.reqEventListen) {
        listenIds.add(id);
        // Body layout: [reqType, id, channel, name] then the arg value.
        final arg = decodeValue(reader);
        listenArgs.add(arg is Map ? Map.from(arg) : const {});
        return;
      }
      if (type == ChannelClient.reqEventDispose) return;
      sent.add(method);
      final arg = decodeValue(reader);
      _args.add((method, arg));
      switch (method) {
        case 'helloConversationV4':
          _reply(c, id, {'connectionId': 'conn-test'});
        case 'initializeConversationV4':
        case 'unsubscribeSessionsIndexV4':
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

  /// Fires [data] at EVERY registered listener — exactly what a shared
  /// channel event does.
  void fire(String event, Object? data) {
    if (listenIds.isEmpty) {
      throw StateError('no event listener registered for $event');
    }
    for (final id in listenIds) {
      final w = ValueWriter();
      encodeValue(w, [ChannelClient.resEventFire, id]);
      encodeValue(w, data);
      client.handleMessage(w.toBytes());
    }
  }

  int count(String method) => sent.where((m) => m == method).length;

  List<Map> argsFor(String method) => [
        for (final (m, a) in _args)
          if (m == method)
            if (a is List && a.isNotEmpty && a.first is Map)
              Map.from(a.first as Map)
            else
              const {},
      ];
}

/// Bridge stand-in: only [channels], [recovered], [degraded],
/// [lastDegradedAt] and [waitHealthy] are real; anything else fails loud
/// via noSuchMethod (conversation_subscription_test.dart's contract).
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
