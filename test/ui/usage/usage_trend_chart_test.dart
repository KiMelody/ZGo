import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/usage_stats.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/usage/usage_trend_chart.dart';

/// D4 trend-chart contracts (task 10-08-parity-usage): series building
/// (≤6 models, sorted dates, zero-filled gaps), x-tick thinning, the
/// overshoot-free monotone path and the legend / empty-state widget.
/// Step 3 of task 10-16-usage-chart-tooltips adds the nearest-day hit test
/// ([trendIndexAt]) and the tapped-day bubble driven by the painter's
/// `selectedIndex` (activeDot).
void main() {
  AppDailyUsage day(String date, Map<String?, int> perModel) => AppDailyUsage(
        date: date,
        models: [
          for (final e in perModel.entries)
            AppModelDayUsage(modelId: e.key, totalTokens: e.value),
        ],
      );

  Widget wrap(Widget child) => MaterialApp(
        theme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: Scaffold(body: child),
      );

  /// The painted chart surface (the bubble's Material adds a shape-border
  /// CustomPaint of its own, so the chart carries a key).
  final chartPaint = find.byKey(UsageLineChart.chartKey);

  /// The floating day bubble — the only elevated Material in the tree.
  final bubble = find.byWidgetPredicate((w) => w is Material && w.elevation == 4);

  /// The selected day handed to `_LineChartPainter` (private class, read
  /// through `dynamic` like the recording gateway test does).
  int? selectedIndex(WidgetTester tester) =>
      (tester.widget<CustomPaint>(chartPaint).painter! as dynamic).selectedIndex
          as int?;

  /// Taps the plot at day [index]'s data point — the same [kTrendXPad]
  /// frame the painter plots and [trendIndexAt] maps over.
  Future<void> tapDay(WidgetTester tester, int index, int n) async {
    final rect = tester.getRect(chartPaint);
    final plotWidth = rect.width - 2 * kTrendXPad;
    await tester.tapAt(Offset(
      rect.left + kTrendXPad + plotWidth * index / (n - 1),
      rect.top + 60,
    ));
    await tester.pumpAndSettle();
  }

  /// Three days × two series; day 2 has usage from a single model only.
  UsageLineChart trendChart() => UsageLineChart(
        xLabels: const ['2026-10-01', '2026-10-02', '2026-10-03'],
        series: const [
          (modelId: 'glm-5.2', values: [10.0, 0.0, 7.0]),
          (modelId: null, values: [15.0, 5.0, 0.0]),
        ],
      );

  test('trendTickIndices thins by label footprint, keeping both ends', () {
    expect(trendTickIndices(0, spacing: 46, labelWidth: 35), isEmpty);
    expect(trendTickIndices(1, spacing: 46, labelWidth: 35), [0]);

    // The on-device overlap (10-17 取证): 8 day labels, 46dp spacing,
    // 35dp label — the left-aligned first used to collide with the
    // centered second (footprints [0,35] vs [28.5,63.5]).
    final dense = trendTickIndices(8, spacing: 46, labelWidth: 35);
    expect(dense.first, 0);
    expect(dense.last, 7);
    expect(dense.contains(1), isFalse);
    // Every kept pair clears the min gap under the painter's alignment
    // (first=left, last=right, middle=centered footprints).
    double leftEdge(int i) => switch (i) {
          0 => 0.0,
          7 => 7 * 46 - 35.0,
          _ => i * 46 - 17.5,
        };
    for (var k = 0; k < dense.length - 1; k++) {
      final a = dense[k], b = dense[k + 1];
      expect(leftEdge(b), greaterThanOrEqualTo(leftEdge(a) + 35 + 8),
          reason: 'tick $a → $b overlap');
    }

    // Wide screen: 66dp spacing clears every adjacent pair — all kept.
    expect(trendTickIndices(8, spacing: 66, labelWidth: 35),
        [for (var i = 0; i < 8; i++) i]);

    // 30-day range on 360dp: 10.8dp spacing thins to every ~5th day.
    final month = trendTickIndices(31, spacing: 10.8, labelWidth: 35);
    expect(month.first, 0);
    expect(month.last, 30);
    expect(month.length, lessThanOrEqualTo(8));

    // End-yield: the last middle tick collides with the end label and
    // steps aside (but [0] never yields — both ends are the range).
    expect(trendTickIndices(4, spacing: 30, labelWidth: 35), [0, 3]);
    expect(trendTickIndices(2, spacing: 20, labelWidth: 35), [0, 1]);
  });

  test('trendIndexAt picks the nearest day and clamps to the plot ends', () {
    // n=5 over a 100dp box: the plot spans [kTrendXPad, 98], so the days
    // sit at 2 / 26 / 50 / 74 / 98.
    expect(trendIndexAt(2, 100, 5), 0);
    expect(trendIndexAt(50, 100, 5), 2); // exact centre of day 2
    expect(trendIndexAt(98, 100, 5), 4);
    expect(trendIndexAt(13, 100, 5), 0); // just left of the midpoint 14
    expect(trendIndexAt(14, 100, 5), 1); // the midpoint rounds to day 1
    // Outside the plot the nearest end wins (the tap still means "closest
    // day"); a single day is always index 0, and nothing to plot is null.
    expect(trendIndexAt(-40, 100, 5), 0);
    expect(trendIndexAt(0, 100, 5), 0);
    expect(trendIndexAt(140, 100, 5), 4);
    expect(trendIndexAt(50, 100, 1), 0);
    expect(trendIndexAt(50, 100, 0), isNull);
    expect(trendIndexAt(50, 100, -3), isNull);
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

  testWidgets('tapping the plot floats the day bubble: date - total tokens '
      'over the day\'s used models in series order', (tester) async {
    await tester.pumpWidget(wrap(trendChart()));
    await tester.pumpAndSettle();
    expect(chartPaint, findsOneWidget);
    expect(bubble, findsNothing);

    await tapDay(tester, 0, 3);
    // Official labelFormatter `{date} - {compact total} tokens` (10 + 15).
    expect(find.text('2026-10-01 - 25 tokens'), findsOneWidget);
    final row0 = find.descendant(of: bubble, matching: find.text('glm-5.2'));
    final row1 = find.descendant(of: bubble, matching: find.text('未知模型'));
    expect(row0, findsOneWidget);
    expect(row1, findsOneWidget);
    expect(find.descendant(of: bubble, matching: find.text('10')),
        findsOneWidget);
    expect(find.descendant(of: bubble, matching: find.text('15')),
        findsOneWidget);
    // Rows keep the series order (top to bottom).
    expect(tester.getTopLeft(row0).dy, lessThan(tester.getTopLeft(row1).dy));
    // Each row carries its series-palette dot.
    final ctx = tester.element(find.byType(UsageLineChart));
    final dots = tester.widgetList<Container>(
      find.descendant(of: bubble, matching: find.byType(Container)),
    );
    expect(
      [for (final d in dots) (d.decoration! as BoxDecoration).color],
      [ZInk.usageChart(ctx, 0), ZInk.usageChart(ctx, 1)],
    );
  });

  testWidgets('a repeat tap closes the bubble, another day re-anchors it and '
      'only >0 models list', (tester) async {
    await tester.pumpWidget(wrap(trendChart()));
    await tester.pumpAndSettle();

    await tapDay(tester, 0, 3);
    expect(bubble, findsOneWidget);

    // A repeat tap on the same day toggles the bubble off.
    await tapDay(tester, 0, 3);
    expect(bubble, findsNothing);
    expect(find.textContaining('tokens'), findsNothing);

    // Day 2 was used by one model only — zero-value rows are filtered out.
    await tapDay(tester, 1, 3);
    expect(find.text('2026-10-02 - 5 tokens'), findsOneWidget);
    expect(find.descendant(of: bubble, matching: find.text('未知模型')),
        findsOneWidget);
    expect(find.descendant(of: bubble, matching: find.text('glm-5.2')),
        findsNothing);

    // Day 3 swaps the single row to the other series.
    await tapDay(tester, 2, 3);
    expect(find.text('2026-10-03 - 7 tokens'), findsOneWidget);
    expect(find.descendant(of: bubble, matching: find.text('glm-5.2')),
        findsOneWidget);
    expect(find.descendant(of: bubble, matching: find.text('未知模型')),
        findsNothing);
  });

  testWidgets('the painter receives the selected day for the activeDot',
      (tester) async {
    await tester.pumpWidget(wrap(trendChart()));
    await tester.pumpAndSettle();
    expect(selectedIndex(tester), isNull);

    await tapDay(tester, 2, 3);
    expect(selectedIndex(tester), 2);

    await tapDay(tester, 2, 3);
    expect(selectedIndex(tester), isNull);
  });

  testWidgets('new labels or series clear the selection (range switch)',
      (tester) async {
    await tester.pumpWidget(wrap(trendChart()));
    await tester.pumpAndSettle();
    await tapDay(tester, 0, 3);
    expect(bubble, findsOneWidget);

    // A range switch rebuilds the chart with another label/values set; the
    // old index no longer points at the same day.
    await tester.pumpWidget(wrap(UsageLineChart(
      xLabels: const ['2026-10-04', '2026-10-05'],
      series: const [
        (modelId: 'glm-5.2', values: [3.0, 4.0]),
      ],
    )));
    await tester.pumpAndSettle();
    expect(bubble, findsNothing);
    expect(selectedIndex(tester), isNull);
  });
}
