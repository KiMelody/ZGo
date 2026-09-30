import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/provider_settings.dart';

/// Parsing and revision-guard contracts of the provider-settings view
/// (wire shapes per the 2026-09-28 live/static certification in the task's
/// notes.md).
void main() {
  Object? sampleView() => {
        'revision': '[30,4]',
        'providerOrder': ['p2', 'p1'],
        'providerTemplates': [
          {
            'templateId': 'deepseek',
            'templateNameMap': {'zh-CN': 'DeepSeek', 'en-US': 'DeepSeek'},
            'config': {
              'api': {
                'type': 'openai-chat-completions',
                'baseUrl': 'https://api.deepseek.com/v1',
              },
              'access': {
                'type': 'api-key',
                'apiKeyManagementUrl':
                    'https://platform.deepseek.com/api_keys',
              },
            },
          },
          {
            'templateId': 'zai-api',
            'templateNameMap': {'en-US': 'Z.ai API'},
            'config': {
              'api': {'type': 'anthropic-messages'},
            },
          },
        ],
        'providers': [
          {
            'providerId': 'account:zai-individual-coding-plan',
            'providerName': 'Z.ai',
            'enabled': true,
            'executable': true,
            'accountState': {'accountType': 'zai'},
            'effectiveConfig': {
              'access': {
                'type': 'zhipu-account',
                'accountType': 'zai',
                'mode': 'individual-coding-plan',
                'entitled': true,
              },
            },
            'issues': [],
            'models': [
              {
                'modelId': 'glm-5.2',
                'builtin': true,
                'effectiveConfig': {
                  'properties': {'contextWindow': 200000},
                },
                'enabled': true,
                'executable': true,
                'selectable': true,
                'issues': [],
              },
            ],
          },
          {
            'providerId': 'p1',
            'providerName': 'Alpha',
            'enabled': false,
            'executable': false,
            'personalConfig': {
              'group': 'standard-personal',
              'access': {'type': 'api-key', 'apiKey': 'sk-abc123'},
              'personalModelIds': ['m1'],
              'modelOrder': [],
            },
            'effectiveConfig': {
              'api': {'type': 'openai-chat-completions'},
              'access': {'type': 'api-key', 'apiKey': 'sk-abc123'},
            },
            'issues': [
              {'code': 'required-field-missing', 'path': ['api'], 'message': '缺少必填配置 api.baseUrl'},
            ],
            'models': [],
          },
          {
            'providerId': 'p2',
            'providerName': 'Beta',
            'enabled': true,
            'executable': true,
            'personalConfig': {
              'group': 'standard-personal',
              'access': {'type': 'zhipu-coding-plan-api-key'},
              'api': {
                'type': 'anthropic-messages',
                'baseUrl': 'https://api.z.ai/api/anthropic',
              },
            },
            'effectiveConfig': {
              'api': {
                'type': 'anthropic-messages',
                'baseUrl': 'https://api.z.ai/api/anthropic',
              },
            },
            'issues': [],
            'models': [
              {
                'modelId': 'builtin-one',
                'builtin': true,
                'effectiveConfig': {},
                'enabled': true,
                'executable': true,
                'selectable': true,
                'issues': [],
              },
              {
                'modelId': 'mine',
                'builtin': false,
                'personalExactConfig': {
                  'properties': {'contextWindow': 64000},
                  'optionSpecs': {'maxOutputTokens': 8192},
                },
                'effectiveConfig': {},
                'useRecommendedConfig': false,
                'enabled': true,
                'executable': true,
                'selectable': true,
                'issues': [],
              },
            ],
          },
        ],
      };

  group('parseProviderSettingsView', () {
    test('parses the full view shape', () {
      final view = ProviderSettingsView.parse(sampleView());
      expect(view.revision, '[30,4]');
      expect(view.providerOrder, ['p2', 'p1']);
      expect(view.templates, hasLength(2));
      expect(view.providers, hasLength(3));
    });

    test('groups account vs custom entries', () {
      final view = ProviderSettingsView.parse(sampleView());
      expect(view.accountProviders.map((p) => p.providerId).toList(),
          ['account:zai-individual-coding-plan']);
      // providerOrder wins over the view array order (p2 before p1).
      expect(view.customProviders.map((p) => p.providerId).toList(),
          ['p2', 'p1']);
    });

    test('account entry carries entitlement and mode, no apiKey', () {
      final view = ProviderSettingsView.parse(sampleView());
      final account = view.accountProviders.single;
      expect(account.isAccount, isTrue);
      expect(account.entitled, isTrue);
      expect(account.apiKey, isNull);
    });

    test('personal entry exposes the plaintext key for prefill', () {
      final view = ProviderSettingsView.parse(sampleView());
      final p1 =
          view.customProviders.firstWhere((p) => p.providerId == 'p1');
      expect(p1.apiKey, 'sk-abc123');
      expect(p1.accessType, 'api-key');
      expect(p1.executable, isFalse);
      expect(p1.issues.single.code, 'required-field-missing');
    });

    test('personal api block prefers the personal override', () {
      final view = ProviderSettingsView.parse(sampleView());
      final p2 =
          view.customProviders.firstWhere((p) => p.providerId == 'p2');
      expect(p2.api['type'], 'anthropic-messages');
      expect(p2.accessType, 'zhipu-coding-plan-api-key');
    });

    test('model entries parse with builtin flag and issues', () {
      final view = ProviderSettingsView.parse(sampleView());
      final p2 =
          view.customProviders.firstWhere((p) => p.providerId == 'p2');
      expect(p2.models, hasLength(2));
      expect(p2.models.first.builtin, isTrue);
      expect(p2.models.last.builtin, isFalse);
      expect(p2.models.last.useRecommendedConfig, isFalse);
    });

    test('malformed payload degrades to an empty view', () {
      final view = ProviderSettingsView.parse({'providers': 'nope'});
      expect(view.providers, isEmpty);
      expect(view.templates, isEmpty);
      expect(view.providerOrder, isEmpty);
      expect(ProviderSettingsView.parse(null).providers, isEmpty);
    });
  });

  group('resolveProviderTemplateName', () {
    test('locale match, then en-US, then templateId', () {
      final view = ProviderSettingsView.parse(sampleView());
      final deepseek = view.templates
          .firstWhere((t) => t.templateId == 'deepseek');
      final zai =
          view.templates.firstWhere((t) => t.templateId == 'zai-api');
      expect(deepseek.name('zh-CN'), 'DeepSeek');
      expect(zai.name('en-US'), 'Z.ai API');
      // zh display falls back to en-US when the zh entry is missing.
      expect(zai.name('zh-CN'), 'Z.ai API');
      // Unknown locale chain still resolves to the id.
      expect(
        resolveProviderTemplateName(const {}, 'x-tpl', 'zh-CN'), 'x-tpl',
      );
    });

    test('template endpoint presets are readable', () {
      final view = ProviderSettingsView.parse(sampleView());
      final deepseek = view.templates
          .firstWhere((t) => t.templateId == 'deepseek');
      expect(deepseek.apiType, 'openai-chat-completions');
      expect(deepseek.baseUrl, 'https://api.deepseek.com/v1');
      expect(deepseek.apiKeyManagementUrl,
          'https://platform.deepseek.com/api_keys');
      expect(deepseek.isZhipuFamily, isFalse);
      expect(
          view.templates
              .firstWhere((t) => t.templateId == 'zai-api')
              .isZhipuFamily,
          isTrue);
    });
  });

  group('ProviderRevisionGuard', () {
    test('accepts strictly newer frames and rejects replays', () {
      final guard = ProviderRevisionGuard();
      expect(guard.accepts('[30,4]'), isTrue);
      guard.note('[30,4]');
      expect(guard.accepts('[30,4]'), isFalse, reason: 'same frame');
      expect(guard.accepts('[30,3]'), isFalse, reason: 'older personal');
      expect(guard.accepts('[29,99]'), isFalse, reason: 'older builtin');
      expect(guard.accepts('[30,5]'), isTrue);
      expect(guard.accepts('[31,0]'), isTrue);
    });

    test('unknown revision formats always apply', () {
      final guard = ProviderRevisionGuard();
      guard.note('[30,4]');
      expect(guard.accepts('weird'), isTrue);
      expect(guard.accepts(null), isTrue);
      expect(guard.accepts('[a,b]'), isTrue);
    });
  });

  group('providerRevisionPair', () {
    test('parses the combined revision string', () {
      expect(providerRevisionPair('[30,4]'), (30, 4));
      expect(providerRevisionPair('[ 30 , 4 ]'), (30, 4));
      expect(providerRevisionPair('[]'), isNull);
      expect(providerRevisionPair('[a,b]'), isNull);
      expect(providerRevisionPair(null), isNull);
    });
  });

  group('modelNumericLimits', () {
    test('prefers personal exact values over effective', () {
      final view = ProviderSettingsView.parse(sampleView());
      final p2 =
          view.customProviders.firstWhere((p) => p.providerId == 'p2');
      final limits = modelNumericLimits(p2.models.last);
      expect(limits.contextWindow, 64000);
      expect(limits.maxOutputTokens, 8192);
      // No personal override: the effective (builtin) value feeds prefill.
      final account = view.accountProviders.single;
      final builtinLimits = modelNumericLimits(account.models.first);
      expect(builtinLimits.contextWindow, 200000);
      expect(builtinLimits.maxOutputTokens, isNull);
    });
  });
}
