// B-06 widget regression net (task 11-06-verification-gates).
//
// 第一棒用同一文件**定证**八处交互的失败路径（结论表：
// .trellis/tasks/11-06-verification-gates/research/10-b06-probe-report.md），
// 第二棒修完六处证伪场景后，本文件转为回归网：每个场景断言
// ①本地乐观投影已回滚 ②出现失败 SnackBar ③异常不再逃逸到 zone。
//
// 注入法：chat 队列命令走 `conversationCommands`（FakeChatGateway 子类换成
// 抛错 transport）；保活走 KeepAliveController 子类；置顶/归档走
// FakeDeviceSession.channelHandler 对 zcode-task 抛 ChannelRpcError。
//
// 反自证：去掉任一处 catch，对应场景的 escaped 断言与 snackbar 断言同时变红
// （异常会重新逃到 zone，且不会出现 SnackBar）——见 12-b06-fix-log.md。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/i18n/lexicon.dart';
import 'package:zgo/notifications/keepalive_controller.dart';
import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/settings_page.dart';
import 'package:zgo/ui/task_list_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../helpers/chat_role_fakes.dart';
import '../helpers/fake_device_session.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

/// Queue-command transport that always fails. `async` + `throw` mirrors the
/// production transport (an awaited `sendCommand` that rejects); the pages
/// under test must catch that rejection themselves — that is what this
/// regression net locks.
class _ThrowingQueueTransport implements ConversationTransport {
  final List<String> calls = [];

  Future<dynamic> _fail(String method) async {
    calls.add(method);
    throw ChannelRpcError('B-06 probe failure: $method', null);
  }

  @override
  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain) =>
      _fail('setAutoDrain');

  @override
  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId) =>
      _fail('sendQueuedNow');

  @override
  Future<dynamic> editQueueItem(
    String sessionId,
    String queueItemId,
    String newText,
  ) =>
      _fail('editQueueItem');

  @override
  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId) =>
      _fail('deleteQueueItem');

  @override
  Future<dynamic> reorderQueueItem(
    String sessionId,
    String queueItemId,
    String? beforeQueueItemId,
  ) =>
      _fail('reorderQueueItem');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _QueueProbeGateway extends FakeChatGateway {
  final _ThrowingQueueTransport transport = _ThrowingQueueTransport();

  @override
  ConversationTransport get conversationCommands => transport;
}

Map<String, dynamic> _queueExtra(
  List<Map<String, dynamic>> items, {
  bool autoDrain = true,
}) =>
    {
      'queue': {'autoDrain': autoDrain, 'items': items},
    };

