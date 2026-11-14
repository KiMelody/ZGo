// Side-chat tab container, step B1 (task 11-11-btw-side-chat / design §4).
//
// The container itself is the subject here — the visual tab strip is B2, so
// tests drive switches through [ChatTabsController], exactly the seam the
// strip will use. Verified faces:
//   * keyed State reuse across a middle-tab removal (never "串 State")
//   * AC4 keep-alive: both scroll position and composer text survive a switch
//   * AC11: back on a side tab returns to the main tab; hidden tabs take no
//     focus
//   * the hidden tab's bridge discipline (isActive early-out, D10's
//     sendViewState gating)
//   * self-heal of a restored tab whose session refuses the subscription
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation_state.dart';
import 'package:zgo/state/side_chat_registry.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  darkTheme: buildDarkTheme(),
  builder: (context, child) => UiSettingsProvider(
    settings: UiSettings()..locale = 'zh-CN',
    child: child!,
  ),
  home: child,
);

const _rows = [
  {'rowId': 1, 'kind': 'userInput', 'text': 'hello'},
  {'rowId': 2, 'kind': 'assistantText', 'text': 'world'},
];

/// Composer TextField of one tab. Hidden slots are offstage, so the finder
/// must opt into them.
Finder _composerOf(String sessionId) => find.descendant(
  of: find.byKey(ValueKey('chat-tab-$sessionId'), skipOffstage: false),
  matching: find.byType(TextField, skipOffstage: false),
  skipOffstage: false,
);

EditableText _composerEditable(WidgetTester tester, String sessionId) =>
    tester.widget<EditableText>(
      find.descendant(
        of: _composerOf(sessionId),
        matching: find.byType(EditableText, skipOffstage: false),
        skipOffstage: false,
      ),
    );

List<(String, List<Object?>)> _viewStateCalls(FakeChatGateway gw) =>
    gw.calls.where((c) => c.$1 == 'sendViewState').toList();

