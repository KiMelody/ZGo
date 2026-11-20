import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/chat/turn_navigator.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

/// Task 11-19 step 4 golden comparison: the GlobalKey-registry highlight must
/// agree with an independent full-tree traversal at every scroll position.
/// The reference implementation below re-derives the R7 visible-query rule
/// (design D6) through the tester: the uppermost built query whose top lies
/// in the viewport window wins; a built-only group below the viewport
/// (cacheExtent) never does; otherwise the nearest above the line.
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

/// The reference algorithm (R7 semantics), walked through the widget tree:
/// the uppermost query with its top inside `[viewportTop - 40,
/// viewportBottom)`; built-only groups below the viewport are skipped; with
/// nothing visible, the last query above the line wins.
int? traversalActiveIndex(WidgetTester tester) {
  final queries = navigator(tester).rowIds;
  final list = messageList();
  final viewportTop = tester.getTopLeft(list).dy;
  final viewportBottom = viewportTop + tester.getSize(list).height;
  double? belowTop;
  int? below;
  double? aboveTop;
  int? above;
  for (final group in tester.widgetList<ChatTurnGroup>(
    find.byType(ChatTurnGroup),
  )) {
    final first = group.rows.first['rowId'];
    if (first is! num) continue;
    final index = queries.indexOf(first.toInt());
    if (index < 0) continue;
    final top = tester.getTopLeft(find.byWidget(group)).dy;
    if (top >= viewportTop - 40 && top < viewportBottom) {
      if (belowTop == null || top < belowTop) {
        belowTop = top;
        below = index;
      }
    } else if (top < viewportTop - 40) {
      if (aboveTop == null || top > aboveTop) {
        aboveTop = top;
        above = index;
      }
    }
  }
  return below ?? above;
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

    // Opens pinned to the bottom: the last visible query wins.
    expect(navigator(tester).activeIndex, traversalActiveIndex(tester),
        reason: 'initial (bottom) position');
    final seen = <int?>{navigator(tester).activeIndex};

    // Walk up through several turns; each stop must agree with the
    // visible-query reference (uppermost visible, else nearest above).
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

  testWidgets(
      'a cacheExtent group below the viewport does not pre-highlight; the '
      'uppermost visible query does', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    // Two queries around one long answer: while the viewport sits inside the
    // long answer, the second query group can be built in the layout cache
    // BELOW the viewport — the R7 "not visible yet" case.
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '问题一', 'origin': 'realUser'},
      {
        'rowId': 2,
        'kind': 'assistantText',
        'text': List.filled(160, '长回答正文，持续铺满并溢出视口。').join('\n'),
      },
      {'rowId': 3, 'kind': 'userInput', 'text': '问题二', 'origin': 'realUser'},
      // Tail answer tall enough that query 2's group can still be parked
      // near the viewport top (the scroll must not clamp at the content end).
      {
        'rowId': 4,
        'kind': 'assistantText',
        'text': List.filled(30, '尾部回答行。').join('\n'),
      },
    ]);
    await tester.pumpAndSettle();

    // Start from the top: the open-frame follow can land past
    // maxScrollExtent while the tall answer is still extent-estimated (a
    // pre-existing anchor behavior, not this test's subject). At px 0 the
    // long-answer group's child layout is exact, so its offset + height
    // give query 2's content offset precisely.
    final controller = tester.widget<ListView>(messageList()).controller!;
    controller.jumpTo(0);
    await tester.pumpAndSettle();

    final listTop = tester.getTopLeft(messageList()).dy;
    final viewportHeight = tester.getSize(messageList()).height;
    final viewportBottom = listTop + viewportHeight;
    final answerGroup = find.byKey(
      const ValueKey('turn-2'),
      skipOffstage: false,
    );
    // Rows 1/2/3/4 each start their own group — the query bubble and its
    // answer are separate groups, so turn-2 spans the long answer.
    final nextGroupOffset =
        tester.getTopLeft(answerGroup).dy -
        listTop +
        tester.getSize(answerGroup).height;
    final nextGroup = find.byKey(
      const ValueKey('turn-3'),
      skipOffstage: false,
    );
    double nextTop() => tester.getTopLeft(nextGroup).dy;

    // Query 2's group top 120px BELOW the viewport bottom: inside the 250px
    // layout cache (built) but outside the visible viewport.
    controller.jumpTo(nextGroupOffset - viewportHeight - 120);
    await tester.pumpAndSettle();
    expect(nextTop(), closeTo(viewportBottom + 120, 2),
        reason: 'the parked group must stay built in the cacheExtent');
    expect(navigator(tester).activeIndex, 0,
        reason: 'cache-only group below the viewport: the reader is still '
            'in query 1\'s long answer');

    // Bring it into the viewport: now it is the uppermost VISIBLE query and
    // takes the highlight (query 1's group top sits far above the line).
    controller.jumpTo(nextGroupOffset - 120);
    await tester.pumpAndSettle();
    expect(nextTop(), closeTo(listTop + 120, 2));
    expect(navigator(tester).activeIndex, 1);
  });
}