import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/notifications/keepalive_controller.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/state/quota_watch.dart';
import 'package:zgo/ui/settings_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

/// The keep-alive support probe reports Platform.isAndroid, which is false
/// on the test host — the quota-watch section rides that probe, so the
/// test override pins it visible.
class _AlwaysSupportedKeepAlive extends KeepAliveController {
  @override
  bool get supported => true;
}

Widget _host(Widget page, UiSettings ui) => MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: ui, child: child!),
      home: page,
    );

SettingsPage _page(UiSettings ui, QuotaWatchController? controller) =>
    SettingsPage(
      store: DeviceStore(),
      theme: ThemeController(),
      ui: ui,
      keepalive: _AlwaysSupportedKeepAlive(),
      quotaWatch: controller,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The settings ListView builds lazily — enlarge the surface so the whole
  // page (including the quota-watch section) is materialized.
  Future<void> enlargeSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 2800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// The slider inside the ListTile titled [title] (the threshold row and
  /// the two expiry-lead rows each carry exactly one).
  Finder rowSlider(String title) => find.descendant(
        of: find.ancestor(
          of: find.text(title),
          matching: find.byType(ListTile),
        ),
        matching: find.byType(Slider),
      );

  testWidgets('master switch reveals the controls and the keep-alive guide',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await enlargeSurface(tester);
    final ui = UiSettings();
    final controller = QuotaWatchController(
      sessionsOf: () => const [],
      onEvent: (_) {},
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(_page(ui, controller), ui));
    await tester.pumpAndSettle();

    expect(find.text('额度监控'), findsOneWidget);
    // Collapsed while the master switch is off.
    expect(find.text('低额度阈值'), findsNothing);
    expect(find.text('刷新频率'), findsNothing);
    expect(find.text('重置券临期提醒'), findsNothing);
    expect(find.text('5 小时券提醒提前量'), findsNothing);
    expect(find.text('周额度券提醒提前量'), findsNothing);

    await tester.tap(find.text('额度监控通知'));
    await tester.pumpAndSettle();
    expect(ui.quotaWatchEnabled, isTrue);
    expect(find.text('低额度阈值'), findsOneWidget);
    expect(find.text('刷新频率'), findsOneWidget);
    expect(find.text('重置券临期提醒'), findsOneWidget);
    // Reminder defaults on → both per-type lead sliders ride along.
    expect(find.text('5 小时券提醒提前量'), findsOneWidget);
    expect(find.text('周额度券提醒提前量'), findsOneWidget);
    // Keep-alive still off → the guide row shows under the switch.
    expect(find.text('开启后台保活以持续监控 →'), findsOneWidget);
    expect(find.text('剩余低于此值时告警（当前 20%）'), findsOneWidget);
  });

  testWidgets('threshold slider and interval segments drive the settings',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await enlargeSurface(tester);
    final ui = UiSettings()..quotaWatchEnabled = true;
    final controller = QuotaWatchController(
      sessionsOf: () => const [],
      onEvent: (_) {},
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(_page(ui, controller), ui));
    await tester.pumpAndSettle();

    // Drag the threshold slider to its right end → clamps at 50%.
    expect(rowSlider('低额度阈值'), findsOneWidget);
    await tester.drag(rowSlider('低额度阈值'), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(ui.quotaWatchThreshold, 50);

    await tester.tap(find.text('15 分钟'));
    await tester.pumpAndSettle();
    expect(ui.quotaWatchIntervalMinutes, 15);

    // The expiry-reminder switch round-trips.
    await tester.tap(find.text('重置券临期提醒'));
    await tester.pumpAndSettle();
    expect(ui.quotaWatchExpiryReminderEnabled, isFalse);
  });

  testWidgets('expiry-lead sliders default, drive the settings and ride the '
      'reminder switch', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await enlargeSurface(tester);
    final ui = UiSettings()..quotaWatchEnabled = true;
    final controller = QuotaWatchController(
      sessionsOf: () => const [],
      onEvent: (_) {},
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(_page(ui, controller), ui));
    await tester.pumpAndSettle();

    // Defaults: five-hour 60 min, weekly 6 h.
    expect(ui.quotaWatchExpiryLeadFiveHourMinutes, 60);
    expect(ui.quotaWatchExpiryLeadWeeklyHours, 6);
    expect(rowSlider('5 小时券提醒提前量'), findsOneWidget);
    expect(rowSlider('周额度券提醒提前量'), findsOneWidget);

    // Five-hour slider to its left end → clamps at 5 min.
    await tester.drag(rowSlider('5 小时券提醒提前量'), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(ui.quotaWatchExpiryLeadFiveHourMinutes, 5);

    // Weekly slider to its right end → clamps at 10 h.
    await tester.drag(rowSlider('周额度券提醒提前量'), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(ui.quotaWatchExpiryLeadWeeklyHours, 10);

    // Reminder off → the lead sliders disappear with it.
    await tester.tap(find.text('重置券临期提醒'));
    await tester.pumpAndSettle();
    expect(find.text('5 小时券提醒提前量'), findsNothing);
    expect(find.text('周额度券提醒提前量'), findsNothing);
  });

  testWidgets('keep-alive guide enables the service and disappears',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await enlargeSurface(tester);
    final ui = UiSettings()..quotaWatchEnabled = true;
    final controller = QuotaWatchController(
      sessionsOf: () => const [],
      onEvent: (_) {},
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(_page(ui, controller), ui));
    await tester.pumpAndSettle();

    await tester.tap(find.text('开启后台保活以持续监控 →'));
    await tester.pumpAndSettle();
    expect(ui.keepAliveEnabled, isTrue);
    expect(find.text('开启后台保活以持续监控 →'), findsNothing);
  });

  testWidgets('child rows share one indented left edge (B12)',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await enlargeSurface(tester);
    final ui = UiSettings()..quotaWatchEnabled = true;
    final controller = QuotaWatchController(
      sessionsOf: () => const [],
      onEvent: (_) {},
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(_page(ui, controller), ui));
    await tester.pumpAndSettle();

    // Child rows indent one ZSpacing tier past the M3 default start 16;
    // combined with the invisible 24-wide leading slot every child title
    // lands on a single edge (parent title +16).
    const childPadding =
        EdgeInsetsDirectional.only(start: 16 + ZSpacing.cardGap, end: 24);

    SwitchListTile switchOf(String title) => tester.widget<SwitchListTile>(
          find.ancestor(
            of: find.text(title),
            matching: find.byType(SwitchListTile),
          ),
        );
    expect(switchOf('任务事件').contentPadding, childPadding);
    expect(switchOf('重置券临期提醒').contentPadding, childPadding);

    // Slider rows carry the same structure as the switches.
    ListTile tileOf(String title) => tester.widget<ListTile>(
          find.ancestor(
            of: find.text(title),
            matching: find.byType(ListTile),
          ),
        );
    expect(tileOf('低额度阈值').contentPadding, childPadding);
    expect(tileOf('低额度阈值').leading, isA<SizedBox>());
    // The interval row was promoted from Padding+Row to the same ListTile
    // structure, so its label rides the shared child edge too.
    expect(tileOf('刷新频率').contentPadding, childPadding);
    expect(tileOf('刷新频率').leading, isA<SizedBox>());
    for (final title in ['5 小时券提醒提前量', '周额度券提醒提前量']) {
      expect(tileOf(title).contentPadding, childPadding);
    }

    // The geometry itself: every child title sits exactly one ZSpacing
    // tier right of the parent title (switches and slider rows alike).
    final parentTitleX = tester.getTopLeft(find.text('额度监控通知')).dx;
    for (final title in ['任务事件', '低额度阈值', '刷新频率']) {
      expect(tester.getTopLeft(find.text(title)).dx, parentTitleX + ZSpacing.cardGap,
          reason: 'child row "$title" must indent +16 under the parent');
    }

    // The keep-alive guide button rides the same child edge (its box, at
    // least — the button carries its own internal inset).
    final guidePaddings = tester.widgetList<Padding>(find.ancestor(
      of: find.text('开启后台保活以持续监控 →'),
      matching: find.byType(Padding),
    ));
    expect(
      guidePaddings.map((p) => p.padding),
      contains(const EdgeInsets.only(left: 16 + ZSpacing.cardGap)),
    );
  });
}
