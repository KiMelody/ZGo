import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/connection_params.dart';
import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/ui/chat/subagent_detail_page.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

import '../../helpers/fake_device_session.dart';

/// FakeDeviceSession answering the child-session subscription from a
/// recorded snapshot shape (live-probed 2026-09-13: rows kinds
/// reasoning/assistantText/toolCall, 60-row window, rowsRange paging).
class _FakeSubagentGateway extends FakeDeviceSession {
  _FakeSubagentGateway({
    required this.rows,
    this.totalCount,
    this.rangeResult,
  }) : super(deviceId: 'd1', params: _params);

  static final _params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
  )!;

  final List<Map<String, dynamic>> rows;
  final int? totalCount;
  final Map<String, dynamic>? rangeResult;

  final List<String> subscribed = [];
  final List<(String, int?, int)> ranges = [];
  final List<(String, String)> cancelled = [];

  @override
  ConversationTransport get conversationCommands =>
      _FakeChildCommands(this);

  @override
  Future<ChatHandle> subscribe(String sessionId) async {
    subscribed.add(sessionId);
    final state = ConversationState();
    state.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessionId': sessionId,
          'logEpoch': 'e1',
          'revision': 1,
          'rows': {
            'window': rows,
            'totalCount': totalCount ?? rows.length,
            if (rows.isNotEmpty)
              'firstRowId': (rows.first['rowId'] as num?)?.toInt(),
          },
        },
      },
    }, onGap: () => fail('unexpected gap'));
    return ChatHandle(state: state, close: () async {});
  }

  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) async {
    ranges.add((sessionId, beforeRowId, limit));
    return rangeResult;
  }

  Future<dynamic> cancelBackgroundWork(String sessionId, String workId) async {
    cancelled.add((sessionId, workId));
    return {'status': 'accepted'};
  }
}

/// Routes the conversation command surface back onto the fake's recorded
/// overrides — a session fake has no live [ConversationTransport] behind
/// [DeviceSession.conversationCommands].
class _FakeChildCommands implements ConversationTransport {
  _FakeChildCommands(this._gateway);

  final _FakeSubagentGateway _gateway;

  @override
  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) =>
      _gateway.rowsRange(sessionId, beforeRowId: beforeRowId, limit: limit);

  @override
  Future<dynamic> cancelBackgroundWork(String sessionId, String workId) =>
      _gateway.cancelBackgroundWork(sessionId, workId);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Map<String, dynamic>>.value(const {'status': 'accepted'});
}

Widget wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  darkTheme: buildDarkTheme(),
  builder: (context, child) =>
      UiSettingsProvider(settings: UiSettings(), child: child!),
  home: child,
);

/// Recorded child-session shape (research/subagents-probe.md).
const _childRows = [
  {'rowId': 1, 'kind': 'userInput', 'text': '调研 Flutter 国内镜像可用性'},
  {'rowId': 2, 'kind': 'reasoning', 'text': '先查 pub 官方文档'},
  {
    'rowId': 3,
    'kind': 'toolCall',
    'toolName': 'Edit',
    'status': 'success',
    'input': {'filePath': 'lib/a.dart', 'old_string': 'a', 'new_string': 'b'},
    'inputText': '{"filePath": "lib/a.dart"}',
  },
  {'rowId': 4, 'kind': 'assistantText', 'text': '已完成 **加固**'},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the child session timeline read-only', (tester) async {
    final gateway = _FakeSubagentGateway(rows: _childRows);
    addTearDown(() => gateway.dispose());
    await tester.pumpWidget(
      wrap(
        SubagentDetailPage(
          gateway: gateway,
          childSessionId: 'sess_child_1',
          title: '实现加固',
          parentSessionId: 's1',
          workId: 'agent_1',
          running: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(gateway.subscribed, ['sess_child_1']);
    expect(find.text('实现加固'), findsOneWidget); // app bar title
    expect(find.text('调研 Flutter 国内镜像可用性'), findsOneWidget); // task prompt
    expect(find.textContaining('已完成'), findsOneWidget); // assistant markdown
    // toolCall compact summary + inline diff
    expect(find.textContaining('已写入'), findsOneWidget);
    expect(find.textContaining('-a'), findsWidgets);
    expect(find.textContaining('+b'), findsWidgets);
    // reasoning is collapsed by default, expands on tap
    expect(find.textContaining('先查 pub 官方文档'), findsNothing);
    await tester.tap(find.byType(ExpansionTile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('先查 pub 官方文档'), findsOneWidget);
    // read-only boundary: no composer anywhere on the page
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('load older triggers rowsRange on the child session', (
    tester,
  ) async {
    final gateway = _FakeSubagentGateway(
      rows: _childRows,
      totalCount: _childRows.length + 40, // older rows exist past the window
      rangeResult: const {
        'hasMore': false,
        'atLogEpoch': 'e1',
        'rows': {
          'window': [
            {'rowId': 0, 'kind': 'userInput', 'text': '更早的任务描述'},
          ],
          'firstRowId': 0,
        },
      },
    );
    addTearDown(() => gateway.dispose());
    await tester.pumpWidget(
      wrap(
        SubagentDetailPage(
          gateway: gateway,
          childSessionId: 'sess_child_1',
          title: '实现加固',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('加载更早消息'), findsOneWidget);
    await tester.tap(find.text('加载更早消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(gateway.ranges, [('sess_child_1', 1, 60)]);
    expect(find.text('更早的任务描述'), findsOneWidget);
  });

  testWidgets('stop confirms then cancels the parent background work', (
    tester,
  ) async {
    final gateway = _FakeSubagentGateway(rows: _childRows);
    addTearDown(() => gateway.dispose());
    await tester.pumpWidget(
      wrap(
        SubagentDetailPage(
          gateway: gateway,
          childSessionId: 'sess_child_1',
          title: '实现加固',
          parentSessionId: 's1',
          workId: 'agent_1',
          running: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byTooltip('停止'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('确定停止这个子智能体吗？'), findsOneWidget);

    // cancelling the dialog must not fire the command
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(gateway.cancelled, isEmpty);

    await tester.tap(find.byTooltip('停止'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.widgetWithText(FilledButton, '停止'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(gateway.cancelled, [('s1', 'agent_1')]);
  });
}
