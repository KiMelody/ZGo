import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/jump_to_bottom_button.dart';
import 'package:zgo/ui/chat/turn_navigator.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/recording_chat_gateway.dart';

/// Chat-page fake, same construction as chat_page_test (real
/// [ConversationState] fed by hand through the recording gateway).
class FakeChatGateway extends RecordingChatGateway {}

Widget wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  builder: (context, child) =>
      UiSettingsProvider(settings: UiSettings(), child: child!),
  home: child,
);

Widget mount(TurnNavigator nav, {double height = 600}) =>
    wrap(Scaffold(body: SizedBox(height: height, child: nav)));

TurnNavigator nav(
  List<int> rowIds, {
  int? active,
  bool canLoadOlder = false,
  void Function(int)? onJump,
}) => TurnNavigator(
  rowIds: rowIds,
  activeIndex: active,
  canLoadOlder: canLoadOlder,
  onJump: onJump ?? (_) {},
);

/// Tappable cells: thin cells when collapsed, enlarged cells while the
/// overlay is open. The outside-tap barrier also carries an onTap —
/// excluded by its key.
Finder get cells => find.descendant(
  of: find.byType(TurnNavigator),
  matching: find.byWidgetPredicate(
    (w) =>
        w is GestureDetector &&
        w.onTap != null &&
        w.key != TurnNavigator.barrierKey,
  ),
);

/// The expanded float panel: the only DecoratedBox in the navigator with
/// a float shadow (R3 removed the hairline border stroke).
Finder get overlayPanel => find.descendant(
  of: find.byType(TurnNavigator),
  matching: find.byWidgetPredicate(
    (w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).boxShadow != null,
  ),
);

/// The ghost placeholder cell (canLoadOlder): the only decorated box in
/// the navigator painted at the fainter [TurnNavigator.ghostAlpha] tone.
Finder ghostCell(WidgetTester tester) {
  final context = tester.element(find.byType(TurnNavigator));
  final ghostColor = ZInk.ghost(
    context,
  ).withValues(alpha: TurnNavigator.ghostAlpha);
  return find.descendant(
    of: find.byType(TurnNavigator),
    matching: find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == ghostColor,
    ),
  );
}

/// A session with deliberately WILD row-height variance (chat-conventions
/// §9: uniform row heights cannot catch landing bugs): long markdown
/// answers, tool cards, reasoning blocks — query rowIds at `i * 10`.
List<Map<String, dynamic>> varianceSession({int queries = 8}) => [
  for (var i = 0; i < queries; i++) ...[
    {
      'rowId': i * 10,
      'kind': 'userInput',
      'text': '问题 $i',
      'origin': 'realUser',
    },
    if (i % 3 == 0)
      {
        'rowId': i * 10 + 1,
        'kind': 'assistantText',
        'text':
            '回答 $i：${'这是一段刻意拉长的回答文本，用来制造行高方差，让落点断言能抓住均匀高度下藏不住的估算误差。' * 12}',
      }
    else if (i % 3 == 1) ...[
      {
        'rowId': i * 10 + 1,
        'kind': 'toolCall',
        'toolName': 'Bash',
        'status': 'success',
        'inputText': '{"command": "flutter test"}',
        'output': 'All tests passed!',
      },
      {'rowId': i * 10 + 2, 'kind': 'assistantText', 'text': '短回答 $i'},
    ] else ...[
      {
        'rowId': i * 10 + 1,
        'kind': 'reasoning',
        'text': '推理 $i：先看构建日志，再定位失败用例，最后修复断言。',
      },
      {'rowId': i * 10 + 2, 'kind': 'assistantText', 'text': '中回答 $i'},
    ],
  ],
];

