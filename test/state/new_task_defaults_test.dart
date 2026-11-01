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

    test('model ids may contain "/": the composite splits on the FIRST slash '
        '(desktop FC semantics)', () {
      // The live accident shape: Command Code's model id is itself
      // "deepseek/deepseek-v4.1-flash", so the option value is a three-part
      // string. A trailing-slash split would corrupt both halves.
      const provider = 'ee6c256c-d8fa-4419-9ed4-bead8bf652bd';
      const value = '$provider/deepseek/deepseek-v4.1-flash';
      final config = sanitizeNewTaskConfig(
        {'model': value, 'mode': '', 'thought': ''},
        prep(models: [value], thoughtCurrent: 'high'),
      );
      expect(config['provider'], provider);
      expect(config['model'], 'deepseek/deepseek-v4.1-flash');
    });

    test('slash-less model keeps the current drop behavior', () {
      final config = sanitizeNewTaskConfig(
        {'model': 'bare-model', 'mode': '', 'thought': ''},
        prep(models: ['bare-model'], thoughtCurrent: 'high'),
      );
      expect(config.containsKey('provider'), isFalse);
      expect(config.containsKey('model'), isFalse);
    });

    test('A4: mode outside prep options ∪ fallback vocabulary → dropped', () {
      final config = sanitizeNewTaskConfig(
        {'mode': 'sudo', 'model': '', 'thought': ''},
        prep(modes: ['build', 'plan'], thoughtCurrent: 'high'),
      );
      expect(config.containsKey('mode'), isFalse);
    });

    test('A4: fallback vocabulary applies even when prep lacks it', () {
      final config = sanitizeNewTaskConfig(
        {'mode': 'yolo', 'model': '', 'thought': ''},
        prep(modes: null, thoughtCurrent: 'high'),
      );
      expect(config['mode'], 'yolo');
    });

    test('A4: prep-listed mode beyond the fallback vocabulary is accepted', () {
      final config = sanitizeNewTaskConfig(
        {'mode': 'agent', 'model': '', 'thought': ''},
        prep(modes: ['build', 'agent'], thoughtCurrent: 'high'),
      );
      expect(config['mode'], 'agent');
    });

    test('A4: guarded (desktop 3.15.1) passes the fallback vocabulary', () {
      final config = sanitizeNewTaskConfig(
        {'mode': 'guarded', 'model': '', 'thought': ''},
        prep(modes: null, thoughtCurrent: 'high'),
      );
      expect(config['mode'], 'guarded');
    });

    test('A4: legacy edit value stays accepted (old-storage compat)', () {
      final config = sanitizeNewTaskConfig(
        {'mode': 'edit', 'model': '', 'thought': ''},
        prep(modes: null, thoughtCurrent: 'high'),
      );
      expect(config['mode'], 'edit');
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

    test('A7: prep null → no model, fallback-vocabulary mode only, thought=max', () {
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

  group('sanitizeNewTaskConfig explicitKeys (user picks vs seeds)', () {
    test('explicit model ships when prep is null', () {
      final config = sanitizeNewTaskConfig(
        {'model': 'uuid/deepseek/deepseek-v4.1-flash', 'mode': '', 'thought': ''},
        null,
        explicitKeys: {'model'},
      );
      expect(config['provider'], 'uuid');
      expect(config['model'], 'deepseek/deepseek-v4.1-flash');
      expect(config['thought'], 'max');
    });

    test('explicit model ships when prep options no longer list it', () {
      final config = sanitizeNewTaskConfig(
        {'model': 'uuid/deepseek-v4.1-flash', 'mode': '', 'thought': ''},
        prep(models: ['builtin/glm'], thoughtCurrent: 'high'),
        explicitKeys: {'model'},
      );
      expect(config['provider'], 'uuid');
      expect(config['model'], 'deepseek-v4.1-flash');
    });

    test('seeded model (no explicit key) keeps dropping without prep', () {
      final config = sanitizeNewTaskConfig(
        {'model': 'uuid/deepseek-v4.1-flash', 'mode': '', 'thought': ''},
        null,
      );
      expect(config.containsKey('provider'), isFalse);
      expect(config.containsKey('model'), isFalse);
    });

    test('explicit mode ships without prep / outside the vocabulary', () {
      final config = sanitizeNewTaskConfig(
        {'mode': 'agent', 'model': '', 'thought': ''},
        null,
        explicitKeys: {'mode'},
      );
      expect(config['mode'], 'agent');
    });

    test('seeded mode outside the vocabulary still drops with prep', () {
      final config = sanitizeNewTaskConfig(
        {'mode': 'agent', 'model': '', 'thought': ''},
        prep(modes: ['build'], thoughtCurrent: 'high'),
      );
      expect(config.containsKey('mode'), isFalse);
    });

    test('explicit thought ships verbatim when prep is null', () {
      final config = sanitizeNewTaskConfig(
        {'mode': '', 'model': '', 'thought': 'high'},
        null,
        explicitKeys: {'thought'},
      );
      expect(config['thought'], 'high');
    });

    test('seeded thought keeps the follow-the-desktop chain', () {
      final config = sanitizeNewTaskConfig(
        {'mode': '', 'model': '', 'thought': 'high'},
        prep(thoughts: ['max'], thoughtCurrent: 'max'),
      );
      expect(config['thought'], 'max');
    });
  });

  group('explicitNewTaskKeys', () {
    test('every non-empty per-message value marks its key', () {
      expect(
        explicitNewTaskKeys(
          {'mode': 'plan', 'model': 'p/m', 'thought': 'high'},
        ),
        {'mode', 'model', 'thought'},
      );
    });

    test('missing / empty per-message values are not explicit', () {
      expect(explicitNewTaskKeys({'model': '', 'mode': 'yolo'}), {'mode'});
      expect(explicitNewTaskKeys(null), isEmpty);
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
