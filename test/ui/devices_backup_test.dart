// Devices page — encrypted backup export/import dialogs. The platform
// channels are injected fakes: save captures the ciphertext, the file picker
// path is unused (raw text is pasted), and the plan token store is in memory.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/notifications/keepalive_controller.dart';
import 'package:zgo/plan/plan_account.dart';
import 'package:zgo/plan/plan_local_memo.dart';
import 'package:zgo/state/device_backup.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/state/scheduled_store.dart';
import 'package:zgo/ui/device_backup_io.dart';
import 'package:zgo/ui/devices_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

class FakeTokenStore implements PlanTokenStore {
  FakeTokenStore([this.token]);

  String? token;
  int writes = 0;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String value) async {
    writes++;
    token = value;
  }

  @override
  Future<void> clearToken() async => token = null;

  @override
  Future<String> deviceMid() async => 'mid-test';
}

class FakePlanMemo implements PlanLocalMemo {
  DateTime? expiry;

  @override
  Future<DateTime?> readPlanExpiry() async => expiry;

  @override
  Future<void> writePlanExpiry(DateTime d) async => expiry = d;

  @override
  Future<void> clearPlanExpiry() async => expiry = null;
}

Map<String, dynamic> backupDevice(String url) => {
      'id': 'dev-1',
      'label': 'Desk',
      'url': url,
      'addedAt': 1700000000000,
      'sortOrder': 0,
    };

String makeJwt({int? exp}) {
  final claims = <String, Object?>{'user_id': 'user-1', 'sub': 'user-1'};
  if (exp != null) claims['exp'] = exp;
  final payload = base64Url.encode(utf8.encode(jsonEncode(claims)));
  return 'aaa.$payload.sig';
}

Widget wrap(Widget page, UiSettings ui) => MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: ui, child: child!),
      home: page,
    );

Future<void> pumpPage(
  WidgetTester tester, {
  required DeviceStore store,
  PlanController? plan,
  SaveBackupFile? saveBackupFile,
  ShareBackupFile? shareBackupFile,
  ReadBackupFile? readBackupFile,
}) async {
  final ui = UiSettings();
  await tester.pumpWidget(wrap(
    DevicesPage(
      store: store,
      theme: ThemeController(),
      ui: ui,
      hub: DeviceSessionHub(nativeListEnabled: () => true),
      scheduled: ScheduledStore(),
      keepalive: KeepAliveController(),
      plan: plan,
      saveBackupFile: saveBackupFile,
      shareBackupFile: shareBackupFile,
      readBackupFile: readBackupFile,
    ),
    ui,
  ));
  await tester.pumpAndSettle();
}

/// Completions of `compute` arrive on a real event loop; widget-test fake
/// async only advances under runAsync, so poll both.
Future<void> waitFor(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not reached within $timeout');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Future<void> openExport(WidgetTester tester) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('导出设备备份'));
  await tester.pumpAndSettle();
}

