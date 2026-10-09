import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/usage_stats.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/usage/usage_heatmap.dart';

/// D3 heatmap contracts: the level formula edges, the 52×7 normalization,
/// weekly/cumulative aggregation, the tap hit test and the widget-level
/// detail / empty states (task 10-08-parity-usage design test matrix).
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

  test('heatmapCellAt maps points to (week, day) and rejects gaps/outside',
      () {
    const cellSize = 10.0;
    const gap = 2.0;
    expect(heatmapCellAt(Offset(5, 5), cellSize: cellSize), (0, 0));
    // Second column starts at 12 — inside gap and inside cell:
    expect(heatmapCellAt(Offset(11, 5), cellSize: cellSize), isNull);
    expect(heatmapCellAt(Offset(13, 5), cellSize: cellSize), (1, 0));
    expect(heatmapCellAt(Offset(5, 25), cellSize: cellSize), (0, 2));
    // Past the grid / negative / on the right edge:
    expect(
      heatmapCellAt(
        Offset(kHeatmapWeeks * (cellSize + gap), 5),
        cellSize: cellSize,
      ),
      isNull,
    );
    expect(heatmapCellAt(Offset(-1, 5), cellSize: cellSize), isNull);
    expect(heatmapCellAt(Offset(5, 85), cellSize: cellSize), isNull);
    expect(heatmapCellAt(Offset(5, 5), cellSize: 0), isNull);
  });

  // -------------------------------------------------------------- widget

  testWidgets('tapping a cell surfaces the official detail copy', (tester) async {
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

    // Switching to the tools metric swaps the detail template.
    await tester.tap(find.text('工具次数'));
    await tester.pumpAndSettle();
    // Selection clears on mode/metric change; tap the cell again.
    await tapCell(tester, dataWeek, 0);
    expect(find.textContaining('2 次工具'), findsOneWidget);
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
