import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/main.dart';
import 'package:zgo/notifications/keepalive_controller.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/state/scheduled_store.dart';
import 'package:zgo/ui/devices_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import 'helpers/fake_device_session.dart';

/// A V2 session stuck on the signed-out failure state; [connect] is
/// recorded instead of dialing so the retry path is observable.
class _AuthRequiredSession extends FakeDeviceSession {
  _AuthRequiredSession({required super.deviceId, required super.params}) {
    status = DeviceStatus.error;
    failureReason = 'auth-required';
  }

  int connectCalls = 0;

  @override
  Future<void> connect() async {
    connectCalls += 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(DevicesPage page) => MaterialApp(
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: page,
      );

  testWidgets('DevicesPage shows empty state with no devices',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    final theme = ThemeController();
    final ui = UiSettings();
    final hub = DeviceSessionHub(nativeListEnabled: () => ui.nativeListEnabled);
    await tester.pumpWidget(wrap(DevicesPage(
      store: store,
      theme: theme,
      ui: ui,
      hub: hub,
      scheduled: ScheduledStore(),
      keepalive: KeepAliveController(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('ZGo'), findsOneWidget);
    expect(find.text('还没有设备'), findsOneWidget);
    expect(find.text('添加设备'), findsOneWidget);
  });

  testWidgets('DevicesPage renders a device card',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=songsong&app_version=3.8.1');

    final theme = ThemeController();
    final ui = UiSettings();
    final hub = DeviceSessionHub(nativeListEnabled: () => false);
    await tester.pumpWidget(wrap(DevicesPage(
      store: store,
      theme: theme,
      ui: ui,
      hub: hub,
      scheduled: ScheduledStore(),
      keepalive: KeepAliveController(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('songsong'), findsOneWidget);
    // R5: the row carries 状态 · 时间 only — the host lives in the device's
    // 「更多」detail sheet now. The meta line is one rich text span.
    expect(find.text('zcode.z.ai'), findsNothing);
    expect(find.textContaining('离线', findRichText: true), findsOneWidget);
    expect(find.textContaining('从未使用', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('zcode.z.ai'), findsOneWidget);
  });

  testWidgets('connected device card hides the 上次使用 segment (B14)',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    final device = await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=songsong&app_version=3.8.1');
    // Set the stat so the segment WOULD render in the offline states.
    await store.touch(device.id);

    final theme = ThemeController();
    final ui = UiSettings();
    // true, like the e2e path test: with the switch off the hub's
    // syncWith() tears down every session, including this installed fake.
    final hub = DeviceSessionHub(nativeListEnabled: () => true);
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
    );
    addTearDown(session.dispose);
    hub.installForTesting(session); // fake defaults to DeviceStatus.connected
    await tester.pumpWidget(wrap(DevicesPage(
      store: store,
      theme: theme,
      ui: ui,
      hub: hub,
      scheduled: ScheduledStore(),
      keepalive: KeepAliveController(),
    )));
    await tester.pumpAndSettle();

    // While connected the live status answers "is it alive" — the
    // wall-clock '上次使用' (last app-open moment) reads stale mid-session.
    expect(find.textContaining('在线', findRichText: true), findsOneWidget);
    expect(find.textContaining('上次使用', findRichText: true), findsNothing);
    expect(find.textContaining('从未使用', findRichText: true), findsNothing);
  });

  testWidgets('offline device card keeps the 上次使用 segment (B14)',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    final device = await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=songsong&app_version=3.8.1');
    await store.touch(device.id);

    final theme = ThemeController();
    final ui = UiSettings();
    final hub = DeviceSessionHub(nativeListEnabled: () => false);
    await tester.pumpWidget(wrap(DevicesPage(
      store: store,
      theme: theme,
      ui: ui,
      hub: hub,
      scheduled: ScheduledStore(),
      keepalive: KeepAliveController(),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('离线', findRichText: true), findsOneWidget);
    expect(find.textContaining('上次使用', findRichText: true), findsOneWidget);
  });

  testWidgets('auth-required card offers a retry that reconnects (P1-1)',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    final device = await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=abc&mid=m1&name=songsong&app_version=3.16.2');

    final theme = ThemeController();
    final ui = UiSettings();
    // true so the retry's hub.ensure() really reaches the session.
    final hub = DeviceSessionHub(nativeListEnabled: () => true);
    final session = _AuthRequiredSession(
      deviceId: device.id,
      params: device.params!,
    );
    addTearDown(session.dispose);
    hub.installForTesting(session);
    await tester.pumpWidget(wrap(DevicesPage(
      store: store,
      theme: theme,
      ui: ui,
      hub: hub,
      scheduled: ScheduledStore(),
      keepalive: KeepAliveController(),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('需要登录', findRichText: true), findsOneWidget);
    // The page's own initial sync may already have retried once; the tap
    // below is what this test locks.
    session.connectCalls = 0;

    await tester.tap(find.text('songsong'));
    await tester.pumpAndSettle();
    expect(find.textContaining('设置 → 套餐'), findsOneWidget,
        reason: 'the failure snackbar guides to the real plan entry');

    await tester.tap(find.widgetWithText(SnackBarAction, '重试'));
    await tester.pumpAndSettle();
    expect(session.connectCalls, 1,
        reason: 'retry re-enters the connection instead of dead-ending');
  });

  testWidgets('App boots', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ZGoApp());
    await tester.pumpAndSettle();
    expect(find.text('ZGo'), findsOneWidget);
  });
}
