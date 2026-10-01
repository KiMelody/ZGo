import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/recording_chat_gateway.dart';

/// Wire fake: records (method, args), answers from a programmed table
/// (default `accepted`), can park calls to hold an item in `sending`.
/// Also owns the bridge-recovery notifier the queue listens to.
class _FakeWire {
  final calls = <(String, List<Object?>)>[];
  final List<Object?> results = [];
  final ValueNotifier<int> recovered = ValueNotifier<int>(0);

  /// When set, every call parks until completed (holds an item in the
  /// sending state for the bar assertions).
  Completer<void>? gate;

  Future<dynamic> call(String method, List<Object?> args) async {
    calls.add((method, args));
    final parking = gate;
    if (parking != null) await parking.future;
    if (results.isNotEmpty) {
      final next = results.removeAt(0);
      if (next is Exception) throw next;
      if (next is Error) throw next;
      return next;
    }
    return const {'accepted': true, 'command': <String, dynamic>{}};
  }
}

ReplayableCommandQueue _queue(_FakeWire wire) => ReplayableCommandQueue(
  call: wire.call,
  scope: const {'workspacePath': '/repo/app'},
  clientId: 'client-1',
  recovered: wire.recovered,
);

Widget wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  darkTheme: buildDarkTheme(),
  builder: (context, child) =>
      UiSettingsProvider(settings: UiSettings(), child: child!),
  home: child,
);

Future<RecordingChatGateway> _pumpPage(
  WidgetTester tester,
  ReplayableCommandQueue? queue,
) async {
  final gateway = RecordingChatGateway()..replayableQueue = queue;
  await tester.pumpWidget(
    wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
  );
  gateway.feedSnapshot([
    {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
  ]);
  await tester.pumpAndSettle();
  return gateway;
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.arrow_upward));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bar renders the content line and the queued state', (
    tester,
  ) async {
    final wire = _FakeWire()..results.add(TimeoutException('dead'));
    final queue = _queue(wire);
    await _pumpPage(tester, queue);

    queue.queueLocal(taskId: 's1', content: '离线排队的第一条消息');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.text('离线排队的第一条消息'), findsOneWidget);
    expect(find.text('排队中'), findsOneWidget);
    expect(find.byTooltip('撤销排队'), findsOneWidget);
  });

  testWidgets('an in-flight enqueue shows the sending state', (tester) async {
    final wire = _FakeWire()..gate = Completer<void>();
    final queue = _queue(wire);
    await _pumpPage(tester, queue);

    final item = queue.queueLocal(taskId: 's1', content: '正在补发');
    await tester.pump();
    expect(item.state, ReplayableQueueItemState.sending);
    expect(find.text('发送中…'), findsOneWidget);
  });

  testWidgets('a failed item surfaces the error with retry and undo', (
    tester,
  ) async {
    final wire = _FakeWire()
      ..results.add(ChannelRpcError('Task command not found.', null));
    final queue = _queue(wire);
    await _pumpPage(tester, queue);

    final item = queue.queueLocal(taskId: 's1', content: '会被拒绝的');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(item.state, ReplayableQueueItemState.failed);
    expect(find.text('发送失败'), findsOneWidget);
    expect(find.text('Task command not found.'), findsOneWidget);
    expect(find.byTooltip('重试'), findsOneWidget);

    // Retry: fresh budget, immediate drain → default accepted → gone.
    await tester.tap(find.byTooltip('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(queue.items, isEmpty);
    expect(find.text('发送失败'), findsNothing);
  });

  testWidgets('undo removes the row and fires the idempotent cancel', (
    tester,
  ) async {
    final wire = _FakeWire()..results.add(TimeoutException('dead'));
    final queue = _queue(wire);
    await _pumpPage(tester, queue);

    final item = queue.queueLocal(taskId: 's1', content: '排队消息');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    await tester.tap(find.byTooltip('撤销排队'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(queue.items, isEmpty);
    expect(find.text('排队中'), findsNothing);
    final cancelCall = wire.calls.last;
    expect(cancelCall.$1, 'cancelTaskCommand');
    expect(cancelCall.$2.single, {
      'commandId': item.commandId,
      'taskId': 's1',
    });
  });

  testWidgets('recovery drains the queue and the bar disappears', (
    tester,
  ) async {
    final wire = _FakeWire()..results.add(TimeoutException('dead'));
    final queue = _queue(wire);
    await _pumpPage(tester, queue);

    queue.queueLocal(taskId: 's1', content: '待补发');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('排队中'), findsOneWidget);

    wire.recovered.value += 1; // bridge recovered → replay → accepted
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(wire.calls.where((c) => c.$1 == 'enqueueTaskCommand'), hasLength(2));
    expect(queue.items, isEmpty);
    expect(find.text('排队消息'), findsNothing);
    expect(find.text('排队中'), findsNothing);
  });

  testWidgets('a queued send result clears the composer; the bar keeps it', (
    tester,
  ) async {
    final wire = _FakeWire()..results.add(TimeoutException('dead'));
    final queue = _queue(wire);
    final gateway = await _pumpPage(tester, queue);

    // The transport parked the message and handed back its queue item —
    // the real sendTextOrQueue contract on a channel-level failure. The
    // page must clear the composer and keep rendering the bar, no toast.
    final item = queue.queueLocal(taskId: 's1', content: '弱网里的消息');
    gateway.sendTextOrQueueResults.add(SendTextResult.queued(item));

    await _send(tester, '弱网里的消息');
    await tester.pump(const Duration(milliseconds: 10));

    expect(
      tester
          .widget<TextField>(find.byType(TextField))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.text('弱网里的消息'), findsOneWidget);
    expect(find.text('排队中'), findsOneWidget);
    expect(find.textContaining('发送失败'), findsNothing);
    expect(
      gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'),
      hasLength(1),
    );
  });
}
