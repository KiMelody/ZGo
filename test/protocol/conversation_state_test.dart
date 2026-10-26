import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';

void main() {
  group('ConfigOptionValue modelProviderId (wire fixture, design 10-24 §2)',
      () {
    WorkspacePrep prepWith(List<Map<String, dynamic>> options) =>
        WorkspacePrep.fromMap({
          'configOptions': [
            {
              'id': 'model',
              'name': 'Model',
              'currentValue': 'account:zai-start-plan/GLM-5.3',
              'options': options,
            },
          ],
          'slashCommands': <Map<String, dynamic>>[],
        });

    test('parses modelProviderId and modelProviderName off the wire', () {
      final options = prepWith([
        {
          'value': 'account:zai-start-plan/GLM-5.3',
          'name': 'GLM-5.3',
          'description': 'Start plan tier',
          'modelProviderId': 'account:zai-start-plan',
          'modelProviderName': 'Start Plan',
        },
      ]).option('model')!.options;

      expect(options.single.modelProviderId, 'account:zai-start-plan');
      expect(options.single.modelProviderName, 'Start Plan');
    });

    test('a projection without modelProviderId degrades to null', () {
      final options = prepWith([
        {'value': 'builtin/glm-5.2', 'name': 'GLM-5.2'},
      ]).option('model')!.options;

      expect(options.single.modelProviderId, isNull);
      expect(options.single.modelProviderName, isNull);
    });

    test('a non-string modelProviderId degrades to null, not a stringified '
        'value', () {
      final options = prepWith([
        {'value': 'x/y', 'name': 'Y', 'modelProviderId': 42},
      ]).option('model')!.options;

      expect(options.single.modelProviderId, isNull);
    });

    test('the public constructor carries the synthesized provider id', () {
      final value = ConfigOptionValue(
        value: 'personal-huancheng/deepseek-v4-flash',
        name: 'deepseek-v4-flash',
        modelProviderId: 'personal-huancheng',
        modelProviderName: '幻城',
      );

      expect(value.modelProviderId, 'personal-huancheng');
      expect(value.modelProviderName, '幻城');
    });
  });
}
