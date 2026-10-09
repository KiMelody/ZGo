import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../protocol/usage_stats.dart';
import '../theme.dart';
import '../ui_settings.dart';

/// 「Token 活动」heatmap (web `settings.usage.heatmapTitle`, task
/// 10-08-parity-usage D3). Fixed 52×7 grid, latest week on the right;
/// three range modes (daily uses the server's per-cell level, weekly /
/// cumulative aggregate client-side) and two count metrics (turns /
/// tools) driving the cell detail copy. Level colors ride
/// [ZInk.usageHeatmap] (official `--color-usage-heatmap-*` ladder).
///
/// Pure geometry helpers ([heatmapLevel], [normalizeHeatmapWeeks],
/// [heatmapLevels], [heatmapCellAt]) are exported for unit tests.

/// Grid shape — official `ewn`=52 week columns × 7 day rows.
const int kHeatmapWeeks = 52;
const int kHeatmapDays = 7;

/// Official `gap-x-0.5` (0.125rem = 2px).
const double kHeatmapGap = 2;

/// Cell floor on narrow screens (design D3: 最小 8dp, then scroll).
const double kHeatmapMinCell = 8;

enum UsageHeatmapMode { daily, weekly, cumulative }

enum UsageHeatmapMetric { turns, tools }

/// Official weekly/cumulative level formula (`dwn`): intensity =
/// `clamp(ceil(value / upperBound * 4), 1, 4)`; zero value or a zero
/// bound (empty data) stays level 0.
int heatmapLevel(num value, num upperBound) {
  if (value <= 0 || upperBound <= 0) return 0;
  return ((value / upperBound * 4).ceil()).clamp(1, 4);
}

/// Official normalization (`uwn`): the server's `weeks` has arbitrary
/// length — pad to the fixed 52×7 grid, latest week on the right. Short
/// histories left-pad with all-null weeks; overflowing ones keep the
/// most recent 52; day rows pad/truncate to 7 preserving nulls.
List<List<UsageHeatmapCell?>> normalizeHeatmapWeeks(UsageHeatmap heatmap) {
  List<UsageHeatmapCell?> dayRow(List<UsageHeatmapCell?> days) {
    final out = List<UsageHeatmapCell?>.filled(kHeatmapDays, null);
    for (var i = 0; i < math.min(kHeatmapDays, days.length); i++) {
      out[i] = days[i];
    }
    return out;
  }

  final weeks = heatmap.weeks.map((w) => dayRow(w.days)).toList();
  if (weeks.length > kHeatmapWeeks) {
    return weeks.sublist(weeks.length - kHeatmapWeeks);
  }
  return [
    for (var i = 0; i < kHeatmapWeeks - weeks.length; i++)
      List<UsageHeatmapCell?>.filled(kHeatmapDays, null),
    ...weeks,
  ];
}

/// Level per cell for the current mode. Daily renders the server level
/// as-is; weekly / cumulative aggregate `totalTokens` per column (the
/// official `hwn` aggregation — counts ride the detail copy only) and
/// paint the whole column with one level (design D3: 整列上色取该列
/// 代表值; cumulative prefixes the sums before the same normalization).
List<List<int>> heatmapLevels(
  List<List<UsageHeatmapCell?>> grid,
  UsageHeatmapMode mode,
) {
  if (mode == UsageHeatmapMode.daily) {
    return [
      for (final week in grid)
        [for (final cell in week) cell?.level ?? 0],
    ];
  }
  final totals = List<int>.filled(kHeatmapWeeks, 0);
  var running = 0;
  for (var w = 0; w < grid.length; w++) {
    var sum = 0;
    for (final cell in grid[w]) {
      sum += cell?.totalTokens ?? 0;
    }
    running += sum;
    totals[w] = mode == UsageHeatmapMode.cumulative ? running : sum;
  }
  final upper = totals.fold(0, math.max);
  return [
    for (final total in totals)
      [for (var d = 0; d < kHeatmapDays; d++) heatmapLevel(total, upper)],
  ];
}

/// Column aggregate for the detail copy: the summed cell values of one
/// week (daily callers pass the single cell instead).
(int tokens, int turns, int tools, String date) heatmapColumnSummary(
  List<UsageHeatmapCell?> week,
) {
  var tokens = 0, turns = 0, tools = 0;
  String? date;
  for (final cell in week) {
    if (cell == null) continue;
    tokens += cell.totalTokens;
    turns += cell.turnCount;
    tools += cell.toolCallCount;
    if (cell.date.isNotEmpty) date = cell.date;
  }
  return (tokens, turns, tools, date ?? '');
}

