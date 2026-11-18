import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/notifications/keepalive_controller.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/state/scheduled_store.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/devices_page.dart';

import '../helpers/fake_device_session.dart';

/// Session whose status/stage the test seeds in a **production shape** — the
/// real projection is covered by test/state/device_session_stage_test.dart,
/// while this file pins the UI mapping for the pairs the session actually
/// produces (a drop redial keeps `connected`, a forced rebuild suspends to
/// `disconnected`, a first dial sits on `connecting` with no stage).
class _StagedSession extends FakeDeviceSession {
  _StagedSession({
    required super.deviceId,
    required super.params,
    required DeviceStatus status,
    required String this.connectionStage,
    this.kickedFlag = false,
  }) {
    this.status = status;
  }

  @override
  final String? connectionStage;

  final bool kickedFlag;

  @override
  bool get kicked => kickedFlag;
}

/// Session that never dials: seeding `DeviceStatus.error` would otherwise
/// make the page's hub sync call `connect()` and arm the session's retry
/// timer inside the test binding (a pending timer fails the test teardown).
class _OfflineSession extends FakeDeviceSession {
  _OfflineSession({
    required super.deviceId,
    required super.params,
  });

  @override
  Future<void> connect() async {}
}

Widget wrap(Widget child) => MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

Future<(DeviceStore, Device)> setupDevice() async {
  SharedPreferences.setMockInitialValues({});
  final store = DeviceStore();
  await store.load();
  final device = await store.addUrl(
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=songsong&app_version=3.8.1');
  return (store, device);
}

Future<void> pumpDevices(
  WidgetTester tester, {
  required DeviceStore store,
  required DeviceSessionHub hub,
  required UiSettings ui,
}) async {
  await tester.pumpWidget(wrap(DevicesPage(
    store: store,
    theme: ThemeController(),
    ui: ui,
    hub: hub,
    scheduled: ScheduledStore(),
    keepalive: KeepAliveController(),
  )));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('each stage renders on its real production status pair',
      (tester) async {
    final (store, device) = await setupDevice();
    await store.touch(device.id); // would render 上次使用 if not suppressed

    for (final (status, stage, copy) in [
      // A post-drop redial: the session deliberately keeps `connected`.
      (DeviceStatus.connected, 'reconnecting', '正在重连…'),
      // A forced rebuild: `_forceRebuildAfterStall` suspends first.
      (DeviceStatus.disconnected, 'rebuilding', '正在重建连接…'),
      // A re-pair wait after the desktop went away.
      (DeviceStatus.connected, 'pairing', '等待桌面端配对…'),
      // The one shape the old status gate could see at all.
      (DeviceStatus.connecting, 'pairing', '等待桌面端配对…'),
    ]) {
      final hub = DeviceSessionHub(nativeListEnabled: () => true);
      final session = _StagedSession(
        deviceId: device.id,
        params: device.params!,
        status: status,
        connectionStage: stage,
      );
      addTearDown(session.dispose);
      hub.installForTesting(session);

      await pumpDevices(tester, store: store, hub: hub, ui: UiSettings());

      expect(find.textContaining(copy, findRichText: true), findsOneWidget,
          reason: 'status=$status stage=$stage must render its short copy');
      // A stage owns the one-line subtitle: 上次使用 loses its slot.
      expect(find.textContaining('上次使用', findRichText: true), findsNothing);
      expect(find.textContaining('从未使用', findRichText: true), findsNothing);
    }
  });

  testWidgets('a first dial without a stage keeps the plain connecting copy',
      (tester) async {
    final (store, device) = await setupDevice();
    // Seed the stat so the 上次使用 segment would render if it kept its slot.
    await store.touch(device.id);
    final hub = DeviceSessionHub(nativeListEnabled: () => true);
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
    )..status = DeviceStatus.connecting;
    addTearDown(session.dispose);
    hub.installForTesting(session);

    await pumpDevices(tester, store: store, hub: hub, ui: UiSettings());

    expect(find.textContaining('连接中…', findRichText: true), findsOneWidget);
    expect(find.textContaining('上次使用', findRichText: true), findsOneWidget,
        reason: 'without a stage the 上次使用 segment keeps its slot');
  });

  testWidgets('a connected card with no stage still reads 在线',
      (tester) async {
    final (store, device) = await setupDevice();
    final hub = DeviceSessionHub(nativeListEnabled: () => true);
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
    );
    addTearDown(session.dispose);
    hub.installForTesting(session);

    await pumpDevices(tester, store: store, hub: hub, ui: UiSettings());

    expect(find.textContaining('在线', findRichText: true), findsOneWidget);
  });

  testWidgets('a plain error status reads the neutral device copy',
      (tester) async {
    // DeviceStatus.error without an auth/kicked detail is a neutral device
    // state label, not a list hint — the old copy carried a "use the web
    // version" instruction that belongs to no surface here.
    final (store, device) = await setupDevice();
    final hub = DeviceSessionHub(nativeListEnabled: () => true);
    final session = _OfflineSession(
      deviceId: device.id,
      params: device.params!,
    )..status = DeviceStatus.error;
    addTearDown(session.dispose);
    hub.installForTesting(session);

    await pumpDevices(tester, store: store, hub: hub, ui: UiSettings());

    expect(find.textContaining('连接异常', findRichText: true), findsOneWidget);
    expect(find.textContaining('请用网页版', findRichText: true), findsNothing);
  });

  testWidgets('the kicked copy wins over a stage (terminal state)',
      (tester) async {
    final (store, device) = await setupDevice();
    final hub = DeviceSessionHub(nativeListEnabled: () => true);
    final session = _StagedSession(
      deviceId: device.id,
      params: device.params!,
      status: DeviceStatus.error,
      connectionStage: 'reconnecting',
      kickedFlag: true,
    );
    addTearDown(session.dispose);
    hub.installForTesting(session);

    await pumpDevices(tester, store: store, hub: hub, ui: UiSettings());

    expect(find.textContaining('已被其他终端接管', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('正在重连…', findRichText: true), findsNothing,
        reason: 'a stage must never paper over the terminal kicked state');
  });
}