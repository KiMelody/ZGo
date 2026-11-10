import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/off_peak.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/ui/off_peak_page.dart';
import 'package:zgo/ui/remote_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../helpers/fake_webview_platform.dart';

/// Hub whose `suspend` the test controls (gate = loading window, error =
/// the no-navigation branch).
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

/// Device link answering from a local table (mirrors off_peak_page_test).
class _FakeHost implements OffPeakHost {
  _FakeHost(this._tasks);

  final List<Map<String, dynamic>> _tasks;

  @override
  DeviceStatus status = DeviceStatus.connected;

  @override
  Map<String, dynamic> offPeakScope = const {
    'workspacePath': '/repo',
    'workspaceIdentity': 'repo-id',
  };

  @override
  Future<WorkspacePrep> prepareWorkspace() async =>
      WorkspacePrep.fromMap(const {});

  @override
  late final OffPeakPort offPeak = OffPeakPort(_call, newWire: false);

  Future<dynamic> _call(String method, List<Object?> args) async {
    if (method.contains('list') || method.contains('List')) return _tasks;
    if (method.startsWith('get') || method == 'status') return const {};
    return null;
  }
}

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(installFakeWebViewPlatform);

  testWidgets('a slow handover spins the result button', (tester) async {
    final (store, device) = await setupDevice();
    final hub = _GatedHub(nativeListEnabled: () => false)..gate = Completer();
    final host = _FakeHost([
      {
        'offPeakTaskId': 't2',
        'title': '文档检查',
        'status': 'completed',
        'sessionId': 's-9',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'startedAt': DateTime.now().millisecondsSinceEpoch - 600000,
        'finishedAt': DateTime.now().millisecondsSinceEpoch,
      },
    ]);

    await tester.pumpWidget(wrap(OffPeakPage(
      store: store,
      hub: hub,
      device: device,
      hostOverride: host,
    )));
    await tester.pumpAndSettle();

    // The history tab carries the completed run's 打开会话 action.
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开会话'));
    await tester.pump();

    expect(hub.suspended, [device.id]);
    expect(find.byType(CircularProgressIndicator), findsWidgets,
        reason: 'the handover wait must show on the result button');
    expect(find.byType(RemotePage), findsNothing);

    hub.gate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RemotePage), findsOneWidget);
  });

  testWidgets('a failed handover toasts and never navigates', (tester) async {
    final (store, device) = await setupDevice();
    final hub = _GatedHub(nativeListEnabled: () => false)
      ..error = StateError('suspend exploded');
    final observer = _RecordingObserver();
    final host = _FakeHost([
      {
        'offPeakTaskId': 't3',
        'title': '文档检查',
        'status': 'completed',
        'sessionId': 's-10',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'startedAt': DateTime.now().millisecondsSinceEpoch - 600000,
        'finishedAt': DateTime.now().millisecondsSinceEpoch,
      },
    ]);

    await tester.pumpWidget(wrap(
      OffPeakPage(
        store: store,
        hub: hub,
        device: device,
        hostOverride: host,
      ),
      observer: observer,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();

    final before = observer.pushed.length;
    await tester.tap(find.text('打开会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('无法让位给网页版，请稍后重试。'), findsOneWidget);
    expect(find.byType(RemotePage), findsNothing);
    expect(observer.pushed.length, before,
        reason: 'a failed suspend must not push the WebView');
  });
}