Future<void> _pumpChat(WidgetTester tester, FakeChatGateway gateway) async {
  await tester.pumpWidget(
    _wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
  );
  gateway.feedSnapshot([
    {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
  ]);
  await tester.pumpAndSettle();
}

bool _hasSnackBar() => find.byType(SnackBar).evaluate().isNotEmpty;

String _snackBarCopy(WidgetTester tester) {
  final snack = find.byType(SnackBar);
  if (snack.evaluate().isEmpty) return '';
  return (tester.widget<SnackBar>(snack).content as Text).data ?? '';
}

/// Runs [action] (the UI interaction + the pumps that land its microtasks)
/// in a child zone so an unhandled async command failure is captured here.
/// Null return = the page caught the failure (the fixed behavior); non-null
/// = it escaped with no handler (the B-06 defect).
Future<Object?> _captureEscape(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  Object? escaped;
  await runZonedGuarded(() async {
    await action();
    await tester.pump();
  }, (error, stack) {
    escaped ??= error;
  });
  return escaped;
}

/// The six fixed paths share one contract: caught (no zone escape), visible
/// failure copy, and — where an optimistic projection was landed — a rollback.
void _expectCaught(WidgetTester tester, Object? escaped, String command) {
  expect(escaped, isNull,
      reason: '$command: the failure must be caught, not left to the zone');
  expect(_hasSnackBar(), isTrue, reason: '$command: failure needs a SnackBar');
  expect(_snackBarCopy(tester), contains('操作失败'),
      reason: '$command: the toast uses the chat.op.failed copy');
  expect(_snackBarCopy(tester), contains(command),
      reason: '$command: the toast names the failed command');
}

/// Keep-alive controller whose start/stop fail (the service could not run).
class _FailingKeepAlive extends KeepAliveController {
  int startCalls = 0;
  int stopCalls = 0;

  @override
  bool get supported => true;

  @override
  Future<void> start(String locale) async {
    startCalls++;
    throw StateError('B-06 probe failure: keepalive start');
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    throw StateError('B-06 probe failure: keepalive stop');
  }

  @override
  Future<bool> isRunning() async => false;
}

void _usePhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('B-06 chat held-queue failure paths', () {
    testWidgets('B-06-1 setAutoDrain failure rolls back and toasts',
        (tester) async {
      final gateway = _QueueProbeGateway();
      gateway.snapshotExtra =
          _queueExtra([{'queueItemId': 'q1', 'text': '排队消息 A'}]);
      await _pumpChat(tester, gateway);
      expect(gateway.state.autoDrain, isTrue, reason: 'fixture starts on');

      final escaped = await _captureEscape(tester, () async {
        await tester.tap(find.text('自动发送: 开'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(gateway.transport.calls, ['setAutoDrain']);

      expect(gateway.state.autoDrain, isTrue,
          reason: 'the optimistic flip must roll back to the old value');
      expect(find.text('自动发送: 开'), findsOneWidget);
      _expectCaught(tester, escaped, 'setAutoDrain');
    });

    testWidgets('B-06-2 sendQueuedNow failure restores the row and toasts',
        (tester) async {
      final gateway = _QueueProbeGateway();
      gateway.snapshotExtra =
          _queueExtra([{'queueItemId': 'q1', 'text': '排队消息 A'}]);
      await _pumpChat(tester, gateway);

      final escaped = await _captureEscape(tester, () async {
        await tester.tap(find.byTooltip('立即发送'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(gateway.transport.calls, ['sendQueuedNow']);

      final items = gateway.state.queueItems;
      expect(items.any((i) => '${i['queueItemId']}' == 'q1'), isTrue,
          reason: 'the optimistically hidden row must come back');
      expect(find.text('排队消息 A'), findsOneWidget,
          reason: 'the restored row is on stage again');
      _expectCaught(tester, escaped, 'sendQueuedNow');
    });

    testWidgets('B-06-3 deleteQueueItem failure restores the row and toasts',
        (tester) async {
      final gateway = _QueueProbeGateway();
      gateway.snapshotExtra =
          _queueExtra([{'queueItemId': 'q1', 'text': '排队消息 A'}]);
      await _pumpChat(tester, gateway);

      final escaped = await _captureEscape(tester, () async {
        await tester.tap(find.byTooltip('删除'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(gateway.transport.calls, ['deleteQueueItem']);

      final items = gateway.state.queueItems;
      expect(items.any((i) => '${i['queueItemId']}' == 'q1'), isTrue,
          reason: 'the optimistically deleted row must come back');
      expect(find.text('排队消息 A'), findsOneWidget);
      _expectCaught(tester, escaped, 'deleteQueueItem');
    });

    testWidgets('B-06-4 reorderQueueItem failure toasts (no projection)',
        (tester) async {
      final gateway = _QueueProbeGateway();
      gateway.snapshotExtra = _queueExtra([
        {'queueItemId': 'q1', 'text': '排队消息 A'},
        {'queueItemId': 'q2', 'text': '排队消息 B'},
      ]);
      await _pumpChat(tester, gateway);

      // Same drag the regression test uses: q2 (bottom) dropped above q1.
      final escaped = await _captureEscape(tester, () async {
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
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(gateway.transport.calls, ['reorderQueueItem']);

      // reorder has no local projection (order comes from the snapshot):
      // nothing to roll back, the toast is the whole contract.
      final ids =
          gateway.state.queueItems.map((i) => '${i['queueItemId']}').toList();
      expect(ids.join(','), 'q1,q2',
          reason: 'no optimistic projection exists for reorder');
      _expectCaught(tester, escaped, 'reorderQueueItem');
    });

    testWidgets('B-06-5 editQueueItem failure reverts the text and toasts',
        (tester) async {
      final gateway = _QueueProbeGateway();
      gateway.snapshotExtra =
          _queueExtra([{'queueItemId': 'q1', 'text': '排队消息 A'}]);
      await _pumpChat(tester, gateway);

      // 不用 enterText：chat 页的 IME 探针会让 testTextInput 的
      // showKeyboard 挂住（实测无限等待）。对话框的 TextField 持有
      // controller，直接改它等价于用户输入。
      final escaped = await _captureEscape(tester, () async {
        await tester.tap(find.byTooltip('编辑'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final field = tester.widget<TextField>(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ));
        field.controller!.text = '编辑后的文本';
        await tester.tap(find.text('保存'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(gateway.transport.calls, ['editQueueItem']);

      expect('${gateway.state.queueItems.first['text']}', '排队消息 A',
          reason: 'the optimistic text edit must revert to the old text');
      expect(find.text('排队消息 A'), findsOneWidget);
      _expectCaught(tester, escaped, 'editQueueItem');
    });
  });

  group('B-06 settings keep-alive failure path', () {
    testWidgets('B-06-6 keepalive start/stop failure flips back and toasts',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(600, 2800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ui = UiSettings();
      final keepalive = _FailingKeepAlive();
      await tester.pumpWidget(_wrap(SettingsPage(
        store: DeviceStore(),
        theme: ThemeController(),
        ui: ui,
        keepalive: keepalive,
      )));
      await tester.pumpAndSettle();

      // start 失败：switch 必须翻回 off，并有失败提示。
      final escapedStart = await _captureEscape(tester, () async {
        await tester.tap(find.text('后台保持连接接收通知'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(keepalive.startCalls, 1);
      expect(escapedStart, isNull,
          reason: 'the service failure is caught, not left to the zone');
      expect(ui.keepAliveEnabled, isFalse,
          reason: 'a failed start must not persist the switch as on');
      expect(_hasSnackBar(), isTrue);
      expect(_snackBarCopy(tester), contains('操作失败'));

      // 让前一条 SnackBar 退场，再量 stop 方向（同一条 try/catch 形状）。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await ui.setKeepAliveEnabled(true);
      await tester.pumpAndSettle();
      final escapedStop = await _captureEscape(tester, () async {
        await tester.tap(find.text('后台保持连接接收通知'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(keepalive.stopCalls, 1,
          reason: 'the toggle off must reach the service controller');
      expect(escapedStop, isNull);
      expect(ui.keepAliveEnabled, isTrue,
          reason: 'a failed stop must not persist the switch as off');
      expect(_hasSnackBar(), isTrue);
    });
  });

  group('B-06 task-list pin/archive failure paths (design-in)', () {
    Future<FakeDeviceSession> pumpTaskList(
      WidgetTester tester, {
      required String failingMethod,
    }) async {
      _usePhone(tester);
      SharedPreferences.setMockInitialValues({});
      final store = DeviceStore();
      await store.load();
      final device = await store.addUrl(
          'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=songsong&app_version=3.8.1');
      final now = DateTime.now().millisecondsSinceEpoch;
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: [
          {
            'sessionId': 's1',
            'title': '修复登录',
            'phase': 'completedSuccess',
            'lastActivityAt': now,
          },
        ],
        workspaces: [
          {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
        ],
        relayTasks: [
          {
            'taskId': 's1',
            'title': '修复登录',
            'workspacePath': '/repo/app',
            'workspaceIdentity': 'app-id',
            'displayStatus': 'idle',
            'updatedAt': now,
          },
        ],
        channelHandler: (channel, method, args) async {
          if (channel == 'zcode-task' && method == failingMethod) {
            throw ChannelRpcError('B-06 probe failure: $method', null);
          }
          return null;
        },
      );
      await tester.pumpWidget(_wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return session;
    }

    Future<void> openSheetAndTap(WidgetTester tester, String label) async {
      await tester.longPress(find.text('修复登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final item = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.widgetWithText(ListTile, label),
      );
      expect(item, findsOneWidget, reason: 'the row action sheet');
      await tester.tap(item);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('B-06-7 setTaskPinned failure', (tester) async {
      final session =
          await pumpTaskList(tester, failingMethod: 'setTaskPinned');
      await openSheetAndTap(tester, '置顶');

      // 命令确实到达 channel。
      expect(
        session.channelCalls.where(
            (c) => c.$1 == 'zcode-task' && c.$2 == 'setTaskPinned'),
        isNotEmpty,
      );
      // pin 没有乐观投影：relay 行未变（无回滚可谈）。
      final projectionApplied = session.relayTasks.first['pinned'] == true;
      final snackbar = _hasSnackBar();
      final copy = _snackBarCopy(tester);
      expect(snackbar, isTrue, reason: 'B-06-7: 失败必须有 SnackBar');
      expect(copy, contains('操作失败'),
          reason: 'the failure toast uses the tasks.opFailed copy');
      expect(projectionApplied, isFalse,
          reason: 'no optimistic projection for pin — nothing to roll back');
    });

    testWidgets('B-06-8 setTaskArchived failure', (tester) async {
      // 未归档行 → sheet 显示「归档」→ 走 archiveTask（失败注入）。
      final session =
          await pumpTaskList(tester, failingMethod: 'archiveTask');
      await openSheetAndTap(tester, '归档');

      expect(
        session.channelCalls.where(
            (c) => c.$1 == 'zcode-task' && c.$2 == 'archiveTask'),
        isNotEmpty,
      );
      // archive 同样没有乐观投影：relay 行 archived 保持空。
      final projectionApplied = session.relayTasks.first['archived'] == true;
      final snackbar = _hasSnackBar();
      final copy = _snackBarCopy(tester);
      expect(snackbar, isTrue, reason: 'B-06-8: 失败必须有 SnackBar');
      expect(copy, contains('操作失败'),
          reason: 'the failure toast uses the tasks.opFailed copy');
      expect(projectionApplied, isFalse,
          reason: 'no optimistic projection for archive — nothing to roll back');
    });
  });

  test('B-06 probe copy table resolves', () {
    expect(trByKeyP('zh-CN', 'tasks.opFailed', ['x']), contains('操作失败'));
    expect(trByKeyP('zh-CN', 'chat.op.failed', ['x']), contains('操作失败'));
  });
}