import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/channel_client.dart';
import 'package:zlinker/protocol/off_peak.dart';

class FakeChannel {
  final calls = <(String, List<Object?>)>[];
  final dynamic Function(String method, List<Object?> args) responder;

  FakeChannel(this.responder);

  Future<dynamic> call(String method, List<Object?> args) {
    calls.add((method, args));
    return Future.sync(() => responder(method, args));
  }
}

ChannelRpcError missing(String method) =>
    ChannelRpcError('no such method: $method', null);

void main() {
  group('OffPeakPort.list', () {
    test('parses a plain list and tolerates status spellings', () async {
      final fake = FakeChannel((m, _) => [
            {
              'offPeakTaskId': 't1',
              'prompt': '跑测试',
              'status': 'waitingQueue',
              'queuePosition': 3,
            },
            {
              'offPeakTaskId': 't2',
              'prompt': 'p',
              'status': 'succeeded',
              'sessionId': 's-2'
            },
            {
              'offPeakTaskId': 't3',
              'prompt': 'p',
              'state': 'error',
              'error': 'boom'
            },
          ]);
      final port = OffPeakPort(fake.call, newWire: false);

      final tasks = await port.list();

      expect(fake.calls.first.$1, 'list');
      expect(tasks, hasLength(3));
      expect(tasks[0].queued, isTrue);
      expect(tasks[0].queuePosition, 3);
      expect(tasks[1].completed, isTrue);
      expect(tasks[1].sessionId, 's-2');
      expect(tasks[2].failed, isTrue);
      expect(tasks[2].error, 'boom');
    });

    test('unwraps {tasks: [...]} and tolerates id/taskId spellings', () async {
      final fake = FakeChannel((m, _) => {
            'tasks': [
              {'taskId': 'x', 'prompt': 'p', 'status': 'running'},
            ],
          });
      final port = OffPeakPort(fake.call, newWire: false);

      final tasks = await port.list();

      expect(tasks.single.id, 'x');
      expect(tasks.single.running, isTrue);
    });
  });

  group('OffPeakPort.submit', () {
    test('sends the documented off-peak-run shape', () async {
      final fake = FakeChannel((m, _) => {'ok': true, 'sessionId': 's-9'});
      final port = OffPeakPort(fake.call, newWire: false);

      final res = await port.submit(OffPeakSubmitInput(
        prompt: ' 修复 flaky 测试 ',
        workspacePath: '/repo',
        workspaceIdentity: 'repo-identity',
        permissionMode: 'yolo',
        model: 'glm-5.2',
      ));

      expect(fake.calls.single.$1, 'run');
      final wire = fake.calls.single.$2.single as Map<String, dynamic>;
      expect(wire['prompt'], '修复 flaky 测试');
      expect(wire['workspacePath'], '/repo');
      expect(wire['workspaceIdentity'], 'repo-identity');
      expect(wire['permissionMode'], 'yolo');
      expect(wire['model'], 'glm-5.2');
      expect(wire['offPeakTaskId'], isNotEmpty);
      // Optional empty fields stay off the wire.
      expect(wire.containsKey('thoughtLevel'), isFalse);
      expect(wire.containsKey('earliestAvailableAt'), isFalse);
      expect(res.ok, isTrue);
      expect(res.sessionId, 's-9');
    });

    test('empty workspaceIdentity is omitted', () async {
      final fake = FakeChannel((m, _) => null);
      final port = OffPeakPort(fake.call, newWire: false);

      await port.submit(OffPeakSubmitInput(
          prompt: 'p', workspacePath: '/w', workspaceIdentity: ''));

      final wire = fake.calls.single.$2.single as Map<String, dynamic>;
      expect(wire.containsKey('workspaceIdentity'), isFalse);
    });

    test('classifies codingPlanOnly failures', () async {
      final fake =
          FakeChannel((m, _) => throw ChannelRpcError('codingPlanOnly', null));
      final port = OffPeakPort(fake.call, newWire: false);

      await expectLater(
        port.submit(OffPeakSubmitInput(prompt: 'p', workspacePath: '/w')),
        throwsA(isA<OffPeakError>()
            .having((e) => e.kind, 'kind', OffPeakError.codingPlanOnly)),
      );
    });

    test('classifies quota failures', () async {
      final fake = FakeChannel(
          (m, _) => throw ChannelRpcError('monthly quota exceeded', null));
      final port = OffPeakPort(fake.call, newWire: false);

      await expectLater(
        port.submit(OffPeakSubmitInput(prompt: 'p', workspacePath: '/w')),
        throwsA(isA<OffPeakError>()
            .having((e) => e.kind, 'kind', OffPeakError.quota)),
      );
    });

    test('feature-absent desktops classify as unavailable', () async {
      final fake = FakeChannel((m, _) => throw missing(m));
      final port = OffPeakPort(fake.call, newWire: false);

      await expectLater(
        port.submit(OffPeakSubmitInput(prompt: 'p', workspacePath: '/w')),
        throwsA(isA<OffPeakError>()
            .having((e) => e.kind, 'kind', OffPeakError.unavailable)),
      );
    });
  });

  group('OffPeakPort lifecycle + status', () {
    test('pause/resume/cancel hit the lifecycle methods with task ids',
        () async {
      final fake = FakeChannel((m, _) => null);
      final port = OffPeakPort(fake.call, newWire: false);

      await port.pause('t1');
      await port.resume('t1');
      await port.cancel('t2');
      await port.remove('t3');

      final methods = fake.calls.map((c) => c.$1).toList();
      expect(methods, ['pause', 'resume', 'cancel', 'delete']);
      expect(fake.calls[0].$2, [
        {'offPeakTaskId': 't1'}
      ]);
      expect(fake.calls[2].$2, [
        {'offPeakTaskId': 't2'}
      ]);
    });

    test('status parses quota minutes + earliest window; null when absent',
        () async {
      final fake = FakeChannel((m, _) => {
            'available': true,
            'quotaRemainingMinutes': 300,
            'quotaTotalMinutes': 600,
            'earliestAvailableAt': 1724400000000,
          });
      final port = OffPeakPort(fake.call, newWire: false);

      final status = await port.status();
      expect(status!.entitled, isTrue);
      expect(status.quotaRemainingMinutes, 300);
      expect(status.quotaTotalMinutes, 600);
      expect(status.earliestAvailableAt, 1724400000000);

      final old = FakeChannel((m, _) => throw missing(m));
      expect(await OffPeakPort(old.call, newWire: false).status(), isNull);
    });

    test('wake never throws', () async {
      final fake = FakeChannel((m, _) => throw missing(m));
      final port = OffPeakPort(fake.call, newWire: false);
      await port.wake(); // must not throw
    });
  });

  group('OffPeakRunResult', () {
    test('error field downgrades ok', () {
      final res = OffPeakRunResult.from(const {
        'ok': true,
        'error': 'quota',
        'sessionId': 's',
      });
      expect(res.ok, isFalse);
      expect(res.error, 'quota');
      expect(res.sessionId, 's');
    });

    test('echo fills session/conversation ids on void acks', () {
      final res = OffPeakRunResult.from(const {},
          echo: {'sessionId': 'e-s', 'conversationId': 'e-c'});
      expect(res.ok, isTrue); // no error field + no explicit ok → accepted
      expect(res.sessionId, 'e-s');
      expect(res.conversationId, 'e-c');
    });
  });

  group('OffPeakTask derived fields', () {
    test('durationMs from startedAt/finishedAt', () {
      final t = OffPeakTask({
        'startedAt': 1000000,
        'finishedAt': 1000000 + 90 * 60 * 1000,
      });
      expect(t.durationMs, 90 * 60 * 1000);
    });

    test('cancelled counts as terminal', () {
      expect(OffPeakTask({'status': 'cancelled'}).terminal, isTrue);
      expect(OffPeakTask({'status': 'running'}).terminal, isFalse);
    });
  });

  group('OffPeakPort new wire (3.12.3)', () {
    test('lifecycle sends positional [taskId], positional names first',
        () async {
      final fake = FakeChannel((m, _) => null);
      final port = OffPeakPort(fake.call, newWire: true);

      await port.pause('t1');
      await port.resume('t1');
      await port.cancel('t2');
      await port.remove('t3');
      await port.deleteHistory('t4');

      expect(fake.calls.map((c) => c.$1).toList(), [
        'pauseTask',
        'continueTask',
        'cancelTask',
        'deleteTask',
        'deleteHistory',
      ]);
      expect(fake.calls[0].$2, ['t1']);
      expect(fake.calls[2].$2, ['t2']);
      expect(fake.calls[4].$2, ['t4']);
    });

    test('lifecycle falls back to the legacy object form on a miss', () async {
      final fake =
          FakeChannel((m, _) => m == 'pauseTask' ? throw missing(m) : null);
      final port = OffPeakPort(fake.call, newWire: true);

      await port.pause('t1');

      expect(fake.calls.map((c) => c.$1).toList(), ['pauseTask', 'pause']);
      expect(fake.calls[1].$2, [
        {'offPeakTaskId': 't1'}
      ]);
    });

    test('lifecycle surfaces structured failures from normal acks', () async {
      final fake = FakeChannel((m, _) => {
            'ok': false,
            'failureStage': 'ticket_request',
            'errorCategory': 'eligibility_3101',
            'errorCode': 'E3101',
          });
      final port = OffPeakPort(fake.call, newWire: true);

      await expectLater(
        port.pause('t1'),
        throwsA(isA<OffPeakError>()
            .having((e) => e.kind, 'kind', OffPeakError.codingPlanOnly)),
      );
    });

    test(
        'update probes the positional (taskId, patch) form first and '
        'encodes modelSelection', () async {
      final fake = FakeChannel((m, _) => null);
      final port = OffPeakPort(fake.call, newWire: true);

      await port.update(
        't1',
        OffPeakUpdateInput(
          title: ' t ',
          prompt: ' p ',
          model: 'glm-5.2',
          provider: 'zai',
          thoughtLevel: 'high',
        ),
      );

      expect(fake.calls.single.$1, 'updateTask');
      expect(fake.calls.single.$2[0], 't1');
      final wire = fake.calls.single.$2[1] as Map<String, dynamic>;
      expect(wire['title'], 't');
      expect(wire['modelSelection'], {
        'providerId': 'zai',
        'modelId': 'glm-5.2',
        'options': {'reasoningLevel': 'high'},
      });
      // The flat model fields stay off the new wire.
      expect(wire.containsKey('model'), isFalse);
      expect(wire.containsKey('thoughtLevel'), isFalse);
    });

    test('update keeps the legacy object form first on old desktops', () async {
      // Shape 0 (object args) misses everywhere; shape 1 hits.
      final fake =
          FakeChannel((m, args) => args.first is Map ? throw missing(m) : null);
      final port = OffPeakPort(fake.call, newWire: false);

      await port.update(
          't1', OffPeakUpdateInput(title: 't', prompt: 'p', model: 'glm-5.2'));

      expect(fake.calls.last.$1, 'updateTask');
      expect(fake.calls.last.$2[0], 't1');
      final wire = fake.calls.last.$2[1] as Map<String, dynamic>;
      // Legacy flat wire keeps the documented fields verbatim.
      expect(wire['model'], 'glm-5.2');
      expect(wire['thoughtLevel'], isNull);
    });
  });

  group('OffPeakUpdateInput.toWire', () {
    test('legacy wire keeps flat model/thoughtLevel with explicit nulls', () {
      expect(
        OffPeakUpdateInput(title: 't', prompt: 'p').toWire(),
        {
          'title': 't',
          'prompt': 'p',
          'permissionMode': 'build',
          'model': null,
          'thoughtLevel': null,
        },
      );
    });

    test(
        'new wire: pair emits modelSelection, null clears, lone model '
        'waits for its provider', () {
      // provider+model 齐备才发；thoughtLevel 依附进 options。
      final full = OffPeakUpdateInput(
              title: 't', prompt: 'p', model: 'm', provider: 'zai')
          .toWire(newWire: true);
      expect(full['modelSelection'], {
        'providerId': 'zai',
        'modelId': 'm',
      });

      // patch 明确 null → modelSelection: null（清除语义保留）。
      final cleared =
          OffPeakUpdateInput(title: 't', prompt: 'p').toWire(newWire: true);
      expect(cleared.containsKey('modelSelection'), isTrue);
      expect(cleared['modelSelection'], isNull);

      // model 有而 provider 缺 → 不发整个对象（thoughtLevel 无载体丢弃）。
      final half = OffPeakUpdateInput(
              title: 't', prompt: 'p', model: 'm', thoughtLevel: 'high')
          .toWire(newWire: true);
      expect(half.containsKey('modelSelection'), isFalse);
      expect(half.containsKey('thoughtLevel'), isFalse);
    });
  });

  group('OffPeakError structured envelope', () {
    test('errorCategory maps onto the official kinds', () {
      expect(
          OffPeakError.structuredFrom({
            'ok': false,
            'failureStage': 'ticket_request',
            'errorCategory': 'eligibility_3101',
            'errorCode': 'E3101',
          })!
              .kind,
          OffPeakError.codingPlanOnly);
      expect(
          OffPeakError.structuredFrom({
            'ok': false,
            'errorCategory': 'quota_3103',
            'errorCode': '',
          })!
              .kind,
          OffPeakError.quota);
      expect(
          OffPeakError.structuredFrom({
            'ok': false,
            'errorCategory': 'network',
          })!
              .kind,
          OffPeakError.unavailable);
      expect(
          OffPeakError.structuredFrom({
            'ok': false,
            'errorCategory': 'invalid_response',
          })!
              .kind,
          OffPeakError.unavailable);
      expect(
          OffPeakError.structuredFrom({
            'ok': false,
            'failureStage': 'client_validation',
            'errorCategory': 'client_validation',
            'errorCode': '',
          })!
              .kind,
          OffPeakError.other);
      expect(
          OffPeakError.structuredFrom({
            'ok': false,
            'errorCategory': 'local_persist',
          })!
              .kind,
          OffPeakError.other);
    });

    test('non-envelopes stay null (void acks, legacy run-results)', () {
      expect(OffPeakError.structuredFrom(null), isNull);
      expect(OffPeakError.structuredFrom({'ok': true}), isNull);
      // Legacy {ok, error} run-result has no errorCategory — the
      // OffPeakRunResult path keeps handling it.
      expect(
          OffPeakError.structuredFrom({'ok': false, 'error': 'quota'}), isNull);
    });

    test('submit throws the classified error on structured acks', () async {
      final fake = FakeChannel((m, _) => {
            'ok': false,
            'failureStage': 'local_persist',
            'errorCategory': 'quota_3103',
            'errorCode': 'Q1',
          });
      final port = OffPeakPort(fake.call, newWire: false);

      await expectLater(
        port.submit(OffPeakSubmitInput(prompt: 'p', workspacePath: '/w')),
        throwsA(isA<OffPeakError>()
            .having((e) => e.kind, 'kind', OffPeakError.quota)),
      );
    });

    test('normalize reads the new enum words from RPC error text', () {
      expect(OffPeakError.normalize('eligibility_3101: plan required'),
          OffPeakError.codingPlanOnly);
      expect(OffPeakError.normalize('quota_3103 exceeded'), OffPeakError.quota);
      expect(OffPeakError.normalize('network unreachable'),
          OffPeakError.unavailable);
      expect(OffPeakError.normalize('invalid_response from upstream'),
          OffPeakError.unavailable);
      expect(OffPeakError.normalize('client_validation'), OffPeakError.other);
    });
  });
}