/// Prefix aggregate for the cumulative detail copy: the summed cell
/// values of weeks `0..week` — the same prefix the cumulative shader
/// normalizes ([heatmapLevels]), so the detail's 截至 … 当周累计 numbers
/// stay self-consistent with the column color.
(int tokens, int turns, int tools, String date) heatmapCumulativeSummary(
  List<List<UsageHeatmapCell?>> grid,
  int week,
) {
  var tokens = 0, turns = 0, tools = 0;
  String? date;
  for (var w = 0; w <= week && w < grid.length; w++) {
    final s = heatmapColumnSummary(grid[w]);
    tokens += s.$1;
    turns += s.$2;
    tools += s.$3;
    if (s.$4.isNotEmpty) date = s.$4;
  }
  return (tokens, turns, tools, date ?? '');
}

/// Most active day (official `heatmapDescription`: 最活跃日期是 …) —
/// the max-token cell over the grid; null when nothing was used.
UsageHeatmapCell? mostActiveCell(List<List<UsageHeatmapCell?>> grid) {
  UsageHeatmapCell? best;
  for (final week in grid) {
    for (final cell in week) {
      if (cell == null) continue;
      if (best == null || cell.totalTokens > best.totalTokens) best = cell;
    }
  }
  return best;
}

/// Hit test: the (week, day) under [local], null on gaps / outside.
/// Pure so the tap→cell mapping stays unit-testable (design D3).
(int week, int day)? heatmapCellAt(
  Offset local, {
  required double cellSize,
  double gap = kHeatmapGap,
  int weeks = kHeatmapWeeks,
  int days = kHeatmapDays,
}) {
  if (cellSize <= 0) return null;
  // Dart's `~/` truncates toward zero, so negatives would fold onto
  // column/row 0 — reject them before the division.
  if (local.dx < 0 || local.dy < 0) return null;
  final step = cellSize + gap;
  final col = local.dx ~/ step;
  final row = local.dy ~/ step;
  if (col < 0 || row < 0 || col >= weeks || row >= days) return null;
  if (local.dx - col * step > cellSize || local.dy - row * step > cellSize) {
    return null;
  }
  return (col, row);
}

class UsageHeatmapCard extends StatefulWidget {
  final UsageHeatmap heatmap;

  /// Grid painter key — tests locate the painted 52×7 surface by it
  /// (the Card's Material interior is a CustomPaint too).
  static const Key gridKey = ValueKey('usage-heatmap-grid');

  const UsageHeatmapCard({super.key, required this.heatmap});

  @override
  State<UsageHeatmapCard> createState() => _UsageHeatmapCardState();
}

class _UsageHeatmapCardState extends State<UsageHeatmapCard> {
  UsageHeatmapMode _mode = UsageHeatmapMode.daily;
  UsageHeatmapMetric _metric = UsageHeatmapMetric.turns;
  (int, int)? _selected;

  /// One-shot auto scroll: jump to the latest (right-most) week when the
  /// grid overflows, then never fight the user's scrolling again.
  final ScrollController _scroll = ScrollController();
  bool _autoScrolled = false;

  /// The painted 52×7 surface, for tap → cell hit testing (its RenderBox
  /// is the only box whose size and local coordinates match the grid — the
  /// card's own box includes the title/padding).
  final GlobalKey _gridBoxKey = GlobalKey();

