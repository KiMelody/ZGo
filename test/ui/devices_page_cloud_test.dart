import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/notifications/keepalive_controller.dart';
import 'package:zgo/plan/plan_account.dart';
import 'package:zgo/plan/remote_device_api.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/state/scheduled_store.dart';
import 'package:zgo/ui/devices_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

/// In-memory token store (the secure-storage plugin has no test backing).
class _FakeTokenStore implements PlanTokenStore {
  _FakeTokenStore([this.token]);
  String? token;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String token) async => this.token = token;

  @override
  Future<void> clearToken() async => token = null;

  @override
  Future<String> deviceMid() async => 'mid-local';
}

Map<String, dynamic> cloudRow({
  required String sid,
  required String mid,
  required String name,
  String platform = 'win32',
  String version = '3.16.2',
  bool online = true,
}) =>
    {
      'device_sid': sid,
      'device_mid': mid,
      'online': online,
      'created_at': 1758000000,
      'meta': {'name': name, 'platform': platform, 'version': version},
    };

RemoteDeviceApi cloudApi(
  List<Map<String, dynamic>> rows, {
  int status = 200,
  void Function()? onRequest,
}) =>
    RemoteDeviceApi(
      client: MockClient((req) async {
        onRequest?.call();
        return http.Response(
          jsonEncode(status == 200
              ? {'code': 0, 'msg': '', 'data': rows}
              : {'code': 500, 'msg': 'boom'}),
          status,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

Widget wrap(DevicesPage page, UiSettings ui) => MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: ui, child: child!),
      home: page,
    );

Future<DeviceSessionHub> pumpDevices(
  WidgetTester tester, {
  required DeviceStore store,
  required PlanController plan,
  required RemoteDeviceApi api,
}) async {
  final ui = UiSettings();
  // No jwtProvider: sessions built for V2 links settle on auth-required
  // without dialing (no network in widget tests).
  final hub = DeviceSessionHub(nativeListEnabled: () => true);
  await tester.pumpWidget(wrap(
    DevicesPage(
      store: store,
      theme: ThemeController(),
      ui: ui,
      hub: hub,
      scheduled: ScheduledStore(),
      keepalive: KeepAliveController(),
      plan: plan,
      cloudApi: api,
    ),
    ui,
  ));
  await tester.pumpAndSettle();
  return hub;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cloud section lists only unadded devices with connect / '
      'offline states', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=sid-local&mid=mid-added'
        '&name=Melody&app_version=3.16.2');

    final plan = PlanController(store: _FakeTokenStore('tok'));
    await plan.loadIdentity();
    var requests = 0;
    final api = cloudApi([
      cloudRow(sid: 'sid-added', mid: 'mid-added', name: 'Melody'),
      cloudRow(
        sid: 'sid-new',
        mid: 'mid-new',
        name: 'Studio',
        platform: 'darwin',
      ),
      cloudRow(
        sid: 'sid-off',
        mid: 'mid-off',
        name: '书房的机器',
        platform: 'linux',
        version: '3.15.3',
        online: false,
      ),
    ], onRequest: () => requests++);

    await pumpDevices(tester, store: store, plan: plan, api: api);

    // R2: one fetch on page entry, no polling.
    expect(requests, 1);
    expect(find.text('账号设备'), findsOneWidget);
    expect(find.text('登录同一账号、尚未添加'), findsOneWidget);
    // R1: the mid-matched row (already added) never renders — the only
    // 'Melody' left is the local card.
    expect(find.text('已添加'), findsNothing);
    expect(find.text('Melody'), findsOneWidget);
    expect(find.text('win32 · 3.16.2'), findsNothing);
    expect(find.text('darwin · 3.16.2'), findsOneWidget);
    expect(find.text('linux · 3.15.3'), findsOneWidget);

    final connect = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '连接'));
    expect(connect.onPressed, isNotNull);
    // R3: offline entries keep the button but disable it.
    final offline = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '离线'));
    expect(offline.onPressed, isNull);
  });

  testWidgets('cloud section disappears when every account device is added',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=sid-local&mid=mid-added'
        '&name=Melody&app_version=3.16.2');
    final plan = PlanController(store: _FakeTokenStore('tok'));
    await plan.loadIdentity();
    final api = cloudApi([
      cloudRow(sid: 'sid-added', mid: 'mid-added', name: 'Melody'),
    ]);

    await pumpDevices(tester, store: store, plan: plan, api: api);

    // R1: nothing left to discover — the whole section folds away.
    expect(find.text('账号设备'), findsNothing);
    expect(find.text('登录同一账号、尚未添加'), findsNothing);
    expect(find.text('已添加'), findsNothing);
    expect(find.text('win32 · 3.16.2'), findsNothing);
  });

  testWidgets('tapping connect adds the V2 link through the store',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    final plan = PlanController(store: _FakeTokenStore('tok'));
    await plan.loadIdentity();
    final api = cloudApi([
      cloudRow(sid: 'sid-new', mid: 'mid-new', name: 'Studio'),
    ]);

    await pumpDevices(tester, store: store, plan: plan, api: api);
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pump();

    expect(store.devices, hasLength(1));
    final params = store.devices.single.params;
    expect(params, isNotNull);
    expect(params!.deviceSid, 'sid-new');
    expect(params.deviceMid, 'mid-new');
    expect(params.deviceName, 'Studio');
    expect(params.appVersion, '3.16.2');
  });

  testWidgets('signed-out hosts neither fetch nor render the section',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    final plan = PlanController(store: _FakeTokenStore());
    await plan.loadIdentity();
    var requests = 0;
    final api = cloudApi([
      cloudRow(sid: 'sid-new', mid: 'mid-new', name: 'Studio'),
    ], onRequest: () => requests++);

    await pumpDevices(tester, store: store, plan: plan, api: api);

    expect(requests, 0);
    expect(find.text('账号设备'), findsNothing);
  });

  testWidgets('a failed fetch collapses the section silently', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    final plan = PlanController(store: _FakeTokenStore('tok'));
    await plan.loadIdentity();
    final api = cloudApi(const [], status: 500);

    await pumpDevices(tester, store: store, plan: plan, api: api);

    expect(find.text('账号设备'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
      'an in-flight fetch for a stale token never renders after an '
      'account switch', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    final plan = PlanController(store: _FakeTokenStore('tokA'));
    await plan.loadIdentity();
    final responses = <Completer<http.Response>>[];
    http.Response ok(List<Map<String, dynamic>> rows) => http.Response(
          jsonEncode({'code': 0, 'msg': '', 'data': rows}),
          200,
          headers: {'content-type': 'application/json'},
        );
    final api = RemoteDeviceApi(
      client: MockClient((req) {
        final c = Completer<http.Response>();
        responses.add(c);
        return c.future;
      }),
    );

    await pumpDevices(tester, store: store, plan: plan, api: api);
    expect(responses.length, 1); // A's fetch parked.

    // Sign straight into B (no sign-out): the new token's fetch must not
    // be swallowed by A's in-flight one.
    plan.signIn('tokB');
    await tester.pump();
    expect(responses.length, 2);

    // A's late response belongs to the previous account.
    responses[0]
        .complete(ok([cloudRow(sid: 'a', mid: 'mid-a', name: 'A的桌面')]));
    await tester.pumpAndSettle();
    expect(find.text('A的桌面'), findsNothing);

    responses[1]
        .complete(ok([cloudRow(sid: 'b', mid: 'mid-b', name: 'B的桌面')]));
    await tester.pumpAndSettle();
    expect(find.text('B的桌面'), findsOneWidget);
  });
}
