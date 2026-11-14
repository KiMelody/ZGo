// CommandLedger contract tests for task 11-13-command-reconcile (AC3/AC4):
// entry scope, five-bucket disposition, sendCommand re-entry shape,
// supersede-on-record, attempt bound, TTL scan scope, gate tightening,
// circuit breaker and the reconcile:false handoff.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/command_ledger.dart';
import 'package:zgo/protocol/conversation_command_query.dart';

void main() {
  group('entry scope', () {
    test('records every non-idempotent envelope kind with its sessionId, '
        'payload and channelExtra', () {
      final h = _Harness();
      addTearDown(h.dispose);
      const kinds = [
        'sendText',
        'stop',
        'compact',
        'retryTurn',
        'editUserQuery',
        'deleteQueueItem',
        'sendQueuedNow',
        'applyFileRewind',
        'renameSession',
        'deleteSession',
        'forkAssistant',
        'resolveInteraction',
        'setAutoDrain',
        'switchModelConfig',
        'setFollowupMode',
        'sendGoalCommand',
        'cancelBackgroundWork',
      ];
      for (final kind in kinds) {
        expect(
          h.ledger.record(
            commandId: 'c-$kind',
            sessionId: 's1',
            kind: kind,
            semanticPayload: {'kind': kind},
            channelExtra: {'extra': kind},
          ),
          isTrue,
        );
      }
      expect(h.ledger.entries, hasLength(kinds.length));
      final entry = h.ledger.entry('c-sendText')!;
      expect(entry.sessionId, 's1');
      expect(entry.kind, 'sendText');
      expect(entry.semanticPayload, {'kind': 'sendText'});
      expect(entry.channelExtra, {'extra': 'sendText'});
      expect(entry.sentAt, isNotNull);
      expect(entry.attempt, 0);
      expect(entry.rootCommandId, isNull);
      expect(entry.state, CommandLedgerState.inflight);
    });

    test('idempotent replay pairs stay out of the ledger', () {
      final h = _Harness();
      addTearDown(h.dispose);
      for (final kind in ['createSession', 'createSelectionSideSession']) {
        expect(
          h.ledger.record(
            commandId: 'c-$kind',
            sessionId: null,
            kind: kind,
            semanticPayload: const {},
          ),
          isFalse,
        );
        expect(h.ledger.entry('c-$kind'), isNull);
      }
      expect(h.ledger.entries, isEmpty);
    });

    test('shouldSuspend enforces the attempt bound and the closed gate', () {
      final h = _Harness();
      addTearDown(h.dispose);
      _track(h, 'first');
      _track(h, 'resend', attempt: 1);
      expect(h.ledger.shouldSuspend('first'), isTrue);
      expect(h.ledger.shouldSuspend('resend'), isFalse,
          reason: 'attempt >= maxAttempts settles instead of looping');
      expect(h.ledger.shouldSuspend('not-tracked'), isFalse);
      h.ledger.noteQueryFailure(
        ChannelRpcError('Method not found: queryConversationCommandsV4', null),
      );
      expect(h.ledger.shouldSuspend('first'), isFalse,
          reason: 'a closed gate falls back to the legacy path');
    });

    test('recording a resend supersedes the root at once, silently', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.ledger.record(
        commandId: 'root',
        sessionId: 's1',
        kind: 'sendText',
        semanticPayload: const {'text': 'hi'},
      );
      h.ledger.record(
        commandId: 'resend',
        sessionId: 's1',
        kind: 'sendText',
        semanticPayload: const {'text': 'hi'},
        attempt: 1,
        rootCommandId: 'root',
      );
      expect(h.ledger.entry('root'), isNull);
      final resend = h.ledger.entry('resend')!;
      expect(resend.attempt, 1);
      expect(resend.rootCommandId, 'root');
      expect(resend.rootId, 'root');
      await _flush();
      expect(h.events, isEmpty);
    });
  });

  group('normal ack settlement', () {
    test('delivered ack clears a non-rooted item silently', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      _track(h, 'c1');
      expect(h.ledger.settleFromAck('c1', {'status': 'accepted'}), isTrue);
      expect(h.ledger.entry('c1'), isNull);
      await _flush();
      expect(h.events, isEmpty);
    });

    test('rejected/failed ack clears; a rooted resend emits its terminal', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      _track(h, 'c1');
      h.ledger.settleFromAck('c1', {'status': 'rejected'});
      expect(h.ledger.entry('c1'), isNull);

      _track(h, 'new', root: 'root');
      h.ledger.settleFromAck('new', {
        'status': 'failed',
        'reasonCode': 'proto.deliveryFailed',
      });
      await _flush();
      expect(h.events, hasLength(1));
      final event = h.events.single;
      expect(event.commandId, 'new');
      expect(event.rootCommandId, 'root');
      expect(event.settlement, CommandLedgerSettlement.failed);
    });

    test('a late ack on a suspended item upgrades it (delivered event)', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(addresses);
      _track(h, 'c1');
      h.ledger.suspend('c1');
      await h.ledger.reconcile();
      expect(h.ledger.entry('c1')!.state, CommandLedgerState.suspended);
      h.ledger.settleFromAck('c1', {'status': 'accepted'});
      await _flush();
      expect(h.events.single.settlement, CommandLedgerSettlement.delivered);
    });

    test('switchModelConfig never emits a user-visible terminal', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      _track(h, 'c1', kind: 'switchModelConfig');
      h.ledger.settleFromAck('c1', {'status': 'rejected'});
      await _flush();
      expect(h.events, isEmpty);
    });

    test('discard clears a non-suspension failure path without an event', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      _track(h, 'c1');
      expect(h.ledger.discard('c1'), isTrue);
      expect(h.ledger.entry('c1'), isNull);
      await _flush();
      expect(h.events, isEmpty);
    });
  });

  group('stale bucket', () {
    test('stale decision re-enters through the resend seam with '
        'revisionAtDecision seeded', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(
        addresses,
        decisions: const {
          'c1': {
            'commandId': 'c1',
            'status': 'stale',
            'reasonCode': 'proto.staleRevision',
            'revisionAtDecision': 42,
          },
        },
      );
      _track(h, 'c1');
      h.ledger.suspend('c1');
      await h.ledger.reconcile();

      expect(h.queries.single, [
        const CommandAddress(sessionId: 's1', commandId: 'c1'),
      ]);
      expect(h.resends, hasLength(1));
      final request = h.resends.single;
      expect(request.commandId, 'c1');
      expect(request.rootCommandId, 'c1');
      expect(request.sessionId, 's1');
      expect(request.kind, 'sendText');
      expect(request.attempt, 1);
      expect(request.reconcile, isTrue);
      expect(request.seedRevision, 42);
      // The fake did not record a resend entry, so the original is still
      // suspended (TTL remains its bound) and nothing was emitted.
      expect(h.ledger.entry('c1')!.state, CommandLedgerState.suspended);
      await _flush();
      expect(h.events, isEmpty);
    });

    test('the resend entry recording supersedes the root; a later ack '
        'emits one delivered outcome and no timeout', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(
        addresses,
        decisions: const {
          'c1': {
            'commandId': 'c1',
            'status': 'stale',
            'revisionAtDecision': 42,
          },
        },
      );
      h.onResend = (request) async {
        h.ledger.record(
          commandId: 'resend-${request.attempt}',
          sessionId: request.sessionId,
          kind: request.kind,
          semanticPayload: request.payload,
          channelExtra: request.channelExtra,
          attempt: request.attempt,
          rootCommandId: request.rootCommandId,
        );
      };
      _track(h, 'c1');
      h.ledger.suspend('c1');
      await h.ledger.reconcile();

      expect(h.ledger.entry('c1'), isNull, reason: 'record superseded root');
      expect(h.ledger.entry('resend-1'), isNotNull);
      h.ledger.settleFromAck('resend-1', {'status': 'accepted'});
      await _flush();
      expect(h.events, hasLength(1));
      expect(h.events.single.rootCommandId, 'c1');
      expect(h.events.single.settlement, CommandLedgerSettlement.delivered);
      expect(
        h.events.where((e) => e.settlement == CommandLedgerSettlement.timedOut),
        isEmpty,
      );
    });

    test('attempt bound: stale on the last allowed attempt settles failed '
        'without another resend', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(
        addresses,
        decisions: const {
          'c1': {'commandId': 'c1', 'status': 'stale', 'revisionAtDecision': 9},
        },
      );
      _track(h, 'c1', attempt: 1);
      h.ledger.suspend('c1');
      await h.ledger.reconcile();
      await _flush();
      expect(h.resends, isEmpty);
      expect(h.ledger.entry('c1'), isNull);
      expect(h.events.single.settlement, CommandLedgerSettlement.failed);
    });
  });

  group('unknown bucket (second confirmation, then one resend)', () {
    test('first unknown schedules the confirm; a second unknown re-sends once', () async {
      final h = _Harness(secondConfirmDelay: const Duration(milliseconds: 25));
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(addresses);
      _track(h, 'c1');
      h.ledger.suspend('c1');
      await h.ledger.reconcile();
      expect(h.resends, isEmpty);
      expect(h.ledger.entry('c1')!.confirmScheduled, isTrue);
      expect(h.ledger.entry('c1')!.confirmed, isFalse);

      await _waitFor(() => h.resends.isNotEmpty);
      expect(h.queries, hasLength(2));
      final request = h.resends.single;
      expect(request.attempt, 1);
      expect(request.seedRevision, isNull, reason: 'unknown re-entry must '
          're-read baseRevision through sendCommand');
      expect(request.reconcile, isTrue);
    });

    test('unknown then accepted on the confirmation settles delivered, '
        'no resend', () async {
      final h = _Harness(secondConfirmDelay: const Duration(milliseconds: 25));
      addTearDown(h.dispose);
      var calls = 0;
      h.onQuery = (addresses) async {
        calls++;
        if (calls == 1) return _outcome(addresses);
        return _outcome(addresses, decisions: const {
          'c1': {'commandId': 'c1', 'status': 'accepted'},
        });
      };
      _track(h, 'c1');
      h.ledger.suspend('c1');
      await h.ledger.reconcile();
      expect(h.resends, isEmpty);

      await _waitFor(() => h.events.isNotEmpty);
      expect(h.resends, isEmpty);
      expect(h.events.single.settlement, CommandLedgerSettlement.delivered);
      expect(h.ledger.entry('c1'), isNull);
    });

    test('unknown past the TTL settles with the existing timeout semantics '
        'without querying', () async {
      var now = DateTime(2026, 1, 1);
      final h = _Harness(now: () => now);
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(addresses);
      _track(h, 'c1');
      now = now.add(const Duration(minutes: 3));
      h.ledger.suspend('c1');
      await h.ledger.reconcile();
      await _flush();
      expect(h.queries, isEmpty);
      expect(h.resends, isEmpty);
      expect(h.events.single.settlement, CommandLedgerSettlement.timedOut);
    });

    test('attempt bound: unknown + confirmation + unknown settles timedOut, '
        'no resend loop', () async {
      final h = _Harness(secondConfirmDelay: const Duration(milliseconds: 20));
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(addresses);
      _track(h, 'c1', attempt: 1);
      h.ledger.suspend('c1');
      await h.ledger.reconcile();
      await _waitFor(() => h.events.isNotEmpty);
      expect(h.resends, isEmpty);
      expect(h.events.single.settlement, CommandLedgerSettlement.timedOut);
      expect(h.ledger.entry('c1'), isNull);
    });

    test('a confirmation query failure is a query-side retry, not a verdict', () async {
      final h = _Harness(
        secondConfirmDelay: const Duration(milliseconds: 20),
        queryRetryDelays: const [
          Duration(milliseconds: 30),
          Duration(milliseconds: 30),
        ],
      );
      addTearDown(h.dispose);
      var calls = 0;
      h.onQuery = (addresses) async {
        calls++;
        if (calls == 1) return _outcome(addresses);
        throw ChannelRpcError('relay wrapped failure', null);
      };
      _track(h, 'c1');
      h.ledger.suspend('c1');
      await h.ledger.reconcile();
      await _waitFor(() => h.queries.length >= 3);
      expect(h.resends, isEmpty);
      expect(h.events, isEmpty);
      expect(h.ledger.entry('c1')!.state, CommandLedgerState.suspended);
    });
  });

  group('query-side failure', () {
    test('missing results never decide; the round backs off and retries', () async {
      final h = _Harness(
        queryRetryDelays: const [Duration(milliseconds: 25)],
      );
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(addresses, omit: const {'c1'});
      _track(h, 'c1');
      h.ledger.suspend('c1');
      await h.ledger.reconcile();
      expect(h.queries, hasLength(1));
      expect(h.events, isEmpty);
      expect(h.ledger.entry('c1')!.state, CommandLedgerState.suspended);
      await _waitFor(() => h.queries.length == 2);
      expect(h.events, isEmpty);
    });
  });

  group('TTL', () {
    test('only suspended items expire; inflight stays and emits nothing', () async {
      final h = _Harness(ttl: const Duration(milliseconds: 70));
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(addresses);
      _track(h, 'inflight');
      _track(h, 'suspended');
      h.ledger.suspend('suspended');
      await h.ledger.reconcile();
      await _waitFor(
        () => h.events.isNotEmpty,
        timeout: const Duration(seconds: 2),
      );
      expect(h.events.single.commandId, 'suspended');
      expect(h.events.single.settlement, CommandLedgerSettlement.timedOut);
      expect(h.ledger.entry('suspended'), isNull);
      expect(h.ledger.entry('inflight'), isNotNull,
          reason: 'TTL only scans suspended items');
    });

    test('switchModelConfig TTL is recorded but never emitted', () async {
      final h = _Harness(ttl: const Duration(milliseconds: 50));
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(addresses);
      _track(h, 'sw', kind: 'switchModelConfig');
      h.ledger.suspend('sw');
      await h.ledger.reconcile();
      await _waitFor(
        () => h.ledger.entry('sw') == null,
        timeout: const Duration(seconds: 2),
      );
      await _flush();
      expect(h.events, isEmpty);
    });
  });

  group('degraded gate', () {
    test('tightened unknown-method detection: method name required', () {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(
        isQueryMethodMissingError(
          ChannelRpcError('Method not found: queryConversationCommandsV4', null),
        ),
        isTrue,
      );
      expect(
        isQueryMethodMissingError(
          ChannelRpcError(
            'Method not found: zcode-agent.queryConversationCommandsV4',
            null,
          ),
        ),
        isTrue,
      );
      expect(
        isQueryMethodMissingError(
          ChannelRpcError('Method not found: someOtherMethod', null),
        ),
        isFalse,
      );
      expect(
        isQueryMethodMissingError(
          ChannelRpcError('not found: queryConversationCommandsV4', null),
        ),
        isFalse,
        reason: 'a bare not found must not disable the ledger',
      );
      expect(
        isQueryMethodMissingError(
          ChannelRpcError('unknown method queryConversationCommandsV4', null),
        ),
        isFalse,
      );
      expect(
        isQueryMethodMissingError(
          ChannelRpcError('permission denied: queryConversationCommandsV4', null),
        ),
        isFalse,
      );
    });

    test('unknown-method closes the gate; transient errors do not', () {
      final transient = _Harness();
      addTearDown(transient.dispose);
      expect(
        transient.ledger.noteQueryFailure(
          ChannelRpcError('Channel name timed out', null),
        ),
        isFalse,
      );
      expect(transient.ledger.ledgerDisabled, isFalse);
      expect(transient.ledger.canSuspend, isTrue);

      final missing = _Harness();
      addTearDown(missing.dispose);
      expect(
        missing.ledger.noteQueryFailure(
          ChannelRpcError('Method not found: queryConversationCommandsV4', null),
        ),
        isTrue,
      );
      expect(missing.ledger.ledgerDisabled, isTrue);
      expect(missing.ledger.canSuspend, isFalse);
    });

    test('deterministic refusal breaker: two consecutive hits, success resets', () {
      final h = _Harness();
      addTearDown(h.dispose);
      final refusal = ChannelRpcError(
        'fault.command.queryConnectionUntrusted',
        null,
      );
      expect(h.ledger.noteQueryFailure(refusal), isFalse);
      expect(h.ledger.ledgerDisabled, isFalse);

      h.ledger.noteQuerySuccess();
      expect(h.ledger.noteQueryFailure(refusal), isFalse,
          reason: 'success reset the consecutive count');
      expect(h.ledger.noteQueryFailure(refusal), isTrue);
      expect(h.ledger.ledgerDisabled, isTrue);
      h.ledger.noteQuerySuccess();
      expect(h.ledger.ledgerDisabled, isTrue,
          reason: 'the gate is transport-lifetime once closed');
    });

    test('gate close hands every suspended item off with reconcile:false, '
        'at most two in flight, without querying again', () async {
      final h = _Harness(ttl: const Duration(milliseconds: 300));
      addTearDown(h.dispose);
      h.onQuery = (addresses) async =>
          throw ChannelRpcError('relay wrapped failure', null);
      for (final id in ['a', 'b', 'c']) {
        _track(h, id);
        h.ledger.suspend(id);
      }
      await h.ledger.reconcile();
      final queriesBefore = h.queries.length;
      var active = 0;
      var maxActive = 0;
      h.onResend = (request) async {
        active++;
        maxActive = maxActive < active ? active : maxActive;
        await Future<void>.delayed(const Duration(milliseconds: 15));
        active--;
      };
      final refusal = ChannelRpcError(
        'fault.command.queryForeignWorkspace',
        null,
      );
      h.ledger.noteQueryFailure(refusal);
      expect(h.ledger.noteQueryFailure(refusal), isTrue);
      await h.ledger.handOffSuspended();

      expect(h.ledger.ledgerDisabled, isTrue);
      expect(h.ledger.entries, isEmpty);
      expect(h.resends, hasLength(3));
      expect(h.resends.every((r) => r.reconcile == false), isTrue);
      expect(h.resends.every((r) => r.attempt == 0), isTrue);
      expect(h.resends.every((r) => r.seedRevision == null), isTrue);
      expect(maxActive, lessThanOrEqualTo(2));
      expect(h.queries.length, queriesBefore,
          reason: 'the gate-close path never queries again');
      await _flush();
      expect(h.events, isEmpty);
      // Past the TTL: the handed-off originals are gone, so no false
      // timeout event can land (the handoff did not wait for TTL).
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(h.events, isEmpty);
    });

    test('handoff of CAS commands carries no ledger seed and never loops '
        '(sendCommand owns the stale retry)', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(addresses);
      _track(h, 'queued', kind: 'sendQueuedNow');
      _track(h, 'switch', kind: 'switchModelConfig');
      h.ledger.suspend('queued');
      h.ledger.suspend('switch');
      await h.ledger.reconcile();
      final refusal = ChannelRpcError(
        'fault.command.queryConnectionUntrusted',
        null,
      );
      h.ledger.noteQueryFailure(refusal);
      h.ledger.noteQueryFailure(refusal);
      await h.ledger.handOffSuspended();

      expect(h.resends.map((r) => r.kind).toSet(), {
        'sendQueuedNow',
        'switchModelConfig',
      });
      expect(h.resends.every((r) => r.seedRevision == null), isTrue,
          reason: 'sendCommand refetches the CAS revision on re-entry');
      expect(h.resends, hasLength(2));
      expect(h.ledger.entries, isEmpty);
    });
  });

  group('switchModelConfig outcome ownership', () {
    test('query-side delivered and timedOut produce no ledger event', () async {
      final h = _Harness(ttl: const Duration(milliseconds: 40));
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(
        addresses,
        decisions: const {
          'sw': {'commandId': 'sw', 'status': 'accepted'},
        },
      );
      _track(h, 'sw', kind: 'switchModelConfig');
      h.ledger.suspend('sw');
      await h.ledger.reconcile();
      await _flush();
      expect(h.ledger.entry('sw'), isNull);
      expect(h.events.where((e) => e.kind == 'switchModelConfig'), isEmpty);
    });
  });

  group('R7 preflight + sessionNotFound recovery', () {
    test('a resend preflight failure keeps the item suspended, backs off and '
        'never emits a terminal outcome', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.onQuery = (addresses) async => _outcome(
        addresses,
        decisions: const {
          'c1': {
            'commandId': 'c1',
            'status': 'stale',
            'reasonCode': 'proto.staleRevision',
            'revisionAtDecision': 3,
          },
        },
      );
      h.onResend = (_) async =>
          throw const CommandPreflightException('session not live');
      _track(h, 'c1');

      h.ledger.suspend('c1');
      await h.ledger.reconcile();
      expect(h.resends, hasLength(1));
      expect(h.ledger.entry('c1')?.state, CommandLedgerState.suspended);
      expect(h.events, isEmpty,
          reason: 'a preflight failure is not a command verdict');

      // The harness schedule is 30 ms then 60 ms: at least one backoff round
      // runs, still without a terminal outcome.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(h.resends.length, greaterThanOrEqualTo(2));
      expect(h.ledger.entry('c1')?.state, CommandLedgerState.suspended);
      expect(h.events, isEmpty);
    });

    test('recoverable sessionNotFound keeps the chain suspended for one '
        'preflight+resend cycle; the second hit is terminal', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.onResend = (_) async {}; // the host preflight + send round
      _track(h, 'c1');

      expect(
        h.ledger.recoverableSessionNotFound('c1', {
          'status': 'rejected',
          'reasonCode': commandSessionNotFoundReasonCode,
          'message': 'Session is not active: s1',
        }),
        isTrue,
      );
      final entry = h.ledger.entry('c1')!;
      expect(entry.state, CommandLedgerState.suspended);
      expect(entry.notFoundRetries, 1);
      expect(h.events, isEmpty,
          reason: 'a pre-execution refusal is recoverable, not terminal');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(h.resends, hasLength(1),
          reason: 'the retry is a fresh preflight+resend cycle');

      expect(
        h.ledger.recoverableSessionNotFound('c1', {
          'status': 'rejected',
          'reasonCode': commandSessionNotFoundReasonCode,
        }),
        isFalse,
      );
      await _flush();
      expect(h.events.single.settlement, CommandLedgerSettlement.rejected);
      expect(h.events.single.commandId, 'c1');
    });

    test('a retry timer colliding with an in-flight resend does not send '
        'twice; the next retry round still runs', () async {
      final h = _Harness(
        queryRetryDelays: const [
          Duration(milliseconds: 100),
          Duration(milliseconds: 100),
        ],
      );
      addTearDown(h.dispose);
      var calls = 0;
      Completer<void>? inFlight;
      h.onQuery = (addresses) async => _outcome(
        addresses,
        decisions: const {
          'c1': {
            'commandId': 'c1',
            'status': 'stale',
            'reasonCode': 'proto.staleRevision',
            'revisionAtDecision': 1,
          },
        },
      );
      h.onResend = (_) async {
        calls++;
        if (calls == 1) {
          throw const CommandPreflightException('preflight failed');
        }
        if (calls == 2) {
          inFlight = Completer<void>();
          await inFlight!.future;
          throw const CommandPreflightException('still not live');
        }
      };
      _track(h, 'c1');

      h.ledger.suspend('c1');
      await h.ledger.reconcile(); // call 1 → retry armed at 100 ms
      expect(calls, 1);

      // A second reconcile starts a resend that stays in flight across the
      // scheduled retry deadline.
      final second = h.ledger.reconcile();
      await _waitFor(() => calls == 2);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(calls, 2,
          reason: 'a retry must not duplicate a resend already on the wire');

      // The in-flight round's own preflight failure arms the next retry; it
      // must still run (the guard skips one round, it cancels nothing).
      inFlight!.complete();
      await second;
      await _waitFor(() => calls == 3);
      expect(h.ledger.entry('c1')?.state, CommandLedgerState.suspended);
      expect(h.events, isEmpty);
    });
  });

  group('ledger teardown (R7)', () {
    test('dispose with a suspended entry cancels the TTL/retry timers and '
        'closes the outcome stream', () async {
      final h = _Harness(ttl: const Duration(milliseconds: 120));
      addTearDown(h.dispose);
      _track(h, 'c1');
      expect(
        h.ledger.recoverableSessionNotFound('c1', {
          'status': 'rejected',
          'reasonCode': commandSessionNotFoundReasonCode,
        }),
        isTrue,
      );
      final entry = h.ledger.entry('c1')!;
      expect(entry.state, CommandLedgerState.suspended);
      expect(entry.retryScheduled, isTrue,
          reason: 'precondition: a retry and a TTL timer are both armed');

      final closed = Completer<void>();
      final sub = h.ledger.outcomes.listen(null, onDone: closed.complete);
      await h.ledger.dispose();
      await closed.future.timeout(const Duration(seconds: 1));
      await sub.cancel();
      expect(h.ledger.entries, isEmpty);

      // Both deadlines pass: a leaked timer would record a resend (30 ms) or
      // emit a timedOut outcome (120 ms).
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(h.resends, isEmpty);
      expect(h.events, isEmpty);
    });
  });
}