  @override
  void didUpdateWidget(covariant UsageHeatmapCard old) {
    super.didUpdateWidget(old);
    if (old.heatmap != widget.heatmap) {
      _selected = null;
      _autoScrolled = false;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grid = normalizeHeatmapWeeks(widget.heatmap);
    final levels = heatmapLevels(grid, _mode);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZSpacing.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(tr(context, 'usage.heatmap.title'),
                      style: ZType.bodyStrong),
                ),
                for (final mode in UsageHeatmapMode.values)
                  _chip(
                    label: tr(context, switch (mode) {
                      UsageHeatmapMode.daily => 'usage.heatmap.daily',
                      UsageHeatmapMode.weekly => 'usage.heatmap.weekly',
                      UsageHeatmapMode.cumulative =>
                        'usage.heatmap.cumulative',
                    }),
                    selected: _mode == mode,
                    onTap: () => setState(() {
                      _mode = mode;
                      _selected = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final metric in UsageHeatmapMetric.values)
                  _chip(
                    label: tr(context, switch (metric) {
                      UsageHeatmapMetric.turns => 'usage.heatmap.metricTurns',
                      UsageHeatmapMetric.tools => 'usage.heatmap.metricTools',
                    }),
                    selected: _metric == metric,
                    onTap: () => setState(() {
                      _metric = metric;
                      _selected = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (widget.heatmap.weeks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(tr(context, 'usage.heatmap.empty'),
                    style: ZType.sub.copyWith(color: ZInk.faint(context))),
              )
            else ...[
              _grid(context, grid, levels),
              const SizedBox(height: 8),
              _legend(context),
              if (_selected case (final week, final day))
                if (grid[week][day] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _detail(context, grid, week, day),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  /// Compact text chip — the same idiom as the range buttons on the page.
  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(ZRadius.mini),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: ZType.caption.copyWith(
            color: selected ? ZColors.sky500 : ZInk.muted(context),
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _grid(
    BuildContext context,
    List<List<UsageHeatmapCell?>> grid,
    List<List<int>> levels,
  ) {
    // Official aria description (最活跃日期是 …) — invisible, semantic only.
    final active = mostActiveCell(grid);
    final semantics = active == null
        ? null
        : trP(context, 'usage.heatmap.description', [
            active.date,
            compactTokens(context, active.totalTokens),
          ]);
    final body = Semantics(
      label: semantics,
      child: LayoutBuilder(builder: (context, constraints) {
        final available = constraints.maxWidth - (kHeatmapWeeks - 1) * kHeatmapGap;
        final cell = math.max(kHeatmapMinCell, available / kHeatmapWeeks);
        final contentW = kHeatmapWeeks * cell + (kHeatmapWeeks - 1) * kHeatmapGap;
        final contentH = kHeatmapDays * cell + (kHeatmapDays - 1) * kHeatmapGap;
        final painted = SizedBox(
          key: _gridBoxKey,
          width: contentW,
          height: contentH,
          child: CustomPaint(
            key: UsageHeatmapCard.gridKey,
            painter: _HeatmapPainter(
              grid: grid,
              levels: levels,
              ladder: [
                for (var l = 0; l <= 4; l++) ZInk.usageHeatmap(context, l),
              ],
              border: ZInk.hairline(context),
              selectedColor: ZInk.usageBlue(context),
              selected: _selected,
            ),
          ),
        );
        if (contentW <= constraints.maxWidth + 0.5) return painted;
        // Narrow: horizontal scroll, opened on the latest (right-most)
        // week like the official heatmap's right alignment.
        if (!_autoScrolled) {
          _autoScrolled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients &&
                _scroll.position.maxScrollExtent > 0 &&
                _scroll.offset < _scroll.position.maxScrollExtent) {
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
            }
          });
        }
        return Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            child: painted,
          ),
        );
      }),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // onTapUp, not onTapDown: a slow drag that starts on a cell would
      // otherwise leave a stray detail panel behind (long-press still picks).
      onTapUp: (d) => _pickCell(d.globalPosition),
      onLongPressStart: (d) => _pickCell(d.globalPosition),
      child: body,
    );
  }

  void _pickCell(Offset globalPosition) {
    final box = _gridBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.width <= 0) return;
    // The grid box's local coordinates already carry the horizontal scroll
    // translation, so no offset fix-up is needed.
    final local = box.globalToLocal(globalPosition);
    final cell = math.max(
      kHeatmapMinCell,
      (box.size.width - (kHeatmapWeeks - 1) * kHeatmapGap) / kHeatmapWeeks,
    );
    final hit = heatmapCellAt(local, cellSize: cell);
    if (hit == null) {
      if (_selected != null) setState(() => _selected = null);
      return;
    }
    setState(() => _selected = hit);
  }

  Widget _detail(
    BuildContext context,
    List<List<UsageHeatmapCell?>> grid,
    int week,
    int day,
  ) {
    // One official template per (mode × metric) — the date prefix embeds
    // the 当周 / 截至 … 当周累计 forms verbatim.
    String key;
    int tokens;
    int turns;
    int tools;
    String date;
    if (_mode == UsageHeatmapMode.daily) {
      final cell = grid[week][day]!;
      tokens = cell.totalTokens;
      turns = cell.turnCount;
      tools = cell.toolCallCount;
      date = cell.date;
      key = switch (_metric) {
        UsageHeatmapMetric.turns => 'usage.heatmapCell',
        UsageHeatmapMetric.tools => 'usage.heatmapToolCell',
      };
    } else {
      // weekly sums one column; cumulative sums the 0..week prefix to match
      // the 截至 … 当周累计 template and the prefix-based shading.
      final summary = _mode == UsageHeatmapMode.cumulative
          ? heatmapCumulativeSummary(grid, week)
          : heatmapColumnSummary(grid[week]);
      tokens = summary.$1;
      turns = summary.$2;
      tools = summary.$3;
      date = summary.$4;
      key = switch ((_mode, _metric)) {
        (UsageHeatmapMode.weekly, UsageHeatmapMetric.turns) =>
          'usage.heatmapWeeklyCell',
        (UsageHeatmapMode.weekly, UsageHeatmapMetric.tools) =>
          'usage.heatmapWeeklyToolCell',
        (_, UsageHeatmapMetric.turns) => 'usage.heatmapCumulativeCell',
        (_, UsageHeatmapMetric.tools) => 'usage.heatmapCumulativeToolCell',
      };
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.field),
      ),
      child: Text(
        trP(context, key, [
          date,
          compactTokens(context, tokens),
          '$turns',
          '$tools',
        ]),
        style: ZType.caption.copyWith(color: ZInk.soft(context)),
      ),
    );
  }

  Widget _legend(BuildContext context) {
    return Semantics(
      label: tr(context, 'usage.heatmap.intensity'),
      child: Row(
        children: [
          Text(tr(context, 'usage.heatmap.less'),
              style: ZType.caption.copyWith(color: ZInk.faint(context))),
          const SizedBox(width: 4),
          for (var level = 0; level <= 4; level++) ...[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: level == 0
                    ? ZInk.tile(context)
                    : ZInk.usageHeatmap(context, level),
                // 10px swatch — a third of the mini tier keeps the
                // official legend chip proportions without a literal.
                borderRadius: BorderRadius.circular(ZRadius.mini / 3),
                border: Border.all(color: ZInk.hairline(context)),
              ),
            ),
            const SizedBox(width: 3),
          ],
          Text(tr(context, 'usage.heatmap.more'),
              style: ZType.caption.copyWith(color: ZInk.faint(context))),
        ],
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  final List<List<UsageHeatmapCell?>> grid;
  final List<List<int>> levels;
  final List<Color> ladder;
  final Color border;
  final Color selectedColor;
  final (int, int)? selected;

  _HeatmapPainter({
    required this.grid,
    required this.levels,
    required this.ladder,
    required this.border,
    required this.selectedColor,
    required this.selected,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (grid.isEmpty) return;
    final step = (size.width + kHeatmapGap) / kHeatmapWeeks;
    final cell = step - kHeatmapGap;
    // Official cells are `rounded-[4px]` at ~12px — scale the corner with
    // the cell so the 8dp narrow-screen floor stays readable.
    final radius = Radius.circular(cell / 3);
    final fill = Paint();
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final selection = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = selectedColor;
    for (var w = 0; w < kHeatmapWeeks && w < grid.length; w++) {
      for (var d = 0; d < kHeatmapDays && d < grid[w].length; d++) {
        final rect = Rect.fromLTWH(
          w * step,
          d * step,
          cell,
          cell,
        );
        final rrect = RRect.fromRectAndRadius(rect, radius);
        final level = levels[w][d];
        if (level > 0) {
          canvas.drawRRect(rrect, fill..color = ladder[level]);
        }
        // `hasUsage ? border-border : border-transparent` — used cells
        // carry the hairline, empty ones stay borderless.
        final cellData = grid[w][d];
        if (cellData != null && cellData.totalTokens > 0) {
          canvas.drawRRect(rrect, stroke..color = border);
        }
        if (selected == (w, d)) {
          canvas.drawRRect(rrect.deflate(1), selection);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      old.grid != grid ||
      old.levels != levels ||
      old.selected != selected ||
      old.ladder != ladder ||
      old.border != border ||
      old.selectedColor != selectedColor;
}