/// Pumps a host chat page carrying [tabs] under parent `p1`.
///
/// Every tab gets its own [ConversationState] (the fake's childStates map),
/// so a composer lookup can never accidentally read another tab's view —
/// sharing one state across children would make the keep-alive assertions
/// vacuous.
Future<({FakeChatGateway gw, ChatTabsController tabs})> _pumpHost(
  WidgetTester tester, {
  List<SideChatTab> tabs = const [],
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);

  final gw = FakeChatGateway();
  if (tabs.isNotEmpty) gw.sideChatTabsByParent['p1'] = [...tabs];
  for (final tab in tabs) {
    gw.childStates[tab.sessionId] = ConversationState();
  }
  final controller = ChatTabsController();

  await tester.pumpWidget(
    _wrap(
      ChatPage(
        host: gw,
        sessionId: 'p1',
        title: '主会话',
        tabsController: controller,
      ),
    ),
  );
  gw.feedSnapshot(_rows);
  for (final tab in tabs) {
    // Feed each side chat its own snapshot so its transcript renders (the
    // frame shape mirrors FakeConversation.feedSnapshot).
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
  return (gw: gw, tabs: controller);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('keyed State reuse', () {
    testWidgets('closing a middle tab keeps the later tab\'s State (no bleed)',
        (tester) async {
      const tabs = [
        SideChatTab(sessionId: 's1', ordinal: 1),
        SideChatTab(sessionId: 's2', ordinal: 2),
        SideChatTab(sessionId: 's3', ordinal: 3),
      ];
      final host = await _pumpHost(tester, tabs: tabs);

      // Fill s3's composer while it is on screen, then go back to the main
      // tab so the draft lives in a State that a positional re-pair would
      // destroy.
      host.tabs.activate('s3');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(_composerOf('s3'), 's3 draft');
      await tester.pump();
      host.tabs.activate('p1');
      await tester.pump();

      // Remove the MIDDLE tab (s2).
      host.gw.sideChatTabsByParent['p1'] = [
        const SideChatTab(sessionId: 's1', ordinal: 1),
        const SideChatTab(sessionId: 's3', ordinal: 3),
      ];
      host.gw.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The surviving later tab kept its widget identity (same State): the
      // draft is still there and no exception was thrown.
      expect(tester.takeException(), isNull);
      expect(
        _composerEditable(tester, 's3').controller.text,
        contains('s3 draft'),
        reason: 'keyed slots must survive a middle-child removal',
      );
    });
  });

  group('AC4 keep-alive across switches', () {
    testWidgets('scroll position and composer draft survive both directions',
        (tester) async {
      const tabs = [SideChatTab(sessionId: 's1', ordinal: 1)];
      final host = await _pumpHost(tester, tabs: tabs);

      // Capture the main composer's controller identity so a rebuild that
      // dropped the State is detectable, not just a text diff.
      final mainController = _composerEditable(tester, 'p1').controller;
      await tester.enterText(_composerOf('p1'), 'main draft');
      await tester.pump();
      expect(mainController.text, 'main draft');

      host.tabs.activate('s1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final sideController = _composerEditable(tester, 's1').controller;
      await tester.enterText(_composerOf('s1'), 'side draft');
      await tester.pump();
      expect(sideController.text, 'side draft');

      // Back to the main tab, then again to the side tab.
      host.tabs.activate('p1');
      await tester.pump();
      host.tabs.activate('s1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final mainAfter = _composerEditable(tester, 'p1').controller;
      final sideAfter = _composerEditable(tester, 's1').controller;
      expect(
        identical(mainAfter, mainController),
        isTrue,
        reason: 'the main tab State must survive both switches',
      );
      expect(
        identical(sideAfter, sideController),
        isTrue,
        reason: 'the side tab State must survive both switches',
      );
      expect(mainAfter.text, 'main draft');
      expect(sideAfter.text, 'side draft');
    });
  });

  group('AC11 back key and focus', () {
    testWidgets('back on a side tab returns to the main tab, not out of the '
        'page', (tester) async {
      final gw = FakeChatGateway();
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      gw.sideChatTabsByParent['p1'] = [
        const SideChatTab(sessionId: 's1', ordinal: 1),
      ];
      final controller = ChatTabsController()..activate('s1');

      await tester.pumpWidget(
        _wrap(
          Scaffold(body: Text('BASE')),
        ),
      );
      tester.state<NavigatorState>(find.byType(Navigator).first).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(
            host: gw,
            sessionId: 'p1',
            title: '主会话',
            tabsController: controller,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      gw.feedSnapshot(_rows);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(ChatPage), findsWidgets);
      // Back on the side tab: the route must NOT pop; the main tab shows.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('BASE'), findsNothing);
      expect(controller.activeId, 'p1');

      // Back on the main tab: the route pops as before.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('BASE'), findsOneWidget);
    });

    testWidgets('a hidden tab\'s composer cannot take focus', (tester) async {
      const tabs = [SideChatTab(sessionId: 's1', ordinal: 1)];
      await _pumpHost(tester, tabs: tabs);

      final hidden = _composerEditable(tester, 's1');
      expect(hidden.focusNode.canRequestFocus, isFalse);
      hidden.focusNode.requestFocus();
      await tester.pump();
      expect(hidden.focusNode.hasFocus, isFalse);

      final visible = _composerEditable(tester, 'p1');
      expect(visible.focusNode.canRequestFocus, isTrue);
    });
  });

  group('hidden tab must not grab the link', () {
    testWidgets('a hidden tab does not resume a revoked handle', (tester) async {
      const tabs = [SideChatTab(sessionId: 's1', ordinal: 1)];
      final host = await _pumpHost(tester, tabs: tabs);

      // The side tab is hidden while the main tab is active.
      host.gw.revoke('s1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.gw.resumedSessions, isNot(contains('s1')));

      // Switching to it runs the deferred resume.
      host.tabs.activate('s1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.gw.resumedSessions, contains('s1'));
    });

    testWidgets('the tab on screen resumes a revoked handle on host notify',
        (tester) async {
      const tabs = [SideChatTab(sessionId: 's1', ordinal: 1)];
      final host = await _pumpHost(tester, tabs: tabs);
      host.tabs.activate('s1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Revoked while ON screen (workspace switch on the desktop): the tab
      // must re-point the bridge itself — there is no route re-entry that
      // would fire didPopNext for it (its `_route` is null by design).
      host.gw.revoke('s1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.gw.resumedSessions, contains('s1'));
    });
  });

  group('D10 sendViewState gating', () {
    testWidgets('only the active tab reports the badge; a hidden tab\'s bind '
        'and teardown stay silent', (tester) async {
      const tabs = [
        SideChatTab(sessionId: 's1', ordinal: 1),
        SideChatTab(sessionId: 's2', ordinal: 2),
      ];
      final host = await _pumpHost(tester, tabs: tabs);

      // Only the main tab bound while active, so only p1's badge went out.
      expect(_viewStateCalls(host.gw).map((c) => c.$2[0]), ['p1']);

      // Switch to s1: it takes the badge; s2's background bind stays silent.
      host.tabs.activate('s1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_viewStateCalls(host.gw).map((c) => c.$2[0]), ['p1', 's1']);

      // Close the hidden s2 (never activated): no clear, no claim.
      host.gw.sideChatTabsByParent['p1'] = [
        const SideChatTab(sessionId: 's1', ordinal: 1),
      ];
      host.gw.notifyListeners();
      await tester.pump();
      expect(_viewStateCalls(host.gw).map((c) => c.$2[0]), ['p1', 's1']);
    });
  });

  group('restore self-heal', () {
    testWidgets('a restored tab whose subscribe is refused is torn down and '
        'leaves the container', (tester) async {
      final gw = FakeChatGateway();
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);

      // The manifest restored a side tab, but the desktop already deleted it:
      // its subscribe answers the authoritative refusal.
      gw.sideChatTabsByParent['p1'] = [
        const SideChatTab(sessionId: 'gone', ordinal: 2),
      ];
      gw.failSubscribeWith = (method) =>
          ChannelRpcError(sessionNotFoundMarker, null);

      await tester.pumpWidget(
        _wrap(
          ChatPage(
            host: gw,
            sessionId: 'p1',
            title: '主会话',
            tabsController: ChatTabsController(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(gw.restoredSideChatParents, ['p1']);
      // The dead tab self-heals through the destroy path (design §3): the
      // host is told, and the tab leaves the container. (The blanket refusal
      // also hits the main conversation here, so the assertion stays on the
      // container shape rather than the composer.)
      expect(gw.destroyedSideChatTabs, [('p1', 'gone')]);
      expect(
        find.byKey(const ValueKey('chat-tab-gone'), skipOffstage: false),
        findsNothing,
      );
      // With no tabs left the container degrades to the plain main body (the
      // pre-B1 shape) — one ChatPage and no tab slots.
      expect(find.byType(ChatPage, skipOffstage: false), findsOneWidget);
    });

    testWidgets('a bridge fault keeps the tab and shows the retry banner',
        (tester) async {
      final gw = FakeChatGateway();
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);

      gw.sideChatTabsByParent['p1'] = [
        const SideChatTab(sessionId: 'flaky', ordinal: 2),
      ];
      // Only the side chat's subscribe faults; the main conversation binds
      // normally (a blanket failure would make the host page's own banner the
      // subject instead).
      gw.conversation.failSubscribeWith = (method) =>
          StateError('bridge down');

      await tester.pumpWidget(
        _wrap(
          ChatPage(
            host: gw,
            sessionId: 'p1',
            title: '主会话',
            tabsController: ChatTabsController(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Only an authoritative refusal self-heals; a fault keeps the tab.
      expect(gw.destroyedSideChatTabs, isEmpty);
      expect(
        find.byKey(const ValueKey('chat-tab-flaky'), skipOffstage: false),
        findsOneWidget,
      );
    });
  });
}
