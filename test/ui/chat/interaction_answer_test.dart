// Pure-Dart coverage for lib/ui/chat/interaction_answer.dart: the
// ask-question collection rules + wire-content assembly lifted out of
// `_QuestionsViewState` (task 10-01-interaction-answer). They only ever
// lived as widget tests because the collector hid inside the page's build
// branches — every assertion below comes verbatim from the 8 widget tests
// this matrix replaces; the 10 chat_page smokes stay as the behavior base.
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/interaction_answer.dart';

/// Form-style `userInput` fixtures (the `questions` payload field names:
/// `label`/`question` question text, `multiSelect` flag and `value`/`label`
/// options) — the same shapes the chat_page_test pump helper feeds.
const envQuestion = {
  'value': 'env',
  'label': '选择环境',
  'multiSelect': false,
  'options': [
    {'value': 'dev', 'label': '开发'},
    {'value': 'prod', 'label': '生产'},
  ],
};

const extrasQuestion = {
  'value': 'extras',
  'label': '附加组件',
  'multiSelect': true,
  'options': [
    {'value': 'lint', 'label': 'Lint'},
    {'value': 'test', 'label': '测试'},
  ],
};

void main() {
  group('collection value chain (toggle rules × single/multi × custom)', () {
    test('questions collect locally and submit full content once', () {
      var answers = const InteractionAnswers();
      answers = answers.toggleOption(0, envQuestion, 'dev');
      answers = answers.toggleOption(1, extrasQuestion, 'lint');
      answers = answers.toggleOption(1, extrasQuestion, 'test');

      // buildBotElicitationContent shape, whole-map assertion.
      expect(buildInteractionContent([envQuestion, extrasQuestion], answers), {
        'answers': {'选择环境': '开发', '附加组件': 'Lint, 测试'},
        'answer_0': 'dev',
        'answer_1': ['lint', 'test'],
      });
    });

    test('unanswered questions are skipped, multiSelect unchecks', () {
      var answers = const InteractionAnswers();
      answers = answers.toggleOption(1, extrasQuestion, 'lint');
      answers = answers.toggleOption(1, extrasQuestion, 'test');
      answers = answers.toggleOption(1, extrasQuestion, 'lint'); // uncheck again

      // Question 0 absent → no answers entry and no answer_0.
      expect(buildInteractionContent([envQuestion, extrasQuestion], answers), {
        'answers': {'附加组件': '测试'},
        'answer_1': ['test'],
      });
    });

    test('single-select re-choice overrides the first pick', () {
      var answers = const InteractionAnswers();
      answers = answers.toggleOption(0, envQuestion, 'dev');
      answers = answers.toggleOption(0, envQuestion, 'prod');

      expect(buildInteractionContent([envQuestion, extrasQuestion], answers), {
        'answers': {'选择环境': '生产'},
        'answer_0': 'prod',
      });
    });

    test('single toggle-off clears; empty submit is the no-answer send', () {
      var answers = const InteractionAnswers();
      answers = answers.toggleOption(0, envQuestion, 'dev');
      expect(answers.answersOf(0), isNotEmpty); // 已答 1/1
      answers = answers.toggleOption(0, envQuestion, 'dev'); // unified toggle
      expect(answers.answersOf(0), isEmpty); // counter hidden again

      // Nothing answered: the explicit "no answer" submit.
      expect(buildInteractionContent([envQuestion], answers), {'answers': {}});
    });

    test('single custom input is exclusive and collapse always clears', () {
      var answers = const InteractionAnswers();
      answers = answers.toggleOption(0, envQuestion, 'dev');
      // Expanding custom is the custom pick: the option deselects (mutually
      // exclusive).
      answers = answers.toggleCustom(0, envQuestion);
      expect(answers.answersOf(0), isEmpty);
      answers = answers.setCustom(0, '本地容器');
      expect(answers.answersOf(0), ['本地容器']);

      // Tapping an option collapses the input and drops its text.
      answers = answers.toggleOption(0, envQuestion, 'prod');
      expect(answers.customOpen.contains(0), isFalse);
      expect(answers.answersOf(0), ['prod']);

      // ...and re-expanding custom clears it again (mutual exclusion).
      answers = answers.toggleCustom(0, envQuestion);
      expect(answers.answersOf(0), isEmpty);

      // Tapping the custom chip again is the second collapse path: it must
      // clear too, so a later re-expand comes back empty (no hidden state).
      answers = answers.setCustom(0, '临时脚本');
      answers = answers.toggleCustom(0, envQuestion);
      expect(answers.customOpen.contains(0), isFalse);
      answers = answers.toggleCustom(0, envQuestion);
      expect(answers.answersOf(0), isEmpty);

      // Custom open but blank (whitespace counts as blank): blank text is
      // not an answer, so this is the no-answer content.
      answers = answers.setCustom(0, '   ');
      expect(answers.answersOf(0), isEmpty);
      expect(buildInteractionContent([envQuestion], answers), {'answers': {}});
    });

    test('multi custom input coexists with the checked options', () {
      var answers = const InteractionAnswers();
      answers = answers.toggleOption(0, extrasQuestion, 'lint');
      // Multi-select: custom is an extra — Lint stays checked next to it,
      // and both go into the answer array together (已答 stays 1/1).
      answers = answers.toggleCustom(0, extrasQuestion);
      expect(answers.answersOf(0), ['lint']);
      answers = answers.setCustom(0, '冒烟脚本');
      expect(answers.answersOf(0), ['lint', '冒烟脚本']);

      expect(buildInteractionContent([extrasQuestion], answers), {
        'answers': {'附加组件': 'Lint, 冒烟脚本'},
        'answer_0': ['lint', '冒烟脚本'],
        // Single-question form folds answer_0 into the flat answer.
        'answer': ['lint', '冒烟脚本'],
      });
    });
  });

  group('wire content (buildInteractionContent)', () {
    test('single-question submit carries the flat answer field', () {
      var answers = const InteractionAnswers();
      answers = answers.toggleOption(0, envQuestion, 'dev');

      expect(buildInteractionContent([envQuestion], answers), {
        'answers': {'选择环境': '开发'},
        'answer_0': 'dev',
        'answer': 'dev',
      });
    });

    test('custom text submits verbatim as its label and value', () {
      var answers = const InteractionAnswers();
      answers = answers.toggleCustom(0, envQuestion);
      answers = answers.setCustom(0, '本地容器');
      expect(answers.answersOf(0), ['本地容器']); // 已答 1/1

      expect(buildInteractionContent([envQuestion], answers), {
        'answers': {'选择环境': '本地容器'},
        'answer_0': '本地容器',
        'answer': '本地容器',
      });
    });
  });
}
