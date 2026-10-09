import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/usage_stats.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/usage/usage_trend_chart.dart';

/// D4 trend-chart contracts (task 10-08-parity-usage): series building
/// (≤6 models, sorted dates, zero-filled gaps), x-tick thinning, the
/// overshoot-free monotone path and the legend / empty-state widget.
void main() {
  AppDailyUsage day(String date, Map<String?, int> perModel) => AppDailyUsage(
        date: date,
        models: [
          for (final e in perModel.entries)
            AppModelDayUsage(modelId: e.key, totalTokens: e.value),
        ],
      );

  test('trendTickIndices follows the official thinning rule', () {
    expect(trendTickIndices(0), isEmpty);
    expect(trendTickIndices(3), [0, 1, 2]); // ≤14 → all
    expect(trendTickIndices(14), List.generate(14, (i) => i));
    expect(trendTickIndices(15), [0, 5, 10]); // >14 → every 5th
    expect(trendTickIndices(46), [0, 7, 14, 21, 28, 35, 42]); // >45 → every 7th
  });

  test('buildTrendSeries keeps the first 6 models, sorts dates and '
      'zero-fills missing days', () {
    final (dates, series) = buildTrendSeries(
      [for (var i = 0; i < 7; i++) AppModelUsage(modelId: 'm$i', totalTokens: 100 - i)],
      [
        day('2026-10-02', {for (var i = 0; i < 7; i++) 'm$i': i}),
        day('2026-10-01', {'m0': 5}),
      ],
    );

    expect(dates, ['2026-10-01', '2026-10-02']); // sorted ascending
    expect(series, hasLength(kTrendMaxModels)); // slice(0, 6)
    expect(series.first.modelId, 'm0');
    expect(series.first.values, [5.0, 0.0]); // 10-01 = 5, 10-02 missing m0 = 0
    expect(series[1].values, [0.0, 1.0]);
  });

  test('monotonePath reaches the data minimum without leaving the envelope',
      () {
    expect(monotonePath(const []).getBounds().isEmpty, isTrue);
    final path = monotonePath(
      const [Offset(0, 10), Offset(1, 0), Offset(2, 10)],
    );
    final metric = path.computeMetrics().first;
    final mid = metric.getTangentForOffset(metric.length / 2)!.position;
    // The true minimum (0) sits at the mid sample; no dip below it.
    expect(mid.dy, closeTo(0, 0.5));
    expect(mid.dx, closeTo(1, 0.1));
  });

  testWidgets('renders the model legend, unknown-model fallback and empty '
      'state', (tester) async {
    Widget wrap(Widget child) => MaterialApp(
          theme: buildDarkTheme(),
          builder: (context, child) =>
              UiSettingsProvider(settings: UiSettings(), child: child!),
          home: Scaffold(body: child),
        );

    await tester.pumpWidget(wrap(const UsageLineChart(xLabels: [], series: [])));
    await tester.pumpAndSettle();
    expect(find.text('该时间范围内暂无用量'), findsOneWidget);

    await tester.pumpWidget(wrap(UsageLineChart(
      xLabels: const ['2026-10-01'],
      series: [
        (modelId: 'glm-5.2', values: [10.0]),
        (modelId: null, values: [5.0]),
      ],
    )));
    await tester.pumpAndSettle();
    expect(find.text('glm-5.2'), findsOneWidget);
    expect(find.text('未知模型'), findsOneWidget);
  });
}
