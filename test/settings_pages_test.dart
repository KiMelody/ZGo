import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zlinker/state/device_store.dart';
import 'package:zlinker/ui/settings_page.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';
import 'package:zlinker/ui/usage_stats_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget page, UiSettings ui) => MaterialApp(
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: ui, child: child!),
        home: page,
      );

  group('SettingsPage', () {
    testWidgets('theme segmented control switches mode',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = DeviceStore();
      final theme = ThemeController();
      final ui = UiSettings();
      await tester.pumpWidget(
          host(SettingsPage(store: store, theme: theme, ui: ui), ui));
      await tester.pumpAndSettle();

      expect(theme.mode, ThemeMode.dark); // default
      await tester.tap(find.text('浅色'));
      await tester.pumpAndSettle();
      expect(theme.mode, ThemeMode.light);
    });

    testWidgets('native list switch toggles the setting',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = DeviceStore();
      final theme = ThemeController();
      final ui = UiSettings();
      await tester.pumpWidget(
          host(SettingsPage(store: store, theme: theme, ui: ui), ui));
      await tester.pumpAndSettle();

      expect(ui.nativeListEnabled, isTrue);
      await tester
          .tap(find.widgetWithText(SwitchListTile, '原生任务列表'));
      await tester.pumpAndSettle();
      expect(ui.nativeListEnabled, isFalse);
    });

    testWidgets('notification switches toggle master and channels',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = DeviceStore();
      final theme = ThemeController();
      final ui = UiSettings();
      await tester.pumpWidget(
          host(SettingsPage(store: store, theme: theme, ui: ui), ui));
      await tester.pumpAndSettle();

      // Channel rows are visible while the master switch is on.
      expect(find.text('任务事件'), findsOneWidget);
      expect(find.text('闲时事件'), findsOneWidget);
      expect(find.text('自动化结果'), findsOneWidget);

      await tester
          .tap(find.widgetWithText(SwitchListTile, '任务事件'));
      await tester.pumpAndSettle();
      expect(ui.notifyTasksEnabled, isFalse);
      expect(ui.notificationsEnabled, isTrue);

      // Master off hides the channel rows.
      await tester
          .tap(find.widgetWithText(SwitchListTile, '通知'));
      await tester.pumpAndSettle();
      expect(ui.notificationsEnabled, isFalse);
      expect(find.text('任务事件'), findsNothing);
    });

    testWidgets('language switches texts live', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = DeviceStore();
      final theme = ThemeController();
      final ui = UiSettings();
      await tester.pumpWidget(
          host(SettingsPage(store: store, theme: theme, ui: ui), ui));
      await tester.pumpAndSettle();

      expect(find.text('外观'), findsOneWidget);
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);
      expect(ui.locale, 'en-US');
    });
  });

  group('UsageStatsPage', () {
    testWidgets('shows summary and per-device stats',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = DeviceStore();
      await store.load();
      final d = await store.addUrl(
          'https://zcode.z.ai/remote/v4?sid=a&hash=b&t=1&name=work-pc');
      await store.touch(d.id);
      await store.touch(d.id);

      final ui = UiSettings();
      await tester.pumpWidget(
          host(UsageStatsPage(store: store, ui: ui), ui));
      await tester.pumpAndSettle();

      expect(find.text('work-pc'), findsOneWidget);
      expect(find.text('2 次'), findsOneWidget);
      expect(find.text('设备数'), findsOneWidget);
    });
  });
}
