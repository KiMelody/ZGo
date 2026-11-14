// Task 11-11-command-availability-pilot (design §3/§4/§5): the three-state
// row-level availability helper and the six command entries it gates.
//
// Wire authority: research/row-actions-push.md — the desktop only ever
// writes `key: true` into a row's `actions` map and normalizes an empty
// result away, so an absent member (or an absent object in a conversation
// that has shown the surface) means UNAVAILABLE, not "no data".
//
// Regression protection note: every pre-existing test fixture builds rows
// WITHOUT an `actions` member, and their ConversationState never saw one
// either, so `sawRowActions` stays false and `rowActionAllowed` answers
// null — the entries render exactly as before. That is what keeps the rest
// of the suite green (the legacy-desktop case below asserts it directly);
// the tighten cases are the only shapes that assert hiding.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/ui/chat/subagent_feed.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

void main() {
  group('rowActionAllowed three-state helper', () {
    ConversationState stateWith({required bool sawRowActions}) {
      final state = ConversationState()..sawRowActions = sawRowActions;
      addTearDown(state.dispose);
      return state;
    }

    test('actions map carrying the key true allows (both gate values)', () {
      final row = {
        'actions': {'canFork': true},
      };
      expect(
        rowActionAllowed(stateWith(sawRowActions: true), row, 'canFork'),
        isTrue,
      );
      expect(
        rowActionAllowed(stateWith(sawRowActions: false), row, 'canFork'),
        isTrue,
      );
    });

    test('actions map without the key tightens (defensive empty object)', () {
      final row = {'actions': <String, dynamic>{}};
      expect(
        rowActionAllowed(stateWith(sawRowActions: false), row, 'canFork'),
        isFalse,
      );
    });

    test('absent actions tightens once the surface was seen', () {
      final row = <String, dynamic>{'rowId': 1, 'kind': 'assistantText'};
      expect(
        rowActionAllowed(stateWith(sawRowActions: true), row, 'canFork'),
        isFalse,
      );
    });

    test('absent actions falls back to null when the surface never appeared',
        () {
      final row = <String, dynamic>{'rowId': 1, 'kind': 'assistantText'};
      expect(
        rowActionAllowed(stateWith(sawRowActions: false), row, 'canFork'),
        isNull,
      );
    });
  });

  group('entry gating through the shared timeline renderer', () {
    Widget wrap(Widget child) => MaterialApp(
          theme: buildDarkTheme(),
          darkTheme: buildDarkTheme(),
          builder: (context, child) =>
              UiSettingsProvider(settings: UiSettings(), child: child!),
          home: Scaffold(body: child),
        );

    /// The page's own wiring shape, reduced: the turn group reads the live
    /// state rows and rebuilds on the state's notifier, so a `row.upserted`
    /// delta reaches the widgets exactly as it does in production.
    Widget harness(
      FakeConversation conversation,
      SubagentFeed feed,
      ValueNotifier<String?> editingRowId, {
      bool sideChat = false,
      bool withAskInSideChat = false,
    }) =>
        wrap(
          ListenableBuilder(
            listenable: conversation.state,
            builder: (context, _) => ChatTurnGroup(
              key: const ValueKey('turn-1'),
              rows: conversation.state.rows,
              conversation: conversation,
              sessionId: 's1',
              onAction: (label, action) async => action(),
              state: conversation.state,
              feed: feed,
              preview: ChatPreview(FakeWorkspaceContext(RecordingCalls())),
              confirmWindow: const Duration(milliseconds: 150),
              editingRowId: editingRowId,
              onEditSend: (target, newText, rewind) async {},
              sideChat: sideChat,
              actions: ChatPageActions(
                fork: (context, sessionId, target) {},
                // Non-null only where the test needs to prove the side-chat
                // gate (not the optional-callback default) hides the entry.
                askInSideChat:
                    withAskInSideChat ? (context, sessionId) {} : null,
              ),
            ),
          ),
        );

    /// One full-row replacement as the desktop sends it (delta op).
    void feedUpsert(
      FakeConversation conversation,
      List<Map<String, dynamic>> rows,
    ) {
      final state = conversation.state;
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            for (final row in rows) {'op': 'row.upserted', 'row': row},
          ],
        },
        'fromSeq': state.seq,
        'toSeq': state.seq + 1,
      }, onGap: () => fail('unexpected gap'));
    }

    Map<String, dynamic> userRow(Map<String, dynamic>? actions) => {
          'rowId': 1,
          'kind': 'userInput',
          'text': '帮我修复登录',
          'state': 'done',
          if (actions != null) 'actions': actions,
        };

    Map<String, dynamic> assistantRow(Map<String, dynamic>? actions) => {
          'rowId': 2,
          'kind': 'assistantText',
          'text': '已修复',
          if (actions != null) 'actions': actions,
        };

    Map<String, dynamic> headerRow(Map<String, dynamic>? actions) => {
          'rowId': 3,
          'kind': 'turnHeader',
          'state': 'completedSuccess',
          'fileChanges': {'files': 2, 'additions': 5, 'deletions': 1},
          if (actions != null) 'actions': actions,
        };

    /// Opens the long-press sheet via the pre-M0 workaround (bubble padding
    /// just outside the glyphs) — kept as a regression guard for the
    /// established recipe. Glyph-center presses are covered by the M0 tests
    /// below.
    Future<void> openSheet(WidgetTester tester, String text) async {
      final topLeft = tester.getTopLeft(find.text(text));
      await tester.longPressAt(topLeft - const Offset(8, 4));
      await tester.pumpAndSettle();
    }

    /// One turn mounted over the state; returns the fake + its notifier.
    Future<
        (
          FakeConversation,
          SubagentFeed,
          ValueNotifier<String?>,
        )> pumpTurn(
      WidgetTester tester,
      List<Map<String, dynamic>> rows, {
      bool sideChat = false,
      bool withAskInSideChat = false,
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final conversation = FakeConversation(RecordingCalls());
      addTearDown(conversation.dispose);
      final feed = SubagentFeed(conversation: conversation);
      addTearDown(feed.dispose);
      final editingRowId = ValueNotifier<String?>(null);
      addTearDown(editingRowId.dispose);
      conversation.feedSnapshot(rows);
      await tester.pumpWidget(harness(
        conversation,
        feed,
        editingRowId,
        sideChat: sideChat,
        withAskInSideChat: withAskInSideChat,
      ));
      await tester.pump();
      return (conversation, feed, editingRowId);
    }

    testWidgets('long-press on the bubble glyphs opens the row action sheet '
        '(M0: no SelectableText arena steal)', (tester) async {
      await pumpTurn(tester, [
        userRow(null),
        assistantRow(null),
      ]);

      // The exact real-device gesture: press the center of the text glyphs.
      await tester.longPress(find.text('帮我修复登录'));
      await tester.pumpAndSettle();
      expect(find.text('查看文件变更'), findsOneWidget);
    });

    testWidgets('long-press on assistant prose glyphs opens the sheet too',
        (tester) async {
      await pumpTurn(tester, [
        userRow(null),
        assistantRow(null),
      ]);

      await tester.longPress(find.text('已修复'));
      await tester.pumpAndSettle();
      expect(find.text('查看文件变更'), findsOneWidget);
    });

    testWidgets('fork glyph stays while the row allows it and disappears '
        'when an upsert replaces the row without actions', (tester) async {
      final (conversation, _, _) = await pumpTurn(tester, [
        userRow(null),
        assistantRow({'canFork': true}),
      ]);
      expect(conversation.state.sawRowActions, isTrue);
      expect(find.byIcon(Icons.fork_right), findsOneWidget);

      // A full-row replacement carrying no actions member is the desktop's
      // "no longer available" shape.
      feedUpsert(conversation, [assistantRow(null)]);
      await tester.pump();
      expect(find.byIcon(Icons.fork_right), findsNothing);
    });

    testWidgets('mini edit affordance hides when canEdit is absent after the '
        'surface appeared, but the bubble still renders', (tester) async {
      final (conversation, _, _) = await pumpTurn(tester, [
        userRow({'canEdit': true}),
        assistantRow(null),
      ]);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);

      feedUpsert(conversation, [userRow(null)]);
      await tester.pump();
      expect(conversation.state.sawRowActions, isTrue);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.text('帮我修复登录'), findsOneWidget);
    });

    testWidgets('sheet edit entry tightens on a user row whose canEdit is '
        'gone, and the dead rewind entry hides', (tester) async {
      final (conversation, _, _) = await pumpTurn(tester, [
        userRow({'canEdit': true}),
        assistantRow({'canFork': true}),
      ]);

      feedUpsert(conversation, [userRow(null), assistantRow(null)]);
      await tester.pump();

      await openSheet(tester, '帮我修复登录');
      expect(find.text('编辑并重发'), findsNothing);
      // Dead-entry disposition (design §4 entry 3): the sheet's rewind tile
      // sends a non-turnHeader target, which the host always rejects.
      expect(find.text('回滚文件到此'), findsNothing);
      // Entries outside this pilot's scope stay untouched.
      expect(find.text('查看文件变更'), findsOneWidget);
    });

    testWidgets('sheet fork entry tightens with canFork absent', (tester) async {
      final (conversation, _, _) = await pumpTurn(tester, [
        userRow({'canEdit': true, 'canFork': true}),
        assistantRow({'canFork': true}),
      ]);

      // The sheet opens on the user row (the established long-press recipe
      // presses the user bubble padding); its fork tile is row-level gated
      // exactly like the assistant row's.
      feedUpsert(conversation, [userRow({'canEdit': true}), assistantRow(null)]);
      await tester.pump();

      await openSheet(tester, '帮我修复登录');
      expect(find.text('编辑并重发'), findsOneWidget);
      expect(find.text('分叉对话'), findsNothing);
      expect(find.text('回滚文件到此'), findsNothing);
      expect(find.text('查看文件变更'), findsOneWidget);
    });

    testWidgets('the file-changes undo hides for an actionless header once '
        'the surface is established', (tester) async {
      final (conversation, _, _) = await pumpTurn(tester, [
        userRow(null),
        assistantRow(null),
        headerRow({'canRewindFiles': true}),
      ]);
      expect(conversation.state.sawRowActions, isTrue);
      expect(find.text('撤销'), findsOneWidget);

      // The desktop's per-turn gate removes the member on a finished turn
      // (the running-turn shape keeps the old-turn entry visible, which is
      // official behavior — not exercised as a tighten case here).
      feedUpsert(conversation, [headerRow(null)]);
      await tester.pump();
      expect(find.text('撤销'), findsNothing);
    });

    testWidgets('side-chat gate hides the restricted entries even when the '
        'row actions allow them; browsing entries stay (R5/AC6)',
        (tester) async {
      final (conversation, _, _) = await pumpTurn(
        tester,
        [
          userRow({'canEdit': true, 'canFork': true}),
          assistantRow({'canFork': true}),
        ],
        sideChat: true,
        withAskInSideChat: true,
      );
      expect(conversation.state.sawRowActions, isTrue);

      // Feedback row: fork gone, the other buttons stay; the user bubble's
      // edit affordance is gone too (null edit-resend plumbing).
      expect(find.byIcon(Icons.fork_right), findsNothing);
      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);

      await openSheet(tester, '帮我修复登录');
      expect(find.text('编辑并重发'), findsNothing);
      expect(find.text('重试本轮'), findsNothing);
      expect(find.text('分叉对话'), findsNothing);
      expect(find.text('在辅助对话中提问'), findsNothing);
      // Browsing entries survive: R5 restricts commands, not reading.
      expect(find.text('查看文件变更'), findsOneWidget);
    });

    testWidgets('legacy desktop shape (no actions ever) renders every entry '
        'exactly as before', (tester) async {
      final (conversation, _, _) = await pumpTurn(tester, [
        userRow(null),
        assistantRow(null),
        headerRow(null),
      ]);
      expect(conversation.state.sawRowActions, isFalse);

      // Fork glyph + mini edit + undo all keep their pre-existing gates.
      expect(find.byIcon(Icons.fork_right), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.text('撤销'), findsOneWidget);

      await openSheet(tester, '帮我修复登录');
      expect(find.text('编辑并重发'), findsOneWidget);
      expect(find.text('分叉对话'), findsOneWidget);
      expect(find.text('回滚文件到此'), findsOneWidget);
      expect(find.text('查看文件变更'), findsOneWidget);
    });
  });
}
