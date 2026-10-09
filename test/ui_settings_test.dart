import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/ui/ui_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UiSettings persistence', () {
    test('locale and nativeListEnabled round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      final s = UiSettings();
      await s.load();
      expect(s.locale, 'zh-CN');
      expect(s.nativeListEnabled, isTrue);

      await s.setLocale('en-US');
      await s.setNativeListEnabled(false);

      final s2 = UiSettings();
      await s2.load();
      expect(s2.locale, 'en-US');
      expect(s2.nativeListEnabled, isFalse);
    });
  });

  group('tr lookup', () {
    Widget host(UiSettings settings) => UiSettingsProvider(
          settings: settings,
          child: Builder(builder: (context) => const SizedBox()),
        );

    testWidgets('zh table by default, en when locale switches',
        (WidgetTester tester) async {
      final s = UiSettings();
      await tester.pumpWidget(host(s));
      final ctx = tester.element(find.byType(SizedBox));
      expect(tr(ctx, 'status.online'), '在线');

      s.locale = 'en-US';
      await tester.pump();
      expect(tr(ctx, 'status.online'), 'Online');
    });

    testWidgets('unknown key falls back to itself', (WidgetTester tester) async {
      final s = UiSettings();
      await tester.pumpWidget(host(s));
      final ctx = tester.element(find.byType(SizedBox));
      expect(tr(ctx, 'no.such.key'), 'no.such.key');
    });

    testWidgets('trP substitutes positional args', (WidgetTester tester) async {
      final s = UiSettings();
      await tester.pumpWidget(host(s));
      final ctx = tester.element(find.byType(SizedBox));
      expect(trP(ctx, 'devices.import.done', ['2']), '已导入 2 台设备');
    });
  });

  group('usage formatters', () {
    Widget host(UiSettings settings) => UiSettingsProvider(
          settings: settings,
          child: Builder(builder: (context) => const SizedBox()),
        );

    Future<BuildContext> ctxOf(WidgetTester tester,
        {String locale = 'zh-CN'}) async {
      final s = UiSettings()..locale = locale;
      await tester.pumpWidget(host(s));
      return tester.element(find.byType(SizedBox));
    }

    test('usageDurationParts reads whole minutes, never seconds', () {
      expect(usageDurationParts(0), (0, 0, 0));
      expect(usageDurationParts(60 * 1000), (0, 0, 1));
      expect(usageDurationParts(65200000), (0, 18, 6)); // 18h 6m
      expect(usageDurationParts((2 * 1440 + 3 * 60 + 5) * 60000), (2, 3, 5));
    });

    testWidgets('usageDuration drops zero parts and renders 0 分钟',
        (WidgetTester tester) async {
      final ctx = await ctxOf(tester);
      expect(usageDuration(ctx, 0), '0 分钟');
      expect(usageDuration(ctx, 90000), '1 分钟');
      expect(usageDuration(ctx, (2 * 1440 + 3 * 60) * 60000), '2 天 3 小时');
    });

    testWidgets('compactTokens adds the 亿 branch and is plain below 1e4',
        (WidgetTester tester) async {
      final zh = await ctxOf(tester);
      expect(compactTokens(zh, 624000000), '6.2亿');
      expect(compactTokens(zh, 62400000000), '624亿');
      expect(compactTokens(zh, 12000), '1.2万');
      expect(compactTokens(zh, 9999), '9999');

      final en = await ctxOf(tester, locale: 'en-US');
      expect(compactTokens(en, 12000), '12k');
    });
  });
}
