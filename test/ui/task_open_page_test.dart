import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/i18n/lexicon.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/task_open_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../helpers/chat_role_fakes.dart';

/// [TaskOpenHost] stand-in: connection flags plus a programmable
/// [prepareTaskOpen] answer (a Completer lets a test hold the warm-up open
/// across a page pop — the AC5 race).
class FakeTaskOpenHost extends ChangeNotifier implements TaskOpenHost {
  FakeTaskOpenHost();

  @override
  DeviceStatus status = DeviceStatus.connected;
  @override
  bool kicked = false;
  @override
  String? error;
  @override
  String? remoteUrl;

  /// True by default: an already-landed overview makes a null prepare
  /// answer a REAL dead end. The AC4 cases flip it false to model the
  /// cold-start window where the directory is still empty.
  @override
  bool taskOverviewLoaded = true;

  int reconnectCalls = 0;
  int prepareCalls = 0;
  final List<String> preparedTaskIds = [];

  /// The hint each call carried (null = no payload ownership).
  final List<Map<String, dynamic>?> prepareHints = [];

  /// Consumed front-first by [prepareTaskOpen]; an empty list answers
  /// [WorkspaceOpenOpened]. A Completer entry holds the call open until the
  /// test completes it.
  final List<FutureOr<WorkspaceOpenResult?>> results = [];

  @override
  Future<WorkspaceOpenResult?> prepareTaskOpen(
    String taskId, {
    Map<String, dynamic>? workspaceHint,
  }) async {
    prepareCalls += 1;
    preparedTaskIds.add(taskId);
    prepareHints.add(workspaceHint);
    if (results.isEmpty) return const WorkspaceOpenOpened();
    return await results.removeAt(0);
  }

  @override
  void sendViewState({String? taskId}) {}

  @override
  Future<void> reconnect() async {
    reconnectCalls += 1;
  }
}

