import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/theme.dart';

/// The 2026-09-19 ZInk slots: every light/dark pair comes from the official
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
    expect(lightDone, const Color(0xFF1E8A3E));

    final (darkGlyph, lightGlyph) =
        await capture(tester, ZInk.iconNeutral);
    expect(darkGlyph, ZColors.neutral300);
    expect(lightGlyph, ZColors.neutral500);
  });
}