Future<void> openImport(WidgetTester tester) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('导入设备备份'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('export requires a matching passphrase and saves ciphertext',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await store.addUrl('https://zcode.z.ai/remote/v4?hash=h&t=t&name=Desk');

    String? savedName;
    List<int>? savedBytes;
    var saveCalls = 0;
    await pumpPage(
      tester,
      store: store,
      saveBackupFile: (fileName, bytes) async {
        saveCalls++;
        savedName = fileName;
        savedBytes = bytes;
        return true;
      },
    );
    await openExport(tester);

    final passField = find.byKey(const Key('backup-export-passphrase'));
    final confirmField = find.byKey(const Key('backup-export-confirm'));
    final saveButton = find.byKey(const Key('backup-export-save'));

    await tester.enterText(passField, 'short');
    await tester.enterText(confirmField, 'short');
    await tester.pump();
    expect(find.text('口令至少 8 位'), findsOneWidget);
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);

    await tester.enterText(passField, 'longenough');
    await tester.enterText(confirmField, 'longenough2');
    await tester.pump();
    expect(find.text('两次输入的口令不一致'), findsOneWidget);
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
    expect(saveCalls, 0);

    await tester.enterText(confirmField, 'longenough');
    await tester.pump();
    expect(find.byKey(const Key('backup-export-error')), findsNothing);
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);

    await tester.tap(saveButton);
    await tester.pump();
    expect(find.text('正在加密…'), findsOneWidget);
    await waitFor(tester, () => saveCalls == 1);
    await tester.pumpAndSettle();

    expect(saveCalls, 1);
    expect(savedName, matches(r'^zgo-backup-\d{4}-\d{2}-\d{2}\.zgobak$'));
    final payload =
        decodeBackup(utf8.decode(savedBytes!), passphrase: 'longenough');
    expect(payload.devices.single['url'], store.devices.single.url);
    expect(find.text('备份已保存'), findsOneWidget);
    expect(passField, findsNothing);
  });

  testWidgets('export pre-fills a generated passphrase the user can copy',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await pumpPage(tester, store: store);
    await openExport(tester);

    final passField = find.byKey(const Key('backup-export-passphrase'));
    final confirmField = find.byKey(const Key('backup-export-confirm'));
    final passText = tester.widget<TextField>(passField).controller!.text;

    expect(passText, isNotEmpty);
    expect(passText.length, greaterThanOrEqualTo(8));
    expect(tester.widget<TextField>(confirmField).controller!.text, passText);
    // Visible on purpose: the user must be able to record it.
    expect(tester.widget<TextField>(passField).obscureText, isFalse);

    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.tap(find.byKey(const Key('backup-export-copy-passphrase')));
    await tester.pump();

    final setData =
        calls.where((c) => c.method == 'Clipboard.setData').single;
    expect((setData.arguments as Map)['text'], passText);
    expect(find.text('口令已复制到剪贴板'), findsOneWidget);
  });

  testWidgets('signed-out export warns the credential is left out',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await pumpPage(tester, store: store);
    await openExport(tester);

    expect(find.text('当前未登录，此备份不含账号凭据。'), findsOneWidget);
  });

  testWidgets('v1 plaintext import needs no passphrase', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await pumpPage(tester, store: store);
    await openImport(tester);

    final raw = jsonEncode({
      'app': 'zgo',
      'format': 'devices',
      'version': 1,
      'devices': [
        backupDevice('https://zcode.z.ai/remote/v4?hash=h&t=t&name=Desk'),
      ],
    });
    await tester.enterText(
        find.byKey(const Key('backup-import-raw')), raw);
    await tester.pump();
    expect(find.byKey(const Key('backup-import-passphrase')), findsNothing);

    await tester.tap(find.byKey(const Key('backup-import-confirm')));
    await waitFor(tester, () => store.devices.length == 1);
    await tester.pumpAndSettle();

    expect(store.devices.single.label, 'Desk');
    expect(find.text('已导入 1 台设备'), findsOneWidget);
    expect(find.byKey(const Key('backup-import-raw')), findsNothing);
  });

  testWidgets('v2 import requires the passphrase and restores the token',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final token = makeJwt();
    final fixture = encodeBackup(
      BackupPayload(
        devices: [
          backupDevice('https://zcode.z.ai/remote/v4?sid=s1&mid=m1'),
        ],
        accountToken: token,
      ),
      passphrase: 'correct-horse',
    );
    final store = DeviceStore();
    await store.load();
    final tokenStore = FakeTokenStore();
    final plan = PlanController(store: tokenStore, memo: FakePlanMemo());
    await pumpPage(tester, store: store, plan: plan);
    await openImport(tester);

    final rawField = find.byKey(const Key('backup-import-raw'));
    final passField = find.byKey(const Key('backup-import-passphrase'));
    final confirmButton = find.byKey(const Key('backup-import-confirm'));

    await tester.enterText(rawField, fixture);
    await tester.pump();
    expect(passField, findsOneWidget);

    // Submitting without a passphrase asks for one instead of decrypting.
    await tester.tap(confirmButton);
    await tester.pump();
    expect(find.text('请先输入备份口令'), findsOneWidget);
    expect(store.devices, isEmpty);

    await tester.enterText(passField, 'wrong-pass');
    await tester.tap(confirmButton);
    await waitFor(tester,
        () => find.text('口令错误或备份已损坏').evaluate().isNotEmpty);
    expect(store.devices, isEmpty);
    expect(tokenStore.token, isNull);

    await tester.enterText(passField, 'correct-horse');
    await tester.tap(confirmButton);
    await waitFor(tester, () => tokenStore.token == token);
    await tester.pumpAndSettle();

    expect(store.devices.length, 1);
    expect(plan.signedIn, isTrue);
    expect(tokenStore.writes, 1);
    expect(find.text('已恢复登录状态'), findsOneWidget);
    expect(rawField, findsNothing);
  });

  testWidgets('expired token still imports and warns to sign in again',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final expired = makeJwt(
      exp: DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch ~/
          1000,
    );
    final fixture = encodeBackup(
      BackupPayload(
        devices: [
          backupDevice('https://zcode.z.ai/remote/v4?sid=s2&mid=m2'),
        ],
        accountToken: expired,
      ),
      passphrase: 'correct-horse',
    );
    final store = DeviceStore();
    await store.load();
    final tokenStore = FakeTokenStore();
    final plan = PlanController(store: tokenStore, memo: FakePlanMemo());
    await pumpPage(tester, store: store, plan: plan);
    await openImport(tester);

    await tester.enterText(
        find.byKey(const Key('backup-import-raw')), fixture);
    await tester.pump();
    await tester.enterText(
        find.byKey(const Key('backup-import-passphrase')), 'correct-horse');
    await tester.tap(find.byKey(const Key('backup-import-confirm')));
    await waitFor(tester,
        () => find.text('凭据已过期，请重新登录').evaluate().isNotEmpty);

    expect(store.devices.length, 1);
    expect(tokenStore.token, expired);
    expect(plan.signedIn, isTrue);
  });

  testWidgets('a newer-version backup shows the upgrade copy', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await pumpPage(tester, store: store);
    await openImport(tester);

    await tester.enterText(
      find.byKey(const Key('backup-import-raw')),
      jsonEncode({
        'app': 'zgo',
        'format': 'devices',
        'version': 3,
        'devices': <Object>[],
      }),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('backup-import-confirm')));
    await tester.pump();

    expect(find.text('备份由更高版本的 ZGo 创建，请先升级应用'), findsOneWidget);
    expect(store.devices, isEmpty);
  });

  testWidgets('a failing save channel keeps the dialog and reports it',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await store.addUrl('https://zcode.z.ai/remote/v4?hash=h&t=t&name=Desk');
    await pumpPage(
      tester,
      store: store,
      saveBackupFile: (_, __) async => throw StateError('boom'),
    );
    await openExport(tester);

    await tester.enterText(
        find.byKey(const Key('backup-export-passphrase')), 'longenough');
    await tester.enterText(
        find.byKey(const Key('backup-export-confirm')), 'longenough');
    await tester.pump();
    await tester.tap(find.byKey(const Key('backup-export-save')));
    await waitFor(
        tester, () => find.text('导出失败，请重试').evaluate().isNotEmpty);

    // The passphrase is retained so a retry does not re-type it.
    expect(find.byKey(const Key('backup-export-passphrase')), findsOneWidget);
  });

  testWidgets('a failing file read reports instead of silently ignoring',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await pumpPage(
      tester,
      store: store,
      readBackupFile: () async => throw StateError('boom'),
    );
    await openImport(tester);

    await tester.tap(find.byKey(const Key('backup-import-file')));
    await waitFor(
        tester, () => find.text('无法读取所选文件').evaluate().isNotEmpty);

    expect(find.byKey(const Key('backup-import-error')), findsOneWidget);
  });
}
