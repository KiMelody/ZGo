import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/state/entitlement_poller.dart';
import 'package:zlinker/state/quota_reset.dart';
import 'package:zlinker/ui/chat/chat_page.dart';
import 'package:zlinker/ui/chat/subagent_detail_page.dart';
import 'package:zlinker/ui/quota_reset_dialog.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

import '../helpers/recording_chat_gateway.dart';

/// Chat-page fake: everything rides the shared loose-default recording
/// gateway — real [ConversationState] frame injection via [RecordingChatGateway.feedSnapshot],
/// command calls recorded in `calls` and answered `accepted` (the
/// conversation command surface goes through `conversationCommands`).
class FakeChatGateway extends RecordingChatGateway {}

Widget wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  darkTheme: buildDarkTheme(),
  builder: (context, child) =>
      UiSettingsProvider(settings: UiSettings(), child: child!),
  home: child,
);

/// Gateway seeded with one running subagent background work
/// (`kind=='subagent'` works entry, live-probed 2026-09-13) whose matching
/// `kind=='subagent'` stream row carries the summary text.
FakeChatGateway _gatewayWithSubagentWork() => FakeChatGateway()
  ..snapshotExtra = {
    'backgroundWorks': [
      {
        'workId': 'agent_1',
        'kind': 'subagent',
        'title': '实现加固',
        'status': 'running',
        'startedAt': 1789279676224,
        'cancellable': true,
        'anchorRowId': null,
        'childSessionId': 'sess_child_1',
      },
    ],
  };