/// Harness: injects the query/resend seams and collects every observable.
class _Harness {
  _Harness({
    Duration ttl = const Duration(minutes: 2),
    Duration secondConfirmDelay = const Duration(milliseconds: 25),
    List<Duration> queryRetryDelays = const [
      Duration(milliseconds: 30),
      Duration(milliseconds: 60),
    ],
    int maxAttempts = 1,
    DateTime Function()? now,
  }) {
    ledger = CommandLedger(
      query: _query,
      resend: _resend,
      ttl: ttl,
      secondConfirmDelay: secondConfirmDelay,
      queryRetryDelays: queryRetryDelays,
      maxAttempts: maxAttempts,
      now: now,
      onLog: logs.add,
    );
    _eventsSub = ledger.outcomes.listen(events.add);
  }

  late final CommandLedger ledger;
  final queries = <List<CommandAddress>>[];
  final resends = <CommandResendRequest>[];
  final events = <CommandLedgerOutcome>[];
  final logs = <String>[];
  late final StreamSubscription<CommandLedgerOutcome> _eventsSub;
  Future<CommandQueryOutcome> Function(List<CommandAddress>)? onQuery;
  Future<void> Function(CommandResendRequest)? onResend;

  Future<CommandQueryOutcome> _query(List<CommandAddress> addresses) async {
    queries.add(List<CommandAddress>.of(addresses));
    final handler = onQuery;
    if (handler == null) return CommandQueryOutcome.empty();
    return handler(addresses);
  }

