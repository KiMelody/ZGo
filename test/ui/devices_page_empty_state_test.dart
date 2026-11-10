// Devices page — first run: the empty state carries the two-step guidance and
// a one-hop "scan to add" button that pushes the scanner through zRoute,
// instead of forcing FAB → add sheet → scan.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/notifications/keepalive_controller.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/state/scheduled_store.dart';
import 'package:zgo/ui/qr_scan_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/devices_page.dart';

Widget wrap(Widget page, UiSettings ui) => MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: ui, child: child!),
      home: page,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty store shows the two-step guidance and a scan button '
      'that opens the scanner in one hop', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    final ui = UiSettings();
    await tester.pumpWidget(wrap(
      DevicesPage(
        store: store,
        theme: ThemeController(),
        ui: ui,
        hub: DeviceSessionHub(nativeListEnabled: () => true),
        scheduled: ScheduledStore(),
        keepalive: KeepAliveController(),
      ),
      ui,
    ));
    await tester.pumpAndSettle();

    // First run: the guidance names both desktop-side steps.
    expect(find.text('还没有设备'), findsOneWidget);
    expect(
      find.text('在桌面 ZCode 中打开「远程控制」，\n扫码或粘贴链接即可添加设备'),
      findsOneWidget,
    );

    // The card's own button is the one-hop path to the scanner.
    final scan = find.widgetWithText(FilledButton, '扫码添加');
    expect(scan, findsOneWidget);

    await tester.tap(scan);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(QrScanPage), findsOneWidget);
  });
}