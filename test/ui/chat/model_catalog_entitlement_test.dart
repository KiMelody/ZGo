import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/ui/chat/chat_page.dart';

/// One model option of a provider group, in the shape the wire parser
/// produces (design 10-24 §2).
ConfigOptionValue option(
  String providerId,
  String providerName,
  String model,
) => ConfigOptionValue(
  value: '$providerId/$model',
  name: model,
  modelProviderId: providerId,
  modelProviderName: providerName,
);

/// The catalog of research §5: two models in each plan group plus the
/// personal provider (幻城).
List<ConfigOptionValue> demoCatalog() => [
  option('account:zai-individual-coding-plan',
      'Z.AI Individual Coding Plan', 'GLM-5.3'),
  option('account:zai-individual-coding-plan',
      'Z.AI Individual Coding Plan', 'GLM-5.3-Flash'),
  option('account:zai-start-plan', 'Start Plan', 'GLM-5.3'),
  option('account:zai-start-plan', 'Start Plan', 'GLM-5.3-Flash'),
  option('account:zai-off-peak', 'Z.AI Idle plan', 'GLM-5.3'),
  option('account:zai-off-peak', 'Z.AI Idle plan', 'GLM-5.3-Flash'),
  option('account:zai-highspeed-card', 'Z.AI Highspeed card', 'GLM-5.3'),
  option('account:zai-highspeed-card', 'Z.AI Highspeed card', 'GLM-5.3-Flash'),
  option('personal-huancheng', '幻城', 'deepseek-v4-flash'),
];

/// Group headers the sheet's render loop would draw from [choices]
/// (`modelProviderId ?? modelProviderName` change points, design §4).
List<String> groupHeaders(List<ConfigOptionValue> choices) => [
  for (final (i, v) in choices.indexed)
    if (i == 0 ||
        (v.modelProviderId ?? v.modelProviderName) !=
            (choices[i - 1].modelProviderId ?? choices[i - 1].modelProviderName))
      v.modelProviderName!,
];

void main() {
  group('filterByEntitlement (design 10-24 §3)', () {
    test('null entitledIds (getView unreachable) keeps the catalog intact', () {
      final catalog = demoCatalog();
      final filtered = filterByEntitlement(
        catalog,
        entitledIds: null,
        currentProviderId: null,
      );
      expect(identical(filtered, catalog), isTrue);
      expect(groupHeaders(filtered), [
        'Z.AI Individual Coding Plan',
        'Start Plan',
        'Z.AI Idle plan',
        'Z.AI Highspeed card',
        '幻城',
      ]);
    });

    test('starter-only: only the entitled Start plan and 幻城 render', () {
      final filtered = filterByEntitlement(
        demoCatalog(),
        entitledIds: {'account:zai-start-plan'},
        currentProviderId: null,
      );
      expect(groupHeaders(filtered), ['Start Plan', '幻城']);
      expect(filtered, hasLength(3));
    });

    test('a fully entitled view keeps all four account groups in order', () {
      // Every account plan the wire can carry is titled here (a full
      // subscriber): the filter must not disturb the catalog.
      final filtered = filterByEntitlement(
        demoCatalog(),
        entitledIds: {
          'account:zai-individual-coding-plan',
          'account:zai-start-plan',
          'account:zai-off-peak',
          'account:zai-highspeed-card',
        },
        currentProviderId: null,
      );
      expect(groupHeaders(filtered), [
        'Z.AI Individual Coding Plan',
        'Start Plan',
        'Z.AI Idle plan',
        'Z.AI Highspeed card',
        '幻城',
      ]);
      expect(filtered, hasLength(9));
    });

    test('coding+start entitled hides the idle/highspeed groups', () {
      final filtered = filterByEntitlement(
        demoCatalog(),
        entitledIds: {
          'account:zai-individual-coding-plan',
          'account:zai-start-plan',
        },
        currentProviderId: null,
      );
      expect(groupHeaders(filtered), [
        'Z.AI Individual Coding Plan',
        'Start Plan',
        '幻城',
      ]);
    });

    test('empty set is a successful read with zero entitlement — every '
        'account group hides', () {
      final filtered = filterByEntitlement(
        demoCatalog(),
        entitledIds: <String>{},
        currentProviderId: null,
      );
      expect(groupHeaders(filtered), ['幻城']);
    });

    test('the current provider is exempt even when its group is not '
        'entitled (PRD §2 exception)', () {
      final filtered = filterByEntitlement(
        demoCatalog(),
        entitledIds: {'account:zai-start-plan'},
        currentProviderId: 'account:zai-off-peak',
      );
      expect(groupHeaders(filtered), ['Start Plan', 'Z.AI Idle plan', '幻城']);
    });

    test('the exemption is scoped to the current provider id only', () {
      final filtered = filterByEntitlement(
        demoCatalog(),
        entitledIds: <String>{},
        currentProviderId: 'account:zai-individual-coding-plan',
      );
      expect(groupHeaders(filtered), ['Z.AI Individual Coding Plan', '幻城']);
    });

    test('non-account providers never hide, even with an empty set', () {
      final filtered = filterByEntitlement(
        [
          option('builtin:zai-coding-plan', 'BigModel', 'GLM-5.3'),
          option('openrouter', 'OpenRouter', 'glm-4.6'),
          option('personal-huancheng', '幻城', 'deepseek-v4-flash'),
        ],
        entitledIds: <String>{},
        currentProviderId: null,
      );
      expect(groupHeaders(filtered), ['BigModel', 'OpenRouter', '幻城']);
    });

    test('options without a modelProviderId never hide (old desktops)', () {
      final filtered = filterByEntitlement(
        [
          ConfigOptionValue(
            value: 'builtin/glm-5.2',
            name: 'GLM-5.2',
          ),
          ConfigOptionValue(
            value: 'legacy/model',
            name: 'model',
            modelProviderName: 'Legacy',
          ),
        ],
        entitledIds: <String>{},
        currentProviderId: null,
      );
      expect(filtered, hasLength(2));
    });

    test('grouping keys off the provider id: same display name, different '
        'ids stay two groups', () {
      final filtered = filterByEntitlement(
        [
          option('account:zai-start-plan', 'Z.AI', 'GLM-5.3'),
          option('account:zai-off-peak', 'Z.AI', 'GLM-5.3'),
        ],
        entitledIds: {'account:zai-start-plan', 'account:zai-off-peak'},
        currentProviderId: null,
      );
      expect(groupHeaders(filtered), ['Z.AI', 'Z.AI']);
    });
  });
}
