import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/automation.dart';
import 'package:zgo/protocol/channel_client.dart';

/// Fake automation channel: answers from a method table, records every
/// call, and can be tuned to reject method names with "no such method".
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
  group('AutomationPort.list', () {
    test('uses listAllAutomations and parses a plain list', () async {
      final fake = FakeChannel((m, _) => [
            {
              'automationId': 'a1',
              'title': '日报',
              'prompt': '写日报',
              'cronExpr': '0 9 * * *',
              'enabled': true,
            },
            {'automationId': 'a2', 'title': '备份数据库', 'interval': 6,
              'intervalUnit': 'hour', 'recurring': true},
          ]);
      final port = AutomationPort(fake.call, newWire: false);

      final items = await port.list();

      expect(fake.calls.single.$1, 'listAllAutomations');
      expect(fake.calls.single.$2, isEmpty);
      expect(items, hasLength(2));
      expect(items[0].id, 'a1');
      expect(items[0].trigger, AutomationInput.triggerCron);
      expect(items[1].trigger, AutomationInput.triggerInterval);
      expect(items[1].intervalUnit, 'hour');
    });

    test('unwraps {automations: [...]} responses', () async {
      final fake = FakeChannel((m, _) => {
            'automations': [
              {'id': 'x', 'title': 'T', 'prompt': 'P', 'relativeDelayMinutes': 30},
            ],
          });
      final port = AutomationPort(fake.call, newWire: false);

      final items = await port.list();

      expect(items, hasLength(1));
      expect(items[0].id, 'x'); // id fallback shape
      expect(items[0].trigger, AutomationInput.triggerOneShot);
    });

    test('falls back to listAutomations and remembers the winner',
        () async {
      var probe = 0;
      final fake = FakeChannel((m, _) {
        probe++;
        if (m == 'listAllAutomations' && probe == 1) throw missing(m);
        return const [];
      });
      final port = AutomationPort(fake.call, newWire: false);

      await port.list();
      await port.list();

      final methods =
          fake.calls.map((c) => c.$1).toList();
      // First call probes both; second goes straight to the resolved one.
      expect(methods, [
        'listAllAutomations',
        'listAutomations',
        'listAutomations',
      ]);
    });

    test('non-missing-method errors surface verbatim', () async {
      final fake = FakeChannel((m, _) =>
          throw ChannelRpcError('cronExpr is required', null));
      final port = AutomationPort(fake.call, newWire: false);

      await expectLater(
          port.list(), throwsA(isA<ChannelRpcError>()));
      expect(fake.calls, hasLength(1));
    });
  });

  group('AutomationPort.create wire shapes', () {
    test('cron trigger', () async {
      final fake = FakeChannel((m, _) => {'automationId': 'new'});
      final port = AutomationPort(fake.call, newWire: false);

      await port.create(
        const AutomationInput(
          title: '站会总结',
          prompt: '总结昨天的 git 提交',
          cronExpr: '30 9 * * 1-5',
        ),
        const {'workspacePath': '/repo'},
      );

      final (method, args) = fake.calls.single;
      expect(method, 'createAutomation');
      expect(args, [
        {
          'workspacePath': '/repo',
          'title': '站会总结',
          'prompt': '总结昨天的 git 提交',
          'cronExpr': '30 9 * * 1-5',
        },
      ]);
    });

    test('interval trigger with cap', () async {
      final fake = FakeChannel((m, _) => null);
      final port = AutomationPort(fake.call, newWire: false);

      await port.create(
        const AutomationInput(
          title: 't',
          prompt: 'p',
          trigger: AutomationInput.triggerInterval,
          interval: 2,
          intervalUnit: 'day',
          recurring: false,
          maxRuns: 10,
          model: 'glm-5.2',
        ),
        const {'workspacePath': '/repo'},
      );

      expect(fake.calls.single.$2, [
        {
          'workspacePath': '/repo',
          'title': 't',
          'prompt': 'p',
          'interval': 2,
          'intervalUnit': 'day',
          'recurring': false,
          'maxRuns': 10,
          'model': 'glm-5.2',
        },
      ]);
    });

    test('one-shot trigger emits relativeDelayMinutes + single run',
        () async {
      final fake = FakeChannel((m, _) => null);
      final port = AutomationPort(fake.call, newWire: false);

      await port.create(
        const AutomationInput(
          title: 't',
          prompt: 'p',
          trigger: AutomationInput.triggerOneShot,
          relativeDelayMinutes: 90,
        ),
        const {'workspacePath': '/repo'},
      );

      expect(fake.calls.single.$2, [
        {
          'workspacePath': '/repo',
          'title': 't',
          'prompt': 'p',
          'relativeDelayMinutes': 90,
          'recurring': false,
          'maxRuns': 1,
        },
      ]);
    });

    test('empty optional fields are omitted', () async {
      final fake = FakeChannel((m, _) => null);
      final port = AutomationPort(fake.call, newWire: false);

      await port.create(
        const AutomationInput(
          title: 't',
          prompt: 'p',
          cronExpr: '* * * * *',
          model: '',
          provider: null,
        ),
        const {'workspacePath': '/repo'},
      );

      final wire = fake.calls.single.$2.first as Map<String, dynamic>;
      expect(wire.containsKey('model'), isFalse);
      expect(wire.containsKey('provider'), isFalse);
    });

    test('create payload carries workspace scope (scope first, form wins)',
        () async {
      final fake = FakeChannel((m, _) => null);
      final port = AutomationPort(fake.call, newWire: false);

      await port.create(
        const AutomationInput(title: 't', prompt: 'p', cronExpr: '0 9 * * *'),
        const {
          'workspacePath': '/repo',
          'workspaceIdentity': 'ws-1',
          'title': 'scope',
        },
      );

      // web 形态 {scope..., ...form}：scope 前置，表单字段后展开
      // 覆盖 scope 中的同名键。
      expect(fake.calls.single.$2, [
        {
          'workspacePath': '/repo',
          'workspaceIdentity': 'ws-1',
          'title': 't',
          'prompt': 'p',
          'cronExpr': '0 9 * * *',
        },
      ]);
    });
  });

  group('AutomationPort.update', () {
    test('probes methods and shapes, remembers the accepted pair',
        () async {
      final fake = FakeChannel((m, args) {
        // Only automationUpdate with positional args is accepted.
        if (m == 'automationUpdate' && args.first is String) return null;
        throw missing(m);
      });
      final port = AutomationPort(fake.call, newWire: false);

      await port.update(
        'a1',
        const AutomationInput(title: 't', prompt: 'p', cronExpr: '* * * * *'),
        const {'workspacePath': '/repo'},
      );

      // Shape 0 probes all methods, then shape 1 does: the accepted call is
      // automationUpdate with positional args. Shape 0 carries the scope
      // (primary shape), shape 1 stays scope-less (legacy fallback).
      expect(fake.calls, hasLength(6));
      expect(
          (fake.calls.first.$2.single as Map)['workspacePath'], '/repo');
      expect(fake.calls.last.$1, 'automationUpdate');
      expect(fake.calls.last.$2, [
        'a1',
        {'title': 't', 'prompt': 'p', 'cronExpr': '* * * * *'},
      ]);

      fake.calls.clear();
      await port.update(
          'a2',
          const AutomationInput(title: 't', prompt: 'p', cronExpr: '* * * * *'),
          const {'workspacePath': '/repo'});
      // Resolved method+shape go straight through without probing.
      expect(fake.calls.single.$1, 'automationUpdate');
      expect(fake.calls.single.$2.first, 'a2');
    });

    test('validation errors are not treated as missing methods', () async {
      final fake = FakeChannel(
          (m, _) => throw ChannelRpcError('title required', null));
      final port = AutomationPort(fake.call, newWire: false);

      await expectLater(
        port.update(
            'a1',
            const AutomationInput(title: 't', prompt: 'p', cronExpr: '* * * * *'),
            const {'workspacePath': '/repo'}),
        throwsA(isA<ChannelRpcError>()),
      );
      expect(fake.calls, hasLength(1));
    });

    test('setEnabled sends a flag-only update on the legacy path', () async {
      final fake = FakeChannel((m, _) => null);
      final port = AutomationPort(fake.call, newWire: false);

      await port.setEnabled('a1', false, const {});

      expect(fake.calls.single.$2, [
        {'automationId': 'a1', 'enabled': false},
      ]);
    });
  });

  group('AutomationPort.remove', () {
    test('deleteAutomation gets an id object; automationDelete gets the id',
        () async {
      final fake = FakeChannel((m, _) {
        if (m == 'deleteAutomation') return null;
        if (m.contains('list')) return const [];
        throw missing(m);
      });
      final port = AutomationPort(fake.call, newWire: false);

      await port.remove('a1');
      expect(fake.calls.first.$2, [
        {'automationId': 'a1'}
      ]);
      // 删除后回读 list() 验证条目消失（消失=通过）。
      expect(fake.calls[1].$1, 'listAllAutomations');

      final fake2 = FakeChannel((m, _) {
        if (m == 'automationDelete') return null;
        if (m.contains('list')) return const [];
        throw missing(m);
      });
      final port2 = AutomationPort(fake2.call, newWire: false);

      await port2.remove('a2');
      // calls: deleteAutomation(miss) → automationDelete(hit) → read-back.
      expect(fake2.calls[1].$1, 'automationDelete');
      expect(fake2.calls[1].$2, ['a2']);
    });

    test('read-back still finds the item → throws with the id '
        '(手机桥假成功处置)', () async {
      final fake = FakeChannel((m, _) {
        if (m == 'deleteAutomation') return null;
        if (m == 'listAllAutomations') {
          return [
            {'automationId': 'a1', 'title': 't', 'prompt': 'p'},
          ];
        }
        throw missing(m);
      });
      final port = AutomationPort(fake.call, newWire: false);

      await expectLater(
          port.remove('a1'),
          throwsA(isA<StateError>()
              .having((e) => '$e', 'message', contains('a1'))));
      expect(fake.calls.map((c) => c.$1),
          containsAll(['deleteAutomation', 'listAllAutomations']));
    });
  });

  group('AutomationInput.validate', () {
    test('requires title, prompt and trigger fields', () {
      expect(const AutomationInput().validate(), 'auto.err.title');
      expect(
          const AutomationInput(title: 't').validate(), 'auto.err.prompt');
      expect(
          const AutomationInput(title: 't', prompt: 'p').validate(),
          'auto.err.cron');
      expect(
          const AutomationInput(title: 't', prompt: 'p', cronExpr: '')
              .validate(),
          'auto.err.cron');
      expect(
          const AutomationInput(
                  title: 't',
                  prompt: 'p',
                  trigger: AutomationInput.triggerInterval)
              .validate(),
          'auto.err.interval');
      expect(
          const AutomationInput(
                  title: 't',
                  prompt: 'p',
                  trigger: AutomationInput.triggerOneShot,
                  relativeDelayMinutes: 0)
              .validate(),
          'auto.err.delay');
      expect(
          const AutomationInput(
                  title: 't',
                  prompt: 'p',
                  trigger: AutomationInput.triggerOneShot,
                  relativeDelayMinutes: 60 * 24 * 365 + 1)
              .validate(),
          'auto.err.delay');
      expect(
          const AutomationInput(
                  title: 't',
                  prompt: 'p',
                  cronExpr: '0 9 * * *',
                  enabledOnly: null)
              .validate(),
          isNull);
    });

    test('flag-only updates skip validation', () {
      expect(
          const AutomationInput(enabledOnly: true, existingId: 'a')
              .validate(),
          isNull);
    });
  });

  group('AutomationItem', () {
    test('field tolerances and trigger derivation', () {
      final item = AutomationItem({
        'id': 'i1', // id fallback shape
        'name': '周报', // name fallback shape
        'instruction': '写周报', // instruction fallback shape
        'interval': 1,
        'intervalUnit': 'week',
      });
      expect(item.id, 'i1');
      expect(item.title, '周报');
      expect(item.prompt, '写周报');
      expect(item.trigger, AutomationInput.triggerInterval);
      expect(item.enabled, isTrue); // absent enabled defaults to on
    });

    test('enabled=false / paused=true both count as disabled', () {
      expect(
          AutomationItem({'enabled': false}).enabled, isFalse);
      expect(AutomationItem({'paused': true}).enabled, isFalse);
    });

    test('toInput round-trips the edit form', () {
      final item = AutomationItem({
        'automationId': 'a9',
        'title': '日报',
        'prompt': '写日报',
        'cronExpr': '0 9 * * *',
        'model': 'glm-5.2',
        'mode': 'build',
        'targetTaskId': 'task-7',
      });
      final input = item.toInput();
      expect(input.title, '日报');
      expect(input.cronExpr, '0 9 * * *');
      expect(input.model, 'glm-5.2');
      expect(input.targetTaskId, 'task-7');
      expect(input.toWire()['cronExpr'], '0 9 * * *');
    });

    test('run bookkeeping getters', () {
      final item = AutomationItem({
        'lastRunAt': 1724400000000,
        'lastResult': 'success',
      });
      expect(item.lastRunAt, 1724400000000);
      expect(item.lastResult, 'success');
    });
  });

  group('AutomationInput.toWire newWire (3.12.3)', () {
    // newWire interval 双字段——cronExpr（本地编译门票）
    // + scheduleRule（桌面实际调度的依据）。
    const unitCrons = {
      'minute': '*/3 * * * *',
      'hour': '5 */3 * * *',
      'day': '5 7 */3 * *',
      'week': '5 7 * * */3',
      'month': '5 7 1-28/3 * *',
    };

    test('interval trigger emits cronExpr + scheduleRule across all units',
        () {
      const ruleUnits = {
        'minute': 'minute',
        'hour': 'hourly',
        'day': 'daily',
        'week': 'weekly',
        'month': 'monthly',
        'year': 'yearly',
      };
      for (final MapEntry(key: legacy, value: ruleUnit) in ruleUnits.entries) {
        final wire = AutomationInput(
          title: 't',
          prompt: 'p',
          trigger: AutomationInput.triggerInterval,
          interval: 3,
          intervalUnit: legacy,
          anchorHour: 7,
          anchorMinute: 5,
        ).toWire(newWire: true);
        final rule = wire['scheduleRule'] as Map<String, dynamic>;
        expect(rule['unit'], ruleUnit, reason: legacy);
        expect(rule['interval'], 3);
        expect(rule['hour'], 7);
        expect(rule['minute'], 5);
        if (unitCrons.containsKey(legacy)) {
          expect(wire['cronExpr'], unitCrons[legacy], reason: legacy);
        } else {
          // year：锚点日/月无 input 字段，取编译时刻——只断言形状。
          expect(
              RegExp(r'^5 7 \d{1,2} \d{1,2} \*$').hasMatch(
                  wire['cronExpr'] as String),
              isTrue,
              reason: legacy);
        }
        // 旧词表字段不再出现。
        expect(wire.containsKey('interval'), isFalse, reason: legacy);
        expect(wire.containsKey('intervalUnit'), isFalse, reason: legacy);
      }
    });

    test('missing anchors fall back to the current minute', () {
      final before = DateTime.now();
      final wire = const AutomationInput(
        title: 't',
        prompt: 'p',
        trigger: AutomationInput.triggerInterval,
        interval: 5,
      ).toWire(newWire: true);
      final after = DateTime.now();
      final rule = wire['scheduleRule'] as Map<String, dynamic>;
      expect(rule['hour'], anyOf(before.hour, after.hour));
      expect(rule['minute'], anyOf(before.minute, after.minute));
    });

    test('modelSelection replaces the flat model fields; '
        'mode/targetTaskId stay flat', () {
      final wire = const AutomationInput(
        title: 't',
        prompt: 'p',
        cronExpr: '0 9 * * *',
        provider: 'zai',
        model: 'glm-5.2',
        thoughtLevel: 'high',
        mode: 'build',
        targetTaskId: 'task-7',
      ).toWire(newWire: true);
      expect(wire['modelSelection'], {
        'providerId': 'zai',
        'modelId': 'glm-5.2',
        'options': {'reasoningLevel': 'high'},
      });
      expect(wire.containsKey('model'), isFalse);
      expect(wire.containsKey('provider'), isFalse);
      expect(wire.containsKey('thoughtLevel'), isFalse);
      expect(wire['mode'], 'build');
      expect(wire['targetTaskId'], 'task-7');
    });

    test('modelSelection requires BOTH provider and model (zod strict)', () {
      // 一旦发出，providerId/modelId 必填——缺一不发整个
      // 对象；thoughtLevel 单独存在无载体，随之丢弃（不回退平铺）。
      final none = const AutomationInput(
        title: 't',
        prompt: 'p',
        cronExpr: '0 9 * * *',
      ).toWire(newWire: true);
      expect(none.containsKey('modelSelection'), isFalse);

      final thoughtOnly = const AutomationInput(
        title: 't',
        prompt: 'p',
        cronExpr: '0 9 * * *',
        thoughtLevel: 'high',
      ).toWire(newWire: true);
      expect(thoughtOnly.containsKey('modelSelection'), isFalse);
      expect(thoughtOnly.containsKey('thoughtLevel'), isFalse);

      final modelOnly = const AutomationInput(
        title: 't',
        prompt: 'p',
        cronExpr: '0 9 * * *',
        model: 'glm-5.2',
      ).toWire(newWire: true);
      expect(modelOnly.containsKey('modelSelection'), isFalse);
    });

    test('cron and one-shot triggers keep their shapes under newWire', () {
      final cron = const AutomationInput(
        title: 't',
        prompt: 'p',
        cronExpr: '0 9 * * *',
      ).toWire(newWire: true);
      expect(cron['cronExpr'], '0 9 * * *');
      expect(cron.containsKey('scheduleRule'), isFalse);

      final oneShot = const AutomationInput(
        title: 't',
        prompt: 'p',
        trigger: AutomationInput.triggerOneShot,
        relativeDelayMinutes: 90,
      ).toWire(newWire: true);
      expect(oneShot['relativeDelayMinutes'], 90);
      expect(oneShot['recurring'], false);
      expect(oneShot['maxRuns'], 1);
      expect(oneShot.containsKey('scheduleRule'), isFalse);
    });

    test('default toWire keeps the legacy flat wire (regression lock)', () {
      final wire = const AutomationInput(
        title: 't',
        prompt: 'p',
        trigger: AutomationInput.triggerInterval,
        interval: 2,
        intervalUnit: 'day',
        model: 'glm-5.2',
      ).toWire();
      expect(wire.containsKey('scheduleRule'), isFalse);
      expect(wire.containsKey('modelSelection'), isFalse);
      expect(wire['interval'], 2);
      expect(wire['intervalUnit'], 'day');
      expect(wire['model'], 'glm-5.2');
    });
  });

  group('AutomationInput.intervalCronExpr', () {
    final now = DateTime(2026, 3, 15, 10, 7);

    test('all six units with explicit anchors', () {
      expect(AutomationInput.intervalCronExpr('minute', 3, 7, 5, now: now),
          '*/3 * * * *');
      expect(AutomationInput.intervalCronExpr('hour', 3, 7, 5, now: now),
          '5 */3 * * *');
      expect(AutomationInput.intervalCronExpr('day', 3, 7, 5, now: now),
          '5 7 */3 * *');
      expect(AutomationInput.intervalCronExpr('week', 3, 7, 5, now: now),
          '5 7 * * */3');
      expect(AutomationInput.intervalCronExpr('month', 3, 7, 5, now: now),
          '5 7 1-28/3 * *');
      // year：锚点日/月取编译时刻（input 无此字段，cron 仅回退载体，
      // 桌面优先按 scheduleRule 调度）。
      expect(AutomationInput.intervalCronExpr('year', 1, 7, 5, now: now),
          '5 7 15 3 *');
    });

    test('day interval clamps to 28 (short months)', () {
      expect(AutomationInput.intervalCronExpr('day', 30, 7, 5, now: now),
          '5 7 */28 * *');
    });

    test('missing anchors fall back to now (minute-truncated)', () {
      expect(
          AutomationInput.intervalCronExpr('hour', 2, null, null, now: now),
          '7 */2 * * *');
      expect(
          AutomationInput.intervalCronExpr('day', 1, null, null, now: now),
          '7 10 */1 * *');
    });

    test('invalid interval or unknown unit yields null (key omitted)', () {
      expect(AutomationInput.intervalCronExpr('day', null, 7, 5, now: now),
          isNull);
      expect(
          AutomationInput.intervalCronExpr('day', 0, 7, 5, now: now), isNull);
      expect(AutomationInput.intervalCronExpr('decade', 2, 7, 5, now: now),
          isNull);
    });
  });

  group('AutomationItem scheduleRule read-side', () {
    test('unit reverse mapping, anchor backfill and trigger derivation', () {
      final item = AutomationItem({
        'automationId': 'a1',
        'title': '备份',
        'prompt': 'p',
        'scheduleRule': {
          'unit': 'hourly',
          'interval': 6,
          'hour': 9,
          'minute': 30,
        },
        'recurring': false,
        'maxRuns': 12,
      });
      expect(item.trigger, AutomationInput.triggerInterval);
      expect(item.interval, 6);
      expect(item.intervalUnit, 'hour');
      expect(item.anchorHour, 9);
      expect(item.anchorMinute, 30);
      // 编辑表单回显带锚点，重发时锚点不丢。
      final input = item.toInput();
      expect(input.anchorHour, 9);
      expect(input.anchorMinute, 30);
      final wire = input.toWire(newWire: true);
      final rule = wire['scheduleRule'] as Map<String, dynamic>;
      expect(rule['unit'], 'hourly');
      expect(rule['hour'], 9);
      expect(rule['minute'], 30);
    });

    test('the other five rule units reverse-map to legacy units', () {
      const cases = {
        'minute': 'minute',
        'daily': 'day',
        'weekly': 'week',
        'monthly': 'month',
        'yearly': 'year',
      };
      for (final MapEntry(key: unit, value: legacy) in cases.entries) {
        final item = AutomationItem({
          'scheduleRule': {'unit': unit, 'interval': 1, 'hour': 0, 'minute': 0},
        });
        expect(item.intervalUnit, legacy, reason: unit);
      }
    });
  });

  group('AutomationItem.lifecycleStatus', () {
    test('parses the lifecycle marker when present', () {
      for (final status in ['active', 'completed', 'failed', 'paused']) {
        expect(
            AutomationItem({'lifecycleStatus': status}).lifecycleStatus,
            status);
      }
    });

    test('null when absent (legacy desktops)', () {
      expect(AutomationItem({'enabled': true}).lifecycleStatus, isNull);
    });
  });

  group('AutomationPort newWire pass-through', () {
    test('create emits cronExpr + scheduleRule + modelSelection on the wire',
        () async {
      final fake = FakeChannel((m, _) => null);
      final port = AutomationPort(fake.call, newWire: true);

      await port.create(
        const AutomationInput(
          title: 't',
          prompt: 'p',
          trigger: AutomationInput.triggerInterval,
          interval: 3,
          intervalUnit: 'day',
          anchorHour: 8,
          anchorMinute: 15,
          provider: 'zai',
          model: 'glm-5.2',
        ),
        const {'workspacePath': '/repo'},
      );

      expect(fake.calls.single.$1, 'createAutomation');
      expect(fake.calls.single.$2, [
        {
          'workspacePath': '/repo',
          'title': 't',
          'prompt': 'p',
          // 双字段：cronExpr 是必填门票（本地编译），scheduleRule 是桌面
          // 实际调度的依据。
          'cronExpr': '15 8 */3 * *',
          'scheduleRule': {
            'unit': 'daily',
            'interval': 3,
            'hour': 8,
            'minute': 15,
          },
          'recurring': true,
          'modelSelection': {'providerId': 'zai', 'modelId': 'glm-5.2'},
        },
      ]);
    });

    test('setEnabled goes through setAutomationEnabled with scope',
        () async {
      final fake = FakeChannel((m, _) => null);
      final port = AutomationPort(fake.call, newWire: true);

      await port.setEnabled('a1', false, const {'workspacePath': '/repo'});

      // Single candidate, live-confirmed shape: scope first, then id+flag.
      expect(fake.calls.single.$1, 'setAutomationEnabled');
      expect(fake.calls.single.$2, [
        {'workspacePath': '/repo', 'automationId': 'a1', 'enabled': false},
      ]);
    });
  });
}
