// Devices page — the empty-shell failure state: a broken preference channel
// must show the diagnostic + retry instead of spinning forever, and the
// add-device FAB must stay hidden.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/notifications/keepalive_controller.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/state/scheduled_store.dart';
import 'package:zgo/ui/devices_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

Widget wrap(Widget page, UiSettings ui) => MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: ui, child: child!),
      home: page,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loadError shows the failure state, hides the FAB, and retry '
      'reloads', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    // First load fails like a missing plugin channel; the retry succeeds.
    final store = DeviceStore(prefsProvider: () async {
      calls++;
      if (calls == 1) {
        throw PlatformException(
          code: 'channel-error',
          message: 'Unable to establish connection on channel',
        );
      }
      return SharedPreferences.getInstance();
    });
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

    expect(find.text('应用组件加载失败'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, '重试'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('应用组件加载失败'), findsNothing);
    // The healthy provider now reports an empty, loaded store.
    expect(find.text('还没有设备'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });
}