Future<void> _pumpWithRunningSubagent(
  WidgetTester tester,
  FakeChatGateway gateway,
) async {
  await tester.pumpWidget(
    wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
  );
  gateway.feedSnapshot([
    {
      'rowId': 9,
      'kind': 'subagent',
      'childSessionId': 'sess_child_1',
      'subagentType': 'general-purpose',
      'status': 'running',
      'summaryText': '实现加固，正在读取 a.dart',
      'workId': 'agent_1',
    },
    {'rowId': 10, 'kind': 'assistantText', 'text': 'done'},
  ]);
  // finite pumps: the works-bar spinner animates forever, pumpAndSettle
  // would time out on it.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders user bubble, assistant markdown and turn footer', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: '修复登录')),
    );
    // subscribe resolves on the next microtask; feed before settle
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '已修复 **登录** 问题'},
      {
        'rowId': 3,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'activeMs': 65000,
        'fileChanges': {'files': 2, 'additions': 10, 'deletions': 3},
      },
    ]);
    await tester.pumpAndSettle();

    expect(find.text('帮我修复登录'), findsOneWidget);
    expect(find.textContaining('已修复'), findsOneWidget);
    expect(find.text('任务会话'), findsOneWidget); // app bar caption
    expect(find.text('修复登录'), findsOneWidget); // app bar title
    // turn footer: worked duration + phase pill
    expect(find.textContaining('已工作'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
  });

  testWidgets('tool call renders summary + expandable diff', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '改一下'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'Edit',
        'status': 'success',
        'input': {
          'filePath': 'lib/a.dart',
          'old_string': 'a',
          'new_string': 'b',
        },
        'inputText':
            '{"filePath": "lib/a.dart", "old_string": "a", "new_string": "b"}',
      },
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(ExpansionTile), findsOneWidget);
    expect(find.textContaining('已写入'), findsOneWidget);
    // Collapsed header shows basename title + directory subtitle.
    expect(find.textContaining('a.dart'), findsOneWidget);
    expect(find.text('lib'), findsOneWidget);
    // Collapsed by default: the diff body is absent until the header opens.
    expect(find.textContaining('-a'), findsNothing);
    expect(find.textContaining('+b'), findsNothing);

    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('-a'), findsWidgets);
    expect(find.textContaining('+b'), findsWidgets);
    // File edits carry the diff only — no raw parameter/output JSON dump.
    expect(find.textContaining('old_string'), findsNothing);
    expect(find.textContaining('filePath'), findsNothing);
  });

  testWidgets('permission interaction resolves through the gateway', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [
        {
          'interactionId': 'i1',
          'payload': {
            'kind': 'permission',
            'toolName': 'Bash',
            'summary': 'rm -rf build',
            'options': [
              {'optionId': 'o1', 'kind': 'allowOnce'},
              {'optionId': 'o2', 'kind': 'deny'},
            ],
          },
        },
      ],
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('权限请求'), findsOneWidget);
    expect(find.text('允许一次'), findsOneWidget);

    await tester.tap(find.text('允许一次'));
    await tester.pumpAndSettle();
    final call = gateway.calls
        .where((c) => c.$1 == 'resolveInteraction')
        .toList()
        .single;
    expect(call.$2[1], 'i1');
    expect(call.$2[2], 'o1');
  });

  Map<String, dynamic> hookReviewInteraction() => {
    'interactionId': 'i1',
    'payload': {
      'kind': 'workspaceHookReview',
      'sessionId': 's1',
      'taskId': 't1',
      'runId': 'r1',
      'workspaceIdentity': 'wid',
      'workspaceLabel': 'my-repo',
      'bundleDigest':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'reviewFlowId': 'rf1',
      'generation': 2,
      'interactionId': 'i1',
      'summary': {'eventCount': 3, 'hookCount': 2, 'pendingCount': 2},
      'items': [
        {
          'reviewItemId': 'r1',
          'event': 'SessionStart',
          'displayName': '启动检查',
          'displayCommand': 'bash startup.sh',
          'trustState': 'pending_trust',
        },
        {
          'reviewItemId': 'r2',
          'event': 'PreToolUse',
          'displayName': '守卫脚本',
          'displayCommand': 'python guard.py',
          'trustState': 'revoked',
        },
      ],
    },
  };

  Future<FakeChatGateway> pumpHookReview(WidgetTester tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [hookReviewInteraction()],
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    return gateway;
  }

  testWidgets('hook review card renders label, summary, items and badges', (
    tester,
  ) async {
    await pumpHookReview(tester);

    expect(find.text('my-repo'), findsOneWidget);
    expect(find.textContaining('3 个事件'), findsOneWidget);
    // items: name, event, mono command, trustState badges.
    expect(find.text('启动检查'), findsOneWidget);
    expect(find.text('SessionStart'), findsOneWidget);
    expect(find.textContaining('bash startup.sh'), findsOneWidget);
    expect(find.text('守卫脚本'), findsOneWidget);
    expect(find.text('待信任'), findsOneWidget);
    expect(find.text('已撤销'), findsOneWidget);
    expect(find.text('信任勾选项'), findsOneWidget);
  });

  testWidgets('trust button sends the checked reviewItemIds subset', (
    tester,
  ) async {
    final gateway = await pumpHookReview(tester);

    // All checked by default; uncheck the second hook, then trust.
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('信任勾选项'));
    await tester.pumpAndSettle();

    final call = gateway.calls
        .where((c) => c.$1 == 'respondWorkspaceHookReview')
        .toList()
        .single;
    expect(call.$2[0], 's1');
    expect(call.$2[2], ['r1']);
  });

  testWidgets('unknown interaction kind keeps the generic fallback', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [
        {
          'interactionId': 'i9',
          'payload': {'kind': 'mysteryCard'},
        },
      ],
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('等待你的输入'), findsOneWidget);
    expect(
      gateway.calls.where((c) => c.$1 == 'respondWorkspaceHookReview'),
      isEmpty,
    );
  });

  testWidgets('queue bar deletes a queued item', (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'queue': {
        'autoDrain': true,
        'items': [
          {'queueItemId': 'q1', 'text': '排队消息 A'},
        ],
      },
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('排队消息 1'), findsOneWidget);
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    // confirm dialog
    await tester.tap(find.text('删除').last);
    await tester.pump();
    final call = gateway.calls
        .where((c) => c.$1 == 'deleteQueueItem')
        .toList()
        .single;
    expect(call.$2, ['s1', 'q1']);
  });

  testWidgets('composer hint switches to the queue wording when queued',
      (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('提出后续修改要求'), findsOneWidget);

    gateway.snapshotExtra = {
      'queue': {
        'autoDrain': true,
        'items': [
          {'queueItemId': 'q1', 'text': '排队消息 A'},
        ],
      },
    };
    gateway.feedSnapshot([
      {'rowId': 2, 'kind': 'userInput', 'text': 'hi again'},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('继续输入以排队后续修改'), findsOneWidget);
  });

  testWidgets('queue bar drag-to-reorder issues reorderQueueItem with web shape',
      (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'queue': {
        'autoDrain': true,
        'items': [
          {'queueItemId': 'q1', 'text': '排队消息 A'},
          {'queueItemId': 'q2', 'text': '排队消息 B'},
        ],
      },
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    // Official parity: rows reorder via the drag handle, no arrow buttons.
    expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));
    expect(find.byTooltip('上移'), findsNothing);
    expect(find.byTooltip('下移'), findsNothing);

    // Drag q2 (bottom) above q1: it should be inserted before q1.
    final q2handle = find.byIcon(Icons.drag_indicator).last;
    final gesture = await tester.startGesture(tester.getCenter(q2handle));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    final up = gateway.calls
        .where((c) => c.$1 == 'reorderQueueItem')
        .toList()
        .single;
    expect(up.$2, ['s1', 'q2', 'q1']);
  });

  testWidgets('@ trigger opens mention picker; picking inserts reference',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final gateway = FakeChatGateway();
    gateway.mentionFilesResult = [
      {
        'name': 'chat_page.dart',
        'relativePath': 'lib/ui/chat/chat_page.dart',
        'type': 'file',
      },
    ];
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '看一下 @');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // category list appears (ensure the tile is on-screen first).
    // Fixed pumps: the sheet's autofocus caret never lets pumpAndSettle
    // settle.
    expect(find.text('文件'), findsOneWidget);
    await tester.ensureVisible(find.text('文件'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('文件'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    expect(find.text('chat_page.dart'), findsOneWidget);
    await tester.tap(find.text('chat_page.dart'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    final tf = tester.widget<TextField>(find.byType(TextField).first);
    expect(tf.controller!.text, '看一下 @lib/ui/chat/chat_page.dart ');
  });

  testWidgets('draft mode: first send issues createSession with firstText', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(wrap(ChatPage(gateway: gateway, title: '新任务')));
    await tester.pumpAndSettle();
    expect(find.text('输入消息开始新任务'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '开始分析');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    // finite pumps: after createSession the page stays on the connect
    // spinner until the (fake) snapshot arrives, so pumpAndSettle hangs.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final call = gateway.calls
        .where((c) => c.$1 == 'createSession')
        .toList()
        .single;
    expect(call.$2[0], 'ws-1');
    expect(call.$2[1], '开始分析');
  });

  testWidgets('existing session: send goes through sendText', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '继续');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    final call = gateway.calls.where((c) => c.$1 == 'sendText').toList().single;
    expect(call.$2, ['s1', '继续', null]);
  });

  testWidgets('running keeps send beside stop so follow-ups can queue',
      (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'control': {'phase': 'running'},
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    // Official web: stop at the far right, send stays available.
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);

    await tester.enterText(find.byType(TextField), '排队消息 A');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    final call = gateway.calls.where((c) => c.$1 == 'sendText').toList().single;
    expect(call.$2[1], '排队消息 A');
  });

  testWidgets('kicked gateway shows the takeover overlay', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    gateway.kicked = true;
    gateway.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('已被其他设备接管'), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
  });

  testWidgets('subscribe failure surfaces the retry banner', (tester) async {
    final gateway = FakeChatGateway()
      ..failSubscribeWith = (m) => StateError('bridge down');
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    // finite pumps: the page shows an endless connect spinner on failure,
    // pumpAndSettle would time out on it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('订阅失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('reasoning rows collapse into the 思考过程 strip', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {'rowId': 2, 'kind': 'reasoning', 'text': '让我想想'},
      {'rowId': 3, 'kind': 'assistantText', 'text': '答案'},
    ]);
    await tester.pumpAndSettle();

    expect(find.text('思考过程'), findsOneWidget);
    // collapsed by default
    expect(find.text('让我想想'), findsNothing);
  });

  testWidgets('timeline markers render as centered capsules', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'timelineMarker',
        'marker': {
          'type': 'modelChange',
          'fromModel': 'glm-5.2',
          'toModel': 'glm-5.2-air',
        },
      },
      {'rowId': 3, 'kind': 'assistantText', 'text': 'ok'},
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('模型已切换 glm-5.2 → glm-5.2-air'), findsOneWidget);
  });

  testWidgets('user bubble hugs short text (no maxLines inflation)', (
    tester,
  ) async {
    // Regression: SelectableText(maxLines: 14) inflated short bubbles to
    // 14 lines inside the unbounded ListView; the bubble must hug content.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '你好', 'state': 'done'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '回复', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getSize(find.text('你好')).height, lessThan(30));
  });

  testWidgets('long user text collapses to 14 lines, 展开 reveals all', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    final longText = List.filled(30, '一行长文本内容').join('\n');
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': longText, 'state': 'done'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '回复', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final bubbleText = find.textContaining('一行长文本内容');
    final clip = find.ancestor(
      of: bubbleText,
      matching: find.byType(SingleChildScrollView),
    );
    expect(clip, findsOneWidget);
    expect(tester.getSize(clip).height, lessThanOrEqualTo(14 * 21.0 + 1));

    await tester.tap(find.text('展开'));
    await tester.pump();
    expect(
      find.ancestor(
        of: bubbleText,
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    expect(tester.getSize(bubbleText).height, greaterThan(14 * 21.0));
  });

  testWidgets('send button disabled while the composer is empty', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The send button is a squircle visual (32) inside a 48px InkWell target.
    InkWell buttonOf() => tester.widget<InkWell>(
      find
          .ancestor(
            of: find.byIcon(Icons.arrow_upward),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(buttonOf().onTap, isNull); // empty input → disabled

    await tester.enterText(find.byType(TextField), '继续');
    await tester.pump();
    expect(buttonOf().onTap, isNotNull);
  });

  testWidgets('更多 menu: official order and pin toggle flips label', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    // Official web order: pin first, then rename / archive / unread,
    // then the copy actions.
    String itemText(PopupMenuItem<String> i) {
      final w = i.child;
      if (w is Text) return w.data ?? '';
      if (w is Row) {
        for (final c in w.children) {
          if (c is Text) return c.data ?? '';
        }
      }
      return '';
    }

    final texts = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .map(itemText)
        .toList();
    expect(texts.first, '置顶任务');
    expect(texts.indexOf('重命名任务'), lessThan(texts.indexOf('归档任务')));
    expect(texts.indexOf('归档任务'), lessThan(texts.indexOf('标记为未读')));
    expect(texts.indexOf('复制路径'), lessThan(texts.indexOf('复制会话 ID')));

    await tester.tap(find.text('置顶任务'));
    await tester.pumpAndSettle();
    final pin = gateway.calls
        .where((c) => c.$1 == 'setTaskPinned')
        .toList()
        .single;
    expect(pin.$2, ['s1', true]);

    // The label flips to the unpinned wording after toggling.
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('取消置顶任务'), findsOneWidget);
  });

  // ------------------------------------- jump-to-bottom button

  testWidgets('jump-to-bottom: hidden at the newest message, appears after '
      'scrolling up, jumps back and hides', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    // 24 turns: enough history to scroll through.
    gateway.feedSnapshot([
      for (var i = 1; i <= 24; i++) ...[
        {
          'rowId': i * 2 - 1,
          'kind': 'userInput',
          'text': '提问 $i',
          'state': 'done',
        },
        {
          'rowId': i * 2,
          'kind': 'assistantText',
          'text': '回答 $i',
          'state': 'done',
        },
      ],
    ]);
    await tester.pumpAndSettle();

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    // The control stays mounted and cross-fades, so its target opacity is the
    // visibility signal (IgnorePointer blocks taps while transparent).
    double opacity() => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.byIcon(Icons.arrow_downward),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity;

    // Precondition: the 24 turns really do overflow the viewport.
    expect(controller.position.maxScrollExtent, greaterThan(100));

    // Opening a session lands on the newest message → no button. The list is
    // laid out lazily, so assert the app's own pinned window instead of an
    // exact pixel.
    expect(
      controller.position.maxScrollExtent - controller.position.pixels,
      lessThan(40),
    );
    expect(opacity(), 0);

    // The reader scrolls up into the history: the button appears.
    controller.jumpTo(controller.position.maxScrollExtent - 200);
    await tester.pump();
    expect(opacity(), 1);

    await tester.tap(find.byTooltip('回到底部'));
    await tester.pumpAndSettle();

    // It lands on the newest message and hides itself again.
    expect(
      controller.position.pixels,
      moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 0.5),
    );
    expect(opacity(), 0);
  });

  testWidgets('subagent background work renders a live row without a goal', (
    tester,
  ) async {
    final gateway = _gatewayWithSubagentWork();
    await _pumpWithRunningSubagent(tester, gateway);

    // goal=null: the goal panel stays hidden, the subagent entry doesn't.
    expect(find.text('目标'), findsNothing);
    expect(find.text('实现加固 · 正在读取 a.dart'), findsOneWidget);
    expect(find.byTooltip('取消此后台任务'), findsOneWidget);
  });

  testWidgets('summaryText stream appends update the works bar row', (
    tester,
  ) async {
    final gateway = _gatewayWithSubagentWork();
    await _pumpWithRunningSubagent(tester, gateway);

    gateway.state.applyFrame({
      'toSeq': gateway.state.seq + 1,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {'op': 'row.delta', 'rowId': 9, 'path': 'summaryText', 'append': '，写入测试'},
        ],
      },
    }, onGap: () => fail('unexpected gap'));
    await tester.pump();

    expect(find.text('实现加固 · 正在读取 a.dart，写入测试'), findsOneWidget);
  });

  testWidgets('tapping the subagent work row opens the read-only detail page', (
    tester,
  ) async {
    final gateway = _gatewayWithSubagentWork();
    await _pumpWithRunningSubagent(tester, gateway);

    await tester.tap(find.text('实现加固 · 正在读取 a.dart'));
    await tester.pump(); // route push + subscribe microtask
    await tester.pump(const Duration(milliseconds: 350)); // transition
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SubagentDetailPage), findsOneWidget);
    expect(gateway.subscribedSessions, contains('sess_child_1'));
    // the detail page is read-only: no composer inside it
    expect(
      find.descendant(
        of: find.byType(SubagentDetailPage),
        matching: find.byType(TextField),
      ),
      findsNothing,
    );
  });

  // ---------------------------------------------- plan quota warning

  /// Entitlement snapshot with the top-level `remaining` mirror plus an
  /// optional token-class quota limit (the only limit kind that drives the
  /// banner — TIME_LIMIT is the monthly MCP quota and must not).
  EntitlementView okQuota(
    Map<String, dynamic> remaining, {
    double? tokenPercentage,
  }) =>
      EntitlementView(
        phase: EntitlementPhase.ok,
        data: {
          'authenticated': true,
          'provider': {'id': 'prov-1', 'name': 'BigModel'},
          'remaining': remaining,
          'quota': tokenPercentage == null
              ? null
              : {
                  'limits': [
                    {
                      'type': 'TOKENS_LIMIT',
                      'unit': 3,
                      'number': 5,
                      'percentage': tokenPercentage,
                    },
                  ],
                },
          'subscription': null,
        },
      );

  Future<void> pumpWithQuota(
    WidgetTester tester,
    FakeChatGateway gateway, {
    void Function()? onOpenUsage,
  }) async {
    await tester.pumpWidget(wrap(ChatPage(
      gateway: gateway,
      sessionId: 's1',
      title: 't',
      onOpenUsage: onOpenUsage,
    )));
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
  }

  testWidgets('monthly MCP TIME_LIMIT exhaustion does not raise the banner '
      '(bug 09-15)', (tester) async {
    // Reported symptom: TIME_LIMIT (search-prime 100/101) topped out and
    // `remaining` mirroring it at 0, token window at 51% → no banner.
    final gateway = FakeChatGateway()
      ..entitlementResult = EntitlementView(
        phase: EntitlementPhase.ok,
        data: {
          'authenticated': true,
          'provider': {'id': 'prov-1', 'name': 'BigModel'},
          'remaining': {'count': 0, 'percentage': 100, 'isShow': true},
          'quota': {
            'limits': [
              {'type': 'TIME_LIMIT', 'unit': 5, 'number': 1, 'percentage': 100},
              {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 51},
            ],
          },
          'subscription': null,
        },
      );
    await pumpWithQuota(tester, gateway);

    expect(gateway.entitlementCalls, 1);
    expect(find.text('套餐额度已用尽'), findsNothing);
    expect(find.text('切换模型'), findsNothing);
  });

  testWidgets('top-level remaining at 100% alone does not raise the banner', (
    tester,
  ) async {
    final gateway = FakeChatGateway()
      ..entitlementResult = okQuota({
        'count': 0,
        'percentage': 100,
        'isShow': true,
      });
    await pumpWithQuota(tester, gateway);

    expect(gateway.entitlementCalls, 1);
    expect(find.text('套餐额度已用尽'), findsNothing);
  });

  testWidgets('exhausted token limit shows the warning banner with actions', (
    tester,
  ) async {
    var openedUsage = false;
    final gateway = FakeChatGateway()
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      );
    await pumpWithQuota(
      tester,
      gateway,
      onOpenUsage: () => openedUsage = true,
    );
    expect(find.text('套餐额度已用尽'), findsOneWidget);
    expect(find.textContaining('已用尽或受限'), findsOneWidget);

    // 查看用量 jumps through the injected callback.
    await tester.tap(find.text('查看用量'));
    await tester.pump();
    expect(openedUsage, isTrue);

    // 切换模型 opens the existing model sheet.
    await tester.tap(find.text('切换模型'));
    await tester.pumpAndSettle();
    expect(find.textContaining('GLM-5.2'), findsWidgets);
  });

  testWidgets('healthy quota snapshot clears the banner on the next open', (
    tester,
  ) async {
    final gateway = FakeChatGateway()
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      );
    await pumpWithQuota(tester, gateway);
    expect(find.text('套餐额度已用尽'), findsOneWidget);

    // Shared poller refreshed to healthy; the page reopens (fresh state).
    gateway.entitlementResult = okQuota(
      {'count': 12, 'percentage': 40, 'isShow': true},
      tokenPercentage: 40,
    );
    await tester.pumpWidget(wrap(ChatPage(
      key: UniqueKey(),
      gateway: gateway,
      sessionId: 's1',
      title: 't',
    )));
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.text('套餐额度已用尽'), findsNothing);
  });

  // ------------------------------------------ banner reset action (R2)

  testWidgets('exhausted banner hides the reset action without '
      'opportunities', (tester) async {
    final gateway = FakeChatGateway()
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      );
    // Default quotaStatusResult: null → no usable pools data.
    await pumpWithQuota(tester, gateway);

    expect(find.text('套餐额度已用尽'), findsOneWidget);
    expect(find.text('使用重置券'), findsNothing);
  });

  testWidgets('exhausted banner is warning-only: no「使用重置券」even with '
      'opportunities (entry moved to the usage sheet)', (tester) async {
    final gateway = FakeChatGateway()
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      )
      ..quotaStatusResult = {
        'availableFiveHourResets': [
          {
            'expireAt':
                DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
          },
        ],
        'availableWeekResets': <Map<String, dynamic>>[],
      };
    await pumpWithQuota(tester, gateway);

    expect(find.text('套餐额度已用尽'), findsOneWidget);
    expect(find.text('使用重置券'), findsNothing);
    expect(gateway.useQuotaCalls, isEmpty);
  });

  testWidgets('usage sheet reset entry consumes one opportunity and flips '
      'the banner off with the refreshed entitlement', (tester) async {
    final gateway = FakeChatGateway()
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      )
      ..quotaStatusResult = {
        'availableFiveHourResets': [
          {
            'expireAt':
                DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
          },
        ],
        'availableWeekResets': <Map<String, dynamic>>[],
      };
    await pumpWithQuota(tester, gateway);

    // More menu → 用量统计 opens the upgraded usage sheet.
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用量统计'));
    await tester.pumpAndSettle();
    // Remaining-quota block (R4): the aggregated reset-credit row is the
    // single reset entry (the per-pool lines were dropped in the restyle).
    // 2026-09-16 semantics: the row carries the earliest coupon expiry.
    expect(find.text('剩余额度'), findsOneWidget);
    expect(find.textContaining('可用 1 张'), findsOneWidget);
    expect(find.textContaining('最早'), findsOneWidget);
    expect(find.text('使用重置券'), findsOneWidget);

    await tester.tap(find.text('使用重置券'));
    await tester.pumpAndSettle();
    // Official-shape dialog: pool rows + counts + expiry + cancel/reset.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('1 张'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('取消'),
      ),
      findsOneWidget,
    );

    // Fresh entitlement for the post-reset confirmation refresh.
    gateway.entitlementResult = okQuota(
      {'count': 12, 'percentage': 40, 'isShow': true},
      tokenPercentage: 40,
    );
    final entitlementCallsBefore = gateway.entitlementCalls;
    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();

    expect(gateway.useQuotaCalls, hasLength(1));
    final (type, providerId, key) = gateway.useQuotaCalls.single;
    expect(type, 'FIVE_HOUR');
    expect(providerId, 'prov-1');
    expect(key, isNotEmpty);
    // The controller's success chain + the banner re-read both hit the
    // entitlement gateway.
    expect(
      gateway.entitlementCalls,
      greaterThanOrEqualTo(entitlementCallsBefore + 2),
    );
    // Banner flips off with the refreshed healthy snapshot.
    expect(find.text('套餐额度已用尽'), findsNothing);
  });

  // The usage-sheet / dialog pool rules (V1 weekly hiding, untouched-window
  // hiding, inline window clock + earliest coupon expiry) are asserted
  // against the projection in test/state/entitlement_projection_test.dart;
  // the test above stays as the wiring smoke (sheet → dialog → use →
  // refresh → banner flip).

  testWidgets('reset dialog degrades to the「暂无可用机会」copy when the '
      'caller finds no resettable pool (defensive)', (tester) async {
    final gateway = FakeChatGateway()
      ..quotaStatusResult = {
        'availableFiveHourResets': [
          {
            'expireAt': DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch,
          },
        ],
        'availableWeekResets': <Map<String, dynamic>>[],
      };
    final controller = QuotaResetController(gateway: gateway);
    addTearDown(controller.dispose);
    controller.updateScope('prov-1');
    await controller.refresh();

    await tester.pumpWidget(wrap(Builder(
      builder: (context) => TextButton(
        onPressed: () => showQuotaResetDialog(
          context,
          controller: controller,
          resettable: const {},
        ),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('暂无可用机会')),
        findsOneWidget);
    expect(find.text('重置'), findsNothing);
  });
}
