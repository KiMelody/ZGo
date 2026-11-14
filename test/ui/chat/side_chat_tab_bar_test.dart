// Side-chat tab strip, step B2 (task 11-11-btw-side-chat / design §4, AC3).
//
// The strip is the B2 subject; B1's container tests drive switches through
// [ChatTabsController] and stay untouched. Faces verified here:
//   * conditional mount: zero side tabs = no strip at all (mock 对照帧)
//   * main tab has no close target; each side tab has one at 28x36
//   * titles come from the registry ordinal (辅助对话 N / Side conversation N)
//   * X closes through the host port; long-press opens the two-action sheet
//   * narrow screen: the strip scrolls horizontally and reaches every tab
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/conversation_state.dart';
import 'package:zgo/state/side_chat_registry.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/side_chat_tab_bar.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

Widget _wrap(Widget child, {String locale = 'zh-CN'}) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) => UiSettingsProvider(
        settings: UiSettings()..locale = locale,
        child: child!,
      ),
      home: child,
    );

const _rows = [
  {'rowId': 1, 'kind': 'userInput', 'text': 'hello'},
  {'rowId': 2, 'kind': 'assistantText', 'text': 'world'},
];

/// The taskId of every `sendViewState` the page issued, in order — null
/// marks the bare clear that would strip the desk badge (D10).
List<Object?> _viewStateIds(FakeChatGateway gw) => [
      for (final call in gw.calls)
        if (call.$1 == 'sendViewState') call.$2.first,
    ];

