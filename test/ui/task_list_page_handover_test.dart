import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/ui/remote_page.dart';
import 'package:zgo/ui/task_list_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../helpers/fake_device_session.dart';
import '../helpers/fake_webview_platform.dart';

/// Hub whose `suspend` the test controls: [gate] holds the handover open,
/// [error] makes it throw (the no-navigation branch).
class _GatedHub extends DeviceSessionHub {
  _GatedHub({required super.nativeListEnabled});

  Completer<void>? gate;
  Object? error;
  final suspended = <String>[];

  @override
  Future<void> suspend(String deviceId) async {
    suspended.add(deviceId);
    final g = gate;
    if (g != null) await g.future;
    final e = error;
    if (e != null) throw e;
  }
}

/// Session whose status/stage the test seeds in a **production shape** — the
/// real projection is covered by test/state/device_session_stage_test.dart,
/// while these UI tests pin the banner mapping for the pairs the session
/// actually produces (a drop redial keeps `connected`, a forced rebuild
/// suspends to `disconnected`, a first dial sits on `connecting`).
class _StagedSession extends FakeDeviceSession {
  _StagedSession({
    required super.deviceId,
    required super.params,
    required DeviceStatus status,
    required String stage,
    this.kickedFlag = false,
  }) {
    this.status = status;
    connectionStageOverride = stage;
  }

  String? connectionStageOverride;

  final bool kickedFlag;

  @override
  String? get connectionStage => connectionStageOverride;

  @override
  bool get kicked => kickedFlag;
}

class _RecordingObserver extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

Widget wrap(Widget child, {NavigatorObserver? observer}) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      navigatorObservers: [if (observer != null) observer],
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

Future<(DeviceStore, Device)> setupDevice() async {
  SharedPreferences.setMockInitialValues({});
  final store = DeviceStore();
  await store.load();
  final device = await store.addUrl(
      'https://zcode.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=songsong&app_version=3.8.1'
          .replaceFirst('zcode.ai', 'zcode.z.ai'));
  return (store, device);
}

void usePhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(installFakeWebViewPlatform);

  testWidgets('each stage renders on its real production status pair',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();

    for (final (status, stage, title, bodyPart) in [
      // A post-drop redial: the session deliberately keeps `connected`.
      (DeviceStatus.connected, 'reconnecting', '正在重连…', '正在自动重连；网络恢复后会自行恢复'),
      // A forced rebuild: `_forceRebuildAfterStall` suspends first.
      (DeviceStatus.disconnected, 'rebuilding', '正在重建连接…', '链路失去响应，正在重建连接'),
      // A re-pair wait after the desktop went away.
      (DeviceStatus.connected, 'pairing', '等待桌面端配对…', '正在等桌面端接受本次配对'),
      // The one shape the old status gate could see at all.
      (DeviceStatus.connecting, 'pairing', '等待桌面端配对…', '正在等桌面端接受本次配对'),
    ]) {
      final session = _StagedSession(
        deviceId: device.id,
        params: device.params!,
        status: status,
        stage: stage,
      );
      addTearDown(session.dispose);

      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: _GatedHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(title), findsOneWidget,
          reason: 'status=$status stage=$stage must render its title');
      expect(find.textContaining(bodyPart), findsOneWidget,
          reason: 'status=$status stage=$stage must render its body');
      // The online card must not win while a stage is live.
      expect(find.text('本次连接可以查看当前设备上已打开的项目、任务和会话；二维码失效后需要回到桌面端重新连接。'),
          findsNothing);
    }
  });

  testWidgets('a kicked session wins over a stage (terminal state)',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = _StagedSession(
      deviceId: device.id,
      params: device.params!,
      status: DeviceStatus.error,
      stage: 'reconnecting',
      kickedFlag: true,
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: _GatedHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('已被其他终端接管'), findsWidgets);
    expect(find.text('其他终端占用了此设备连接，可等待其退出后重试'), findsOneWidget);
    expect(find.text('正在重连…'), findsNothing,
        reason: 'a stage must never paper over the terminal kicked state');
  });

  testWidgets('without a stage the banner keeps the plain connecting copy',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
    )..status = DeviceStatus.connecting;
    addTearDown(session.dispose);

    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: _GatedHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('连接中…'), findsWidgets);
    expect(find.text('正在连接桌面端…'), findsOneWidget);
  });

  testWidgets('a slow handover disables the web button and shows progress',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final hub = _GatedHub(nativeListEnabled: () => false)..gate = Completer();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
    )..status = DeviceStatus.error;
    addTearDown(session.dispose);

    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: hub,
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.widgetWithText(TextButton, '网页版打开'));
    await tester.pump();

    expect(hub.suspended, [device.id]);
    expect(find.byType(CircularProgressIndicator), findsWidgets,
        reason: 'the fallback button reports the suspend wait');
    expect(find.byType(RemotePage), findsNothing);

    hub.gate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RemotePage), findsOneWidget);
  });

  testWidgets('a failed handover toasts and never navigates', (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final hub = _GatedHub(nativeListEnabled: () => false)
      ..error = StateError('suspend exploded');
    final observer = _RecordingObserver();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
    )..status = DeviceStatus.error;
    addTearDown(session.dispose);

    await tester.pumpWidget(wrap(
      TaskListPage(
        store: store,
        hub: hub,
        device: device,
        sessionOverride: session,
      ),
      observer: observer,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final before = observer.pushed.length;
    await tester.tap(find.widgetWithText(TextButton, '网页版打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('无法让位给网页版，请稍后重试。'), findsOneWidget);
    expect(find.byType(RemotePage), findsNothing);
    expect(observer.pushed.length, before,
        reason: 'a failed suspend must not push the WebView');
  });
}