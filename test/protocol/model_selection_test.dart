import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/model_selection.dart';

/// Live-confirmed 3.14 `model-selection.getView` shape (2026-09-19 probe,
/// trimmed to the fields the mapping reads).
Map<String, dynamic> get liveView => {
      'revision': 3,
      'providers': [
        {
          'providerId': 'account:zai-individual-coding-plan',
          'providerName': 'Z.ai 个人编码套餐',
          'config': {
            'group': 'builtin',
            'access': {'kind': 'account'},
            'api': {'type': 'builtin', 'baseUrl': ''},
            'builtinModelIds': ['GLM-5.3', 'GLM-5.3-Flash'],
          },
          'models': [
            {
              'modelId': 'GLM-5.3',
              'config': {
                'enabled': true,
                'properties': {'thought': true},
              },
            },
            {
              'modelId': 'GLM-5.3-Flash',
              'config': {'enabled': false},
            },
          ],
        },
      ],
    };

void main() {
  group('parseModelSelectionCatalog', () {
    test('maps the live getView shape to the legacy catalog entries', () {
      final catalog = parseModelSelectionCatalog(liveView);

      expect(catalog, hasLength(1));
      expect(catalog.single['id'], 'account:zai-individual-coding-plan');
      expect(catalog.single['name'], 'Z.ai 个人编码套餐');
      // Disabled model dropped, enabled one kept as {id}.
      expect(catalog.single['models'], [
        {'id': 'GLM-5.3'},
      ]);
    });

    test('keeps models whose enabled flag is absent (== false filtering)',
        () {
      final res = {
        'providers': [
          {
            'providerId': 'p1',
            'providerName': 'P1',
            'models': [
              {'modelId': 'm-enabled', 'config': {'enabled': true}},
              {'modelId': 'm-unmarked', 'config': {'properties': {}}},
              {'modelId': 'm-off', 'config': {'enabled': false}},
            ],
          },
        ],
      };

      final catalog = parseModelSelectionCatalog(res);

      expect(catalog.single['models'], [
        {'id': 'm-enabled'},
        {'id': 'm-unmarked'},
      ]);
    });

    test('falls back to providerId when providerName is absent', () {
      final res = {
        'providers': [
          {'providerId': 'p1', 'models': []},
        ],
      };

      expect(parseModelSelectionCatalog(res).single['name'], 'p1');
    });

    test('skips providers without a providerId', () {
      final res = {
        'providers': [
          {'providerName': 'no-id'},
          {'providerId': 'p1'},
        ],
      };

      final catalog = parseModelSelectionCatalog(res);
      expect(catalog, hasLength(1));
      expect(catalog.single['id'], 'p1');
      expect(catalog.single['models'], isEmpty);
    });

    test('degrades malformed payloads to an empty catalog', () {
      expect(parseModelSelectionCatalog(null), isEmpty);
      expect(parseModelSelectionCatalog('nope'), isEmpty);
      expect(parseModelSelectionCatalog(<dynamic>[]), isEmpty);
      expect(parseModelSelectionCatalog({'revision': 3}), isEmpty);
      expect(
        parseModelSelectionCatalog({
          'providers': [
            'not-a-map',
            {
              'providerId': 'p1',
              'models': ['not-a-map', {'config': {'enabled': true}}],
            },
          ],
        }),
        [
          {'id': 'p1', 'name': 'p1', 'models': const <dynamic>[]},
        ],
      );
    });
  });
}
