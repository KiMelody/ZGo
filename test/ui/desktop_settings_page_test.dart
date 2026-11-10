// S1 桌面设置读写面 widget 测试（task 11-06-product-scope-decisions）。
//
// setting 通道 `get`/`update` 的三项最小面一起锁：
//   ① 渲染：zcodeInteractionBehavior=guide 单选选中 / 自动归档开 + 14 天 chip
//      选中 / 显示思考过程=off（mock get 显式返回三字段）。
//   ② 写：切控件 → `setting.update` 收到 `[{<key>: <value>}]` 单字段补丁
//      （逐项抽验三项）。
//   ③ 失败：update 抛错 → SnackBar 出现（deskSet.saveFailed）。
//
// 反自证：删掉 `_showReasoningCard`（第三卡）→ 渲染/写/失败三处断言全红。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/ui/desktop_settings_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../helpers/fake_device_session.dart';

/// Desktop answer for `setting.get` — the three mobile-meaningful keys.
Map<String, dynamic> _settingsPayload() => {
      'zcodeInteractionBehavior': 'guide',
      'taskAutoArchiveEnabled': true,
      'taskAutoArchiveOlderThanDays': 14,
      'messageStreamShowReasoning': false,
    };

Widget _wrap(Widget child, {String locale = 'zh-CN'}) => MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) => UiSettingsProvider(
        settings: UiSettings()..locale = locale,
        child: child!,
      ),
      home: child,
    );

RemoteConnectionParams _params() => RemoteConnectionParams.parse(
      'https://zcode.zai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
    )!;

/// Fake session whose `setting` channel answers [get] and records every
/// `update` patch. [failUpdates] flips the update path to the production
/// rejection shape so the page's SnackBar branch runs.
FakeDeviceSession _session(
  Map<String, dynamic> get, {
  bool failUpdates = false,
}) =>
    FakeDeviceSession(
      deviceId: 'd1',
      params: _params(),
      channelHandler: (channel, method, args) async {
        if (channel != Channels.setting) {
          throw StateError('unexpected channel $channel.$method');
        }
        if (method == 'get') return get;
        if (method == 'update') {
          if (failUpdates) throw ChannelRpcError('probe failure: update', null);
          return null;
        }
        throw StateError('unexpected $channel.$method');
      },
    );

/// The `update` payloads the page sent, in order (args[0] is the patch map).
List<Map<String, dynamic>> _updatesOf(FakeDeviceSession session) => [
      for (final (channel, method, args) in session.channelCalls)
        if (channel == Channels.setting && method == 'update')
          (args.first as Map).cast<String, dynamic>(),
    ];

Future<FakeDeviceSession> _pump(
  WidgetTester tester, {
  Map<String, dynamic>? get,
  bool failUpdates = false,
  String locale = 'zh-CN',
}) async {
  // Tall surface: three cards plus the archive chips column.
  tester.view.physicalSize = const Size(420, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final session = _session(get ?? _settingsPayload(), failUpdates: failUpdates);
  await tester.pumpWidget(
    _wrap(DesktopSettingsPage(session: session), locale: locale),
  );
  await tester.pumpAndSettle();
  return session;
}

Finder _reasoningSwitch([String title = '显示思考过程']) => find.descendant(
      of: find.widgetWithText(Card, title),
      matching: find.byType(Switch),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('S1 desktop settings rendering', () {
    testWidgets('get payload drives all three cards', (tester) async {
      await _pump(tester);

      // ① 交互行为：guide 选中（RadioGroup 的 groupValue 是渲染真值）。
      final group = tester.widget<RadioGroup<String>>(
        find.byType(RadioGroup<String>),
      );
      expect(group.groupValue, 'guide');
      expect(find.text('引导'), findsOneWidget);

      // ② 自动归档：开关 on + 14 天 chip 选中。
      final archiveSwitch = tester.widget<Switch>(find.descendant(
        of: find.widgetWithText(Card, '自动归档旧任务'),
        matching: find.byType(Switch),
      ));
      expect(archiveSwitch.value, isTrue);
      expect(
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '14 天')).selected,
        isTrue,
      );

      // ③ 显示思考过程：wire false → 开关 off。
      expect(tester.widget<Switch>(_reasoningSwitch()).value, isFalse);
      expect(find.text('在消息流中显示模型的推理过程'), findsOneWidget);
    });

    testWidgets('missing reasoning key renders on (desktop default true)',
        (tester) async {
      await _pump(tester, get: {'zcodeInteractionBehavior': 'queue'});

      expect(tester.widget<Switch>(_reasoningSwitch()).value, isTrue,
          reason: 'schema default(true): a missing key means on');
    });

    testWidgets('en locale renders the finished copy (i18n §2.10)',
        (tester) async {
      await _pump(tester, locale: 'en-US');

      expect(find.text('Show reasoning'), findsOneWidget);
      expect(
        find.text("Show the model's reasoning in the message stream"),
        findsOneWidget,
      );
      expect(find.text('Show reasoning'), isNot(equals('deskSet.showReasoning')),
          reason: 'a missing en value would render the raw key');
    });
  });

  group('S1 desktop settings writes', () {
    testWidgets('toggling reasoning sends the single-key patch',
        (tester) async {
      final session = await _pump(tester);

      await tester.tap(_reasoningSwitch());
      await tester.pumpAndSettle();

      expect(_updatesOf(session), [
        {'messageStreamShowReasoning': true},
      ]);
      expect(
        tester.widget<Switch>(_reasoningSwitch()).value,
        isTrue,
        reason: '乐观合并：补丁落地后立即回显',
      );
    });

    testWidgets('picking guide sends the interaction patch', (tester) async {
      final session = await _pump(
        tester,
        get: {
          'zcodeInteractionBehavior': 'queue',
          'messageStreamShowReasoning': true,
        },
      );

      await tester.tap(find.text('引导'));
      await tester.pumpAndSettle();

      expect(_updatesOf(session), [
        {'zcodeInteractionBehavior': 'guide'},
      ]);
    });

    testWidgets('switching auto-archive off sends the enabled patch',
        (tester) async {
      final session = await _pump(tester);

      await tester.tap(find.descendant(
        of: find.widgetWithText(Card, '自动归档旧任务'),
        matching: find.byType(Switch),
      ));
      await tester.pumpAndSettle();

      expect(_updatesOf(session), [
        {'taskAutoArchiveEnabled': false},
      ]);
      expect(find.widgetWithText(ChoiceChip, '14 天'), findsNothing,
          reason: '关掉归档后保留期 chips 收起');
    });
  });

  group('S1 desktop settings failure path', () {
    testWidgets('failed update surfaces the save-failed SnackBar',
        (tester) async {
      final session = await _pump(tester, failUpdates: true);

      await tester.tap(_reasoningSwitch());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(_updatesOf(session), [
        {'messageStreamShowReasoning': true},
      ]);
      final snack = find.byType(SnackBar);
      expect(snack, findsOneWidget);
      final copy = (tester.widget<SnackBar>(snack).content as Text).data ?? '';
      expect(copy, contains('保存失败'));
      expect(
        tester.widget<Switch>(_reasoningSwitch()).value,
        isFalse,
        reason: '失败不落投影：开关回落到 get 的旧值',
      );
    });
  });
}
