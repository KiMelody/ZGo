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

  /// The child-session state handed to the page — tests push delta frames
  /// onto it to simulate streamed rows.
  ConversationState? lastState;

  @override
  ConversationTransport get conversationCommands =>
      _FakeChildCommands(this);

  @override
  Future<ChatHandle> subscribe(String sessionId) async {
    subscribed.add(sessionId);
    final state = ConversationState();
    lastState = state;
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

/// Streams one appended row onto the child state (live delta shape).
void _appendRow(_FakeSubagentGateway gateway, Map<String, dynamic> row) {
  final state = gateway.lastState!;
  state.applyFrame({
    'toSeq': state.seq + 1,
    'payload': {
      'kind': 'deltas',
      'deltas': [
        {'op': 'row.appended', 'row': row},
      ],
    },
  }, onGap: () => fail('unexpected gap'));
}

/// The jump-to-bottom button stays mounted (cross-fade); its visibility is
/// the animated opacity.
double jumpButtonOpacity(WidgetTester tester) {
  final opacity = tester.widget<AnimatedOpacity>(
    find.ancestor(
      of: find.byTooltip('回到底部'),
      matching: find.byType(AnimatedOpacity),
    ),
  );
  return opacity.opacity;
}

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
    // toolCall compact summary; the diff is collapsed until the row expands
    // (R2, same pattern as the chat page's _ToolCallTile)
    expect(find.textContaining('已写入'), findsOneWidget);
    expect(find.textContaining('-a'), findsNothing);
    expect(find.textContaining('+b'), findsNothing);
    // reasoning is collapsed by default, expands on tap
    expect(find.textContaining('先查 pub 官方文档'), findsNothing);
    await tester.tap(find.byType(ExpansionTile).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('先查 pub 官方文档'), findsOneWidget);
    // expanding the tool row reveals its diff
    await tester.tap(find.textContaining('已写入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('-a'), findsWidgets);
    expect(find.textContaining('+b'), findsWidgets);
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

  testWidgets('opens pinned to the newest row and follows streamed rows '
      'only while the reader stays at the bottom', (tester) async {
    // Rows tall enough to overflow the viewport, so stick/jump are real
    // scroll moves rather than no-ops on a flat list.
    final gateway = _FakeSubagentGateway(
      rows: [
        for (var i = 1; i <= 12; i++)
          {'rowId': i, 'kind': 'assistantText', 'text': '第 $i 段输出' * 20},
      ],
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

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    // R1b: opens at the newest content, not at the top.
    expect(
      controller.position.pixels,
      moreOrLessEquals(controller.position.maxScrollExtent),
    );
    expect(jumpButtonOpacity(tester), 0);

    // R1c: a streamed row while pinned → smooth follow to the new bottom.
    _appendRow(gateway, {
      'rowId': 13,
      'kind': 'assistantText',
      'text': '最新的一段输出' * 20,
    });
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      controller.position.pixels,
      moreOrLessEquals(controller.position.maxScrollExtent),
    );

    // Reader scrolls up: follow stops and the jump button fades in.
    await tester.drag(find.byType(ListView), const Offset(0, 240));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      controller.position.pixels,
      lessThan(controller.position.maxScrollExtent - 40),
    );
    expect(jumpButtonOpacity(tester), 1);

    // Another streamed row while reading history: no follow.
    _appendRow(gateway, {
      'rowId': 14,
      'kind': 'assistantText',
      'text': '更新的一段输出' * 20,
    });
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      controller.position.pixels,
      lessThan(controller.position.maxScrollExtent - 40),
    );

    // The jump button returns to the newest row and fades out.
    await tester.tap(find.byTooltip('回到底部'));
    await tester.pumpAndSettle();
    expect(
      controller.position.pixels,
      moreOrLessEquals(controller.position.maxScrollExtent),
    );
    expect(jumpButtonOpacity(tester), 0);
  });

  testWidgets('prepending older history unsticks the pinned state '
      '(no stale jump-button / follow yank)', (tester) async {
    // Check-finding regression shape: a tail window that does not fill the
    // viewport (max = 0, stick = true, load-older visible). Prepending
    // only grows maxScrollExtent — pixels stays 0, so no scroll
    // notification fires — the pinned cache must be recomputed, not
    // trusted: the jump button has to appear, and a streamed row must not
    // yank the reader (now far from the bottom) down.
    final gateway = _FakeSubagentGateway(
      rows: const [
        {'rowId': 61, 'kind': 'assistantText', 'text': '尾部短输出'},
        {'rowId': 62, 'kind': 'assistantText', 'text': '最新短输出'},
      ],
      totalCount: 62,
      rangeResult: {
        'hasMore': false,
        'atLogEpoch': 'e1',
        'rows': {
          'window': [
            for (var i = 1; i <= 60; i++)
              {'rowId': i, 'kind': 'assistantText', 'text': '第 $i 段历史输出' * 20},
          ],
          'firstRowId': 1,
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

    // Flat list: pinned at the bottom, button hidden.
    expect(jumpButtonOpacity(tester), 0);

    await tester.tap(find.text('加载更早消息'));
    await tester.pumpAndSettle();

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    // Viewport unchanged (pixels 0) but now far from the bottom.
    expect(controller.position.pixels, 0);
    expect(
      controller.position.pixels,
      lessThan(controller.position.maxScrollExtent - 40),
    );
    // Recomputed stick: the jump button fades in despite no scroll event.
    expect(jumpButtonOpacity(tester), 1);

    // A streamed row must not follow: the stale "pinned" state would have
    // yanked the reader from the top of the history to the bottom.
    _appendRow(gateway, {
      'rowId': 63,
      'kind': 'assistantText',
      'text': '流式新输出' * 20,
    });
    await tester.pump();
    await tester.pumpAndSettle();
    expect(controller.position.pixels, 0);
  });
}
