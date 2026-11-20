import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/notifications/keepalive_controller.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/ui/settings_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

/// OLED option (2026-11-19): the backdrop stays #000000 while surfaces lift
/// onto a micro-ladder (#0A0A0A card / #0F0F0F tile / #040404 sidebar /
/// #080808 inline code / #050505 code block); text, borders, tracks and
/// status pills keep their normal dark values. The 8960a66 all-black collapse
/// was re-ruled into this ladder after on-device acceptance.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildDarkTheme oled surfaces', () {
    test('oled keeps the backdrop black and lifts surfaces on the ladder',
        () {
      final oled = buildDarkTheme(oled: true);

      // Backdrop: #000000 (OLED pixels off).
      expect(oled.colorScheme.surface, const Color(0xFF000000));

      // Surface ladder: card step, not pure black.
      expect(
          oled.colorScheme.surfaceContainerHighest, const Color(0xFF0A0A0A));
      expect(oled.scaffoldBackgroundColor, const Color(0xFF000000));
      expect(oled.appBarTheme.backgroundColor, const Color(0xFF000000));
      expect(oled.bottomSheetTheme.backgroundColor, const Color(0xFF0A0A0A));
      expect(oled.popupMenuTheme.color, const Color(0xFF0A0A0A));
      expect(oled.inputDecorationTheme.fillColor, const Color(0xFF0A0A0A));
      expect(oled.extension<ZOledFlag>()?.isPureBlack, isTrue);

      // Functional layers keep their normal dark values: borders/tracks
      // stay visible on a black backdrop, snackbars use the card step and
      // flip their ink.
      expect(oled.dividerTheme.color, const Color(0x1AFFFFFF));
      expect(oled.snackBarTheme.backgroundColor, const Color(0xFF0A0A0A));
      expect(oled.snackBarTheme.contentTextStyle?.color, ZColors.neutral200);
    });

    test('non-oled dark theme output is unchanged', () {
      final dark = buildDarkTheme();

      expect(dark.colorScheme.surface, ZColors.darkBackground);
      expect(dark.colorScheme.surfaceContainerHighest, ZColors.darkCard);
      expect(dark.scaffoldBackgroundColor, ZColors.darkBackground);
      expect(dark.appBarTheme.backgroundColor, ZColors.darkBackground);
      expect(dark.bottomSheetTheme.backgroundColor, ZColors.darkCard);
      expect(dark.popupMenuTheme.color, ZColors.darkCard);
      expect(dark.inputDecorationTheme.fillColor, ZColors.darkCard);
      expect(dark.extension<ZOledFlag>(), isNull);
      expect(dark.snackBarTheme.backgroundColor, ZColors.neutral50);
      expect(dark.snackBarTheme.contentTextStyle?.color, ZColors.neutral950);
    });

    test('light theme never carries the flag', () {
      final light = buildLightTheme();

      expect(light.extension<ZOledFlag>(), isNull);
      expect(light.scaffoldBackgroundColor, ZColors.lightBackground);
      expect(light.colorScheme.surface, ZColors.lightBackground);
    });

    test('card / dialog widget themes follow the flag', () {
      expect(zCardTheme(Brightness.dark, oled: true).color,
          const Color(0xFF0A0A0A));
      expect(zDialogTheme(Brightness.dark, oled: true).backgroundColor,
          const Color(0xFF0A0A0A));

      // Non-oled paths are byte-identical to the pre-task values.
      expect(zCardTheme(Brightness.dark).color, ZColors.darkCard);
      expect(zDialogTheme(Brightness.dark).backgroundColor, ZColors.darkCard);
      expect(zCardTheme(Brightness.light).color, ZColors.lightCard);
      expect(zCardTheme(Brightness.light, oled: true).color,
          ZColors.lightCard);
    });
  });

  group('ZInk oled branches', () {
    Future<Color> capture(WidgetTester tester, ThemeData data,
        Color Function(BuildContext) slot) async {
      var color = const Color(0x00000000);
      await tester.pumpWidget(Theme(
        data: data,
        child: Builder(builder: (c) {
          color = slot(c);
          return const SizedBox.shrink();
        }),
      ));
      return color;
    }

    testWidgets('surface slots lift to the oled micro-ladder', (tester) async {
      final oled = buildDarkTheme(oled: true);

      // Each slot maps to its ladder step (PRD 11-19-oled-surface-step).
      expect(await capture(tester, oled, ZInk.tile), const Color(0xFF0F0F0F));
      expect(await capture(tester, oled, ZInk.card), const Color(0xFF0A0A0A));
      expect(await capture(tester, oled, ZInk.codeInlineBg),
          const Color(0xFF080808));
      expect(await capture(tester, oled, ZInk.codeBlockBg),
          const Color(0xFF050505));
      expect(
          await capture(tester, oled, ZInk.sidebar), const Color(0xFF040404));

      // Functional tokens are not surfaces: they stay translucent white.
      expect(await capture(tester, oled, ZInk.hairline),
          const Color(0x14FFFFFF));
      expect(await capture(tester, oled, ZInk.cardBorder),
          const Color(0x1AFFFFFF));
      expect(await capture(tester, oled, ZInk.barTrack),
          const Color(0x1AFFFFFF));
    });

    testWidgets('non-oled dark keeps the near-black ladder', (tester) async {
      final dark = buildDarkTheme();

      expect(await capture(tester, dark, ZInk.tile), ZColors.darkSecondary);
      expect(await capture(tester, dark, ZInk.card), ZColors.darkCard);
      expect(await capture(tester, dark, ZInk.codeInlineBg), ZColors.neutral800);
      expect(await capture(tester, dark, ZInk.codeBlockBg), ZColors.neutral950);
      expect(await capture(tester, dark, ZInk.sidebar), ZColors.darkSidebar);
    });

    testWidgets('light branches are untouched', (tester) async {
      final light = buildLightTheme();

      expect(await capture(tester, light, ZInk.tile), ZColors.lightSecondary);
      expect(await capture(tester, light, ZInk.card), ZColors.lightCard);
      expect(await capture(tester, light, ZInk.codeInlineBg), ZColors.neutral200);
      expect(await capture(tester, light, ZInk.codeBlockBg), ZColors.neutral100);
      expect(await capture(tester, light, ZInk.sidebar), ZColors.lightSidebar);
    });
  });

  group('ThemeController oled persistence', () {
    test('default off and round-trips through SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final theme = ThemeController();
      await theme.load();
      expect(theme.oledBlack, isFalse);

      await theme.setOledBlack(true);
      final reloaded = ThemeController();
      await reloaded.load();
      expect(reloaded.oledBlack, isTrue);

      await reloaded.setOledBlack(false);
      final again = ThemeController();
      await again.load();
      expect(again.oledBlack, isFalse);
    });
  });

  group('SettingsPage oled switch', () {
    Widget host(SettingsPage page, UiSettings ui, ThemeController theme) =>
        MaterialApp(
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: theme.mode,
          builder: (context, child) =>
              UiSettingsProvider(settings: ui, child: child!),
          home: page,
        );

    testWidgets('toggles the setting and disables in light mode',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = DeviceStore();
      final theme = ThemeController();
      final ui = UiSettings()..locale = 'en-US';
      await tester.pumpWidget(host(
          SettingsPage(
              store: store,
              theme: theme,
              ui: ui,
              keepalive: KeepAliveController()),
          ui,
          theme));
      await tester.pumpAndSettle();

      // English finished strings (not raw keys) — i18n.md §2.10.
      expect(find.text('Pure black background (OLED)'), findsOneWidget);
      expect(find.text('Only applies in dark mode'), findsOneWidget);

      await tester.tap(find.widgetWithText(
          SwitchListTile, 'Pure black background (OLED)'));
      await tester.pumpAndSettle();
      expect(theme.oledBlack, isTrue);
      expect(
          tester
              .widget<SwitchListTile>(find.widgetWithText(
                  SwitchListTile, 'Pure black background (OLED)'))
              .value,
          isTrue);

      // Light mode greys the row out but keeps the persisted value so a
      // return to dark restores the user's choice.
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      final tile = tester.widget<SwitchListTile>(find.widgetWithText(
          SwitchListTile, 'Pure black background (OLED)'));
      expect(theme.mode, ThemeMode.light);
      expect(tile.onChanged, isNull);
      expect(tile.value, isTrue);
    });
  });
}