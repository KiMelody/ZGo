import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/timeline.dart';

/// Task 11-19 chat-scroll wave 2 step 3: [groupChatRows] now repairs the
/// persisted row inversion inline (single pass) instead of consuming the
/// fully materialized [repairInvertedToolOrder] output. This golden test
/// pins item-for-item equivalence with the old two-pass composition,
/// including the inverted tool order repair cases, across the boundary
/// shapes that matter (user turns, turn headers, timeline markers, keyless
/// attachments, multiple messages per turn, idempotence).
void main() {
  Map<String, dynamic> row(
    int id,
    String kind, {
    String? ar,
    Map<String, dynamic>? extra,
  }) => {
    'rowId': id,
    'kind': kind,
    if (ar != null) 'assistantResponseId': ar,
    ...?extra,
  };

  /// The pre-change pipeline: repair the whole list, then partition.
  List<List<Map<String, dynamic>>> reference(
    List<Map<String, dynamic>> rows,
  ) {
    final groups = <List<Map<String, dynamic>>>[];
    List<Map<String, dynamic>>? current;
    for (final row in repairInvertedToolOrder(rows)) {
      final kind = row['kind'];
      if (kind == 'timelineMarker') {
        current = null;
        groups.add([row]);
        continue;
      }
      final isUser = kind == 'userInput';
      final startsGroup =
          isUser || current == null || current.first['kind'] == 'userInput';
      if (startsGroup) {
        current = [row];
        groups.add(current);
      } else {
        current.add(row);
      }
    }
    return groups;
  }

  void expectSameGroups(
    List<List<Map<String, dynamic>>> actual,
    List<List<Map<String, dynamic>>> expected,
  ) {
    expect(actual.length, expected.length, reason: 'group count');
    for (var g = 0; g < expected.length; g++) {
      expect(actual[g].length, expected[g].length, reason: 'group $g length');
      for (var i = 0; i < expected[g].length; i++) {
        expect(identical(actual[g][i], expected[g][i]), isTrue,
            reason: 'group $g item $i must be the same row instance');
      }
    }
  }

  test('canonical order is a no-op', () {
    final rows = [
      row(1, 'userInput'),
      row(2, 'turnHeader'),
      row(3, 'reasoning', ar: 'm1'),
      row(4, 'assistantText', ar: 'm1'),
      row(5, 'toolCall', ar: 'm1'),
    ];
    expectSameGroups(groupChatRows(rows), reference(rows));
  });

  test('inverted tool order inside one message run is repaired', () {
    final rows = [
      row(1, 'userInput'),
      row(2, 'turnHeader'),
      row(3, 'toolCall', ar: 'm1'),
      row(4, 'reasoning', ar: 'm1'),
      row(5, 'assistantText', ar: 'm1'),
    ];
    final grouped = groupChatRows(rows);
    expectSameGroups(grouped, reference(rows));
    // Same group, canonical class order inside it.
    expect([for (final r in grouped[1]) r['rowId']], [2, 4, 5, 3]);
  });

  test('keyless rows ride their run; boundaries stay put', () {
    final rows = [
      row(1, 'assistantText', ar: 'm1'),
      row(2, 'subagent'), // keyless, inside the run
      row(3, 'toolCall', ar: 'm1'),
      row(4, 'reasoning', ar: 'm1'),
      row(5, 'timelineMarker'),
      row(6, 'assistantText', ar: 'm2'),
      row(7, 'turnHeader'),
      row(8, 'userInput'),
      row(9, 'assistantText', ar: 'm3'),
      row(10, 'toolCall', ar: 'm3'),
      row(11, 'reasoning', ar: 'm3'),
    ];
    final grouped = groupChatRows(rows);
    expectSameGroups(grouped, reference(rows));
  });

  test('multiple messages in one turn stay in one group', () {
    final rows = [
      row(1, 'userInput'),
      row(2, 'turnHeader'),
      row(3, 'assistantText', ar: 'm1'),
      row(4, 'toolCall', ar: 'm2'),
      row(5, 'reasoning', ar: 'm2'),
      row(6, 'assistantText', ar: 'm2'),
    ];
    expectSameGroups(groupChatRows(rows), reference(rows));
  });

  test('markers split groups; user rows always start one', () {
    final rows = [
      row(1, 'assistantText', ar: 'm1'),
      row(2, 'timelineMarker'),
      row(3, 'assistantText', ar: 'm1'),
      row(4, 'userInput'),
      row(5, 'userInput'),
      row(6, 'reasoning', ar: 'm1'),
    ];
    expectSameGroups(groupChatRows(rows), reference(rows));
  });

  test('empty, single and singleton-keyed inputs', () {
    expect(groupChatRows(const []), isEmpty);
    final single = [row(1, 'assistantText', ar: 'm1')];
    expectSameGroups(groupChatRows(single), reference(single));
    final keyless = [row(1, 'assistantText')];
    expectSameGroups(groupChatRows(keyless), reference(keyless));
  });

  test('idempotent under its own output order', () {
    final rows = [
      row(1, 'userInput'),
      row(2, 'toolCall', ar: 'm1'),
      row(3, 'reasoning', ar: 'm1'),
      row(4, 'assistantText', ar: 'm1'),
      row(5, 'toolCall', ar: 'm1'),
      row(6, 'subagent'),
      row(7, 'assistantText', ar: 'm2'),
      row(8, 'reasoning', ar: 'm2'),
    ];
    final once = groupChatRows(rows);
    final flattened = [for (final g in once) ...g];
    expectSameGroups(groupChatRows(flattened), reference(flattened));
    expectSameGroups(groupChatRows(flattened), once);
  });
}