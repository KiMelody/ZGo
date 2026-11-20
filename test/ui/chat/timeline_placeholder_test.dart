// Task 11-19-nav-landing-blank-fix step 4 (R4/D3): the shared timeline must
// never silently drop a row. Unknown kinds and terminal empty assistant text
// render a caption placeholder; streaming empty text stays silent, and a
// whitespace-only trailing segment must not produce a part (which would move
// the feedback anchor off the real answer).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation_state.dart';
import 'package:zgo/ui/chat/markdown_view.dart';
import 'package:zgo/ui/chat/subagent_feed.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

Widget wrap(Widget child, {String locale = 'zh-CN'}) => MaterialApp(
  theme: buildDarkTheme(),
  builder: (context, child) => UiSettingsProvider(
    settings: UiSettings()..locale = locale,
    child: child!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

ConversationState _stateWith(List<Map<String, dynamic>> rows) =>
    ConversationState()..rows = rows;

Widget _chatRow(Map<String, dynamic> row, {bool turnFeedbackLocked = false}) {
  final recording = RecordingCalls();
  return ChatRow(
    row: row,
    conversation: FakeConversation(recording),
    sessionId: 's1',
    onAction: (_, __) async {},
    state: _stateWith([row]),
    preview: ChatPreview(FakeWorkspaceContext(recording)),
    turnFeedbackLocked: turnFeedbackLocked,
  );
}

Future<void> _pumpGroup(
  WidgetTester tester,
  List<Map<String, dynamic>> rows, {
  String locale = 'zh-CN',
}) async {
  final recording = RecordingCalls();
  final conversation = FakeConversation(recording);
  final feed = SubagentFeed(conversation: conversation);
  addTearDown(feed.dispose);
  addTearDown(conversation.dispose);
  await tester.pumpWidget(
    wrap(
      ChatTurnGroup(
        key: const ValueKey('turn-1'),
        rows: rows,
        conversation: conversation,
        sessionId: 's1',
        onAction: (_, __) async {},
        state: conversation.state,
        feed: feed,
        preview: ChatPreview(FakeWorkspaceContext(recording)),
        confirmWindow: const Duration(seconds: 3),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('unknown kind renders the unsupported caption, kind stays off '
      'screen', (tester) async {
    await tester.pumpWidget(
      wrap(_chatRow({'rowId': 1, 'kind': 'futureKind', 'text': 'x'})),
    );

    expect(find.text('该消息类型暂不支持'), findsOneWidget);
    expect(find.textContaining('futureKind'), findsNothing);
  });

  testWidgets('terminal empty assistant text renders the empty caption', (
    tester,
  ) async {
    await _pumpGroup(tester, [
      {'rowId': 1, 'kind': 'assistantText', 'text': ''},
    ]);

    expect(find.text('空消息'), findsOneWidget);
    // The feedback row still belongs to this row (anchor unchanged).
    expect(find.byTooltip('赞'), findsOneWidget);
  });

  testWidgets('streaming empty text renders no placeholder', (tester) async {
    await tester.pumpWidget(
      wrap(
        _chatRow({
          'rowId': 1,
          'kind': 'assistantText',
          'text': '',
          'state': 'streaming',
        }),
      ),
    );

    expect(find.text('空消息'), findsNothing);
  });

  testWidgets('feedback-locked empty text keeps the legacy empty markdown', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        _chatRow(
          {'rowId': 1, 'kind': 'assistantText', 'text': ''},
          turnFeedbackLocked: true,
        ),
      ),
    );

    expect(find.text('空消息'), findsNothing);
  });

  testWidgets('whitespace-only trailing segment adds no part and keeps the '
      'feedback anchor on the real answer', (tester) async {
    await _pumpGroup(tester, [
      {'rowId': 1, 'kind': 'assistantText', 'text': '真实回答'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '\n'},
    ]);

    expect(find.text('真实回答'), findsOneWidget);
    expect(find.text('空消息'), findsNothing);
    // One text part only: the separator must not add a second bubble.
    expect(find.byType(AppMarkdown), findsOneWidget);
    expect(find.byTooltip('赞'), findsOneWidget);
  });

  testWidgets('whitespace-only segment alone renders nothing', (tester) async {
    await _pumpGroup(tester, [
      {'rowId': 1, 'kind': 'assistantText', 'text': '\n'},
    ]);

    expect(find.text('空消息'), findsNothing);
    expect(find.byType(AppMarkdown), findsNothing);
  });

  testWidgets('en table renders both placeholders', (tester) async {
    await tester.pumpWidget(
      wrap(
        _chatRow({'rowId': 1, 'kind': 'futureKind', 'text': 'x'}),
        locale: 'en-US',
      ),
    );
    expect(find.text('Unsupported message type'), findsOneWidget);

    await tester.pumpWidget(
      wrap(
        _chatRow({'rowId': 1, 'kind': 'assistantText', 'text': ''}),
        locale: 'en-US',
      ),
    );
    expect(find.text('Empty message'), findsOneWidget);
  });
}