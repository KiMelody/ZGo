// Step-4 wiring tests for task 11-13-command-reconcile (AC5 triggers +
// AC6 caller contract): a degraded-window timeout suspends and starts the
// first query fire-and-forget, the recovered wave compensates, every
// reconcile path awaits handshake first, query-side failures back off and
// leave the item to the TTL, and an attempt-1 resend never suspends again.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/ipc_codec.dart';
import 'package:zgo/protocol/remote_client.dart' show BridgeSession;

void main() {
  group('reconcile triggers', () {
    late _Wire wire;
    late _Session session;
    late ConversationTransport transport;
    late List<CommandLedgerOutcome> outcomes;
    late StreamSubscription<CommandLedgerOutcome> outcomeSub;
    final failures = <Object>[];

    setUp(() {
      wire = _Wire();
      session = _Session(wire.client);
      failures.clear();
      transport = ConversationTransport(
        session: session,
        scope: const {'workspacePath': '/repo'},
        workspaceHookReviewUi: true,
        commandLedgerTtl: const Duration(seconds: 10),
        commandLedgerSecondConfirmDelay: const Duration(seconds: 3),
        commandLedgerQueryRetryDelays: const [
          Duration(milliseconds: 60),
          Duration(milliseconds: 60),
        ],
        onLinkLevelFailure: (_, error) => failures.add(error),
      );
      outcomes = [];
      outcomeSub = transport.ledger.outcomes.listen(outcomes.add);
    });

    tearDown(() async {
      await outcomeSub.cancel();
      await transport.ledger.dispose();
      session.recovered.dispose();
      session.degraded.dispose();
    });

    test('a degraded-window timeout suspends, returns the sentinel first, '
        'then reconciles with handshake-first', () async {
      final done = transport.sendCommand(
        's1',
        'sendText',
        {'text': 'hi'},
        timeout: const Duration(milliseconds: 100),
      );
      await _pumpUntil(() => wire.envelopes.isNotEmpty);
      // The recovered wave clears the cached handshake; the degraded stamp
      // stays behind, so the timeout still catches the pendulum window.
      session.recovered.value++;
      session.markDegraded('rpc-transport-fault');
      session.degraded.value = null;

      final commandId = '${wire.envelopes.single['commandId']}';
      await expectLater(
        done,
        throwsA(
          isA<CommandSuspendedException>()
              .having((e) => e.commandId, 'commandId', commandId),
        ),
      );
      // Fire-and-forget: the sentinel is already thrown while the first
      // query is still parked on the wire.
      await _pumpUntil(() => wire.queries.isNotEmpty);
      expect(wire.parkedQueries, 1);
      expect(
        transport.ledger.entry(commandId)?.state,
        CommandLedgerState.suspended,
      );
      // The reconcile path awaits handshake() first: the recovered wave
      // cleared `_handshaken`, so a NEW hello/initialize pair precedes the
      // query call.
      final queryAt = wire.methods.indexOf('queryConversationCommandsV4');
      final helloAt = wire.methods.lastIndexOf('helloConversationV4');
      expect(
        wire.methods.where((m) => m == 'helloConversationV4').length,
        2,
        reason: 'the recovered wave forced a fresh handshake',
      );
      expect(helloAt, lessThan(queryAt));
      expect(wire.methods.lastIndexOf('initializeConversationV4'),
          lessThan(queryAt));
      expect(wire.queries.single.single, {
        'sessionId': 's1',
        'commandId': commandId,
      });
      expect(failures, isEmpty,
          reason: 'a suspension is not a link failure');

      wire.answerQuery(0, _accepted(sessionId: 's1', commandId: commandId));
      await _pumpUntil(() => transport.ledger.entry(commandId) == null);
    });

    test('the recovered wave compensates a suspended item without waiting '
        'for the second-confirmation delay', () async {
      final done = transport.sendCommand(
        's1',
        'sendText',
        {'text': 'hi'},
        timeout: const Duration(milliseconds: 80),
      );
      await _pumpUntil(() => wire.envelopes.isNotEmpty);
      session.markDegraded('rpc-transport-fault');

      final commandId = '${wire.envelopes.single['commandId']}';
      await expectLater(done, throwsA(isA<CommandSuspendedException>()));

      await _pumpUntil(() => wire.queries.length == 1);
      wire.answerQuery(0, _unknown(sessionId: 's1', commandId: commandId));
      await _pumpUntil(
        () => transport.ledger.entry(commandId)?.confirmScheduled ?? false,
      );
      final firstQueryAt = wire.methods.indexOf('queryConversationCommandsV4');

      // Compensation trigger: the bridge recovers and the transport starts
      // a reconcile immediately (not on the 3s confirmation timer).
      session.degraded.value = null;
      session.recovered.value++;

      await _pumpUntil(() => wire.queries.length == 2);
      final helloAt = wire.methods.lastIndexOf('helloConversationV4');
      final secondQueryAt =
          wire.methods.lastIndexOf('queryConversationCommandsV4');
      expect(helloAt, greaterThan(firstQueryAt),
          reason: 'the compensation path must handshake again');
      expect(secondQueryAt, greaterThan(helloAt));

      wire.answerQuery(0, _accepted(sessionId: 's1', commandId: commandId));
      await _pumpUntil(() => transport.ledger.entry(commandId) == null);
      // A suspended item's terminal delivery IS emitted (the UI chip
      // upgrades on it); the chain's root binds to the original command id.
      expect(outcomes.single.settlement, CommandLedgerSettlement.delivered);
      expect(outcomes.single.rootCommandId, commandId);
    });

    test('query-side failures back off twice and leave the item to the TTL '
        '(never a command verdict)', () async {
      final local = ConversationTransport(
        session: session,
        scope: const {'workspacePath': '/repo'},
        commandLedgerTtl: const Duration(milliseconds: 700),
        commandLedgerSecondConfirmDelay: const Duration(seconds: 3),
        commandLedgerQueryRetryDelays: const [
          Duration(milliseconds: 50),
          Duration(milliseconds: 50),
        ],
        onLinkLevelFailure: (_, error) => failures.add(error),
      );
      final localOutcomes = <CommandLedgerOutcome>[];
      final localSub = local.ledger.outcomes.listen(localOutcomes.add);
      addTearDown(localSub.cancel);
      addTearDown(local.ledger.dispose);

      wire.queryResponder = (_, __) =>
          throw StateError('relay wrapped failure');

      final done = local.sendCommand(
        's1',
        'sendText',
        {'text': 'hi'},
        timeout: const Duration(milliseconds: 80),
      );
      await _pumpUntil(() => wire.envelopes.isNotEmpty);
      session.markDegraded('rpc-transport-fault');

      final commandId = '${wire.envelopes.single['commandId']}';
      await expectLater(done, throwsA(isA<CommandSuspendedException>()));

      // Initial query + two backoff rounds, all transient failures.
      await _pumpUntil(() => wire.queries.length == 3);
      expect(
        local.ledger.entry(commandId)?.state,
        CommandLedgerState.suspended,
      );
      expect(localOutcomes, isEmpty,
          reason: 'a query failure is never a command outcome');

      await _pumpUntil(() => localOutcomes.isNotEmpty);
      expect(localOutcomes.single.settlement, CommandLedgerSettlement.timedOut);
      expect(local.ledger.entry(commandId), isNull);
    });

    test('an attempt-1 resend timeout is terminal: no second suspension, '
        'failed outcome emitted', () async {
      final done = transport.sendCommand(
        's1',
        'sendText',
        {'text': 'hi'},
        timeout: const Duration(milliseconds: 80),
        attempt: 1,
        rootCommandId: 'root-1',
      );
      await _pumpUntil(() => wire.envelopes.isNotEmpty);
      session.markDegraded('rpc-transport-fault');
      session.degraded.value = null;

      await expectLater(
        done,
        throwsA(
          isA<TimeoutException>().having(
            (e) => e is CommandSuspendedException,
            'isSuspendedSentinel',
            isFalse,
          ),
        ),
      );
      // No blind replay, no re-suspension, no query: the attempt bound is
      // the terminal failure.
      expect(wire.envelopes, hasLength(1));
      expect(transport.ledger.entries, isEmpty);
      expect(wire.queries, isEmpty);
      await _pumpUntil(() => outcomes.isNotEmpty);
      expect(outcomes.single.settlement, CommandLedgerSettlement.failed);
      expect(outcomes.single.rootCommandId, 'root-1');
    });

    test('a stale query decision seeds the CAS base: the ledger resend hits '
        'the wire with revisionAtDecision as baseRevision', () async {
      wire.commandResponder = (index, envelope) =>
          index == 0 ? null : const {'status': 'accepted'};
      wire.queryResponder = (index, commands) {
        final commandId = '${wire.envelopes.first['commandId']}';
        return _queryReply('s1', commandId, {
          'commandId': commandId,
          'status': 'stale',
          'reasonCode': 'proto.staleRevision',
          'revisionAtDecision': 42,
        });
      };
      final done = transport.sendCommand(
        's1',
        'setFollowupMode',
        {'mode': 'always'},
        timeout: const Duration(milliseconds: 120),
      );
      await _pumpUntil(() => wire.envelopes.isNotEmpty);
      final original = wire.envelopes.single;
      final commandId = '${original['commandId']}';
      expect(original['baseRevision'], 0);

      session.markDegraded('rpc-transport-fault');
      session.degraded.value = null;

      await expectLater(done, throwsA(isA<CommandSuspendedException>()));

      // The stale bucket re-enters through _resendFromLedger; the seeded
      // revision must be the CAS base of the resend envelope itself.
      await _pumpUntil(() => wire.envelopes.length == 2);
      final resend = wire.envelopes[1];
      expect('${resend['commandId']}', isNot(commandId));
      expect(resend['type'], 'setFollowupMode');
      expect(resend['payload'], {'mode': 'always'});
      expect(resend['baseRevision'], 42,
          reason: 'the stale decision seeds _ackedRevisions before re-entry');
      expect(wire.queries, hasLength(1));

      await _pumpUntil(() => outcomes.isNotEmpty);
      expect(outcomes.single.settlement, CommandLedgerSettlement.delivered);
      expect(outcomes.single.rootCommandId, commandId);
      expect(outcomes.single.commandId, '${resend['commandId']}');
      expect(transport.ledger.entries, isEmpty);
    });

    test('a closed gate degrades non-idempotent commands to the legacy blind '
        'resend: fresh commandId, no ledger entry, no further query',
        () async {
      wire.commandResponder = (index, envelope) =>
          index == 0 || index == 2 ? null : const {'status': 'accepted'};
      wire.queryResponder = (index, commands) => throw ChannelRpcError(
            'Method not found: queryConversationCommandsV4',
            null,
          );

      final done = transport.sendCommand(
        's1',
        'sendText',
        {'text': 'hi'},
        timeout: const Duration(milliseconds: 120),
      );
      await _pumpUntil(() => wire.envelopes.isNotEmpty);
      final original = wire.envelopes.single;
      final commandId = '${original['commandId']}';
      session.markDegraded('rpc-transport-fault');
      session.degraded.value = null;

      await expectLater(done, throwsA(isA<CommandSuspendedException>()));
      await _pumpUntil(() => wire.envelopes.length == 2);
      await _pumpUntil(() => transport.ledger.ledgerDisabled);

      // The gate-close handoff re-enters with reconcile:false: the legacy
      // path must blind-resend with a fresh commandId (non-idempotent),
      // record nothing and never query again.
      final handoff = wire.envelopes[1];
      expect('${handoff['commandId']}', isNot(commandId));
      expect(handoff['type'], 'sendText');
      expect(handoff['payload'], {'text': 'hi'});
      expect(wire.queries, hasLength(1));
      expect(transport.ledger.entries, isEmpty);

      // A NEW command sent after the gate closed falls to the same legacy
      // branch when its degraded-window timeout hits (the else-if
      // ledgerDisabled arm): blind resend, no suspension, no entry.
      final post = transport.sendCommand(
        's1',
        'sendText',
        {'text': 'again'},
        timeout: const Duration(milliseconds: 120),
      );
      await _pumpUntil(() => wire.envelopes.length == 3);
      final afterClose = wire.envelopes[2];
      session.markDegraded('rpc-transport-fault');
      session.degraded.value = null;

      expect(await post, {'status': 'accepted'});
      expect(wire.envelopes, hasLength(4));
      final retry = wire.envelopes[3];
      expect('${retry['commandId']}', isNot('${afterClose['commandId']}'));
      expect(retry['payload'], {'text': 'again'});
      expect(wire.queries, hasLength(1),
          reason: 'the closed gate never queries again');
      expect(transport.ledger.entries, isEmpty);
      // Both blind resends are silent: the handoff supersedes its original
      // and the post-close settle is a non-root inflight item.
      expect(outcomes, isEmpty);
    });

    test('a resend rejected with proto.sessionNotFound is recoverable: one '
        'preflight+resend cycle, the second hit is terminal', () async {
      wire.commandResponder = (index, envelope) {
        if (index == 0) return null; // original times out → suspension
        return {
          'status': 'rejected',
          'reasonCode': commandSessionNotFoundReasonCode,
          'message': 'Session is not active: s1',
          'revisionAtDecision': 0,
        };
      };
      wire.queryResponder = (index, commands) {
        final commandId = '${wire.envelopes.first['commandId']}';
        return _queryReply('s1', commandId, {
          'commandId': commandId,
          'status': 'stale',
          'reasonCode': 'proto.staleRevision',
          'revisionAtDecision': 2,
        });
      };
      final done = transport.sendCommand(
        's1',
        'sendText',
        {'text': 'hi'},
        timeout: const Duration(milliseconds: 80),
      );
      await _pumpUntil(() => wire.envelopes.isNotEmpty);
      session.markDegraded('rpc-transport-fault');
      session.degraded.value = null;
      await expectLater(done, throwsA(isA<CommandSuspendedException>()));
      final rootId = '${wire.envelopes.first['commandId']}';

      // Envelope 2 is the stale-driven resend; the desktop refuses it
      // before execution because the session was not live on the bridge.
      await _pumpUntil(() => wire.envelopes.length == 2);
      final firstResend = '${wire.envelopes[1]['commandId']}';
      expect(
        transport.ledger.entry(firstResend)?.state,
        CommandLedgerState.suspended,
        reason: 'sessionNotFound keeps the chain suspended',
      );
      expect(outcomes, isEmpty,
          reason: 'the recoverable refusal never reaches the chip');

      // One backoff round later the chain re-enters; the second refusal is
      // the terminal failure (maxNotFoundRetries = 1).
      await _pumpUntil(() => wire.envelopes.length == 3);
      expect('${wire.envelopes[2]['commandId']}', isNot(firstResend));
      await _pumpUntil(() => outcomes.isNotEmpty);
      expect(outcomes.single.settlement, CommandLedgerSettlement.rejected);
      expect(outcomes.single.rootCommandId, rootId);
      expect(transport.ledger.entries, isEmpty);
    });
  });
}

