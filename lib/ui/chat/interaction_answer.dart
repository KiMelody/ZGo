import 'package:flutter/foundation.dart';

/// Ask-question collection semantics for `userInput` interaction cards,
/// lifted verbatim out of `_QuestionsViewState` (task
/// 10-01-interaction-answer): the toggle rules, the custom-input
/// exclusivity and the wire-content assembly used to live in the page's
/// build branches and could only be exercised by pumping the whole
/// ChatPage — they are pure rules, so they live here as a value object +
/// one assembly function (the widget keeps controllers / focus nodes and
/// the IME focus choreography; this file keeps the semantics only).
@immutable
class InteractionAnswers {
  const InteractionAnswers({
    this.selections = const {},
    this.customOpen = const {},
    this.customText = const {},
  });

  /// Collected option values per question index — nothing resolves until
  /// the explicit submit.
  final Map<int, List<String>> selections;

  /// Questions with the inline custom-answer input expanded.
  final Set<int> customOpen;

  /// Semantic copy of the open custom inputs' text, mirrored from the
  /// view buffer on every edit ([setCustom]) and dropped by every collapse
  /// — no hidden state survives a collapse.
  final Map<int, String> customText;

  /// Unified toggle: tapping the picked option deselects it (single-select
  /// may return to "nothing picked"), tapping another single-select option
  /// re-chooses. Any option tap collapses the custom input and drops its
  /// text — single-select options and the custom answer are mutually
  /// exclusive.
  InteractionAnswers toggleOption(int index, Map question, String value) {
    final selected = List<String>.of(selections[index] ?? const []);
    if (question['multiSelect'] == true) {
      // Set semantics: a duplicate toggle must not grow the list.
      selected.contains(value) ? selected.remove(value) : selected.add(value);
    } else if (selected.contains(value)) {
      selected.remove(value);
    } else {
      selected
        ..clear()
        ..add(value);
    }
    return InteractionAnswers(
      selections: Map<int, List<String>>.of(selections)..[index] = selected,
      // The collapse half of the old _closeCustom: the open flag and the
      // text die together with the input.
      customOpen: Set<int>.of(customOpen)..remove(index),
      customText: Map<int, String>.of(customText)..remove(index),
    );
  }

  /// Custom chip: expands the inline input (single-select clears the picked
  /// option first — multiSelect keeps custom as an extra coexisting answer);
  /// tapping again collapses and clears. Focus stays a widget concern (the
  /// explicit next-frame request — `autofocus` loses the race against slow
  /// OEM IME startup, notably Xiaomi/HyperOS).
  InteractionAnswers toggleCustom(int index, Map question) {
    if (customOpen.contains(index)) {
      return InteractionAnswers(
        selections: selections,
        customOpen: Set<int>.of(customOpen)..remove(index),
        customText: Map<int, String>.of(customText)..remove(index),
      );
    }
    final nextSelections = Map<int, List<String>>.of(selections);
    if (question['multiSelect'] != true) nextSelections.remove(index);
    return InteractionAnswers(
      selections: nextSelections,
      customOpen: Set<int>.of(customOpen)..add(index),
      customText: customText,
    );
  }

  /// The single sync point from the view buffer (the widget's onChanged);
  /// collapse paths never route through here — they drop the entry instead.
  InteractionAnswers setCustom(int index, String text) => InteractionAnswers(
    selections: selections,
    customOpen: customOpen,
    customText: Map<int, String>.of(customText)..[index] = text,
  );

  /// A question's answer: selected option values ∪ (custom input open with
  /// non-blank text ? [text] : ∅) — blank text is not an answer.
  List<String> answersOf(int index) {
    final answer = List<String>.of(selections[index] ?? const []);
    if (customOpen.contains(index)) {
      final text = (customText[index] ?? '').trim();
      if (text.isNotEmpty) answer.add(text);
    }
    return answer;
  }
}

/// `buildBotElicitationContent` shape: `answers` keyed by question
/// text with comma-joined option labels, `answer_N` carrying option values
/// (scalar for single-select, list for multiSelect), `answer` only for the
/// single-question form. Custom text joins verbatim (it is its own label).
/// Unanswered questions are silently skipped; nothing answered yields just
/// the empty `answers` map (the explicit "no answer" submit).
Map<String, dynamic> buildInteractionContent(
  List<Map> questions,
  InteractionAnswers answers,
) {
  final content = <String, dynamic>{};
  final answerTexts = <String, String>{};
  for (var i = 0; i < questions.length; i++) {
    final answer = answers.answersOf(i);
    if (answer.isEmpty) continue;
    final q = questions[i];
    final multi = q['multiSelect'] == true;
    final options = (q['options'] as List?) ?? const [];
    String labelOf(String value) {
      for (final o in options) {
        if (o is Map && '${o['value']}' == value) {
          return '${o['label'] ?? o['value'] ?? value}';
        }
      }
      return value;
    }

    answerTexts['${q['label'] ?? q['question'] ?? q['value'] ?? 'answer_$i'}'] =
        answer.map(labelOf).join(', ');
    content['answer_$i'] = multi ? answer : answer.first;
  }
  content['answers'] = answerTexts;
  if (questions.length == 1 && content.containsKey('answer_0')) {
    content['answer'] = content['answer_0'];
  }
  return content;
}
