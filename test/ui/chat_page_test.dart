import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/ui/chat/chat_page.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

/// Recording fake: subscribes answer from a real [ConversationState] fed
/// by hand; every mutating call is captured for assertions.
class FakeChatGateway extends ChangeNotifier implements ChatGateway {
  @override
  DeviceStatus status = DeviceStatus.connected;
  @override
  bool kicked = false;
  @override
  String? error;

  final ConversationState state = ConversationState();
  final List<(String, List<Object?>)> calls = [];
  Object Function(String method)? failSubscribeWith;

  /// Extra snapshot fields merged into every feed (queue, interactions...).
  Map<String, dynamic> snapshotExtra = const {};

  void feedSnapshot(
    List<Map<String, dynamic>> rows, {
    int? firstRowId,
    int? totalCount,
  }) {
    state.applyFrame({
      'toSeq': state.seq + 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessionId': 's1',
          'logEpoch': 'e1',
          'revision': 3,
          'rows': {
            'window': rows,
            'totalCount': totalCount ?? rows.length,
            'firstRowId': firstRowId,
          },
          ...snapshotExtra,
        },
      },
    }, onGap: () => fail('unexpected gap'));
  }

  @override
  Future<ChatHandle> subscribe(String sessionId) async {
    final fail = failSubscribeWith;
    if (fail != null) throw fail('subscribe');
    return ChatHandle(state: state, close: () async {});
  }

  dynamic _rec(String method, [List<Object?> args = const []]) {
    calls.add((method, args));
    return {'status': 'accepted'};
  }

  @override
  Future<WorkspacePrep> prepareWorkspace() async =>
      WorkspacePrep.fromMap(const {
        'configOptions': [
          {
            'id': 'model',
            'name': '模型',
            'currentValue': 'builtin/glm-5.2',
            'options': [
              {'value': 'builtin/glm-5.2', 'name': 'GLM-5.2'},
              {'value': 'builtin/glm-5.2-air', 'name': 'GLM-5.2 Air'},
            ],
          },
          {
            'id': 'thought_level',
            'name': '思考等级',
            'currentValue': 'enabled',
            'options': [
              {'value': 'enabled', 'name': '开启'},
              {'value': 'off', 'name': '关闭'},
            ],
          },
        ],
        'slashCommands': [
          {'name': 'compact', 'description': '压缩上下文'},
        ],
      });

  @override
  Future<List<SkillEntry>> skills() async => const [];

  @override
  String? get chatWorkspaceId => 'ws-1';
  @override
  String? get workspacePath => '/repo/app';
  @override
  String? get remoteUrl =>
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=demo';

  @override
  Future<void> reconnect() async => _rec('reconnect');

  @override
  Future<dynamic> renameTask(String sessionId, String title) async =>
      _rec('renameTask', [sessionId, title]);
  @override
  Future<dynamic> setTaskPinned(String sessionId, bool pinned) async =>
      _rec('setTaskPinned', [sessionId, pinned]);
  @override
  Future<dynamic> setTaskArchived(String sessionId, bool archived) async =>
      _rec('setTaskArchived', [sessionId, archived]);
  @override
  Future<dynamic> setTaskUnread(String sessionId, bool unread) async =>
      _rec('setTaskUnread', [sessionId, unread]);
  @override
  Future<dynamic> deleteTask(String sessionId) async =>
      _rec('deleteTask', [sessionId]);

  @override
  void sendViewState({String? taskId}) {}

  @override
  Future<dynamic> reorderQueueItem(
    String sessionId,
    String queueItemId,
    String? beforeQueueItemId,
  ) async => _rec('reorderQueueItem', [sessionId, queueItemId,
        beforeQueueItemId]);

  @override
  Future<dynamic> snoozeInteraction(String sessionId, String interactionId) =>
      _rec('snoozeInteraction', [sessionId, interactionId]);

  @override
  Future<dynamic> cancelBackgroundWork(String sessionId, String workId) =>
      _rec('cancelBackgroundWork', [sessionId, workId]);

  @override
  Future<dynamic> deleteSession(String sessionId) =>
      _rec('deleteSession', [sessionId]);

  @override
  Future<dynamic> fileRewindPreview(
    String sessionId, {
    required Map<String, dynamic> target,
  }) async =>
      _rec('fileRewindPreview', [sessionId, target]);

  List<Map<String, dynamic>> mentionFilesResult = const [];
  List<Map<String, dynamic>> mentionSubagentsResult = const [];
  List<Map<String, dynamic>> mentionSkillsResult = const [];
  List<({String id, String title})> mentionSessionsResult = const [];

  @override
  Future<List<Map<String, dynamic>>> mentionFiles() async =>
      mentionFilesResult;

  @override
  Future<List<Map<String, dynamic>>> mentionSkills() async =>
      mentionSkillsResult;

  @override
  Future<List<Map<String, dynamic>>> mentionSubagents() async =>
      mentionSubagentsResult;

  @override
  List<({String id, String title})> mentionSessions() =>
      mentionSessionsResult;

  @override
  List<Map<String, dynamic>> mentionSkillsSync() => mentionSkillsResult;

  @override
  Future<String> createSession(
    String workspaceId, {
    String? firstText,
    List<Map<String, dynamic>>? attachments,
    Map<String, dynamic>? config,
  }) async {
    _rec('createSession', [workspaceId, firstText, config]);
    return 'new-s1';
  }

  @override
  Future<dynamic> sendText(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
  }) async => _rec('sendText', [sessionId, text, heldQueueDisposition]);

  @override
  Future<dynamic> sendGoalCommand(
    String sessionId,
    String text, {
    String? heldQueueDisposition,
  }) async => _rec('sendGoalCommand', [sessionId, text]);

  @override
  Future<dynamic> stop(String sessionId) async => _rec('stop', [sessionId]);
  @override
  Future<dynamic> compact(String sessionId) async =>
      _rec('compact', [sessionId]);
  @override
  Future<dynamic> pauseGoal(String sessionId) async =>
      _rec('pauseGoal', [sessionId]);
  @override
  Future<dynamic> resumeGoal(String sessionId) async =>
      _rec('resumeGoal', [sessionId]);

  @override
  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  }) async => _rec('switchModelConfig', [sessionId, provider, model, thought]);

  @override
  Future<dynamic> switchCollaborationMode(String sessionId, String mode) =>
      Future.value(_rec('switchCollaborationMode', [sessionId, mode]));

  @override
  Future<dynamic> setFollowupMode(String sessionId, String mode) async =>
      _rec('setFollowupMode', [sessionId, mode]);

  @override
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  ) =>
      Future.value(_rec('setAssistantFeedback', [sessionId, target, feedback]));

  @override
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) => Future.value(
    _rec('resolveInteraction', [sessionId, interactionId, optionId, content]),
  );

  @override
  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) async => _rec('rowsRange', [sessionId, beforeRowId, limit]);

  @override
  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  }) async => {'ref': 'r1', 'fileName': fileName, 'mime': mime, 'bytes': 1};

  @override
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  }) async => (bytes: Uint8List(0), mediaType: 'application/octet-stream');

  @override
  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId) async =>
      _rec('sendQueuedNow', [sessionId, queueItemId]);
  @override
  Future<dynamic> editQueueItem(
    String sessionId,
    String queueItemId,
    String newText,
  ) async => _rec('editQueueItem', [sessionId, queueItemId, newText]);
  @override
  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId) async =>
      _rec('deleteQueueItem', [sessionId, queueItemId]);
  @override
  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain) async =>
      _rec('setAutoDrain', [sessionId, autoDrain]);
  @override
  Future<dynamic> plans(String sessionId) async => _rec('plans', [sessionId]);
  @override
  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
  }) async => _rec('fileChanges', [sessionId, target]);
  @override
  Future<dynamic> retryTurn(String sessionId, Map<String, dynamic> target) =>
      Future.value(_rec('retryTurn', [sessionId, target]));
  @override
  Future<dynamic> forkAssistant(
    String sessionId,
    Map<String, dynamic> target,
  ) => Future.value(_rec('forkAssistant', [sessionId, target]));
  @override
  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText,
  ) => Future.value(_rec('editUserQuery', [sessionId, target, newText]));
  @override
  Future<dynamic> applyFileRewind(
    String sessionId,
    Map<String, dynamic> target,
  ) => Future.value(_rec('applyFileRewind', [sessionId, target]));
}