/// Pumps a host chat page carrying [tabs] under parent `p1`.
Future<FakeChatGateway> _pumpHost(
  WidgetTester tester, {
  List<SideChatTab> tabs = const [],
  double width = 390,
  String locale = 'zh-CN',
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.reset);

  final gw = FakeChatGateway();
  if (tabs.isNotEmpty) gw.sideChatTabsByParent['p1'] = [...tabs];
  for (final tab in tabs) {
    gw.childStates[tab.sessionId] = ConversationState();
  }

  await tester.pumpWidget(
    _wrap(
      ChatPage(
        host: gw,
        sessionId: 'p1',
        title: '主会话任务',
        tabsController: ChatTabsController(),
      ),
      locale: locale,
    ),
  );
  gw.feedSnapshot(_rows);
  for (final tab in tabs) {
    gw.childStates[tab.sessionId]!.applyFrame({
      'toSeq': 1,
      'payload': {
        'type': 'snapshot',
        'sessionId': tab.sessionId,
        'logEpoch': 'e1',
        'revision': 1,
        'rows': {
          'window': _rows,
          'totalCount': _rows.length,
          'firstRowId': 1,
        },
      },
    }, onGap: () => fail('unexpected gap'));
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return gw;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('conditional mount (AC3 baseline)', () {
    testWidgets('no side tabs: the strip is not mounted at all',
        (tester) async {
      await _pumpHost(tester);
      expect(find.byType(SideChatTabBar), findsNothing);
      // No stray band either: the title row is the only thing above the
      // message list, exactly the pre-B2 shape.
      expect(find.text('主会话任务'), findsOneWidget);
    });

    testWidgets('one side tab mounts the strip with the main tab first',
        (tester) async {
      await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
      );
      expect(find.byType(SideChatTabBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SideChatTabBar),
          matching: find.text('主会话'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(SideChatTabBar),
          matching: find.text('辅助对话 1'),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
        'the strip sits under the title row and above the message '
        'area', (tester) async {
      await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
      );
      final titleY = tester.getTopLeft(find.text('主会话任务')).dy;
      final stripY = tester.getTopLeft(find.byType(SideChatTabBar)).dy;
      expect(stripY, greaterThan(titleY));
      expect(stripY - titleY, lessThan(80));
      // The strip body is exactly 44dp tall (mock decision 3).
      expect(
        tester.getSize(find.byType(SideChatTabBar)).height,
        SideChatTabBar.barHeight,
      );
    });

    testWidgets(
        'the title row is drawn once (hoisted above the strip, not '
        'per tab body)', (tester) async {
      await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
      );
      expect(find.text('主会话任务'), findsOneWidget);
      // Hoisting is what keeps it still across a switch (mock decision 1).
      final titleY = tester.getTopLeft(find.text('主会话任务')).dy;
      final controller =
          tester.widget<ChatPage>(find.byType(ChatPage).first).tabsController!;
      controller.activate('s1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getTopLeft(find.text('主会话任务')).dy, titleY);
    });
  });

  group('close button placement', () {
    testWidgets('the main tab has no close target; every side tab has one',
        (tester) async {
      await _pumpHost(
        tester,
        tabs: const [
          SideChatTab(sessionId: 's1', ordinal: 1),
          SideChatTab(sessionId: 's2', ordinal: 2),
        ],
      );
      expect(find.byKey(const ValueKey('side-tab-close-s1')), findsOneWidget);
      expect(find.byKey(const ValueKey('side-tab-close-s2')), findsOneWidget);
      // The main tab's own key carries no close sibling — assert on the
      // subtree rather than a global icon count (the transcript may draw ✕
      // glyphs of its own).
      final mainTab = find.byKey(const ValueKey('side-tab-main'));
      expect(
        find.descendant(
          of: mainTab,
          matching: find.byKey(const ValueKey('side-tab-close-p1')),
        ),
        findsNothing,
      );
      // 28x36 close hit box (mock decision 4's dense-strip exception).
      final box =
          tester.getSize(find.byKey(const ValueKey('side-tab-close-s1')));
      expect(box.width, SideChatTabBar.closeHitWidth);
      expect(box.height, SideChatTabBar.pillHeight);
    });

    testWidgets('titles follow the registry ordinals, not tab position',
        (tester) async {
      // Ordinal 2 and 4 as a close-then-recreate would leave them (the freed
      // number is reused by the registry, not renumbered here).
      await _pumpHost(
        tester,
        tabs: const [
          SideChatTab(sessionId: 's2', ordinal: 2),
          SideChatTab(sessionId: 's4', ordinal: 4),
        ],
      );
      final bar = find.byType(SideChatTabBar);
      expect(
        find.descendant(of: bar, matching: find.text('辅助对话 2')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.text('辅助对话 4')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.text('辅助对话 1')),
        findsNothing,
      );
    });

    testWidgets('EN copy renders the finished strings', (tester) async {
      await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 3)],
        locale: 'en-US',
      );
      final bar = find.byType(SideChatTabBar);
      expect(
        find.descendant(of: bar, matching: find.text('Main conversation')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: bar,
          matching: find.text('Side conversation 3'),
        ),
        findsOneWidget,
      );
      // No key echo (a missing entry renders the dotted key verbatim).
      expect(find.textContaining('sideChat.'), findsNothing);
    });
  });

  group('switch and close wiring', () {
    testWidgets(
        'tapping a side pill switches the visible tab; tapping the '
        'main pill switches back', (tester) async {
      final gw = await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
      );
      final controller =
          tester.widget<ChatPage>(find.byType(ChatPage).first).tabsController!;
      expect(controller.activeId, isNull);

      await tester.tap(find.byKey(const ValueKey('side-tab-s1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.activeId, 's1');
      // Switched: the side page is the on-stage ChatPage (main is offstage).
      expect(
        find.byKey(const ValueKey('chat-tab-s1')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('side-tab-main')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.activeId, 'p1');
      expect(gw.closedSideChatTabs, isEmpty);
    });

    testWidgets('X closes through the host port and the tab leaves the strip',
        (tester) async {
      final gw = await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
      );

      await tester.tap(find.byKey(const ValueKey('side-tab-close-s1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(gw.closedSideChatTabs, [('p1', 's1')]);
      expect(find.byKey(const ValueKey('side-tab-s1')), findsNothing);
      // With no side tabs left the strip unmounts again (conditional mount).
      expect(find.byType(SideChatTabBar), findsNothing);
      expect(
        find.byKey(const ValueKey('chat-tab-s1'), skipOffstage: false),
        findsNothing,
      );
      // Close is restorable (design §6): the toast names the way back.
      expect(find.text('辅助对话 1 已关闭，重新进入会话可恢复'), findsOneWidget);
    });

    testWidgets('X on the ACTIVE tab returns to the main tab first, and the '
        'teardown leaves the main reader alone (AC5/D10)', (tester) async {
      final gw = await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
      );
      final controller =
          tester.widget<ChatPage>(find.byType(ChatPage).first).tabsController!;
      await tester.tap(find.byKey(const ValueKey('side-tab-s1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.activeId, 's1');
      expect(gw.conversation.closedSessions, isEmpty);
      // The active side tab already claimed the desk badge; the close must
      // not send a bare clear that would take it away from the main tab
      // (design §6 / D10).
      expect(_viewStateIds(gw), ['p1', 's1']);

      await tester.tap(find.byKey(const ValueKey('side-tab-close-s1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(gw.closedSideChatTabs, [('p1', 's1')]);
      expect(controller.activeId, 'p1');
      // The side page left the tree and released its reader; the main
      // conversation's handle is still open (R4: the parent is untouched).
      expect(gw.conversation.closedSessions, ['s1']);
      expect(_viewStateIds(gw), ['p1', 's1'],
          reason: 'deactivation and teardown stay silent for the badge');
    });

    testWidgets('closing a background tab keeps the active tab and the main '
        'conversation', (tester) async {
      final gw = await _pumpHost(
        tester,
        tabs: const [
          SideChatTab(sessionId: 's1', ordinal: 1),
          SideChatTab(sessionId: 's2', ordinal: 2),
        ],
      );
      final controller =
          tester.widget<ChatPage>(find.byType(ChatPage).first).tabsController!;
      await tester.tap(find.byKey(const ValueKey('side-tab-s2')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.activeId, 's2');
      expect(_viewStateIds(gw), ['p1', 's2']);

      await tester.tap(find.byKey(const ValueKey('side-tab-close-s1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(gw.closedSideChatTabs, [('p1', 's1')]);
      expect(controller.activeId, 's2',
          reason: 'closing a background tab must not switch the visible tab');
      expect(gw.conversation.closedSessions, ['s1']);
      expect(find.byKey(const ValueKey('side-tab-s1')), findsNothing);
      expect(find.byKey(const ValueKey('side-tab-s2')), findsOneWidget);
      expect(_viewStateIds(gw), ['p1', 's2']);
    });
  });

  group('long-press sheet (close / destroy entries)', () {
    testWidgets(
        'long-pressing a side pill offers both lifecycle actions; '
        'close runs the close port', (tester) async {
      final gw = await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
      );

      await tester.longPress(find.byKey(const ValueKey('side-tab-s1')));
      await tester.pumpAndSettle();
      expect(find.text('关闭旁支'), findsOneWidget);
      expect(find.text('销毁旁支会话'), findsOneWidget);

      await tester.tap(find.text('关闭旁支'));
      await tester.pumpAndSettle();
      expect(gw.closedSideChatTabs, [('p1', 's1')]);
      expect(gw.destroyedSideChatTabs, isEmpty);
    });

    testWidgets(
        'the destroy entry asks first: cancel runs no port and keeps the tab',
        (tester) async {
      final gw = await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
      );

      await tester.longPress(find.byKey(const ValueKey('side-tab-s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('销毁旁支会话'));
      await tester.pumpAndSettle();

      // Design §7/R9: the gate names the target and warns that the delete is
      // permanent; nothing has been sent yet.
      expect(find.text('销毁辅助对话 1？'), findsOneWidget);
      expect(
        find.text('该操作不可恢复：辅助对话及其消息记录将被永久删除。'),
        findsOneWidget,
      );
      expect(gw.destroyedSideChatTabs, isEmpty);

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(gw.destroyedSideChatTabs, isEmpty);
      expect(gw.closedSideChatTabs, isEmpty);
      expect(find.byKey(const ValueKey('side-tab-s1')), findsOneWidget);
      expect(find.text('辅助对话 1 已销毁'), findsNothing);
    });

    testWidgets('confirming the gate reaches the destroy port', (tester) async {
      final gw = await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
      );

      await tester.longPress(find.byKey(const ValueKey('side-tab-s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('销毁旁支会话'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '销毁旁支会话'));
      await tester.pumpAndSettle();

      expect(gw.destroyedSideChatTabs, [('p1', 's1')]);
      expect(gw.closedSideChatTabs, isEmpty);
      expect(find.byKey(const ValueKey('side-tab-s1')), findsNothing);
      expect(find.text('辅助对话 1 已销毁'), findsOneWidget);
    });

    testWidgets('a failed destroy keeps the tab and surfaces the failure',
        (tester) async {
      final gw = await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
      );
      gw.destroySideChatTabResults.add(Exception('boom'));

      await tester.longPress(find.byKey(const ValueKey('side-tab-s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('销毁旁支会话'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '销毁旁支会话'));
      await tester.pumpAndSettle();

      // The state layer rethrows a non-idempotent delete fault with the tab
      // untouched (AC10 retry path); the page must not claim success.
      expect(gw.destroyedSideChatTabs, [('p1', 's1')]);
      expect(find.byKey(const ValueKey('side-tab-s1')), findsOneWidget);
      expect(find.text('辅助对话 1 已销毁'), findsNothing);
      expect(find.text('操作失败: Exception: boom'), findsOneWidget);
    });

    testWidgets('the gate renders the EN copy', (tester) async {
      final gw = await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
        locale: 'en-US',
        // The EN pills are wider than the zh ones; keep both inside the
        // viewport so the long-press lands on the pill (the 360/390 cases
        // live in the scroll group).
        width: 500,
      );

      await tester.longPress(find.byKey(const ValueKey('side-tab-s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete side conversation'));
      await tester.pumpAndSettle();
      expect(find.text('Delete side conversation 1?'), findsOneWidget);
      expect(
        find.text('The side conversation and its messages will be '
            'permanently deleted. This cannot be undone.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(gw.destroyedSideChatTabs, isEmpty);
    });

    testWidgets('dismissing the sheet runs no action', (tester) async {
      final gw = await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
      );
      await tester.longPress(find.byKey(const ValueKey('side-tab-s1')));
      await tester.pumpAndSettle();
      // Tap the scrim above the sheet.
      await tester.tapAt(const Offset(195, 60));
      await tester.pumpAndSettle();
      expect(gw.closedSideChatTabs, isEmpty);
      expect(gw.destroyedSideChatTabs, isEmpty);
      expect(find.byKey(const ValueKey('side-tab-s1')), findsOneWidget);
    });
  });

  group('embedded host (check memo 1)', () {
    // The dual-pane host (task_list_page) is a pane inside the TASK LIST
    // route: a back-press guard there would swallow the whole list page's
    // back action, not just the chat's. The strip therefore renders for
    // display/switch, but the PopScope gate is dropped (the pane owns no
    // route of its own).
    testWidgets('the strip renders in the pane, but no PopScope is added',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);

      final gw = FakeChatGateway();
      gw.sideChatTabsByParent['p1'] = [
        const SideChatTab(sessionId: 's1', ordinal: 1),
      ];
      final controller = ChatTabsController()..activate('s1');

      await tester.pumpWidget(
        _wrap(
          Scaffold(
            body: ChatPage(
              host: gw,
              sessionId: 'p1',
              title: '主会话任务',
              embedded: true,
              tabsController: controller,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(SideChatTabBar), findsOneWidget);
      // The gate would intercept the task list's own back action.
      expect(find.byType(PopScope), findsNothing);
    });
  });

  group('switch path keeps the resume legs (check memo 2)', () {
    // A side page has no route of its own (`_route` is null), so `didPopNext`
    // never fires for it; its recovery rides `_onHostChanged` (revoke while
    // on screen) and `didUpdateWidget` (revoke while hidden, then activated).
    // The strip switches through the same controller seam, so both legs cover
    // the strip path — this test pins the deferred leg down.
    testWidgets('a revoke while hidden resumes on the strip switch',
        (tester) async {
      final gw = await _pumpHost(
        tester,
        tabs: const [SideChatTab(sessionId: 's1', ordinal: 1)],
      );

      // Hidden tab, revoked by a desktop-side workspace switch.
      gw.revoke('s1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(gw.resumedSessions, isNot(contains('s1')));

      // The strip's switch is what lets the tab resume.
      await tester.tap(find.byKey(const ValueKey('side-tab-s1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(gw.resumedSessions, contains('s1'));
    });
  });

  group('narrow screen (360dp) horizontal scroll', () {
    // Horizontal clipping does not take a child offstage (unlike
    // IndexedStack), so plain finders see every pill. "Visible" therefore
    // means the pill's center sits inside the strip's viewport — what a
    // finger can actually reach.
    bool centerInStrip(WidgetTester tester, String key) {
      final bar = tester.getRect(find.byType(SideChatTabBar));
      final center = tester.getCenter(find.byKey(ValueKey(key)));
      return center.dx >= bar.left && center.dx <= bar.right;
    }

    testWidgets('six tabs overflow and every pill is reachable by scrolling',
        (tester) async {
      final tabs = [
        for (var i = 1; i <= 5; i++) SideChatTab(sessionId: 's$i', ordinal: i),
      ];
      await _pumpHost(tester, tabs: tabs, width: 360);

      final bar = find.byType(SideChatTabBar);
      expect(tester.getSize(bar).width, 360);
      // The content is wider than the viewport (mock: 6 tabs ≈ 646dp), so
      // the strip overflows by construction.
      final scrollable = find.descendant(
        of: bar,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));

      // The last pill starts off-screen; scrolling to the far end brings it
      // into the viewport and it becomes tappable.
      expect(centerInStrip(tester, 'side-tab-s5'), isFalse);
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      expect(centerInStrip(tester, 'side-tab-s5'), isTrue);
      await tester.tap(find.byKey(const ValueKey('side-tab-s5')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final controller =
          tester.widget<ChatPage>(find.byType(ChatPage).first).tabsController!;
      expect(controller.activeId, 's5');
    });

    testWidgets('switching to an off-screen tab reveals it', (tester) async {
      final tabs = [
        for (var i = 1; i <= 5; i++) SideChatTab(sessionId: 's$i', ordinal: i),
      ];
      await _pumpHost(tester, tabs: tabs, width: 360);
      expect(centerInStrip(tester, 'side-tab-s5'), isFalse);
      // Drive the switch from the controller (what the create path does):
      // the strip must bring the newly active pill into view.
      final controller =
          tester.widget<ChatPage>(find.byType(ChatPage).first).tabsController!;
      controller.activate('s5');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(centerInStrip(tester, 'side-tab-s5'), isTrue);
    });
  });
}
