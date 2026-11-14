// Selection quote + comment (task 11-13-quote-comment-lite M1): entry →
// isolated selection view → optional comment → composer chip → send.
//
// The M0 gesture fix made the message glyphs long-pressable; this suite
// drives the REAL long-press path (no padding workaround) so the entry is
// proved on the same gesture users have.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation_transport.dart';
import 'package:zgo/protocol/replayable_queue.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/selection_quote_page.dart';
import 'package:zgo/ui/chat/subagent_feed.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

Widget _wrap(Widget child, {bool english = false}) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) => UiSettingsProvider(
        settings: UiSettings()..locale = english ? 'en-US' : 'zh-CN',
        child: child!,
      ),
      home: child,
    );

Future<FakeChatGateway> _pumpPage(
  WidgetTester tester, {
  bool english = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  final gateway = FakeChatGateway();
  await tester.pumpWidget(
    _wrap(ChatPage(host: gateway, sessionId: 's1', title: 't'),
        english: english),
  );
  gateway.feedSnapshot([
    {
      'rowId': 1,
      'kind': 'userInput',
      'text': '帮我修复登录',
      'state': 'done',
    },
  ]);
  await tester.pumpAndSettle();
  return gateway;
}

/// Drives the production path: long-press the glyph center → sheet entry →
/// selection view (select all) → optional comment → add.
Future<void> _addQuote(
  WidgetTester tester, {
  String? comment,
  String entryCopy = '引用此段',
  String selectAllCopy = '全选',
  String nextCopy = '下一步',
  String addCopy = '添加引用',
}) async {
  await tester.longPress(find.text('帮我修复登录'));
  await tester.pumpAndSettle();
  expect(find.text(entryCopy), findsOneWidget);
  await tester.tap(find.text(entryCopy));
  await tester.pumpAndSettle();
  expect(find.byType(SelectionQuotePage), findsOneWidget);

  await tester.tap(find.text(selectAllCopy));
  await tester.pump();
  await tester.tap(find.text(nextCopy));
  await tester.pumpAndSettle();
  if (comment != null) {
    await tester.enterText(
      find.descendant(
        of: find.byType(SelectionQuotePage),
        matching: find.byType(TextField),
      ),
      comment,
    );
    await tester.pump();
  }
  await tester.tap(find.text(addCopy));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('quote flow: selection → comment → chip → send clears it',
      (tester) async {
    final gateway = await _pumpPage(tester);
    // The probe is seeded once per page; the fake answers unknown.
    expect(gateway.probeSelectionQuoteSupportCalls, 1);

    await _addQuote(tester, comment: '我的批注');

    final bar = find.byKey(const ValueKey('quote-chip-bar'));
    expect(bar, findsOneWidget);
    expect(
      find.descendant(of: bar, matching: find.text('帮我修复登录')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.text('我的批注')),
      findsOneWidget,
    );

    // Send: the wire payload carries the structured quotes, then the chip
    // clears with the sent message.
    await tester.enterText(find.byType(TextField), '回复');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    final call = gateway.calls.lastWhere((c) => c.$1 == 'sendTextOrQueue');
    expect(call.$2[3], [
      {'text': '帮我修复登录', 'comment': '我的批注'},
    ]);
    expect(bar, findsNothing);
    expect(find.byKey(const ValueKey('quote-chip-bar')), findsNothing);
  });

  testWidgets('quote-only tap explains the missing body instead of sending',
      (tester) async {
    final gateway = await _pumpPage(tester);
    await _addQuote(tester, comment: '我的批注');

    // Empty composer: the armed quote keeps the send button live and swaps
    // the hint; the tap must explain what is missing — ZGo never sends an
    // empty-body text — and nothing leaves the device.
    expect(find.text('输入正文以发送引用'), findsOneWidget);
    final sendCallsBefore =
        gateway.calls.where((c) => c.$1 == 'sendTextOrQueue').length;
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    // Hint + toast share the copy while the composer stays empty.
    expect(find.text('输入正文以发送引用'), findsNWidgets(2));
    expect(
      gateway.calls.where((c) => c.$1 == 'sendTextOrQueue').length,
      sendCallsBefore,
    );
    expect(find.byKey(const ValueKey('quote-chip-bar')), findsOneWidget);
  });

  testWidgets('the chip is removable before sending', (tester) async {
    await _pumpPage(tester);
    await _addQuote(tester);

    final bar = find.byKey(const ValueKey('quote-chip-bar'));
    expect(bar, findsOneWidget);
    await tester.tap(find.byTooltip('移除对话引用'));
    await tester.pumpAndSettle();

    expect(bar, findsNothing);
  });

  testWidgets('a failed send keeps the chip', (tester) async {
    final gateway = await _pumpPage(tester);
    await _addQuote(tester);
    gateway.sendTextOrQueueResults.add(
      SendTextResult.failed(StateError('bridge down')),
    );

    await tester.enterText(find.byType(TextField), '回复');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('quote-chip-bar')), findsOneWidget);
    expect(find.textContaining('发送失败'), findsOneWidget);
  });

  testWidgets('a queued send keeps the chip (R2: message still pending)',
      (tester) async {
    final gateway = await _pumpPage(tester);
    await _addQuote(tester, comment: '我的批注');
    gateway.sendTextOrQueueResults.add(
      SendTextQueued(
        ReplayableQueueItem(
          commandId: 'cmd-queued-1',
          taskId: 's1',
          content: '回复',
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '回复');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    // The message is parked in the replayable queue, not delivered — the
    // chips stay per PRD R2 while the composer clears for the next input.
    expect(find.byKey(const ValueKey('quote-chip-bar')), findsOneWidget);
    expect(find.widgetWithText(TextField, '回复'), findsNothing);
  });

  testWidgets('hiding a side-chat tab clears its pending quotes',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    final active = ValueNotifier<bool>(true);
    addTearDown(active.dispose);

    Widget build() => ListenableBuilder(
          listenable: active,
          builder: (context, _) => ChatPage(
            host: gateway,
            sessionId: 'side-1',
            title: 'side',
            chromeless: true,
            isActive: active.value,
          ),
        );

    await tester.pumpWidget(_wrap(build()));
    gateway.feedSnapshot([
      {
        'rowId': 1,
        'kind': 'userInput',
        'text': '帮我修复登录',
        'state': 'done',
      },
    ]);
    await tester.pumpAndSettle();

    await _addQuote(tester);
    final bar = find.byKey(const ValueKey('quote-chip-bar'));
    expect(bar, findsOneWidget);

    active.value = false;
    await tester.pumpAndSettle();
    active.value = true;
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
  });

  testWidgets('the capability gate hides only the quote entry', (tester) async {
    final gateway = await _pumpPage(tester);
    gateway.selectionQuoteEntryEnabled = false;

    await tester.longPress(find.text('帮我修复登录'));
    await tester.pumpAndSettle();

    expect(find.text('引用此段'), findsNothing);
    expect(find.text('查看文件变更'), findsOneWidget);
  });

  testWidgets('the entry renders when the gate is open', (tester) async {
    final gateway = await _pumpPage(tester);
    gateway.selectionQuoteEntryEnabled = true;

    await tester.longPress(find.text('帮我修复登录'));
    await tester.pumpAndSettle();

    expect(find.text('引用此段'), findsOneWidget);
  });

  testWidgets('readOnly surfaces make the entry unreachable', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final conversation = FakeConversation(RecordingCalls());
    addTearDown(conversation.dispose);
    final feed = SubagentFeed(conversation: conversation);
    addTearDown(feed.dispose);
    var quoteOpened = false;
    conversation.feedSnapshot([
      {
        'rowId': 1,
        'kind': 'userInput',
        'text': '帮我修复登录',
        'state': 'done',
      },
    ]);

    await tester.pumpWidget(_wrap(
      Scaffold(
        body: ChatTurnGroup(
          rows: conversation.state.rows,
          conversation: conversation,
          sessionId: 's1',
          onAction: (label, action) async => action(),
          state: conversation.state,
          feed: feed,
          preview: ChatPreview(FakeWorkspaceContext(RecordingCalls())),
          confirmWindow: const Duration(milliseconds: 150),
          readOnly: true,
          actions: ChatPageActions(
            quote: (context, sessionId, text, {required markdown}) {
              quoteOpened = true;
            },
          ),
        ),
      ),
    ));
    await tester.pump();

    await tester.longPress(find.text('帮我修复登录'));
    await tester.pumpAndSettle();

    expect(find.text('引用此段'), findsNothing);
    expect(quoteOpened, isFalse);
  });

  testWidgets('assistant markdown rows quote through the selection view',
      (tester) async {
    final gateway = await _pumpPage(tester);
    gateway.feedSnapshot([
      {
        'rowId': 2,
        'kind': 'assistantText',
        'text': '已修复登录\n\n```dart\nvoid main() {}\n```',
      },
    ]);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('已修复登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用此段'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectionQuotePage), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pump();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加引用'));
    await tester.pumpAndSettle();

    final bar = find.byKey(const ValueKey('quote-chip-bar'));
    expect(bar, findsOneWidget);
    expect(
      find.descendant(of: bar, matching: find.textContaining('已修复登录')),
      findsOneWidget,
    );
  });

  testWidgets('English copy lock for the entry and selection view',
      (tester) async {
    await _pumpPage(tester, english: true);
    await _addQuote(
      tester,
      entryCopy: 'Quote this text',
      selectAllCopy: 'Select all',
      nextCopy: 'Next',
      addCopy: 'Add quote',
    );

    final bar = find.byKey(const ValueKey('quote-chip-bar'));
    expect(bar, findsOneWidget);
    expect(
      find.descendant(of: bar, matching: find.text('帮我修复登录')),
      findsOneWidget,
    );
  });
}