Widget wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  darkTheme: buildDarkTheme(),
  builder: (context, child) =>
      UiSettingsProvider(settings: UiSettings(), child: child!),
  home: child,
);

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
    expect(find.textContaining('lib/a.dart'), findsWidgets);

    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('-a'), findsWidgets);
    expect(find.textContaining('+b'), findsWidgets);
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

  testWidgets('queue bar reorder issues reorderQueueItem with web shape',
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

    // move q2 up: it should be inserted before q1
    await tester.tap(find.byTooltip('上移').last);
    await tester.pump();
    final up = gateway.calls
        .where((c) => c.$1 == 'reorderQueueItem')
        .toList()
        .single;
    expect(up.$2, ['s1', 'q2', 'q1']);

    // move q1 down with nothing after q2 → beforeQueueItemId null (end)
    await tester.tap(find.byTooltip('下移').first);
    await tester.pump();
    final downs = gateway.calls
        .where((c) => c.$1 == 'reorderQueueItem')
        .toList();
    expect(downs.last.$2, ['s1', 'q1', null]);
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

    IconButton buttonOf() => tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byIcon(Icons.arrow_upward),
            matching: find.byType(IconButton),
          )
          .first,
    );
    expect(buttonOf().onPressed, isNull); // empty input → disabled

    await tester.enterText(find.byType(TextField), '继续');
    await tester.pump();
    expect(buttonOf().onPressed, isNotNull);
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
}
