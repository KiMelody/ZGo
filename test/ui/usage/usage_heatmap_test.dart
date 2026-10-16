import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/usage_stats.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/usage/usage_heatmap.dart';

/// D3 heatmap contracts: the level formula edges, the 52×7 normalization,
/// weekly/cumulative aggregation, the snapped tap hit test, the month-label
/// spans and the widget-level bubble / empty states (task 10-08-parity-usage
/// design test matrix; 10-16-usage-chart-tooltips steps 1-2).
void main() {
  UsageHeatmap heatmapOf(List<List<UsageHeatmapCell?>> days) => UsageHeatmap(
        weeks: [
          for (var i = 0; i < days.length; i++)
            UsageHeatmapWeek(weekIndex: i, days: days[i]),
        ],
      );

  UsageHeatmapCell cell(String date,
          {int level = 0,
          int tokens = 0,
          int turns = 0,
          int tools = 0}) =>
      UsageHeatmapCell(
        date: date,
        level: level,
        totalTokens: tokens,
        turnCount: turns,
        toolCallCount: tools,
      );

  Widget wrap(Widget child) => MaterialApp(
        theme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: Scaffold(body: child),
      );

  /// Taps the cell at (week, day) on the painted 52×7 surface. Short
  /// histories are left-padded to 52, so a fixture week lands at the far
  /// right — the helper derives the on-screen center from the same
  /// geometry the painter uses instead of hard-coding a corner.
  Future<void> tapCell(WidgetTester tester, int week, int day) async {
    final rect = tester.getRect(find.byKey(UsageHeatmapCard.gridKey));
    final cell = (rect.width - (kHeatmapWeeks - 1) * kHeatmapGap) / kHeatmapWeeks;
    final step = cell + kHeatmapGap;
    await tester.tapAt(
      rect.topLeft + Offset(week * step + cell / 2, day * step + cell / 2),
    );
    await tester.pumpAndSettle();
  }

  // The fixture's single week is left-padded to the last of the 52 columns.
  const int dataWeek = kHeatmapWeeks - 1;

  // ------------------------------------------------------- level formula

  test('heatmapLevel: 0 value and 0 bound stay level 0', () {
    expect(heatmapLevel(0, 100), 0);
    expect(heatmapLevel(100, 0), 0);
    expect(heatmapLevel(0, 0), 0);
  });

  test('heatmapLevel: ceil edges clamp to 1..4', () {
    expect(heatmapLevel(1, 100), 1); // ceil(0.04) = 1
    expect(heatmapLevel(25, 100), 1); // ceil(1.0) = 1
    expect(heatmapLevel(26, 100), 2); // ceil(1.04) = 2
    expect(heatmapLevel(50, 100), 2);
    expect(heatmapLevel(51, 100), 3);
    expect(heatmapLevel(75, 100), 3);
    expect(heatmapLevel(76, 100), 4);
    expect(heatmapLevel(100, 100), 4); // upper bound → top level
    expect(heatmapLevel(400, 100), 4); // over-intensity clamps at 4
  });

  // -------------------------------------------------------- normalization

  test('normalize pads short histories to 52×7 with leading empty weeks',
      () {
    final grid = normalizeHeatmapWeeks(heatmapOf([
      [cell('2026-10-06', tokens: 5)],
      [],
    ]));
    expect(grid, hasLength(kHeatmapWeeks));
    for (var i = 0; i < kHeatmapWeeks - 2; i++) {
      expect(grid[i], everyElement(isNull));
    }
    expect(grid[kHeatmapWeeks - 2].first?.date, '2026-10-06');
    expect(grid.last, everyElement(isNull));
  });

  test('normalize keeps only the latest 52 weeks and truncates day rows',
      () {
    final longWeeks = [
      for (var i = 0; i < 60; i++)
        UsageHeatmapWeek(
          weekIndex: i,
          days: [cell('w$i'), cell('w$i-b')],
        ),
    ];
    final grid = normalizeHeatmapWeeks(
      UsageHeatmap(weeks: longWeeks),
    );
    expect(grid, hasLength(kHeatmapWeeks));
    expect(grid.first.first?.date, 'w8'); // 60 - 52 → weeks 8..59 kept
    expect(grid.first, hasLength(kHeatmapDays)); // 2-day rows pad to 7
  });

  // --------------------------------------------------------- aggregation

  test('weekly mode paints whole columns from weekly token sums', () {
    final grid = normalizeHeatmapWeeks(heatmapOf([
      [cell('a', tokens: 100)],
      [cell('b', tokens: 400), cell('c', tokens: 100)],
      [],
    ]));
    final levels = heatmapLevels(grid, UsageHeatmapMode.weekly);
    // normalize left-pads to 52 — the three fixture weeks sit at the end.
    final last = grid.length;
    // Upper bound = max weekly total = 500.
    expect(
      levels[last - 3],
      everyElement(heatmapLevel(100, 500)),
    ); // ceil(0.8)=1
    expect(levels[last - 2], everyElement(heatmapLevel(500, 500))); // 4
    expect(levels[last - 1], everyElement(0)); // empty week stays 0
  });

  test('cumulative mode prefixes the sums before the same normalization',
      () {
    final grid = normalizeHeatmapWeeks(heatmapOf([
      [cell('a', tokens: 100)],
      [cell('b', tokens: 100)],
      [cell('c', tokens: 100)],
    ]));
    final levels = heatmapLevels(grid, UsageHeatmapMode.cumulative);
    // Prefix sums 100/200/300 over the last three columns, upper = 300.
    final last = grid.length;
    expect(levels[last - 3], everyElement(heatmapLevel(100, 300))); // 2
    expect(levels[last - 2], everyElement(heatmapLevel(200, 300))); // 3
    expect(levels[last - 1], everyElement(4));
  });

  test('daily mode renders the server level as-is', () {
    final grid = normalizeHeatmapWeeks(heatmapOf([
      [cell('a', level: 3, tokens: 1), null, cell('b', level: 1, tokens: 2)],
    ]));
    final levels = heatmapLevels(grid, UsageHeatmapMode.daily);
    expect(levels.last[0], 3);
    expect(levels.last[1], 0); // null placeholder
    expect(levels.last[2], 1);
  });

  // ------------------------------------------------------- hit locating

  test('heatmapCellAt snaps gaps to the nearest cell and rejects outside',
      () {
    const cellSize = 10.0;
    const gap = 2.0;
    expect(heatmapCellAt(Offset(5, 5), cellSize: cellSize), (0, 0));
    expect(heatmapCellAt(Offset(0, 0), cellSize: cellSize), (0, 0));
    // Gap between columns 0/1 (10..12): its first half still snaps to 0,
    // the exact midpoint and beyond round to cell 1.
    expect(heatmapCellAt(Offset(10.5, 5), cellSize: cellSize), (0, 0));
    expect(heatmapCellAt(Offset(11, 5), cellSize: cellSize), (1, 0));
    expect(heatmapCellAt(Offset(13, 5), cellSize: cellSize), (1, 0));
    expect(heatmapCellAt(Offset(5, 25), cellSize: cellSize), (0, 2));
    // Half a step beyond the top-left borders still snaps inward...
    expect(heatmapCellAt(Offset(-0.9, -0.9), cellSize: cellSize), (0, 0));
    // ...but past that the grid is left behind.
    expect(heatmapCellAt(Offset(-1.1, 5), cellSize: cellSize), isNull);
    expect(
      heatmapCellAt(
        Offset(kHeatmapWeeks * (cellSize + gap), 5),
        cellSize: cellSize,
      ),
      isNull,
    );
    expect(heatmapCellAt(Offset(5, 85), cellSize: cellSize), isNull);
    expect(heatmapCellAt(Offset(5, 5), cellSize: 0), isNull);
  });

  // --------------------------------------------------- month label spans

  test('heatmapMonthSpans merges consecutive same-month columns (kVn)', () {
    final grid = <List<UsageHeatmapCell?>>[
      [cell('2025-12-03')], // no '-01' → the column's first day
      [cell('2025-12-28'), cell('2026-01-01')], // '-01' wins over day 0
      [cell('2026-01-08')], // merges with the previous column
      [null, null], // all-null column → synthesized from the anchor
      [null, cell('2026-02-03')], // first non-null day fallback
    ];
    final spans = heatmapMonthSpans(grid);
    expect(spans, hasLength(3));
    expect(spans[0].key, '2025-12');
    expect(spans[0].startWeek, 0);
    expect(spans[0].span, 1);
    expect(spans[0].month, 12);
    expect(spans[1].key, '2026-01');
    expect(spans[1].startWeek, 1);
    expect(spans[1].span, 2); // two consecutive January columns
    expect(spans[1].month, 1);
    // The all-null column sits one week before the anchor column (whose
    // first non-null day 2026-02-03 minus its row lands on 2026-02-02): its
    // 7-day window [01-26..02-01] carries the 02-01 month start, so it joins
    // February instead of collapsing into a blank '' stretch.
    expect(spans[2].key, '2026-02');
    expect(spans[2].startWeek, 3);
    expect(spans[2].span, 2);
    expect(spans[2].month, 2);
    expect(
      spans.fold(0, (sum, span) => sum + span.span),
      grid.length,
    );
  });

  test('heatmapMonthSpans keeps only the last 12 month labels', () {
    final grid = [
      for (var m = 1; m <= 12; m++)
        [cell('2025-${m.toString().padLeft(2, '0')}-15')],
      [cell('2026-01-15')], // the 13th month group
    ];
    final spans = heatmapMonthSpans(grid);
    expect(spans, hasLength(13));
    // The oldest group stays blank but keeps its span width; the last 12
    // keep their labels.
    expect(spans.first.key, '2025-01');
    expect(spans.first.startWeek, 0);
    expect(spans.first.span, 1);
    expect(spans.first.month, isNull);
    expect(spans[1].month, 2);
    expect(spans.last.key, '2026-01');
    expect(spans.last.startWeek, 12);
    expect(spans.last.month, 1);
  });

  test('heatmapMonthSpans backfills a short history across the full year',
      () {
    // Real data: two mid-October 2026 weeks; normalize left-pads the other
    // 50 columns with nulls. The label row must still carry the full-year
    // axis instead of one clipped '10月' (10-16-heatmap-month-lattice).
    final grid = normalizeHeatmapWeeks(heatmapOf([
      [cell('2026-10-06')],
      [cell('2026-10-13')],
    ]));
    final spans = heatmapMonthSpans(grid);
    // Twelve labeled groups — one per month, the year wrap reading 11月,
    // 12月, 1月 … 10月 (the oldest partial group is blanked, not dropped).
    expect(
      [for (final span in spans) span.month].whereType<int>().toList(),
      [11, 12, for (var month = 1; month <= 10; month++) month],
    );
    expect(spans.first.month, isNull);
    expect(spans.last.key, '2026-10');
    // The synthesized 09-29 column (its window carries 10-01) joins the two
    // real October weeks.
    expect(spans.last.startWeek, kHeatmapWeeks - 3);
    expect(spans.last.span, 3);
    // Geometric visibility gate: a label only reads when its slot is a few
    // columns wide — every middle group must clear that (the bug was
    // find.text passing while the lone label was clipped invisible).
    for (final span in spans.sublist(1, spans.length - 1)) {
      expect(span.span, greaterThanOrEqualTo(4), reason: span.key);
    }
  });

  test('heatmapMonthSpans synthesizes across the year boundary', () {
    // The anchor week starts 2025-12-29, so its window [12-29..01-04] holds
    // 01-01 and reads as January — December and January must stay separate
    // labeled groups.
    final grid = normalizeHeatmapWeeks(heatmapOf([
      [cell('2026-01-05')],
    ]));
    final spans = heatmapMonthSpans(grid);
    final december = spans.firstWhere((span) => span.key == '2025-12');
    final january = spans.firstWhere((span) => span.key == '2026-01');
    expect(december.month, 12);
    expect(december.span, 4); // the full December window
    expect(january.month, 1);
    expect(january.startWeek, december.startWeek + december.span);
    expect(spans.last.key, '2026-01');
    // 13 groups over the year; the oldest (2025-01) is the blanked one.
    expect(spans.first.key, '2025-01');
    expect(spans.first.month, isNull);
  });

  test('heatmapMonthSpans: an all-null grid is one blank span', () {
    final spans = heatmapMonthSpans(normalizeHeatmapWeeks(heatmapOf([[]])));
    expect(spans, hasLength(1));
    expect(spans.single.key, '');
    expect(spans.single.startWeek, 0);
    expect(spans.single.span, kHeatmapWeeks);
    expect(spans.single.month, isNull);
  });

  // -------------------------------------------------------------- widget

  testWidgets('tapping a cell surfaces the official detail bubble',
      (tester) async {
    await tester.pumpWidget(wrap(UsageHeatmapCard(
      heatmap: heatmapOf([
        [cell('2026-10-06', level: 2, tokens: 12000, turns: 4, tools: 2)],
      ]),
    )));
    await tester.pumpAndSettle();

    // The widget runs the same [heatmapCellAt] math the unit test pins.
    await tapCell(tester, dataWeek, 0);

    expect(find.textContaining('2026-10-06'), findsOneWidget);
    expect(find.textContaining('1.2万'), findsOneWidget); // compact tokens
    expect(find.textContaining('4 轮消息'), findsOneWidget);

    // A repeat tap on the same cell closes the bubble (toggle).
    await tapCell(tester, dataWeek, 0);
    expect(find.textContaining('tokens'), findsNothing);

    // Switching to the tools metric clears the selection...
    await tapCell(tester, dataWeek, 0);
    await tester.tap(find.text('工具次数'));
    await tester.pumpAndSettle();
    expect(find.textContaining('tokens'), findsNothing);
    // ...and a fresh tap surfaces the tools template in the bubble.
    await tapCell(tester, dataWeek, 0);
    expect(find.textContaining('2 次工具'), findsOneWidget);

    // A range-mode switch with a live selection clears it too (the same
    // reset the metric chip exercises — pinned for the AC list).
    await tester.tap(find.text('每周'));
    await tester.pumpAndSettle();
    expect(find.textContaining('tokens'), findsNothing);

    // A refreshed heatmap (new snapshot instance) drops the stale selection.
    await tapCell(tester, dataWeek, 0);
    await tester.pumpWidget(wrap(UsageHeatmapCard(
      heatmap: heatmapOf([
        [cell('2026-10-06', level: 2, tokens: 12000, turns: 4, tools: 2)],
      ]),
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('tokens'), findsNothing);
  });

  testWidgets('empty cells and the month-label row dismiss the bubble',
      (tester) async {
    await tester.pumpWidget(wrap(UsageHeatmapCard(
      heatmap: heatmapOf([
        [cell('2026-10-06', level: 2, tokens: 12000, turns: 4, tools: 2)],
      ]),
    )));
    await tester.pumpAndSettle();

    await tapCell(tester, dataWeek, 0);
    expect(find.textContaining('tokens'), findsOneWidget);

    // A null cell clears the selection instead of opening a bubble.
    await tapCell(tester, 0, 0);
    expect(find.textContaining('tokens'), findsNothing);

    // The month-label row sits past the 52×7 range (row ≥ 7) — its taps
    // dismiss the bubble as "outside the grid".
    await tapCell(tester, dataWeek, 0);
    expect(find.textContaining('tokens'), findsOneWidget);
    final gridRect = tester.getRect(find.byKey(UsageHeatmapCard.gridKey));
    await tester.tapAt(gridRect.bottomLeft + const Offset(20, 14));
    await tester.pumpAndSettle();
    expect(find.textContaining('tokens'), findsNothing);
  });

  testWidgets('the month-label row aligns each label with its month span',
      (tester) async {
    await tester.pumpWidget(wrap(UsageHeatmapCard(
      heatmap: heatmapOf([
        [cell('2026-10-06', level: 2, tokens: 5)],
      ]),
    )));
    await tester.pumpAndSettle();

    final gridRect = tester.getRect(find.byKey(UsageHeatmapCard.gridKey));
    final cellSize =
        (gridRect.width - (kHeatmapWeeks - 1) * kHeatmapGap) / kHeatmapWeeks;
    final step = cellSize + kHeatmapGap;
    // The 10月 group also absorbs the synthesized column one week up (its
    // 09-29..10-05 window carries 10-01), so the label starts a step earlier
    // than the real week.
    expect(find.text('10月'), findsOneWidget);
    expect(
      tester.getRect(find.text('10月')).left,
      closeTo(gridRect.left + (dataWeek - 1) * step, 1),
    );
    // ...and the synthesized lead columns fill the whole year's label row.
    expect(find.textContaining('月'), findsNWidgets(12));
  });

  testWidgets('short histories keep the full year of month labels',
      (tester) async {
    await tester.pumpWidget(wrap(UsageHeatmapCard(
      heatmap: heatmapOf([
        [cell('2026-10-06', level: 2, tokens: 5)],
        [cell('2026-10-13', level: 1, tokens: 3)],
      ]),
    )));
    await tester.pumpAndSettle();

    // Two real weeks only, yet the label row carries the same full-year axis
    // the official padded grid does — including months far from the data
    // stretch (10-16-heatmap-month-lattice).
    expect(find.textContaining('月'), findsNWidgets(12));
    expect(find.text('11月'), findsOneWidget); // the oldest kept month
    expect(find.text('5月'), findsOneWidget); // mid-year, far from the data
    expect(find.text('10月'), findsOneWidget);
  });

  testWidgets('weekly mode detail aggregates the column', (tester) async {
    await tester.pumpWidget(wrap(UsageHeatmapCard(
      heatmap: heatmapOf([
        [
          cell('2026-10-05', level: 1, tokens: 100, turns: 1, tools: 0),
          cell('2026-10-06', level: 1, tokens: 200, turns: 2, tools: 3),
        ],
      ]),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每周'));
    await tester.pumpAndSettle();

    await tapCell(tester, dataWeek, 0);
    expect(find.textContaining('2026-10-06 当周'), findsOneWidget);
    expect(find.textContaining('300'), findsOneWidget);
    expect(find.textContaining('3 轮消息'), findsOneWidget);
  });

  testWidgets('cumulative mode detail aggregates the 0..week prefix',
      (tester) async {
    await tester.pumpWidget(wrap(UsageHeatmapCard(
      heatmap: heatmapOf([
        [cell('2026-09-28', level: 1, tokens: 100, turns: 1, tools: 0)],
        [cell('2026-10-06', level: 1, tokens: 200, turns: 2, tools: 3)],
      ]),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('累计'));
    await tester.pumpAndSettle();

    await tapCell(tester, dataWeek, 0);
    // 截至 the tapped week: the prefix (100+200 tokens, 1+2 turns), not the
    // single-week sum 200/2 — the shader shades by the same prefix.
    expect(find.textContaining('截至 2026-10-06 当周累计'), findsOneWidget);
    expect(find.textContaining('300 tokens'), findsOneWidget);
    expect(find.textContaining('3 轮消息'), findsOneWidget);

    // The tools template carries the tool count from the same prefix.
    await tester.tap(find.text('工具次数'));
    await tester.pumpAndSettle();
    await tapCell(tester, dataWeek, 0);
    expect(find.textContaining('3 次工具'), findsOneWidget);
  });

  testWidgets('empty heatmap (backup source) renders the empty copy',
      (tester) async {
    await tester.pumpWidget(wrap(UsageHeatmapCard(
      heatmap: const UsageHeatmap(weeks: []),
    )));
    await tester.pumpAndSettle();
    expect(find.text('暂无 Token 活动'), findsOneWidget);
    expect(find.byKey(UsageHeatmapCard.gridKey), findsNothing);
  });

  testWidgets('narrow width scrolls the grid horizontally behind a Scrollbar',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(UsageHeatmapCard(
      heatmap: heatmapOf([
        [cell('2026-10-06', level: 2, tokens: 5)],
      ]),
    )));
    await tester.pumpAndSettle();

    // The 52 columns exceed 360dp, so the grid scrolls (design D3) and is
    // still painted (auto-scrolled to the latest week).
    expect(find.byType(Scrollbar), findsOneWidget);
    expect(find.byKey(UsageHeatmapCard.gridKey), findsOneWidget);
    // D3: opened on the latest (right-most) week — scrolled to the end.
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets(
      'narrow scroll: gap taps snap to the nearest cell, scrolling closes '
      'the bubble', (tester) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(1080, 2400); // 360dp wide
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(UsageHeatmapCard(
      heatmap: heatmapOf([
        [cell('2026-10-05', level: 2, tokens: 12000, turns: 4, tools: 2)],
        [cell('2026-10-12', level: 3, tokens: 8000, turns: 2, tools: 1)],
      ]),
    )));
    await tester.pumpAndSettle();

    // The label row rides the same scroll child as the grid: both fixture
    // weeks share 2026-10, and the synthesized column one step up (its
    // 09-28..10-04 window carries 10-01) joins them, so the single '10月'
    // slot starts two steps before the latest week.
    final rect = tester.getRect(find.byKey(UsageHeatmapCard.gridKey));
    final cellSize =
        (rect.width - (kHeatmapWeeks - 1) * kHeatmapGap) / kHeatmapWeeks;
    final step = cellSize + kHeatmapGap;
    expect(find.text('10月'), findsOneWidget);
    expect(
      tester.getRect(find.text('10月')).left,
      closeTo(rect.left + (dataWeek - 2) * step, 1),
    );

    // Tap inside the 2dp gap on the right of the week-1 column (0.5dp past
    // its edge): still nearer that column, so the snapped hit selects it
    // instead of being rejected as a gap.
    await tester.tapAt(
      rect.topLeft +
          Offset((dataWeek - 1) * step + cellSize + 0.5, cellSize / 2),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('2026-10-05'), findsOneWidget);
    expect(find.textContaining('tokens'), findsOneWidget);

    // A horizontal scroll invalidates the bubble's anchor: it closes. The
    // drag starts in row 0, above the bubble anchored under the tapped cell.
    await tester.dragFrom(
      rect.topLeft + Offset(rect.width / 2, 4),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('tokens'), findsNothing);
  });

  testWidgets('the grid paints the 52×7 ladder and carries the intensity '
      'legend', (tester) async {
    await tester.pumpWidget(wrap(UsageHeatmapCard(
      heatmap: heatmapOf([
        [cell('2026-10-06', level: 4, tokens: 99)],
      ]),
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(UsageHeatmapCard.gridKey), findsOneWidget);
    expect(find.text('较少'), findsOneWidget);
    expect(find.text('较多'), findsOneWidget);
    // Official aria description surfaces for screen readers.
    expect(
      find.bySemanticsLabel('最活跃日期是 2026-10-06，约 99 Tokens。'),
      findsOneWidget,
    );
    // The five legend swatches carry the same intensity ladder the grid
    // painter uses: level 0 keeps the tile base, 1-4 ride ZInk.usageHeatmap.
    final cardCtx = tester.element(find.byType(UsageHeatmapCard));
    final swatches = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) => c.constraints == BoxConstraints.tight(const Size(10, 10)))
        .toList();
    expect(swatches, hasLength(5));
    final expected = [
      ZInk.tile(cardCtx),
      for (var level = 1; level <= 4; level++) ZInk.usageHeatmap(cardCtx, level),
    ];
    for (var i = 0; i <= 4; i++) {
      expect(
        (swatches[i].decoration! as BoxDecoration).color,
        expected[i],
        reason: 'legend swatch level $i',
      );
    }
  });
}
