// Task 11-06-a11y-semantic-labels (child 05): icon-only affordances must give
// TalkBack a name.
//
// Two distinct mechanisms are locked here, because Flutter routes them onto
// two different semantics fields:
//
//   * an outer `Semantics(label:)` wrapper lands on `SemanticsData.label`
//     (`find.bySemanticsLabel` sees it) — used where the control is an
//     InkWell with a glyph child (`_ControlChip` icon state, the fenced-code
//     copy button);
//   * `IconButton(tooltip:)` lands on `SemanticsData.tooltip` (on Android that
//     is `AccessibilityNodeInfo.setTooltipText`) — `find.bySemanticsLabel`
//     does NOT see it, so those cases assert through the semantics tree.
//
// Only the naming plumbing is under test: geometry/hit-area assertions live in
// the sibling page tests (child 01/04) and must not be duplicated here.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation_state.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/markdown_view.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../helpers/chat_role_fakes.dart';

Widget wrap(Widget child, {String locale = 'zh-CN'}) => MaterialApp(
      theme: buildDarkTheme(),
      builder: (context, child) => UiSettingsProvider(
        settings: UiSettings()..locale = locale,
        child: child!,
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// Every non-empty `tooltip` string in the mounted semantics tree.
///
/// `IconButton(tooltip:)` writes `SemanticsData.tooltip`, not `label`, so
/// `find.bySemanticsLabel` cannot reach it; walking the tree keeps the
/// assertion on the exact field the platform reads.
///
/// The semantics tree hangs off the render view's own pipeline owner (which
/// is where `flutter_test` itself reads it, see `SemanticsController`), not
/// off the root owner.
List<String> tooltips(WidgetTester tester) {
  final renderView = tester.binding.renderViews.first;
  final root = renderView.owner!.semanticsOwner!.rootSemanticsNode!;
  final found = <String>[];
  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.tooltip.isNotEmpty) found.add(data.tooltip);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  return found;
}

/// Assistant turn body with the feedback row mounted (copy / like / dislike,
/// plus fork and hook-runs when the caller wires them).
Widget assistantRow(
    {bool withFork = false, List<Map<String, dynamic>> hookRows = const []}) {
  final row = <String, dynamic>{
    'rowId': 1,
    'kind': 'assistantText',
    'text': 'answer',
  };
  return ChatRow(
    row: row,
    conversation: FakeConversation(RecordingCalls()),
    sessionId: 's1',
    onAction: (_, __) async {},
    state: ConversationState()..rows = [row],
    preview: ChatPreview(FakeWorkspaceContext(RecordingCalls())),
    hookRows: hookRows,
    actions: withFork
        ? ChatPageActions(fork: (context, sessionId, target) {})
        : null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('outer Semantics(label:) on icon-only tap targets', () {
    // `_ControlChip` is private, so it is exercised through its only real
    // mount: the composer tool row. Below the 640dp breakpoint `wide` is
    // false and the chip drops to the icon-only branch.
    testWidgets('composer mode chip is named in its icon-only state',
        (tester) async {
      final handle = tester.ensureSemantics();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final gateway = FakeChatGateway();
      await tester.pumpWidget(MaterialApp(
        theme: buildDarkTheme(),
        builder: (context, child) => UiSettingsProvider(
          settings: UiSettings(),
          child: child!,
        ),
        home: ChatPage(host: gateway, sessionId: 's1', title: 't'),
      ));
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Icon-only: the chip paints no text, so the reader would otherwise
      // have had nothing to announce. 中文 mode label for `build`.
      expect(find.text('变更前确认'), findsNothing);
      expect(find.bySemanticsLabel('变更前确认'), findsOneWidget);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('变更前确认'))
            .getSemanticsData()
            .flagsCollection
            .isButton,
        isTrue,
        reason: 'TalkBack announces the chip as a button',
      );
      handle.dispose();
    });

    testWidgets('fenced-code copy button is named in zh and en',
        (tester) async {
      for (final cell in const [('zh-CN', '复制'), ('en-US', 'Copy')]) {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(wrap(
          const AppMarkdown('```dart\nvoid main() {}\n```'),
          locale: cell.$1,
        ));
        await tester.pumpAndSettle();

        expect(
          find.bySemanticsLabel(cell.$2),
          findsOneWidget,
          reason: 'the copy glyph carries no text, so the wrapper must name '
              'it (${cell.$1})',
        );
        final data = tester
            .getSemantics(find.bySemanticsLabel(cell.$2))
            .getSemanticsData();
        expect(data.flagsCollection.isButton, isTrue,
            reason: 'TalkBack announces the control as a button');
        handle.dispose();
      }
    });
  });

  group('IconButton(tooltip:) as the reader name', () {
    testWidgets('feedback row names like / dislike / fork / hooks (zh)',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(wrap(assistantRow(
        withFork: true,
        hookRows: const [
          {'state': 'completed', 'outcome': 'success'},
        ],
      )));

      final names = tooltips(tester);
      expect(names, contains('赞'));
      expect(names, contains('踩'));
      expect(names, contains('分叉会话'));
      expect(names, contains('查看钩子运行记录'));
      expect(names, contains('复制'));
      // The assistant copy button shares the fenced-code copy key (V4).
      handle.dispose();
    });

    testWidgets('feedback row names follow the active locale (en)',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(wrap(
        assistantRow(
          withFork: true,
          hookRows: const [
            {'state': 'completed', 'outcome': 'success'},
          ],
        ),
        locale: 'en-US',
      ));

      final names = tooltips(tester);
      expect(names, contains('Like'));
      expect(names, contains('Dislike'));
      expect(names, contains('Fork'));
      expect(names, contains('View hook runs'));
      expect(names, contains('Copy'));
      handle.dispose();
    });

    testWidgets('fork and hooks stay absent without their wiring',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(wrap(assistantRow()));

      final names = tooltips(tester);
      expect(names, isNot(contains('分叉会话')));
      expect(names, isNot(contains('查看钩子运行记录')));
      handle.dispose();
    });
  });

  group('behavior that must not regress', () {
    // `_CompactIconButton` is timeline's `_MiniAction`; it carried a tooltip
    // before this task and still must (V1 — no duplicate semanticLabel).
    testWidgets('user-bubble compact copy button keeps its tooltip',
        (tester) async {
      final handle = tester.ensureSemantics();
      final row = <String, dynamic>{
        'rowId': 1,
        'kind': 'userInput',
        'text': 'hello',
      };
      await tester.pumpWidget(wrap(ChatRow(
        row: row,
        conversation: FakeConversation(RecordingCalls()),
        sessionId: 's1',
        onAction: (_, __) async {},
        state: ConversationState()..rows = [row],
        preview: ChatPreview(FakeWorkspaceContext(RecordingCalls())),
      )));

      expect(tooltips(tester), contains('复制'));
      expect(find.byTooltip('复制'), findsOneWidget);
      handle.dispose();
    });
  });
}
