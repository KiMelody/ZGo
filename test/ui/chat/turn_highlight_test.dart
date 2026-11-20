import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/chat/turn_navigator.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

/// Task 11-19 step 4 golden comparison: the GlobalKey-registry highlight must
/// agree with the retired full-tree traversal at every scroll position. The
/// reference implementation below is the OLD algorithm, rebuilt against the
/// widget tree through the tester.
///
/// Task 10-14 frame contract: scroll notifications fire before layout, the
/// page computes the highlight post-frame; `pumpAndSettle` drives that.

Widget wrap(Widget child, {String locale = 'zh-CN'}) => MaterialApp(
  theme: buildDarkTheme(),
  darkTheme: buildDarkTheme(),
  builder: (context, child) => UiSettingsProvider(
    settings: UiSettings()..locale = locale,
    child: child!,
  ),
  home: child,
);

/// The message list's ListView — the turn navigator strip mounts its own
/// scrollable as a later sibling, so unqualified `find.byType(ListView)`
/// matches two.
Finder messageList() => find.byType(ListView).first;

TurnNavigator navigator(WidgetTester tester) =>
    tester.widget<TurnNavigator>(find.byType(TurnNavigator));

/// The pre-change algorithm: walk every built ChatTurnGroup in list order,
/// keep the last query above the viewport top, stop at the first at/over it.
int? traversalActiveIndex(WidgetTester tester) {
  final queries = navigator(tester).rowIds;
  final viewportTop = tester.getTopLeft(messageList()).dy;
  int? active;
  for (final group in tester.widgetList<ChatTurnGroup>(
    find.byType(ChatTurnGroup),
  )) {
    final first = group.rows.first['rowId'];
    if (first is! num) continue;
    final index = queries.indexOf(first.toInt());
    if (index < 0) continue;
    final top = tester.getTopLeft(find.byWidget(group)).dy;
    if (top >= viewportTop - 40) {
      active = index;
      break;
    }
    active = index;
  }
  return active;
}

List<Map<String, dynamic>> conversationRows() {
  final rows = <Map<String, dynamic>>[];
  var id = 1;
  for (var q = 1; q <= 8; q++) {
    rows.add({'rowId': id++, 'kind': 'userInput', 'text': '问题 $q'});
    rows.add({
      'rowId': id++,
      'kind': 'assistantText',
      'text': List.filled(12, '回答 $q 的第二段内容').join('\n'),
    });
  }
  return rows;
}

void main() {
  testWidgets('highlight equals the full-tree traversal at every scroll stop',
      (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(conversationRows());
    await tester.pumpAndSettle();

    final queries = navigator(tester).rowIds;
    expect(queries, hasLength(8));

    // Opens pinned to the bottom: the nearest query above the line wins.
    expect(navigator(tester).activeIndex, traversalActiveIndex(tester),
        reason: 'initial (bottom) position');
    final seen = <int?>{navigator(tester).activeIndex};

    // Walk up through several turns; each stop must agree with the
    // traversal reference (first query at/over the line, else nearest above).
    for (var step = 0; step < 8; step++) {
      await tester.drag(messageList(), const Offset(0, 180));
      await tester.pumpAndSettle();
      final expected = traversalActiveIndex(tester);
      expect(navigator(tester).activeIndex, expected,
          reason: 'scroll-up stop $step: queries=$queries');
      seen.add(navigator(tester).activeIndex);
    }
    expect(seen.length, greaterThanOrEqualTo(2),
        reason: 'the walk must cross a turn boundary; sampled $seen');

    // And back down a little.
    await tester.drag(messageList(), const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(navigator(tester).activeIndex, traversalActiveIndex(tester),
        reason: 'scroll-down stop');
  });

  testWidgets('a new query appended while pinned at the bottom updates the '
      'highlight', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    final rows = conversationRows();
    gateway.feedSnapshot(rows);
    await tester.pumpAndSettle();
    expect(navigator(tester).activeIndex, traversalActiveIndex(tester));

    // Directory growth (user sends a new message): the highlight follows the
    // appended query through the post-frame pass.
    rows.add({'rowId': 100, 'kind': 'userInput', 'text': '追加问题'});
    rows.add({
      'rowId': 101,
      'kind': 'assistantText',
      'text': '追加回答',
    });
    gateway.feedSnapshot(rows);
    await tester.pumpAndSettle();

    expect(navigator(tester).rowIds.last, 100);
    expect(navigator(tester).activeIndex, traversalActiveIndex(tester));
  });
}