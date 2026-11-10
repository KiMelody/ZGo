import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/notifications/keepalive_controller.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/state/scheduled_store.dart';
import 'package:zgo/ui/remote_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/devices_page.dart';

import '../helpers/fake_device_session.dart';
import '../helpers/fake_webview_platform.dart';

/// Hub whose `suspend` the test controls: [gate] keeps the handover open
/// (loading window) and [error] makes it fail (no-navigation branch).
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

/// Records programmatic pushes so "failure must not navigate" is assertable.
class _RecordingObserver extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

Widget wrap(Widget child, {NavigatorObserver? observer}) => MaterialApp(
      theme: buildLightTheme(),
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
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=songsong&app_version=3.8.1');
  return (store, device);
}

/// The WebView leg is what is under test, so the native-list switch is off
/// (its `_open` branch would push the task list instead).
UiSettings webLegSettings() => UiSettings()..nativeListEnabled = false;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(installFakeWebViewPlatform);

  testWidgets('a slow handover shows progress on the card', (tester) async {
    final (store, device) = await setupDevice();
    final hub = _GatedHub(nativeListEnabled: () => true);
    hub.gate = Completer<void>();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
    );
    addTearDown(session.dispose);
    hub.installForTesting(session);

    await tester.pumpWidget(wrap(DevicesPage(
      store: store,
      theme: ThemeController(),
      ui: webLegSettings(),
      hub: hub,
      scheduled: ScheduledStore(),
      keepalive: KeepAliveController(),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('songsong'));
    await tester.pump();

    expect(hub.suspended, [device.id]);
    expect(find.byType(LinearProgressIndicator), findsOneWidget,
        reason: 'the suspend wait must be visible on the card');
    expect(find.byType(RemotePage), findsNothing);

    // The WebView needs a platform impl; release the gate only after the
    // assertions so the loading window is what gets measured. The remote
    // page's own progress bar never settles, so use finite pumps.
    hub.gate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RemotePage), findsOneWidget);
  });

  testWidgets('a failed handover toasts and never navigates', (tester) async {
    final (store, device) = await setupDevice();
    final hub = _GatedHub(nativeListEnabled: () => true)
      ..error = StateError('suspend exploded');
    final observer = _RecordingObserver();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
    );
    addTearDown(session.dispose);
    hub.installForTesting(session);

    await tester.pumpWidget(wrap(
      DevicesPage(
        store: store,
        theme: ThemeController(),
        ui: webLegSettings(),
        hub: hub,
        scheduled: ScheduledStore(),
        keepalive: KeepAliveController(),
      ),
      observer: observer,
    ));
    await tester.pumpAndSettle();

    final pushesBefore = observer.pushed.length;
    await tester.tap(find.text('songsong'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('无法让位给网页版，请稍后重试。'), findsOneWidget,
        reason: 'the failure copy comes from the lexicon, never a literal');
    expect(find.byType(RemotePage), findsNothing);
    expect(observer.pushed.length, pushesBefore,
        reason: 'a failed suspend must not push the WebView');
    // The busy state is released either way.
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}