  Future<void> _resend(CommandResendRequest request) async {
    resends.add(request);
    await onResend?.call(request);
  }

  Future<void> dispose() async {
    await _eventsSub.cancel();
    await ledger.dispose();
  }
}

void _track(
  _Harness h,
  String commandId, {
  String sessionId = 's1',
  String kind = 'sendText',
  int attempt = 0,
  String? root,
}) {
  h.ledger.record(
    commandId: commandId,
    sessionId: sessionId,
    kind: kind,
    semanticPayload: {'text': commandId},
    channelExtra: {'extra': commandId},
    attempt: attempt,
    rootCommandId: root,
  );
}

/// Builds a parse-level outcome for [addresses]. [decisions] carries raw
/// decision objects; every address without one answers the `"unknown"`
/// sentinel; [omit] leaves the address out of `results` (partial response).
CommandQueryOutcome _outcome(
  List<CommandAddress> addresses, {
  Map<String, Object?> decisions = const {},
  Set<String> omit = const {},
}) {
  final results = <Map<String, dynamic>>[];
  for (final address in addresses) {
    if (omit.contains(address.commandId)) continue;
    final result = decisions.containsKey(address.commandId)
        ? decisions[address.commandId]
        : 'unknown';
    results.add({
      'key': {
        'sessionId': address.sessionId,
        'commandId': address.commandId,
      },
      'result': result,
    });
  }
  return CommandQueryOutcome.parse({'results': results}, addresses);
}

Future<void> _flush() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'timed out waiting for condition');
}