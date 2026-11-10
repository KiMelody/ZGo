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

  /// Per-model thought table (design 11-09 §1): the desktop builder emits
  /// `modelThoughtLevels` / `modelDefaultThoughtLevel` only when the model
  /// has reasoning levels, so every shape other than a non-empty string
  /// array must read as "no table" (null) — the callers keep their fallback
  /// chains for those models.
  group('ConfigOptionValue modelThoughtLevels (wire fixture, design 11-09)',
      () {
    WorkspacePrep prepWith(Map<String, dynamic> option) =>
        WorkspacePrep.fromMap({
          'configOptions': [
            {
              'id': 'model',
              'name': 'Model',
              'currentValue': 'builtin/glm-5.2',
              'options': [
                {'value': 'builtin/glm-5.2', 'name': 'GLM-5.2', ...option},
              ],
            },
          ],
          'slashCommands': <Map<String, dynamic>>[],
        });

    test('parses both fields off the wire when present', () {
      final value = prepWith({
        'modelThoughtLevels': ['low', 'high', 'max'],
        'modelDefaultThoughtLevel': 'max',
      }).option('model')!.options.single;

      expect(value.modelThoughtLevels, ['low', 'high', 'max']);
      expect(value.modelDefaultThoughtLevel, 'max');
    });

    test('an absent key degrades to null (the conditional-spread form)', () {
      final value = prepWith(const {}).option('model')!.options.single;

      expect(value.modelThoughtLevels, isNull);
      expect(value.modelDefaultThoughtLevel, isNull);
    });

    test('an empty array is the same "no table" answer as an absent key', () {
      final value = prepWith(const {
        'modelThoughtLevels': <String>[],
      }).option('model')!.options.single;

      expect(value.modelThoughtLevels, isNull);
    });

    test('a wrong-typed value degrades to null instead of throwing', () {
      final value = prepWith(const {
        'modelThoughtLevels': 'low,high',
        'modelDefaultThoughtLevel': 42,
      }).option('model')!.options.single;

      expect(value.modelThoughtLevels, isNull);
      expect(value.modelDefaultThoughtLevel, isNull);
    });

    test('the public constructor carries synthesized levels (spec rather '
        'than wire drift)', () {
      final value = ConfigOptionValue(
        value: 'builtin/glm-5.2',
        name: 'GLM-5.2',
        modelThoughtLevels: const ['low', 'max'],
        modelDefaultThoughtLevel: 'low',
      );

      expect(value.modelThoughtLevels, ['low', 'max']);
      expect(value.modelDefaultThoughtLevel, 'low');
    });
  });

  /// Task-row `lastError` getters (task 11-08-error-detail): the chat error
  /// preview / detail sheet read message / code / traceId / attribution off
  /// the same raw meta the Copy-TraceID surface already used. Every getter
  /// is a defensive read: absent, wrong-typed and blank values all answer
  /// null so callers can gate on "null means don't render".
  group('SessionEntry.lastError* (task-row error meta)', () {
    SessionEntry entryWith(Object? lastError) => SessionEntry({
          'sessionId': 's1',
          'lastError': lastError,
        });

    test('a complete meta answers every field verbatim', () {
      final entry = entryWith({
        'message': '429 Rate limit exceeded',
        'code': '429',
        'traceId': 'trc_9f2k',
        'attribution': 'provider',
        'taskId': 't1',
      });

      expect(entry.lastErrorMessage, '429 Rate limit exceeded');
      expect(entry.lastErrorCode, '429');
      expect(entry.lastErrorTraceId, 'trc_9f2k');
      expect(entry.lastErrorAttribution, 'provider');
    });

    test('message-only meta: message answers, the rest stay null', () {
      final entry = entryWith({'message': 'boom'});

      expect(entry.lastErrorMessage, 'boom');
      expect(entry.lastErrorCode, isNull);
      expect(entry.lastErrorTraceId, isNull);
      expect(entry.lastErrorAttribution, isNull);
    });

    test('absent / non-map / null meta answers null everywhere', () {
      for (final raw in [null, 'not-a-map', 42, const <String, dynamic>{}]) {
        final entry = entryWith(raw);
        expect(entry.lastErrorMessage, isNull, reason: 'raw=$raw');
        expect(entry.lastErrorCode, isNull, reason: 'raw=$raw');
        expect(entry.lastErrorTraceId, isNull, reason: 'raw=$raw');
        expect(entry.lastErrorAttribution, isNull, reason: 'raw=$raw');
      }
    });

    test('blank and wrong-typed fields degrade to null (never "null")', () {
      final entry = entryWith({
        'message': '   ',
        'code': 429,
        'traceId': '',
        'attribution': <String>[],
      });

      expect(entry.lastErrorMessage, isNull,
          reason: 'a whitespace-only message has nothing to preview');
      expect(entry.lastErrorCode, isNull);
      expect(entry.lastErrorTraceId, isNull);
      expect(entry.lastErrorAttribution, isNull);
    });

    test('message keeps internal whitespace and trailing text as-is', () {
      // Only TRIM decides emptiness — the rendered copy is the wire string
      // (the preview ellipsizes, the sheet shows it verbatim).
      final entry = entryWith({'message': 'line one\n  line two  '});
      expect(entry.lastErrorMessage, 'line one\n  line two  ');
    });

    test('getters survive the relay-task factory whitelist rebuild', () {
      final entry = SessionEntry.fromRelayTask({
        'taskId': 't1',
        'title': 'relay',
        'displayStatus': 'error',
        'lastError': {
          'message': 'createSession rejected',
          'code': 'no_model',
          'traceId': 'tr-9',
          'attribution': 'relay',
        },
      });

      expect(entry.lastErrorMessage, 'createSession rejected');
      expect(entry.lastErrorCode, 'no_model');
      expect(entry.lastErrorTraceId, 'tr-9');
      expect(entry.lastErrorAttribution, 'relay');
    });
  });
}