Future<ScrollController> pumpVariancePage(
  WidgetTester tester,
  FakeChatGateway gateway, {
  int queries = 8,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    wrap(
      ChatPage(
        gateway: gateway,
        sessionId: 's1',
        title: 't',
        // Pin the terminal-footer confirm window beyond the test: the
        // footer popping in per group (3s default) grows every group
        // mid-test and shifts content AFTER a measured landing.
        turnFooterConfirmWindow: const Duration(days: 1),
      ),
    ),
  );
  gateway.feedSnapshot(varianceSession(queries: queries));
  await tester.pumpAndSettle();
  // The message list is the FIRST ListView in the Stack (the navigator
  // strip's own scrollable is a later sibling).
  return tester.widget<ListView>(find.byType(ListView).first).controller!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('turnNavigatorQueryRowIds (directory derivation)', () {
    test('keeps only real user queries, in order', () {
      final rows = [
        {'rowId': 1, 'kind': 'userInput', 'text': 'q1', 'origin': 'realUser'},
        {'rowId': 2, 'kind': 'assistantText', 'text': 'a1'},
        // Old wire without `origin`: a plain userInput row is a query.
        {'rowId': 3, 'kind': 'userInput', 'text': 'q2'},
        {'rowId': 4, 'kind': 'toolCall', 'toolName': 'AskUserQuestion'},
        // Non-realUser origins never form a cell.
        {'rowId': 5, 'kind': 'userInput', 'text': 'x', 'origin': 'system'},
        // Tool-answer markers (rebuilt AskUserQuestion row shape).
        {
          'rowId': 6,
          'kind': 'userInput',
          'anchorRowId': 4,
          'payload': {'kind': 'userInput', 'toolCallId': 'c1'},
        },
        {'rowId': 7, 'kind': 'timelineMarker'},
        {
          'rowId': 8,
          'kind': 'userInput',
          'text': 'q3',
          'origin': 'realUser',
        },
        {'rowId': 9, 'kind': 'subagent', 'childSessionId': 's'},
      ];
      expect(turnNavigatorQueryRowIds(rows), [1, 3, 8]);
    });

    test('empty and row-less inputs degenerate to empty', () {
      expect(turnNavigatorQueryRowIds(const []), isEmpty);
      expect(
        turnNavigatorQueryRowIds([
          {'rowId': 1, 'kind': 'assistantText', 'text': 'a'},
        ]),
        isEmpty,
      );
    });
  });

  group('TurnNavigator widget', () {
    testWidgets('renders one cell per query; hides below two', (
      tester,
    ) async {
      await tester.pumpWidget(
        mount(nav([3, 7, 11], active: 0)),
      );
      expect(cells, findsNWidgets(3));

      await tester.pumpWidget(mount(nav([3], active: 0)));
      expect(cells, findsNothing);
    });

    testWidgets('tap calls onJump with the cell\'s rowId', (tester) async {
      var jumped = -1;
      await tester.pumpWidget(
        mount(nav([30, 70, 110], active: 0, onJump: (id) => jumped = id)),
      );
      await tester.tap(cells.at(1));
      expect(jumped, 70);
      await tester.tap(cells.at(0));
      expect(jumped, 30);
    });

    testWidgets(
      'ghost cell follows canLoadOlder: same geometry, fainter, not tappable, '
      'real cells keep count and labels',
      (tester) async {
        final handle = tester.ensureSemantics();
        var jumped = -1;
        await tester.pumpWidget(
          mount(nav([3, 7], canLoadOlder: true, onJump: (id) => jumped = id)),
        );
        expect(ghostCell(tester), findsOneWidget);
        // Same geometry as a real thin cell (12×2 bar in a 10dp slot).
        expect(tester.getSize(ghostCell(tester)), const Size(12, 2));
        // The ghost is not a cell: tapping it never jumps, and the real
        // cells keep their count and their "第 N 条" labels.
        expect(cells, findsNWidgets(2));
        // The GHOST sits at the strip's head; the first REAL cell is
        // still "第 1 条" (labels never shift for the placeholder).
        expect(find.bySemanticsLabel('跳转到第 1 条问题'), findsOneWidget);
        await tester.tap(ghostCell(tester), warnIfMissed: false);
        expect(jumped, -1);

        await tester.pumpWidget(
          mount(nav([3, 7], canLoadOlder: false, onJump: (id) => jumped = id)),
        );
        expect(ghostCell(tester), findsNothing);
        expect(cells, findsNWidgets(2));
        handle.dispose();
      },
    );

    testWidgets('semantics: container label + per-cell jump label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(mount(nav([3, 7, 11], active: 0)));
      expect(find.bySemanticsLabel('对话问题导航'), findsOneWidget);
      expect(find.bySemanticsLabel('跳转到第 2 条问题'), findsOneWidget);
      expect(find.bySemanticsLabel('跳转到第 3 条问题'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('strip scrolls itself and follows the active cell', (
      tester,
    ) async {
      await tester.pumpWidget(mount(nav(List.generate(80, (i) => i * 10),
          active: 0)));
      await tester.pumpAndSettle();
      final strip = tester
          .widget<ListView>(
            find.descendant(
              of: find.byType(TurnNavigator),
              matching: find.byType(ListView),
            ),
          )
          .controller!;
      expect(strip.position.maxScrollExtent, greaterThan(0));
      // Active moves to the tail: the strip scrolls to keep it visible.
      await tester.pumpWidget(
        mount(nav(List.generate(80, (i) => i * 10), active: 79)),
      );
      await tester.pumpAndSettle();
      expect(
        strip.position.pixels,
        closeTo(strip.position.maxScrollExtent, 1),
      );
    });
  });

  group('expanded overlay (design §3.1, R2)', () {
    testWidgets(
      'long-press ≥250ms floats the panel out and replaces the thin strip; '
      'a plain tap keeps jumping without expanding',
      (tester) async {
        final handle = tester.ensureSemantics();
        var jumped = -1;
        await tester.pumpWidget(
          mount(nav([30, 70, 110], active: 0, onJump: (id) => jumped = id)),
        );

        // Plain tap: jumps immediately, nothing expands.
        await tester.tap(cells.at(2));
        expect(jumped, 110);
        expect(overlayPanel, findsNothing);
        await tester.pumpAndSettle();

        // Long-press: the enlarged panel floats out; the thin strip is
        // replaced (one ListView left, the enlarged 32dp slot one) and the
        // cell semantics labels carry over.
        await tester.longPress(cells.at(0));
        await tester.pumpAndSettle();
        expect(overlayPanel, findsOneWidget);
        final stripList = tester.widget<ListView>(
          find.descendant(
            of: find.byType(TurnNavigator),
            matching: find.byType(ListView),
          ),
        );
        expect(stripList.itemExtent, TurnNavigator.expandedSlotHeight);
        expect(find.bySemanticsLabel('跳转到第 3 条问题'), findsOneWidget);
        handle.dispose();
      },
    );

    testWidgets(
      'the long-press deadline is 250ms, not the 500ms default (R4): '
      'not yet at 100ms, out at the deadline',
      (tester) async {
        await tester.pumpWidget(mount(nav([30, 70], active: 0)));

        // Hold 100ms: before the deadline — nothing expands.
        final gesture = await tester.startGesture(
          tester.getCenter(cells.at(0)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(overlayPanel, findsNothing);

        // At the cumulative 250ms deadline the panel is already out —
        // well before the 500ms framework default (R4: 500 felt laggy).
        await tester.pump(const Duration(milliseconds: 150));
        expect(overlayPanel, findsOneWidget);
        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets('tapping a big cell jumps with the right rowId and collapses', (
      tester,
    ) async {
      var jumped = -1;
      await tester.pumpWidget(
        mount(nav([30, 70], active: 0, onJump: (id) => jumped = id)),
      );
      await tester.longPress(cells.at(0));
      await tester.pumpAndSettle();

      await tester.tap(cells.at(1));
      expect(jumped, 70);
      await tester.pumpAndSettle();
      expect(overlayPanel, findsNothing);
      // The thin strip is back (10dp slots).
      final stripList = tester.widget<ListView>(
        find.descendant(
          of: find.byType(TurnNavigator),
          matching: find.byType(ListView),
        ),
      );
      expect(stripList.itemExtent, TurnNavigator.slotHeight);
    });

    testWidgets('tapping outside (barrier) collapses without jumping', (
      tester,
    ) async {
      var jumped = -1;
      await tester.pumpWidget(
        mount(nav([30, 70], active: 0, onJump: (id) => jumped = id)),
      );
      await tester.longPress(cells.at(0));
      await tester.pumpAndSettle();
      expect(overlayPanel, findsOneWidget);

      await tester.tap(find.byKey(TurnNavigator.barrierKey));
      await tester.pumpAndSettle();
      expect(jumped, -1);
      expect(overlayPanel, findsNothing);
    });

    testWidgets(
      'panel background is a translucent scaffold background color, no '
      'border stroke (R2 feedback: the old card tone read as a foreign '
      'color; R3 feedback: the hairline frame read too strong)',
      (tester) async {
        await tester.pumpWidget(mount(nav([30, 70], active: 0)));
        await tester.longPress(cells.at(0));
        await tester.pumpAndSettle();

        final decoration =
            tester.widget<DecoratedBox>(overlayPanel).decoration
                as BoxDecoration;
        expect(
          decoration.color,
          buildDarkTheme().scaffoldBackgroundColor.withValues(alpha: 0.5),
        );
        expect(decoration.border, isNull);
        expect(decoration.boxShadow, isNotNull);
      },
    );

    testWidgets('expanded panel shows the enlarged ghost at its head', (
      tester,
    ) async {
      await tester.pumpWidget(mount(nav([30, 70], canLoadOlder: true)));
      await tester.longPress(cells.at(0));
      await tester.pumpAndSettle();
      expect(overlayPanel, findsOneWidget);
      // Same rule as the thin strip: one fainter ghost slot at the head,
      // at the enlarged geometry (4×24), and the real cells keep the
      // count (the ghost carries no onTap).
      expect(ghostCell(tester), findsOneWidget);
      expect(tester.getSize(ghostCell(tester)), const Size(4, 24));
      expect(cells, findsNWidgets(2));
    });
  });

  group('chat page integration', () {
    testWidgets('strip appears with two real queries, hides with one', (
      tester,
    ) async {
      final gateway = FakeChatGateway();
      await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {
          'rowId': 1,
          'kind': 'userInput',
          'text': '只有一条',
          'origin': 'realUser',
        },
        {'rowId': 2, 'kind': 'assistantText', 'text': '答'},
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(TurnNavigator), findsNothing);

      gateway.feedSnapshot([
        {
          'rowId': 1,
          'kind': 'userInput',
          'text': '第一条',
          'origin': 'realUser',
        },
        {'rowId': 2, 'kind': 'assistantText', 'text': '答'},
        {
          'rowId': 3,
          'kind': 'userInput',
          'text': '第二条',
          'origin': 'realUser',
        },
        {'rowId': 4, 'kind': 'assistantText', 'text': '答二'},
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(TurnNavigator), findsOneWidget);
      // AskUserQuestion toolCall rows do not form cells (2 queries only).
      expect(cells, findsNWidgets(2));
    });

    testWidgets(
      'directory is memoized: a text delta keeps the SAME list instance',
      (tester) async {
        final gateway = FakeChatGateway();
        await tester.pumpWidget(
          wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
        );
        gateway.feedSnapshot([
          {
            'rowId': 1,
            'kind': 'userInput',
            'text': '第一条',
            'origin': 'realUser',
          },
          {'rowId': 2, 'kind': 'assistantText', 'text': '答'},
          {
            'rowId': 3,
            'kind': 'userInput',
            'text': '第二条',
            'origin': 'realUser',
          },
          {'rowId': 4, 'kind': 'assistantText', 'text': '答二'},
        ]);
        await tester.pumpAndSettle();
        final before = tester
            .widget<TurnNavigator>(find.byType(TurnNavigator))
            .rowIds;

        // Streaming text delta: shape unchanged → the memo key hits and the
        // directory list instance is reused (PRD AC: 不随文本 delta 重算).
        gateway.state.applyFrame(
          {
            'toSeq': gateway.state.seq + 1,
            'payload': {
              'kind': 'deltas',
              'deltas': [
                {'op': 'row.delta', 'rowId': 4, 'path': 'text', 'append': 'x'},
              ],
            },
          },
          onGap: () => fail('unexpected gap'),
        );
        await tester.pumpAndSettle();
        final after = tester
            .widget<TurnNavigator>(find.byType(TurnNavigator))
            .rowIds;
        expect(identical(before, after), isTrue);

        // An appended query grows the directory.
        gateway.state.applyFrame(
          {
            'toSeq': gateway.state.seq + 1,
            'payload': {
              'kind': 'deltas',
              'deltas': [
                {
                  'op': 'row.appended',
                  'row': {
                    'rowId': 5,
                    'kind': 'userInput',
                    'text': '第三条',
                    'origin': 'realUser',
                  },
                },
              ],
            },
          },
          onGap: () => fail('unexpected gap'),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<TurnNavigator>(find.byType(TurnNavigator)).rowIds,
          [1, 3, 5],
        );
      },
    );

    testWidgets('highlight follows the query at the viewport top', (
      tester,
    ) async {
      final gateway = FakeChatGateway();
      final controller = await pumpVariancePage(tester, gateway);
      TurnNavigator strip() =>
          tester.widget<TurnNavigator>(find.byType(TurnNavigator));

      // Open lands at the bottom: the last query is the active one.
      expect(strip().activeIndex, 7);

      // Land query 5 (rowId 50) on the viewport top, the way a scroll does:
      // coarse-scroll so the target group is built, then measure the
      // (translation-invariant) distance and jump by it.
      controller.jumpTo(controller.position.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      final groupTop = tester.getTopLeft(
        find.byKey(const ValueKey('turn-50'), skipOffstage: false),
      );
      final listTop = tester.getTopLeft(find.byType(ListView).first);
      controller.jumpTo(controller.position.pixels + groupTop.dy - listTop.dy);
      await tester.pumpAndSettle();
      expect(strip().activeIndex, 5);
    });

    testWidgets(
      'jump lands the target query on the viewport top under row-height '
      'variance and detaches the bottom pin',
      (tester) async {
        final gateway = FakeChatGateway();
        final controller = await pumpVariancePage(tester, gateway);
        TurnNavigator strip() =>
            tester.widget<TurnNavigator>(find.byType(TurnNavigator));

        // From the pinned bottom, tap the second query's cell.
        expect(strip().activeIndex, 7);
        await tester.tap(cells.at(1));
        await tester.pumpAndSettle();

        final listTop = tester.getTopLeft(find.byType(ListView).first).dy;
        final landed = tester.getTopLeft(find.byKey(const ValueKey('turn-10'), skipOffstage: false));
        // The landed query group's top sits on the viewport top (± 40px
        // tolerance — chat-conventions §9's measured-landing contract).
        expect(landed.dy - listTop, closeTo(0, 40));
        // Mid-session jump detached the pin: the jump-to-bottom button is up.
        expect(find.byType(JumpToBottomButton), findsOneWidget);

        // New content arrives afterwards: no pull back to the bottom.
        final atLanding = controller.position.pixels;
        gateway.feedSnapshot([
          ...varianceSession(queries: 8),
          {
            'rowId': 80,
            'kind': 'userInput',
            'text': '新提问',
            'origin': 'realUser',
          },
          {'rowId': 81, 'kind': 'assistantText', 'text': '新回答'},
        ]);
        await tester.pumpAndSettle();
        expect(controller.position.pixels, closeTo(atLanding, 1));
      },
    );

    testWidgets(
      'jump clamps when the last query cannot align to the top (short '
      'tail answer) — expected boundary, not a bug',
      (tester) async {
        final gateway = FakeChatGateway();
        final controller = await pumpVariancePage(tester, gateway);
        controller.jumpTo(0);
        await tester.pumpAndSettle();

        // Tap the LAST query: its short tail answer cannot fill a viewport,
        // so the landing clamps to the content end instead of aligning.
        await tester.tap(cells.at(7));
        await tester.pumpAndSettle();
        // Cannot align: the clamped landing keeps the last query BELOW the
        // viewport top (its short tail cannot fill a viewport)…
        final listTop = tester.getTopLeft(find.byType(ListView).first).dy;
        final groupTop = tester.getTopLeft(
          find.byKey(const ValueKey('turn-70'), skipOffstage: false),
        ).dy;
        expect(groupTop - listTop, greaterThan(0));
        // …but fully on screen (parked at the content end, never blank),
        // and the offset stays put across another settle round.
        final viewportH = tester.getSize(find.byType(ListView).first).height;
        expect(groupTop - listTop, lessThan(viewportH));
        final parked = controller.position.pixels;
        await tester.pumpAndSettle();
        expect(controller.position.pixels, closeTo(parked, 1));
      },
    );

    testWidgets('renders in landscape and portrait without overflow', (
      tester,
    ) async {
      final gateway = FakeChatGateway();
      await pumpVariancePage(tester, gateway, queries: 6);
      expect(tester.takeException(), isNull);
      expect(find.byType(TurnNavigator), findsOneWidget);
      expect(cells, findsNWidgets(6));

      // Landscape: the capped strip still fits the short message area.
      tester.view.physicalSize = const Size(844, 390);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(TurnNavigator), findsOneWidget);
    });

    testWidgets('ghost cell shows while older history is unloaded', (
      tester,
    ) async {
      final gateway = FakeChatGateway();
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot(
        varianceSession(queries: 3),
        firstRowId: 1,
        totalCount: 99,
      );
      await tester.pumpAndSettle();
      expect(ghostCell(tester), findsOneWidget);
      // The ghost never counts as a cell: three real queries only.
      expect(cells, findsNWidgets(3));
    });

    testWidgets('a message list scroll collapses the expanded overlay', (
      tester,
    ) async {
      final gateway = FakeChatGateway();
      final controller = await pumpVariancePage(tester, gateway);

      // Expand via long-press on the thin band...
      await tester.longPress(cells.at(0));
      await tester.pumpAndSettle();
      expect(overlayPanel, findsOneWidget);

      // ...then scroll the list: the page's scroll hook collapses it.
      controller.jumpTo(controller.position.pixels - 120);
      await tester.pumpAndSettle();
      expect(overlayPanel, findsNothing);
      // The thin strip is back.
      expect(cells, findsNWidgets(8));
    });
  });
}
