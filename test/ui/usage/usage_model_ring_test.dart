import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/usage_stats.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/usage/usage_model_ring.dart';

/// D5 model-ring contracts (task 10-08-parity-usage): the ≤6-slice cap with
/// an 其他模型 aggregate, client-recomputed shares, and the widget-level
/// total / share list / empty state.
void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: Scaffold(body: child),
      );

  test('buildRingSlices keeps 5 + an aggregate and recomputes shares', () {
    final models = [
      for (var i = 0; i < 8; i++)
        AppModelUsage(modelId: 'm$i', totalTokens: 10 * (8 - i)),
    ];
    final slices = buildRingSlices(models);

    expect(slices, hasLength(kRingMaxSlices));
    expect(slices.take(5).map((s) => s.modelId), ['m0', 'm1', 'm2', 'm3', 'm4']);
    final other = slices.last;
    expect(other.isOther, isTrue);
    expect(other.totalTokens, 60); // m5 (30) + m6 (20) + m7 (10)
    expect(other.share, closeTo(60 / 360, 1e-9));
    // Shares are recomputed over the kept set and sum to 1.
    expect(
      slices.fold<double>(0, (a, s) => a + s.share),
      closeTo(1, 1e-9),
    );
  });

  test('buildRingSlices drops zero-token models and skips the aggregate '
      'when nothing overflows', () {
    expect(buildRingSlices(const []), isEmpty);
    expect(
      buildRingSlices([const AppModelUsage(modelId: 'x', totalTokens: 0)]),
      isEmpty,
    );
    final five = [
      for (var i = 0; i < 5; i++)
        AppModelUsage(modelId: 'm$i', totalTokens: 5),
    ];
    final slices = buildRingSlices(five);
    expect(slices, hasLength(5));
    expect(slices.any((s) => s.isOther), isFalse);
    expect(slices.every((s) => s.share == 0.2), isTrue);
  });

  testWidgets('renders the total, model names and shares', (tester) async {
    await tester.pumpWidget(wrap(UsageModelRing(models: [
      const AppModelUsage(modelId: 'glm-5.2', totalTokens: 300),
      const AppModelUsage(modelId: 'glm-4', totalTokens: 100),
    ])));
    await tester.pumpAndSettle();

    expect(find.text('400'), findsOneWidget); // compact total
    expect(find.text('tokens'), findsOneWidget);
    expect(find.text('glm-5.2'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.textContaining('glm-5.2 当前占比最高'), findsOneWidget);
  });

  testWidgets('renders the empty state without usable models', (tester) async {
    await tester.pumpWidget(wrap(const UsageModelRing(models: [])));
    await tester.pumpAndSettle();
    expect(find.text('该时间范围内暂无用量'), findsOneWidget);
  });
}
