import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zlinker/main.dart';
import 'package:zlinker/notifications/keepalive_controller.dart';
import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/state/device_store.dart';
import 'package:zlinker/state/scheduled_store.dart';
import 'package:zlinker/ui/devices_page.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

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

    expect(find.text('ZLinker'), findsOneWidget);
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

  testWidgets('App boots', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ZLinkerApp());
    await tester.pumpAndSettle();
    expect(find.text('ZLinker'), findsOneWidget);
  });
}