Widget wrap(Widget child, {String locale = 'zh-CN'}) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) => UiSettingsProvider(
        settings: UiSettings()..locale = locale,
        child: child!,
      ),
      home: child,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTaskOpenHost openHost;
  late FakeChatGateway chatHost;

  setUp(() {
    openHost = FakeTaskOpenHost();
    chatHost = FakeChatGateway();
  });

  TaskOpenPage page({
    ThemeController? theme,
    Duration? resolveTimeout,
  }) =>
      TaskOpenPage(
        openHost: openHost,
        chatHost: chatHost,
        sessionId: 's1',
        title: '修复登录',
        theme: theme,
        resolveTimeout: resolveTimeout ?? const Duration(seconds: 15),
      );

  testWidgets('opened: warm-up lands on the conversation, replacing the '
      'transition page', (tester) async {
    await tester.pumpWidget(wrap(page()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(openHost.preparedTaskIds, ['s1']);
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.byType(TaskOpenPage), findsNothing,
        reason: 'pushReplacement keeps the transition page out of the stack');
    // The landed chat subscribes the payload's session.
    expect(chatHost.subscribedSessions, ['s1']);
  });

  testWidgets('the payload ownership hint rides the one prepare call (R1)',
      (tester) async {
    await tester.pumpWidget(wrap(TaskOpenPage(
      openHost: openHost,
      chatHost: chatHost,
      sessionId: 's1',
      title: '修复登录',
      workspaceScope: const {
        'workspacePath': '/repo/beta',
        'workspaceIdentity': 'beta',
      },
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(openHost.prepareHints.single, {
      'workspacePath': '/repo/beta',
      'workspaceIdentity': 'beta',
    });
    expect(find.byType(ChatPage), findsOneWidget);
  });

  testWidgets('runtimeNotRunning: stays on the page with the actionable '
      'runtime copy and a retry', (tester) async {
    openHost.results
        .add(const WorkspaceOpenRuntimeNotRunning('runtime is not running'));
    await tester.pumpWidget(wrap(page()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ChatPage), findsNothing,
        reason: 'a chat here would subscribe against a cold runtime');
    expect(find.textContaining('该工作区的智能体运行时未启动'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
  });

  testWidgets('null ownership: reports the scope-unknown copy instead of '
      'guessing a workspace', (tester) async {
    // Overview already landed (the fake's default): null is a REAL dead
    // end, not the transient cold-start emptiness.
    openHost.results.add(null);
    await tester.pumpWidget(wrap(page()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(openHost.prepareCalls, 1);
    expect(find.byType(ChatPage), findsNothing);
    expect(find.text('无法确定会话归属，未打开该任务'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('null ownership before the overview lands: waits, re-resolves '
      'and lands (AC4 cold start)', (tester) async {
    // The cold-start window: the directory is empty until bootstrap ⊕
    // listTaskList land, and the notice carried no ownership hint (a
    // live-row notice). That null is TRANSIENT — the manual retry the
    // 2026-11-07 acceptance needed becomes an automatic re-resolve.
    openHost.taskOverviewLoaded = false;
    openHost.results
      ..add(null)
      ..add(const WorkspaceOpenOpened());
    await tester.pumpWidget(wrap(page()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Still waiting on the overview — no failure copy, no landing yet.
    expect(openHost.prepareCalls, 1);
    expect(find.text('无法确定会话归属，未打开该任务'), findsNothing);
    expect(find.byType(ChatPage), findsNothing);

    openHost.taskOverviewLoaded = true;
    openHost.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(openHost.prepareCalls, 2, reason: 'the directory answer re-ran');
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.byType(TaskOpenPage), findsNothing);
  });

  testWidgets('null ownership and the overview never lands: times out into '
      'the scope-unknown copy', (tester) async {
    openHost.taskOverviewLoaded = false;
    openHost.results.add(null);
    await tester.pumpWidget(wrap(page(resolveTimeout:
        const Duration(milliseconds: 100))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(openHost.prepareCalls, 1, reason: 'no re-resolve past the timeout');
    expect(find.byType(ChatPage), findsNothing);
    expect(find.text('无法确定会话归属，未打开该任务'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
  });

  testWidgets('failure state: 关闭 pops the transition page', (tester) async {
    // Mechanism-level lock for the 2026-11-07 acceptance report of an
    // unresponsive 关闭 (the taps there landed 40-80dp below the button).
    openHost.results.add(null); // overview landed (default) → failure state.
    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) => UiSettingsProvider(
        settings: UiSettings()..locale = 'zh-CN',
        child: child!,
      ),
      home: Scaffold(body: Center(child: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              Navigator.of(context).push(zRoute((_) => page())),
          child: const Text('go'),
        ),
      ))),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(TaskOpenPage), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    expect(find.byType(TaskOpenPage), findsNothing,
        reason: '关闭 must pop the page');
    expect(find.text('go'), findsOneWidget);
  });

  testWidgets('a retry re-runs the warm-up and can still land',
      (tester) async {
    openHost.results
      ..add(const WorkspaceOpenUnreachable('window gate dead end'))
      ..add(const WorkspaceOpenOpened());
    await tester.pumpWidget(wrap(page()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('该工作区未在桌面端打开'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(openHost.prepareCalls, 2);
    expect(find.byType(ChatPage), findsOneWidget);
  });

  testWidgets('a superseded open is re-run once, then fails with the '
      'generic copy', (tester) async {
    // Two aborts in a row: the first is the reconnect-window race (re-run),
    // the second is a dead end — and it must not spin.
    openHost.results
      ..add(const WorkspaceOpenAborted())
      ..add(const WorkspaceOpenAborted());
    await tester.pumpWidget(wrap(page()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(openHost.prepareCalls, 2);
    expect(find.text('打开任务失败，请重试'), findsOneWidget);
    expect(find.byType(ChatPage), findsNothing);
  });

  testWidgets('leaving before the warm-up resolves pushes nothing (AC5)',
      (tester) async {
    final gate = Completer<WorkspaceOpenResult?>();
    openHost.results.add(gate.future);
    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      builder: (context, child) => UiSettingsProvider(
        settings: UiSettings(),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                zRoute((_) => page()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TaskOpenPage), findsOneWidget);

    // User backs out while the bridge open is still in flight…
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TaskOpenPage), findsNothing);

    // …and the warm-up completes afterwards: no page may appear.
    gate.complete(const WorkspaceOpenOpened());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ChatPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('connecting: waits for the link, then continues (AC2)',
      (tester) async {
    openHost.status = DeviceStatus.connecting;
    await tester.pumpWidget(wrap(page()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(openHost.prepareCalls, 0,
        reason: 'no open may ride a link that is not connected yet');
    expect(find.text('正在连接设备…'), findsOneWidget);

    openHost.status = DeviceStatus.connected;
    openHost.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(openHost.preparedTaskIds, ['s1']);
    expect(find.byType(ChatPage), findsOneWidget);

    // Both stages' copy in the en table (i18n parity for a new UI surface).
    expect(trLocale('en-US', 'tasks.open.connecting'), 'Connecting to the '
        'device…');
  });

  testWidgets('a connecting wait that times out offers retry, not a chat',
      (tester) async {
    openHost.status = DeviceStatus.connecting;
    await tester.pumpWidget(wrap(TaskOpenPage(
      openHost: openHost,
      chatHost: chatHost,
      sessionId: 's1',
      title: '修复登录',
      connectTimeout: const Duration(seconds: 2),
    )));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    expect(find.byType(ChatPage), findsNothing);
    expect(find.textContaining('连接超时'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('the slow hint appears while the link keeps reconnecting',
      (tester) async {
    openHost.status = DeviceStatus.error;
    await tester.pumpWidget(wrap(TaskOpenPage(
      openHost: openHost,
      chatHost: chatHost,
      sessionId: 's1',
      title: '修复登录',
      slowHintAfter: const Duration(milliseconds: 100),
    )));
    await tester.pump();
    expect(find.textContaining('正在连接设备'), findsOneWidget);
    expect(find.textContaining('可能需要一点时间'), findsNothing);

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('可能需要一点时间'), findsOneWidget);
  });

  testWidgets('kicked is terminal: the page says so instead of waiting out '
      'the timeout', (tester) async {
    openHost
      ..status = DeviceStatus.error
      ..kicked = true;
    await tester.pumpWidget(wrap(page()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('relay 已踢出这次配对'), findsOneWidget);
    expect(openHost.prepareCalls, 0);

    // The documented recovery entry is what the retry button drives.
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(openHost.reconnectCalls, 1);
  });
}
