// Query-side contract tests for task 11-13-command-reconcile (AC2):
// single-leg payload assembly, >64 batching, key-based matching, every
// decision status, "unknown", queryUnavailable, turn/clock passthrough,
// partial results and malformed input.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation_command_query.dart';
import 'package:zgo/protocol/conversation_transport.dart';
import 'package:zgo/protocol/ipc_codec.dart';
import 'package:zgo/protocol/remote_client.dart';

void main() {
  group('commandQueryBatches', () {
    test('empty input produces no calls', () {
      expect(commandQueryBatches(const []), isEmpty);
    });

    test('64 stays one batch; 65 splits 64+1; 129 splits 64+64+1', () {
      List<CommandAddress> addresses(int n) => [
        for (var i = 0; i < n; i++) CommandAddress(sessionId: 's', commandId: 'c$i'),
      ];

      expect(commandQueryBatches(addresses(64)), hasLength(1));
      final split65 = commandQueryBatches(addresses(65));
      expect(split65.map((b) => b.length), [64, 1]);
      final split129 = commandQueryBatches(addresses(129));
      expect(split129.map((b) => b.length), [64, 64, 1]);
      // Order is preserved across chunking.
      expect(split129.expand((b) => b).map((a) => a.commandId).first, 'c0');
      expect(split129.expand((b) => b).map((a) => a.commandId).last, 'c128');
    });
  });

  group('commandQueryPayload', () {
    test('single-leg shape with scope merged; no null-leg duplication', () {
      final payload = commandQueryPayload(
        {'workspacePath': '/repo', 'workspaceIdentity': 'id-1'},
        const [
          CommandAddress(sessionId: 's1', commandId: 'c1'),
          CommandAddress(sessionId: 's2', commandId: 'c2'),
        ],
      );
      expect(payload['workspacePath'], '/repo');
      expect(payload['workspaceIdentity'], 'id-1');
      final commands = payload['commands'] as List;
      expect(commands, hasLength(2));
      expect(commands[0], {'sessionId': 's1', 'commandId': 'c1'});
      expect(commands[1], {'sessionId': 's2', 'commandId': 'c2'});
      // Exactly one leg per address: no synthetic {sessionId:null} sibling.
      expect(
        commands.where((c) => (c as Map)['sessionId'] == null),
        isEmpty,
      );
    });

    test('a null-session address is carried verbatim when requested', () {
      final payload = commandQueryPayload(
        {'workspacePath': '/repo'},
        const [CommandAddress(commandId: 'clock-1')],
      );
      expect((payload['commands'] as List).single, {
        'sessionId': null,
        'commandId': 'clock-1',
      });
    });
  });

  group('CommandQueryOutcome.parse', () {
    const address = CommandAddress(sessionId: 's1', commandId: 'c1');

    Map<String, dynamic> responseWith(Object? result, {Object? turn}) => {
      'results': [
        {
          'key': {'sessionId': 's1', 'commandId': 'c1'},
          'result': result,
          if (turn != null) 'turn': turn,
        },
      ],
    };

    test('accepted decision keeps the raw map (extra command-specific '
        'fields survive)', () {
      final outcome = CommandQueryOutcome.parse(
        responseWith({
          'commandId': 'c1',
          'status': 'accepted',
          'revisionAtDecision': 1702,
          'memoryEnabled': true,
          'commandSpecific': {'nested': 1},
        }),
        const [address],
      );
      final entry = outcome.entryFor(sessionId: 's1', commandId: 'c1')!;
      expect(entry.unknown, isFalse);
      expect(entry.querySideFailure, isFalse);
      final decision = entry.decision!;
      expect(decision.status, CommandDecisionStatus.accepted);
      expect(decision.isDelivered, isTrue);
      expect(decision.revisionAtDecision, 1702);
      expect(decision.commandId, 'c1');
      // Raw passthrough: unknown/command-specific fields must not be lost.
      expect(decision.raw['memoryEnabled'], isTrue);
      expect(decision.raw['commandSpecific'], {'nested': 1});
    });

    test('matching is by key, not result-array position', () {
      final outcome = CommandQueryOutcome.parse({
        'results': [
          {
            'key': {'sessionId': 's2', 'commandId': 'c2'},
            'result': {'commandId': 'c2', 'status': 'noop'},
          },
          {
            'key': {'sessionId': 's1', 'commandId': 'c1'},
            'result': {'commandId': 'c1', 'status': 'accepted'},
          },
        ],
      }, const [
        CommandAddress(sessionId: 's1', commandId: 'c1'),
        CommandAddress(sessionId: 's2', commandId: 'c2'),
      ]);
      expect(
        outcome.entryFor(sessionId: 's1', commandId: 'c1')!.decision!.status,
        CommandDecisionStatus.accepted,
      );
      expect(
        outcome.entryFor(sessionId: 's2', commandId: 'c2')!.decision!.status,
        CommandDecisionStatus.noop,
      );
    });

    test('duplicate and noop both count as delivered', () {
      for (final status in ['duplicate', 'noop']) {
        final outcome = CommandQueryOutcome.parse(
          responseWith({'commandId': 'c1', 'status': status}),
          const [address],
        );
        final decision = outcome
            .entryFor(sessionId: 's1', commandId: 'c1')!
            .decision!;
        expect(decision.wireStatus, status);
        expect(decision.isDelivered, isTrue);
      }
    });

    test('stale carries revisionAtDecision; rejected carries reasonCode and '
        'message', () {
      final stale = CommandQueryOutcome.parse(
        responseWith({
          'commandId': 'c1',
          'status': 'stale',
          'reasonCode': 'proto.staleRevision',
          'revisionAtDecision': 42,
        }),
        const [address],
      ).entryFor(sessionId: 's1', commandId: 'c1')!.decision!;
      expect(stale.status, CommandDecisionStatus.stale);
      expect(stale.reasonCode, 'proto.staleRevision');
      expect(stale.revisionAtDecision, 42);
      expect(stale.isDelivered, isFalse);

      final rejected = CommandQueryOutcome.parse(
        responseWith({
          'commandId': 'c1',
          'status': 'rejected',
          'reasonCode': 'proto.guard',
          'message': 'no',
        }),
        const [address],
      ).entryFor(sessionId: 's1', commandId: 'c1')!.decision!;
      expect(rejected.status, CommandDecisionStatus.rejected);
      expect(rejected.reasonCode, 'proto.guard');
      expect(rejected.message, 'no');
    });

    test('failed + queryUnavailable is a QUERY-side failure, not a command '
        'verdict', () {
      final outcome = CommandQueryOutcome.parse(
        responseWith({
          'commandId': 'c1',
          'status': 'failed',
          'reasonCode': 'fault.command.queryUnavailable',
        }),
        const [address],
      );
      final entry = outcome.entryFor(sessionId: 's1', commandId: 'c1')!;
      expect(entry.decision!.isQueryUnavailable, isTrue);
      expect(entry.querySideFailure, isTrue);
      expect(entry.resolved, isFalse);
    });

    test('failed with another reasonCode is a terminal command outcome', () {
      final entry = CommandQueryOutcome.parse(
        responseWith({
          'commandId': 'c1',
          'status': 'failed',
          'reasonCode': 'proto.deliveryFailed',
        }),
        const [address],
      ).entryFor(sessionId: 's1', commandId: 'c1')!;
      expect(entry.querySideFailure, isFalse);
      expect(entry.decision!.status, CommandDecisionStatus.failed);
    });

    test('the exact string "unknown" is the sentinel; near-misses are '
        'malformed', () {
      final unknown = CommandQueryOutcome.parse(
        responseWith('unknown'),
        const [address],
      ).entryFor(sessionId: 's1', commandId: 'c1')!;
      expect(unknown.unknown, isTrue);
      expect(unknown.decision, isNull);
      expect(unknown.querySideFailure, isFalse);
      expect(unknown.resolved, isTrue);

      for (final nearMiss in ['Unknown', 'unknown ', 'UNKNOWN']) {
        final entry = CommandQueryOutcome.parse(
          responseWith(nearMiss),
          const [address],
        ).entryFor(sessionId: 's1', commandId: 'c1')!;
        expect(entry.unknown, isFalse);
        expect(entry.malformed, isTrue);
        expect(entry.querySideFailure, isTrue);
      }
    });

    test('turn and top-level clock pass through untouched', () {
      final outcome = CommandQueryOutcome.parse({
        'results': [
          {
            'key': {'sessionId': 's1', 'commandId': 'c1'},
            'result': {'commandId': 'c1', 'status': 'accepted'},
            'turn': {'turnId': 't1', 'index': 3},
          },
        ],
        'clock': {'serverTime': 123, 'latency': 45},
      }, const [address]);
      final entry = outcome.entryFor(sessionId: 's1', commandId: 'c1')!;
      expect(entry.turn, {'turnId': 't1', 'index': 3});
      expect(outcome.clock, {'serverTime': 123, 'latency': 45});
    });

    test('partial results: a requested address absent from results is a '
        'query-side failure', () {
      final outcome = CommandQueryOutcome.parse({
        'results': [
          {
            'key': {'sessionId': 's1', 'commandId': 'c1'},
            'result': {'commandId': 'c1', 'status': 'accepted'},
          },
        ],
      }, const [
        CommandAddress(sessionId: 's1', commandId: 'c1'),
        CommandAddress(sessionId: 's2', commandId: 'c2'),
      ]);
      final missing = outcome.entryFor(sessionId: 's2', commandId: 'c2')!;
      expect(missing.missing, isTrue);
      expect(missing.querySideFailure, isTrue);
      expect(outcome.partial, isTrue);
    });

    test('extra unrequested results are ignored', () {
      final outcome = CommandQueryOutcome.parse({
        'results': [
          {
            'key': {'sessionId': 'other', 'commandId': 'x'},
            'result': 'unknown',
          },
        ],
      }, const [address]);
      expect(outcome.entryFor(sessionId: 's1', commandId: 'c1')!.missing,
          isTrue);
    });

    test('malformed envelopes never throw and always leave query-side '
        'failures', () {
      final cases = <Object?>[
        null,
        'not a map',
        <String, dynamic>{},
        {'results': 'not a list'},
        {'results': [1, 'x', null]},
        {'results': [<String, dynamic>{}]},
        {'results': [<String, dynamic>{'key': 'nope', 'result': 'unknown'}]},
        {
          'results': [
            {
              'key': {'sessionId': 's1'},
              'result': 'unknown',
            },
          ],
        },
        {
          'results': [
            {
              'key': {'sessionId': 's1', 'commandId': 'c1'},
              'result': {'commandId': 'c1', 'status': 'pending'},
            },
          ],
        },
      ];
      for (final raw in cases) {
        final outcome = CommandQueryOutcome.parse(raw, const [address]);
        final entry = outcome.entryFor(sessionId: 's1', commandId: 'c1')!;
        expect(entry.querySideFailure, isTrue, reason: 'raw=$raw');
        expect(entry.resolved, isFalse);
      }
    });

    test('a key with a different sessionId does not match the requested '
        'session leg', () {
      final outcome = CommandQueryOutcome.parse({
        'results': [
          {
            'key': {'sessionId': null, 'commandId': 'c1'},
            'result': {'commandId': 'c1', 'status': 'accepted'},
          },
        ],
      }, const [address]);
      expect(outcome.entryFor(sessionId: 's1', commandId: 'c1')!.missing,
          isTrue);
    });

    test('merge unions batches and keeps the first clock', () {
      final first = CommandQueryOutcome.parse({
        'results': [
          {
            'key': {'sessionId': 's1', 'commandId': 'c1'},
            'result': {'commandId': 'c1', 'status': 'accepted'},
          },
        ],
        'clock': {'a': 1},
      }, const [address]);
      final second = CommandQueryOutcome.parse({
        'results': [
          {
            'key': {'sessionId': 's2', 'commandId': 'c2'},
            'result': 'unknown',
          },
        ],
        'clock': {'b': 2},
      }, const [CommandAddress(sessionId: 's2', commandId: 'c2')]);
      final merged = CommandQueryOutcome.merge([first, second]);
      expect(merged.entries, hasLength(2));
      expect(
        merged.entryFor(sessionId: 's1', commandId: 'c1')!.decision!.isDelivered,
        isTrue,
      );
      expect(merged.entryFor(sessionId: 's2', commandId: 'c2')!.unknown, isTrue);
      expect(merged.clock, {'a': 1});
    });
  });

  group('ConversationTransport.queryCommands', () {
    test('handshake precedes the query; single-leg payload is exact', () async {
      final calls = <_Call>[];
      final transport = _transport((method, args) {
        if (method == 'helloConversationV4') {
          return {'connectionId': 'conn-1'};
        }
        if (method == 'initializeConversationV4') {
          return {};
        }
        final commands = ((args.single as Map)['commands'] as List)
            .cast<Map<String, dynamic>>();
        return {
          'results': [
            for (final command in commands)
              {
                'key': {
                  'sessionId': command['sessionId'],
                  'commandId': command['commandId'],
                },
                'result': 'unknown',
              },
          ],
        };
      }, calls);

      final outcome = await transport.queryCommands(const [
        CommandAddress(sessionId: 's1', commandId: 'c1'),
        CommandAddress(sessionId: 's2', commandId: 'c2'),
      ]);

      expect(calls.map((c) => c.method), [
        'helloConversationV4',
        'initializeConversationV4',
        'queryConversationCommandsV4',
      ]);
      final query = calls.last;
      expect(query.channel, 'zcode-agent');
      final payload = query.args.single as Map;
      expect(payload['workspacePath'], '/repo');
      final commands = (payload['commands'] as List).cast<Map>();
      expect(commands, hasLength(2));
      expect(commands[0].keys.toSet(), {'sessionId', 'commandId'});
      expect(commands[0]['sessionId'], 's1');
      expect(commands[0]['commandId'], 'c1');
      // One leg per address: no sessionId:null siblings.
      expect(commands.where((c) => c['sessionId'] == null), isEmpty);
      expect(outcome.values.every((e) => e.unknown), isTrue);
    });

    test('65 addresses split into 64+1 calls and merge by address', () async {
      final calls = <_Call>[];
      var queryCalls = 0;
      final transport = _transport((method, args) {
        if (method == 'helloConversationV4') return {'connectionId': 'x'};
        if (method == 'initializeConversationV4') return {};
        queryCalls++;
        final commands = ((args.single as Map)['commands'] as List)
            .cast<Map<String, dynamic>>();
        return {
          'results': [
            for (final command in commands)
              {
                'key': {
                  'sessionId': command['sessionId'],
                  'commandId': command['commandId'],
                },
                'result': {'commandId': command['commandId'], 'status': 'accepted'},
              },
          ],
        };
      }, calls);

      final addresses = [
        for (var i = 0; i < 65; i++)
          CommandAddress(sessionId: 's$i', commandId: 'c$i'),
      ];
      final outcome = await transport.queryCommands(addresses);

      expect(queryCalls, 2);
      expect((calls.last.args.single as Map)['commands'], hasLength(1));
      expect(outcome.entries, hasLength(65));
      for (final address in addresses) {
        expect(
          outcome.entryFor(
            sessionId: address.sessionId,
            commandId: address.commandId,
          )!.decision!.isDelivered,
          isTrue,
          reason: '$address missing from merged outcome',
        );
      }
    });

    test('empty input never handshakes and never queries', () async {
      final calls = <_Call>[];
      final transport = _transport((method, args) => fail('no RPC expected'),
          calls);
      final outcome = await transport.queryCommands(const []);
      expect(calls, isEmpty);
      expect(outcome.entries, isEmpty);
    });
  });
}

class _Call {
  _Call(this.channel, this.method, this.args);

  final String channel;
  final String method;
  final List<Object?> args;
}

ConversationTransport _transport(
  Object? Function(String method, List<Object?> args) respond,
  List<_Call> calls,
) {
  final client = _respondingChannelClient((channel, method, args) {
    calls.add(_Call(channel, method, args));
    return respond(method, args);
  });
  return ConversationTransport(
    session: _FakeBridgeSession(client),
    scope: {'workspacePath': '/repo'},
  );
}

/// Channel client that resolves every `call` synchronously out of [respond].
ChannelClient _respondingChannelClient(
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

/// Bridge stand-in for transport-level RPC tests (same shape as the one in
/// conversation_test.dart): only the members the transport constructor and
/// send gate touch are real.
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