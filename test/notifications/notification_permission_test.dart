import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/notifications/keepalive_controller.dart';
import 'package:zgo/notifications/notification_service.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/ui/settings_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

/// Permission seam (B-04): the real service talks to the plugin channels, so
/// the settings surface takes a fake that answers a scripted verdict.
class FakeNotificationService implements NotificationService {
  FakeNotificationService({this.granted = false});

  bool? granted;
  int permissionRequests = 0;
  bool openedSettings = false;

  @override
  bool get isReady => true;

  @override
  Future<bool?> requestPermission({bool force = false}) async {
    permissionRequests += 1;
    return granted;
  }

  @override
  Future<bool> openAppNotificationSettings() async {
    openedSettings = true;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget host(Widget page, UiSettings ui) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: ui, child: child!),
      home: page,
    );

Future<(UiSettings, FakeNotificationService)> pumpSettings(
  WidgetTester tester,
  FakeNotificationService service,
) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final ui = UiSettings();
  // Start with the master switch off so the test can turn it on — that
  // transition is the permission moment.
  ui.notificationsEnabled = false;
  await tester.pumpWidget(host(
    SettingsPage(
      store: DeviceStore(),
      theme: ThemeController(),
      ui: ui,
      keepalive: KeepAliveController(),
      notifications: service,
    ),
    ui,
  ));
  await tester.pumpAndSettle();
  return (ui, service);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a denied permission says so once and offers the settings '
      'action', (tester) async {
    final (ui, service) = await pumpSettings(
      tester,
      FakeNotificationService(granted: false),
    );

    await tester.tap(find.widgetWithText(SwitchListTile, '通知'));
    await tester.pumpAndSettle();

    expect(ui.notificationsEnabled, isTrue,
        reason: 'the switch is the user intent — it persists either way');
    expect(service.permissionRequests, 1);
    expect(find.textContaining('系统未允许通知'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);

    // The action opens the OS notification settings through the service.
    await tester.tap(find.text('去设置'));
    await tester.pumpAndSettle();
    expect(service.openedSettings, isTrue);
  });

  testWidgets('a granted permission shows no nudge', (tester) async {
    final (ui, service) =
        await pumpSettings(tester, FakeNotificationService(granted: true));

    await tester.tap(find.widgetWithText(SwitchListTile, '通知'));
    await tester.pumpAndSettle();

    expect(ui.notificationsEnabled, isTrue);
    expect(service.permissionRequests, 1);
    expect(find.textContaining('系统未允许通知'), findsNothing);
  });

  testWidgets('an unknown verdict (null: no platform implementation) stays '
      'silent', (tester) async {
    final (_, service) =
        await pumpSettings(tester, FakeNotificationService(granted: null));

    await tester.tap(find.widgetWithText(SwitchListTile, '通知'));
    await tester.pumpAndSettle();

    expect(service.permissionRequests, 1);
    expect(find.textContaining('系统未允许通知'), findsNothing,
        reason: '"cannot know" must never nag as if the user denied');
  });

  testWidgets('turning the master switch off asks nothing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ui = UiSettings(); // master switch defaults on
    final service = FakeNotificationService(granted: false);
    await tester.pumpWidget(host(
      SettingsPage(
        store: DeviceStore(),
        theme: ThemeController(),
        ui: ui,
        keepalive: KeepAliveController(),
        notifications: service,
      ),
      ui,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SwitchListTile, '通知'));
    await tester.pumpAndSettle();

    expect(ui.notificationsEnabled, isFalse);
    expect(service.permissionRequests, 0);
    expect(find.textContaining('系统未允许通知'), findsNothing);
  });
}