Future<void> _pumpUntil(
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

Map<String, dynamic> _accepted({
  required String sessionId,
  required String commandId,
}) => _queryReply(sessionId, commandId, {
  'commandId': commandId,
  'status': 'accepted',
});

Map<String, dynamic> _unknown({
  required String sessionId,
  required String commandId,
}) => _queryReply(sessionId, commandId, 'unknown');

Map<String, dynamic> _queryReply(
  String sessionId,
  String commandId,
  Object result,
) => {
  'results': [
    {
      'key': {'sessionId': sessionId, 'commandId': commandId},
      'result': result,
    },
  ],
};

/// Channel stand-in: handshake answers immediately; command calls park until
/// the transport timeout fires; query calls park unless [queryResponder]
/// answers (a throw becomes a channel rejection).
class _Wire {
  final methods = <String>[];
  final envelopes = <Map<String, dynamic>>[];
  final queries = <List<Map<String, dynamic>>>[];
  final _parkedQueries = <int, void Function(Object?)>{};

  /// Optional query responder. Null (or a null return) parks the call for
  /// [answerQuery]; a throw replies as `resPromiseError`.
  Object? Function(int index, List<Map<String, dynamic>> commands)?
      queryResponder;

  /// Optional command responder. A null return parks the call (the
  /// suspension source); a throw replies as `resPromiseError`.
  Object? Function(int index, Map<String, dynamic> envelope)?
      commandResponder;

  late final ChannelClient client;

  int get parkedQueries => _parkedQueries.length;

  _Wire() {
    late final ChannelClient c;
    c = ChannelClient(sendBody: (body) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      final method = '${header[3]}';
      final id = header[1] as int;
      final arg = decodeValue(reader);
      final args = arg is List ? arg : <Object?>[arg];
      methods.add(method);
      switch (method) {
        case 'helloConversationV4':
          _reply(c, id, {'connectionId': 'conn-test'});
        case 'initializeConversationV4':
          _reply(c, id, const {'status': 'accepted'});
        case 'sendConversationCommandV4':
          final sendRequest = args.single as Map;
          final envelope = (sendRequest['envelope'] as Map? ?? const {})
              .cast<String, dynamic>();
          envelopes.add(envelope);
          final commandResponder = this.commandResponder;
          if (commandResponder != null) {
            try {
              final answer =
                  commandResponder(envelopes.length - 1, envelope);
              if (answer != null) _reply(c, id, answer);
            } catch (error) {
              _replyError(c, id, error);
            }
          }
          // Otherwise park: the command timeout must fire for the
          // suspension branch.
        case 'queryConversationCommandsV4':
          final queryRequest = args.single as Map;
          final queryCommands = [
            for (final raw in (queryRequest['commands'] as List? ?? const []))
              (raw as Map).cast<String, dynamic>(),
          ];
          queries.add(queryCommands);
          final responder = queryResponder;
          if (responder == null) {
            _parkedQueries[id] = (value) => _reply(c, id, value);
          } else {
            try {
              final answer = responder(queries.length - 1, queryCommands);
              if (answer == null) {
                _parkedQueries[id] = (value) => _reply(c, id, value);
              } else {
                _reply(c, id, answer);
              }
            } catch (error) {
              _replyError(c, id, error);
            }
          }
        default:
          _reply(c, id, null);
      }
    });
    final init = ValueWriter();
    encodeValue(init, [ChannelClient.resInitialize, 0]);
    c.handleMessage(init.toBytes());
    client = c;
  }

  void answerQuery(int at, Object? payload) {
    final id = _parkedQueries.keys.elementAt(at);
    final reply = _parkedQueries.remove(id);
    reply?.call(payload);
  }

  void _reply(ChannelClient c, int id, Object? payload) {
    final w = ValueWriter();
    encodeValue(w, [ChannelClient.resPromiseSuccess, id]);
    encodeValue(w, payload);
    c.handleMessage(w.toBytes());
  }

  void _replyError(ChannelClient c, int id, Object error) {
    final w = ValueWriter();
    encodeValue(w, [ChannelClient.resPromiseError, id]);
    encodeValue(w, {'message': '$error'});
    c.handleMessage(w.toBytes());
  }
}

/// Bridge stand-in: only what the transport constructor, send gate and
/// recovery listener touch.
class _Session implements BridgeSession {
  _Session(this.channels);

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
