import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation_state.dart';
import 'package:zgo/state/entitlement_poller.dart';
import 'package:zgo/ui/chat/chat_page.dart';

/// Start-plan auto switch (task 10-24 C, design §2/§7): the trigger matrix
/// and target selection over the live-probed snapshot shapes (research §3/§7).
void main() {
  const start = 'account:zai-start-plan';
  const coding = 'account:zai-individual-coding-plan';
  const teamCoding = 'account:zai-team-coding-plan';
  const bigmodelCoding = 'account:bigmodel-individual-coding-plan';

  ConfigOptionValue option(
    String provider,
    String model, {
    String? providerName,
    bool withProviderId = true,
  }) => ConfigOptionValue(
    value: '$provider/$model',
    name: model,
    modelProviderId: withProviderId ? provider : null,
    modelProviderName: providerName ?? provider,
  );

  /// Research §7 fixture: two one-time buckets whose wire `percentage` is
  /// the REMAINING ratio in 0..1 (asar `normalizeZaiStartPlanBalanceLimits`
  /// has no ×100). The production poller normalizes it
  /// ([normalizeStartQuota]) before any consumer sees it — the fixture does
  /// the same, so [EntitlementView.exhausted] reads the task-A semantics.
  EntitlementView startSnapshot({List<num> percentages = const [1.0, 1.0]}) {
    final data = <String, dynamic>{
      'authenticated': true,
      'provider': {'id': start, 'name': 'ZCode 1024 Dev Day'},
      'remaining': {'count': 2, 'isShow': true, 'percentage': 1.0},
      'quota': {
        'level': 'Start',
        'limits': <Map<String, dynamic>>[
          for (var i = 0; i < percentages.length; i++)
            {
              'bucketId': 'bucket_$i',
              'type': 'ent-zcode-v3-start-plan-1024-${i + 1}',
              'unit': 300000000 - i * 100000000,
              'number': 300000000 - i * 100000000,
              'usage': 0,
              'remaining':
                  percentages[i] * (300000000 - i * 100000000),
              'percentage': percentages[i],
              'nextResetTime': 1792976400000,
            },
        ],
      },
    };
    return EntitlementView(
      phase: EntitlementPhase.ok,
      data: normalizeStartQuota(data),
    );
  }

  EntitlementView exhausted() =>
      startSnapshot(percentages: const [0.0, 1.0]);

  /// Expired shape (research §3): provider stays, quota/remaining are empty,
  /// `startPlanExpired` is the only terminal marker.
  EntitlementView expired() => EntitlementView(
    phase: EntitlementPhase.ok,
    data: {
      'authenticated': true,
      'provider': {'id': start, 'name': 'ZCode 1024 Dev Day'},
      'remaining': null,
      'quota': null,
      'subscription': null,
      'unavailableReason': 'no_plan',
      'startPlanExpired': true,
    },
  );

  /// The full prep catalog of the user's screenshot (research §7): the
  /// coding plan and the Start plan both carry GLM-5.3 / GLM-5.3-Flash.
  List<ConfigOptionValue> catalog({
    List<String> codingModels = const ['GLM-5.3', 'GLM-5.3-Flash'],
  }) => [
    for (final m in codingModels) option(coding, m),
    option(start, 'GLM-5.3'),
    option(start, 'GLM-5.3-Flash'),
  ];

  group('evaluate — terminal trigger matrix', () {
    test('drained Start bucket switches to the entitled coding plan', () {
      final plan = StartPlanAutoSwitch.evaluate(
        view: exhausted(),
        entitledIds: {start, coding},
        currentProviderId: start,
        currentModelId: 'GLM-5.3',
        modelOptions: catalog(),
      );
      expect(plan, isNotNull);
      expect(plan!.reason, StartPlanSwitchReason.exhausted);
      expect(plan.targetOption.value, '$coding/GLM-5.3');
    });

    test('expired Start snapshot (no quota to read) switches', () {
      final plan = StartPlanAutoSwitch.evaluate(
        view: expired(),
        entitledIds: {start, coding},
        currentProviderId: start,
        currentModelId: 'GLM-5.3-Flash',
        modelOptions: catalog(),
      );
      expect(plan, isNotNull);
      expect(plan!.reason, StartPlanSwitchReason.expired);
      expect(plan.targetOption.value, '$coding/GLM-5.3-Flash');
    });

    test('a Start provider missing from the entitled set switches '
        '(desktop-side entitlement revoked)', () {
      final plan = StartPlanAutoSwitch.evaluate(
        view: startSnapshot(), // healthy numbers — the set is the signal
        entitledIds: {coding},
        currentProviderId: start,
        currentModelId: 'GLM-5.3',
        modelOptions: catalog(),
      );
      expect(plan, isNotNull);
      expect(plan!.reason, StartPlanSwitchReason.disentitled);
      expect(plan.targetOption.value, '$coding/GLM-5.3');
    });

    test('a healthy, still-entitled Start plan never switches', () {
      expect(
        StartPlanAutoSwitch.evaluate(
          view: startSnapshot(),
          entitledIds: {start, coding},
          currentProviderId: start,
          currentModelId: 'GLM-5.3',
          modelOptions: catalog(),
        ),
        isNull,
      );
    });

    test('every terminal signal is ignored when the current provider is '
        'not a Start plan', () {
      for (final view in [exhausted(), expired()]) {
        expect(
          StartPlanAutoSwitch.evaluate(
            view: view,
            entitledIds: {start, coding},
            currentProviderId: coding,
            currentModelId: 'GLM-5.3',
            modelOptions: catalog(),
          ),
          isNull,
        );
      }
      // The disentitled signal only judges Start providers too.
      expect(
        StartPlanAutoSwitch.evaluate(
          view: startSnapshot(),
          entitledIds: {start},
          currentProviderId: coding,
          currentModelId: 'GLM-5.3',
          modelOptions: catalog(),
        ),
        isNull,
      );
    });

    test('a non-Start provider with a Start-looking neighbour never enters '
        'the judgement', () {
      expect(
        StartPlanAutoSwitch.evaluate(
          view: exhausted(),
          entitledIds: {start},
          currentProviderId: 'account:zai-individual-coding-plan',
          currentModelId: 'GLM-5.3',
          modelOptions: catalog(),
        ),
        isNull,
      );
    });

    test('no entitled coding plan → no switch (banner stays the entry)', () {
      expect(
        StartPlanAutoSwitch.evaluate(
          view: exhausted(),
          entitledIds: {start},
          currentProviderId: start,
          currentModelId: 'GLM-5.3',
          modelOptions: catalog(),
        ),
        isNull,
      );
    });

    test('a coding plan without any prep option → no switch', () {
      expect(
        StartPlanAutoSwitch.evaluate(
          view: exhausted(),
          entitledIds: {start, coding},
          currentProviderId: start,
          currentModelId: 'GLM-5.3',
          modelOptions: [
            option(start, 'GLM-5.3'),
            option(start, 'GLM-5.3-Flash'),
          ],
        ),
        isNull,
      );
    });

    test('entitlement unknown (null) skips the judgement even when '
        'exhausted', () {
      expect(
        StartPlanAutoSwitch.evaluate(
          view: exhausted(),
          entitledIds: null,
          currentProviderId: start,
          currentModelId: 'GLM-5.3',
          modelOptions: catalog(),
        ),
        isNull,
      );
    });

    test('an empty entitled set finds no target', () {
      expect(
        StartPlanAutoSwitch.evaluate(
          view: exhausted(),
          entitledIds: const {},
          currentProviderId: start,
          currentModelId: 'GLM-5.3',
          modelOptions: catalog(),
        ),
        isNull,
      );
    });

    test('exhausted wins the reason when both terminal flags are set', () {
      final both = EntitlementView(
        phase: EntitlementPhase.ok,
        data: {
          ...exhausted().data!,
          'startPlanExpired': true,
        },
      );
      final plan = StartPlanAutoSwitch.evaluate(
        view: both,
        entitledIds: {start, coding},
        currentProviderId: start,
        currentModelId: 'GLM-5.3',
        modelOptions: catalog(),
      );
      expect(plan!.reason, StartPlanSwitchReason.exhausted);
    });
  });

  group('evaluate — target selection', () {
    test('prefers the same modelId inside the target provider', () {
      final plan = StartPlanAutoSwitch.evaluate(
        view: exhausted(),
        entitledIds: {start, coding},
        currentProviderId: start,
        currentModelId: 'GLM-5.3-Flash',
        modelOptions: catalog(),
      );
      expect(plan!.targetOption.value, '$coding/GLM-5.3-Flash');
    });

    test('falls back to the target provider first option without a same '
        'modelId', () {
      final plan = StartPlanAutoSwitch.evaluate(
        view: exhausted(),
        entitledIds: {start, coding},
        currentProviderId: start,
        currentModelId: 'GLM-5.3', // coding only ships GLM-5.4/GLM-5.5
        modelOptions: [
          option(coding, 'GLM-5.4'),
          option(coding, 'GLM-5.5'),
          option(start, 'GLM-5.3'),
        ],
      );
      expect(plan!.targetOption.value, '$coding/GLM-5.4');
    });

    test('the same bare model id under the Start plan never counts as a '
        'target', () {
      final plan = StartPlanAutoSwitch.evaluate(
        view: exhausted(),
        entitledIds: {start, coding},
        currentProviderId: start,
        currentModelId: 'GLM-5.3',
        modelOptions: [
          option(start, 'GLM-5.3'),
          option(start, 'GLM-5.3-Flash'),
          option(coding, 'GLM-5.4'),
        ],
      );
      expect(plan!.targetOption.value, '$coding/GLM-5.4');
    });

    test('empty model options → no switch', () {
      expect(
        StartPlanAutoSwitch.evaluate(
          view: exhausted(),
          entitledIds: {start, coding},
          currentProviderId: start,
          currentModelId: 'GLM-5.3',
          modelOptions: const [],
        ),
        isNull,
      );
    });

    test('empty current model id falls back to the first target option', () {
      final plan = StartPlanAutoSwitch.evaluate(
        view: exhausted(),
        entitledIds: {start, coding},
        currentProviderId: start,
        currentModelId: '',
        modelOptions: catalog(),
      );
      expect(plan!.targetOption.value, '$coding/GLM-5.3');
    });

    test('the first entitled coding plan in view order wins', () {
      final options = [
        option(teamCoding, 'GLM-5.3'),
        option(coding, 'GLM-5.3'),
        option(bigmodelCoding, 'GLM-5.3'),
        option(start, 'GLM-5.3'),
      ];
      final first = StartPlanAutoSwitch.evaluate(
        view: exhausted(),
        entitledIds: {start, teamCoding, coding, bigmodelCoding},
        currentProviderId: start,
        currentModelId: 'GLM-5.3',
        modelOptions: options,
      );
      expect(first!.targetOption.value, '$teamCoding/GLM-5.3');

      final reordered = StartPlanAutoSwitch.evaluate(
        view: exhausted(),
        entitledIds: {start, bigmodelCoding, coding, teamCoding},
        currentProviderId: start,
        currentModelId: 'GLM-5.3',
        modelOptions: options,
      );
      expect(reordered!.targetOption.value, '$bigmodelCoding/GLM-5.3');
    });

    test('off-peak / highspeed entitled ids are not coding-plan targets', () {
      expect(
        StartPlanAutoSwitch.evaluate(
          view: exhausted(),
          entitledIds: {start, 'account:zai-off-peak'},
          currentProviderId: start,
          currentModelId: 'GLM-5.3',
          modelOptions: [
            option('account:zai-off-peak', 'GLM-5.3'),
            option(start, 'GLM-5.3'),
          ],
        ),
        isNull,
      );
    });

    test('an option without modelProviderId falls back to its value '
        'provider segment', () {
      final plan = StartPlanAutoSwitch.evaluate(
        view: exhausted(),
        entitledIds: {start, coding},
        currentProviderId: start,
        currentModelId: 'GLM-5.3-Flash',
        modelOptions: [
          option(coding, 'GLM-5.3', withProviderId: false),
          option(coding, 'GLM-5.3-Flash', withProviderId: false),
          option(start, 'GLM-5.3'),
        ],
      );
      expect(plan!.targetOption.value, '$coding/GLM-5.3-Flash');
    });
  });
}
