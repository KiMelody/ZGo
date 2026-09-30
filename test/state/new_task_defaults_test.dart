import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/state/new_task_defaults.dart';

void main() {
  // ConfigOption has no public constructor; everything goes through
  // WorkspacePrep.fromMap in the same shape the wire parser produces.
  WorkspacePrep prep({
    List<String>? models,
    List<String>? modes,
    List<String>? thoughts,
    Object? thoughtCurrent,
  }) =>
      WorkspacePrep.fromMap({
        'configOptions': [
          {
            'id': 'model',
            if (models != null)
              'options': [for (final m in models) {'value': m, 'name': m}],
          },
          {
            'id': 'mode',
            if (modes != null)
              'options': [for (final m in modes) {'value': m, 'name': m}],
          },
          {
            'id': 'thought_level',
            'currentValue': thoughtCurrent,
            if (thoughts != null)
              'options': [for (final t in thoughts) {'value': t, 'name': t}],
          },
        ],
      });

  group('mergeNewTaskConfig', () {
    test('perMessage overrides every persisted value (perMessage > persisted)',
        () {
      final merged = mergeNewTaskConfig(
        {'mode': 'plan', 'model': 'p/b', 'thought': 'high'},
        {'mode': 'yolo', 'model': 'p/a', 'thought': 'max'},
      );
      expect(merged, {'mode': 'plan', 'model': 'p/b', 'thought': 'high'});
    });

    test('per-message gaps fall back to persisted defaults', () {
      final merged = mergeNewTaskConfig(
        {'mode': 'plan'},
        {'mode': 'yolo', 'model': 'p/a', 'thought': 'max'},
      );
      expect(merged, {'mode': 'plan', 'model': 'p/a', 'thought': 'max'});
    });

    test('empty per-message strings count as unset', () {
      final merged = mergeNewTaskConfig(
        {'mode': '', 'model': '', 'thought': ''},
        {'mode': 'yolo'},
      );
      expect(merged, {'mode': 'yolo', 'model': '', 'thought': ''});
    });

    test('both empty → all-empty map (follow the desktop)', () {
      expect(mergeNewTaskConfig(null, const {}),
          {'mode': '', 'model': '', 'thought': ''});
    });
  });

  group('sanitizeNewTaskConfig', () {
    test('A2 baseline: nothing set → bare config with legal thought', () {
      final config = sanitizeNewTaskConfig(
        mergeNewTaskConfig(null, const {}),
        prep(
          models: ['builtin/glm'],
          modes: ['build'],
          thoughts: ['high'],
          thoughtCurrent: 'high',
        ),
      );
      expect(config, {'thought': 'high'});
    });

    test('A3: default model not among prep options → dropped, no throw', () {
      final config = sanitizeNewTaskConfig(
        {'model': 'other/gone', 'mode': '', 'thought': ''},
        prep(models: ['builtin/glm'], thoughtCurrent: 'high'),
      );
      expect(config.containsKey('provider'), isFalse);
      expect(config.containsKey('model'), isFalse);
      expect(config['thought'], 'high');
    });

    test('A3: valid model ships split provider/model', () {
      final config = sanitizeNewTaskConfig(
        {'model': 'builtin:zai/GLM-5.2', 'mode': '', 'thought': ''},
        prep(models: ['builtin:zai/GLM-5.2'], thoughtCurrent: 'high'),
      );
      expect(config['provider'], 'builtin:zai');
      expect(config['model'], 'GLM-5.2');
    });

    test('A3: prep without model options → model passes unvalidated', () {
      final config = sanitizeNewTaskConfig(
        {'model': 'custom/anything', 'mode': '', 'thought': ''},
        prep(models: null, thoughtCurrent: 'high'),
      );
      expect(config['provider'], 'custom');
      expect(config['model'], 'anything');
    });

    test('A4: mode outside prep options ∪ four tiers → dropped', () {
      final config = sanitizeNewTaskConfig(
        {'mode': 'sudo', 'model': '', 'thought': ''},
        prep(modes: ['build', 'plan'], thoughtCurrent: 'high'),
      );
      expect(config.containsKey('mode'), isFalse);
    });

    test('A4: four-tier vocabulary applies even when prep lacks it', () {
      final config = sanitizeNewTaskConfig(
        {'mode': 'yolo', 'model': '', 'thought': ''},
        prep(modes: null, thoughtCurrent: 'high'),
      );
      expect(config['mode'], 'yolo');
    });

    test('A4: prep-listed mode beyond four tiers is accepted', () {
      final config = sanitizeNewTaskConfig(
        {'mode': 'agent', 'model': '', 'thought': ''},
        prep(modes: ['build', 'agent'], thoughtCurrent: 'high'),
      );
      expect(config['mode'], 'agent');
    });

    test('A5: invalid thought falls back to prep currentValue', () {
      final config = sanitizeNewTaskConfig(
        {'thought': 'ultra', 'mode': '', 'model': ''},
        prep(thoughts: ['high', 'max'], thoughtCurrent: 'high'),
      );
      expect(config['thought'], 'high');
    });

    test('A5: invalid thought with no prep value → max', () {
      final config = sanitizeNewTaskConfig(
        {'thought': 'ultra', 'mode': '', 'model': ''},
        prep(thoughts: ['high'], thoughtCurrent: null),
      );
      expect(config['thought'], 'max');
    });

    test('A5: valid explicit thought wins', () {
      final config = sanitizeNewTaskConfig(
        {'thought': 'max', 'mode': '', 'model': ''},
        prep(thoughts: ['high', 'max'], thoughtCurrent: 'high'),
      );
      expect(config['thought'], 'max');
    });

    test('A7: prep null → no model, four-tier mode only, thought=max', () {
      final dropped = sanitizeNewTaskConfig(
        {'mode': 'agent', 'model': 'p/m', 'thought': ''},
        null,
      );
      expect(dropped.containsKey('provider'), isFalse);
      expect(dropped.containsKey('model'), isFalse);
      expect(dropped.containsKey('mode'), isFalse);
      expect(dropped['thought'], 'max');

      final kept = sanitizeNewTaskConfig(
        {'mode': 'plan', 'model': 'p/m', 'thought': ''},
        null,
      );
      expect(kept['mode'], 'plan');
      expect(kept['thought'], 'max');
    });
  });

  group('effectiveNewTaskThought', () {
    test('explicit legal pick wins over currentValue', () {
      expect(
        effectiveNewTaskThought(
          {'thought': 'max'},
          prep(thoughts: ['high', 'max'], thoughtCurrent: 'high'),
        ),
        'max',
      );
    });

    test('A5 chain: invalid explicit → currentValue → max', () {
      final p = prep(thoughts: ['high'], thoughtCurrent: 'high');
      expect(effectiveNewTaskThought({'thought': 'ultra'}, p), 'high');
      expect(effectiveNewTaskThought(null, p), 'high');
      expect(effectiveNewTaskThought(null, prep(thoughts: ['high'])), 'max');
      expect(effectiveNewTaskThought(null, null), 'max');
    });
  });
}
