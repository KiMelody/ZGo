import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/theme.dart';

/// The 2026-09-19 ZInk slots: every light/dark pair comes from the
/// theme-zai-* value table (design.md §1/§3, direct lifts). These asserts
/// pin both branches so a token drift breaks here, not on a device.
void main() {
  Color slot(BuildContext c, Color Function(BuildContext) f) => f(c);

  Future<(Color, Color)> capture(
      WidgetTester tester, Color Function(BuildContext) f) async {
    // A bare Theme ancestor, not MaterialApp: MaterialApp animates theme
    // swaps (AnimatedTheme), so Theme.of right after the swap still answers
    // with the outgoing palette and dependents don't rebuild per tick.
    var dark = const Color(0x00000000);
    var light = const Color(0x00000000);
    await tester.pumpWidget(Theme(
      data: buildDarkTheme(),
      child: Builder(
          builder: (c) {
            dark = slot(c, f);
            return const SizedBox.shrink();
          }),
    ));
    await tester.pumpWidget(Theme(
      data: buildLightTheme(),
      child: Builder(
          builder: (c) {
            light = slot(c, f);
            return const SizedBox.shrink();
          }),
    ));
    return (dark, light);
  }

  testWidgets('card / barTrack / barTrackSoft / dangerTone branch', (tester) async {
    final (darkCard, lightCard) =
        await capture(tester, ZInk.card);
    expect(darkCard, ZColors.darkCard);
    expect(lightCard, ZColors.lightCard);

    final (darkTrack, lightTrack) = await capture(tester, ZInk.barTrack);
    expect(darkTrack, const Color(0x1AFFFFFF)); // bg-surface-hover
    expect(lightTrack, const Color(0x0D0D0D0D));

    final (darkSoft, lightSoft) =
        await capture(tester, ZInk.barTrackSoft);
    expect(darkSoft, const Color(0x0DFFFFFF)); // bg-surface
    expect(lightSoft, const Color(0x080D0D0D));

    final (darkDanger, lightDanger) =
        await capture(tester, ZInk.dangerTone);
    expect(darkDanger, ZColors.danger);
    expect(lightDanger, ZColors.dangerLight);
  });

  testWidgets('status foreground tones stay readable in light mode',
      (tester) async {
    final (darkSuccess, lightSuccess) =
        await capture(tester, ZInk.successTone);
    expect(darkSuccess, ZColors.success);
    expect(lightSuccess, ZColors.pillSuccessFgLight);

    final (darkWarning, lightWarning) =
        await capture(tester, ZInk.warningTone);
    expect(darkWarning, ZColors.warning);
    // --color-warning literal from the theme-zai-light bundle —
    // the same value light mode uses for --color-usage-chart-5.
    expect(lightWarning, ZColors.usageOrangeLight);
  });

  testWidgets('usage accents deepen in light mode (official direct lifts)',
      (tester) async {
    final (darkBlue, lightBlue) = await capture(tester, ZInk.usageBlue);
    expect(darkBlue, const Color(0xFF4099FF));
    expect(lightBlue, const Color(0xFF0B7FFF));

    final (darkOrange, lightOrange) =
        await capture(tester, ZInk.usageOrange);
    expect(darkOrange, const Color(0xFFFF8A30));
    expect(lightOrange, const Color(0xFFE07B00));

    final (darkGreen, lightGreen) = await capture(tester, ZInk.usageGreen);
    expect(darkGreen, const Color(0xFF87D9A4));
    expect(lightGreen, const Color(0xFF166B32));
  });

  testWidgets('status pill surfaces pair with their foregrounds',
      (tester) async {
    final (darkRunBg, lightRunBg) =
        await capture(tester, ZInk.pillRunningBg);
    expect(darkRunBg, const Color(0xFF001D3D));
    expect(lightRunBg, const Color(0xFFEBF4FF));

    final (darkRunFg, lightRunFg) =
        await capture(tester, ZInk.pillRunningFg);
    expect(darkRunFg, ZColors.neutral200.withValues(alpha: 0.87));
    expect(lightRunFg, const Color(0xFF0066DD));

    final (darkDone, lightDone) =
        await capture(tester, ZInk.pillSuccessBg);
    expect(darkDone, const Color(0xFF46BF72));
    // Interaction-confirmation surface (not the usage-chart green
    // the old 0xFF1E8A3E value belonged to).
    expect(lightDone, const Color(0xFFEAF7EE));

    final (darkDoneFg, lightDoneFg) =
        await capture(tester, ZInk.pillSuccessFg);
    expect(darkDoneFg, Colors.black); // dark pair unchanged
    expect(lightDoneFg, const Color(0xFF166B32)); // confirmation-foreground

    final (darkGlyph, lightGlyph) =
        await capture(tester, ZInk.iconNeutral);
    expect(darkGlyph, ZColors.neutral300);
    expect(lightGlyph, ZColors.neutral500);
  });

  testWidgets('FAB and slider themes ride the brand/ghost pair (B10/B11)',
      (tester) async {
    final dark = buildDarkTheme();
    final light = buildLightTheme();

    // FAB: brand sky fill + white glyph on both modes — the same pairing
    // as the device-card running badge (the M3 default falls back to the
    // text-color primary here, white-on-white).
    expect(dark.floatingActionButtonTheme.backgroundColor, ZColors.sky500);
    expect(dark.floatingActionButtonTheme.foregroundColor, Colors.white);
    expect(light.floatingActionButtonTheme.backgroundColor, ZColors.sky500);
    expect(light.floatingActionButtonTheme.foregroundColor, Colors.white);

    // Slider: active track + thumb = brand sky; inactive track = the
    // mode's ZInk.ghost so it stays visible on the page background (the
    // M3 default picks the card color, ~1.3:1 against dark background).
    expect(dark.sliderTheme.activeTrackColor, ZColors.sky500);
    expect(dark.sliderTheme.thumbColor, ZColors.sky500);
    expect(light.sliderTheme.activeTrackColor, ZColors.sky500);
    expect(light.sliderTheme.thumbColor, ZColors.sky500);
    final (darkGhost, lightGhost) = await capture(tester, ZInk.ghost);
    expect(dark.sliderTheme.inactiveTrackColor, darkGhost);
    expect(light.sliderTheme.inactiveTrackColor, lightGhost);
    // Pin the ghost slots themselves so the context-free mirror in
    // _base() cannot drift silently.
    expect(darkGhost, ZColors.neutral200.withValues(alpha: 0.30));
    expect(lightGhost, ZColors.neutral700.withValues(alpha: 0.40));
    // Drag bubble rides the same sky as the active track.
    expect(dark.sliderTheme.valueIndicatorColor, ZColors.sky500);
    expect(light.sliderTheme.valueIndicatorColor, ZColors.sky500);
  });

  testWidgets('off-peak violet + card-border tokens (D1/D4)', (tester) async {
    // D4: the light user bubble reads the official 10% card border (the
    // weaker 8% tile hairline was the pre-closeout value).
    final (darkBorder, lightBorder) = await capture(tester, ZInk.cardBorder);
    expect(lightBorder, const Color(0x1A0D0D0D)); // --color-border light
    expect(darkBorder, const Color(0x1AFFFFFF)); // dark theme outline pair

    // D1: official idle-task pair (violet-600 / violet-50, resolved from
    // oklch 54.1% .281 293.009 / 96.9% .016 293.756).
    expect(ZColors.violet600, const Color(0xFF7F22FE));
    expect(ZColors.violet50, const Color(0xFFF5F3FF));
  });
}
