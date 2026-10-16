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
/// [heatmapLevels], [heatmapCellAt], [heatmapMonthSpans]) are exported for
/// unit tests.

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

/// Snapped hit test: the (week, day) whose cell center is nearest to
/// [local]. The 2dp gaps are too small to aim at, so gap pixels — and up
/// to half a step beyond the borders — snap to the closest cell; results
/// outside the weeks×days range return null, which the tap handler reads
/// as "outside the grid" (dismiss the bubble). Pure so the tap→cell
/// mapping stays unit-testable (design D3).
(int week, int day)? heatmapCellAt(
  Offset local, {
  required double cellSize,
  double gap = kHeatmapGap,
  int weeks = kHeatmapWeeks,
  int days = kHeatmapDays,
}) {
  if (cellSize <= 0) return null;
  // Cell centers sit at k * step + cellSize / 2 — rounding the offset from
  // the nearest center snaps gaps to the closest cell. Negative results
  // fall out of the range check instead of folding onto column/row 0
  // (Dart's round() rounds halves away from zero, so the exact midpoint
  // between two cells picks the later one).
  final step = cellSize + gap;
  final col = ((local.dx - cellSize / 2) / step).round();
  final row = ((local.dy - cellSize / 2) / step).round();
  if (col < 0 || row < 0 || col >= weeks || row >= days) return null;
  return (col, row);
}

/// One month-label group over the normalized 52×7 grid (official `kVn`):
/// consecutive week columns sharing a YYYY-MM merge into one span; only
/// the last [keepMonths] groups keep a label ([month] non-null), earlier
/// groups stay blank but keep their span width.
typedef HeatmapMonthSpan = ({String key, int startWeek, int span, int? month});

/// Groups the grid's columns into month spans for the label row under the
/// grid (official `kVn`): each column contributes its monthDate
/// ([_columnMonthDate] for real columns, [_synthesizedMonthKey] for the
/// null-filled stretches), consecutive columns with the same 'YYYY-MM' key
/// merge, and only the last [keepMonths] groups keep a label. [month] is
/// the 'YYYY-MM' month number (1-12) or null for blanked groups and the
/// unlabeled stretches that carry no anchor (key '').
///
/// The synthesized dates mirror the official window backfill (`SVn` — the
/// server pads to the full 52-week window with dated zero cells): without
/// them a short history's null-filled lead columns collapse into one blank
/// span and the lone real month's 1-2 column label gets clipped to
/// invisibility. The anchor is the last real column: its first non-null
/// day minus its row index (the row IS the weekday, see protocol
/// `_parseWeek`) lands on the column's first day; every other all-null
/// column reads the day-1 date of the 7-day window at that offset
/// (official `TVn` preference), else the offset itself.
List<HeatmapMonthSpan> heatmapMonthSpans(
  List<List<UsageHeatmapCell?>> grid, {
  int keepMonths = 12,
}) {
  // One sweep for the anchor: the last column with a non-null day.
  int? anchorWeek;
  for (var w = grid.length - 1; w >= 0 && anchorWeek == null; w--) {
    if (grid[w].any((cell) => cell != null)) anchorWeek = w;
  }
  DateTime? anchorStart;
  if (anchorWeek != null) {
    for (var row = 0; row < grid[anchorWeek].length; row++) {
      final date = grid[anchorWeek][row]?.date ?? '';
      if (date.isEmpty) continue;
      final parsed = DateTime.tryParse(date);
      if (parsed != null) anchorStart = parsed.subtract(Duration(days: row));
      break;
    }
  }
  final keys = <String>[];
  final starts = <int>[];
  final spans = <int>[];
  for (var week = 0; week < grid.length; week++) {
    final key = _heatmapMonthKey(grid[week]) ??
        _synthesizedMonthKey(anchorStart, anchorWeek, week);
    if (keys.isNotEmpty && keys.last == key) {
      spans[spans.length - 1] += 1;
    } else {
      keys.add(key);
      starts.add(week);
      spans.add(1);
    }
  }
  final blank = math.max(0, keys.length - keepMonths);
  return [
    for (var i = 0; i < keys.length; i++)
      (
        key: keys[i],
        startWeek: starts[i],
        span: spans[i],
        month: i < blank ? null : _heatmapMonthNumber(keys[i]),
      ),
  ];
}

/// Month key of an all-null column given the anchor ([anchorStart] = the
/// anchor column's first day, [anchorWeek] its index): the day-1 date of
/// the 7-day window ending on that column's own first day when present,
/// else the first day itself. '' when there is no anchor — with nothing
/// real to project, the null stretches keep the legacy blank grouping.
String _synthesizedMonthKey(DateTime? anchorStart, int? anchorWeek, int week) {
  if (anchorStart == null || anchorWeek == null) return '';
  final start = anchorStart.add(Duration(days: 7 * (week - anchorWeek)));
  for (var row = 0; row < kHeatmapDays; row++) {
    final day = start.add(Duration(days: row));
    if (day.day == 1) return _monthKeyOf(day);
  }
  return _monthKeyOf(start);
}

/// 'YYYY-MM' of a date, month zero-padded (official `TVn(...).slice(0, 7)`).
String _monthKeyOf(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}';

/// Column monthDate (official `TVn`): the column's first date ending with
/// '-01' (a month start), else its first day, else its first non-null day;
/// null for all-null columns, whose key falls back to a synthesized date
/// ([_synthesizedMonthKey]).
String? _columnMonthDate(List<UsageHeatmapCell?> week) {
  for (final cell in week) {
    if (cell != null && cell.date.endsWith('-01')) return cell.date;
  }
  if (week.isNotEmpty && week.first != null) return week.first!.date;
  for (final cell in week) {
    if (cell != null) return cell.date;
  }
  return null;
}

/// 'YYYY-MM' grouping key of a column (`TVn(...).slice(0, 7)`); null for
/// all-null columns (no monthDate to slice).
String? _heatmapMonthKey(List<UsageHeatmapCell?> week) {
  final date = _columnMonthDate(week);
  if (date == null) return null;
  return date.length > 7 ? date.substring(0, 7) : date;
}

/// Month number (1-12) of a 'YYYY-MM' key; null for '' or malformed keys,
/// so padding stretches never render a label.
int? _heatmapMonthNumber(String key) {
  if (key.length != 7 || key[4] != '-') return null;
  final month = int.tryParse(key.substring(5));
  return month != null && month >= 1 && month <= 12 ? month : null;
}

/// Bubble width cap; on narrow screens the bubble shrinks with the card
/// (`min(260, stackW - 32)`, design §2.2).
const double _kBubbleMaxWidth = 260;

/// Minimum free space above a cell before the bubble anchors above it —
/// roughly a bubble's height, so the anchor edge can be picked blindly.
const double _kBubbleAboveMin = 72;

/// Gap between the cell border and the bubble edge.
const double _kBubbleOffset = 6;

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
  /// grid overflows, then never fight the user's scrolling again. The
  /// controller also watches [ScrollPosition.isScrollingNotifier] — scrolling
  /// invalidates the bubble's anchor coordinates, so it dismisses the bubble.
  late final ScrollController _scroll = ScrollController(
    onAttach: (position) =>
        position.isScrollingNotifier.addListener(_clearOnScroll),
  );
  bool _autoScrolled = false;

  /// The painted 52×7 surface, for tap → cell hit testing (its RenderBox
  /// is the only box whose size and local coordinates match the grid — the
  /// card's own box includes the title/padding).
  final GlobalKey _gridBoxKey = GlobalKey();

  /// The card-interior Stack the bubble positions itself in.
  final GlobalKey _stackKey = GlobalKey();

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
    for (final position in _scroll.positions) {
      position.isScrollingNotifier.removeListener(_clearOnScroll);
    }
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grid = normalizeHeatmapWeeks(widget.heatmap);
    final levels = heatmapLevels(grid, _mode);
    return Card(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The bubble rides a Stack over the whole card interior so it can
          // anchor next to the selected cell (design §2.2); bubbleW leaves
          // the 16dp clamp margins on both sides.
          final stackW = constraints.maxWidth;
          final bubbleW =
              math.min(_kBubbleMaxWidth, math.max(0.0, stackW - 32));
          final bubble = _bubble(context, grid, stackW, bubbleW);
          return Stack(
            key: _stackKey,
            children: [
              Padding(
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
                              UsageHeatmapMetric.turns =>
                                'usage.heatmap.metricTurns',
                              UsageHeatmapMetric.tools =>
                                'usage.heatmap.metricTools',
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
                            style:
                                ZType.sub.copyWith(color: ZInk.faint(context))),
                      )
                    else ...[
                      _grid(context, grid, levels),
                      const SizedBox(height: 8),
                      _legend(context),
                    ],
                  ],
                ),
              ),
              if (bubble != null) bubble,
            ],
          );
        },
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
    // Scoped to the painted surface so the month-label texts below never
    // merge into the description node.
    final active = mostActiveCell(grid);
    final semantics = active == null
        ? null
        : trP(context, 'usage.heatmap.description', [
            active.date,
            compactTokens(context, active.totalTokens),
          ]);
    final spans = heatmapMonthSpans(grid);
    final body = LayoutBuilder(builder: (context, constraints) {
      final available = constraints.maxWidth - (kHeatmapWeeks - 1) * kHeatmapGap;
      final cell = math.max(kHeatmapMinCell, available / kHeatmapWeeks);
      final step = cell + kHeatmapGap;
      final contentW = kHeatmapWeeks * cell + (kHeatmapWeeks - 1) * kHeatmapGap;
      final contentH = kHeatmapDays * cell + (kHeatmapDays - 1) * kHeatmapGap;
      // The month-label row is part of the same scroll child (official puts
      // it under the grid), so it rides the horizontal scroll.
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            container: true,
            label: semantics,
            child: SizedBox(
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
            ),
          ),
          const SizedBox(height: 6),
          _monthLabels(context, spans, step, contentW),
        ],
      );
      if (contentW <= constraints.maxWidth + 0.5) return content;
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
        child: SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          child: content,
        ),
      );
    });
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // onTapUp, not onTapDown: a slow drag that starts on a cell would
      // otherwise leave a stray bubble behind (long-press still picks).
      onTapUp: (d) => _pickCell(d.globalPosition),
      onLongPressStart: (d) => _pickCell(d.globalPosition),
      child: body,
    );
  }

  /// Official `kVn` label row under the grid: one slot per month span, the
  /// last one net of the trailing grid gap so the slots span exactly the
  /// grid width; only the last 12 months carry a left-aligned short name
  /// ([ZType.caption], blank slots keep their width for alignment).
  Widget _monthLabels(
    BuildContext context,
    List<HeatmapMonthSpan> spans,
    double step,
    double width,
  ) {
    return SizedBox(
      width: width,
      height: 16,
      child: Row(
        children: [
          for (var i = 0; i < spans.length; i++)
            SizedBox(
              width: spans[i].span * step -
                  (i == spans.length - 1 ? kHeatmapGap : 0),
              child: spans[i].month == null
                  ? null
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        tr(context, 'usage.heatmap.month.${spans[i].month}'),
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style:
                            ZType.caption.copyWith(color: ZInk.faint(context)),
                      ),
                    ),
            ),
        ],
      ),
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
    // Snapped hits on empty cells, gap-outs (month-label row included: row
    // math lands ≥ 7) and points beyond the grid dismiss the bubble; a
    // repeat tap on the selected cell toggles it off.
    if (hit != null) {
      final grid = normalizeHeatmapWeeks(widget.heatmap);
      final (week, day) = hit;
      if (grid[week][day] != null) {
        setState(() => _selected = _selected == hit ? null : hit);
        return;
      }
    }
    if (_selected != null) setState(() => _selected = null);
  }

  /// Dismisses the bubble while a horizontal scroll activity is running —
  /// its anchor coordinates were captured for the pre-scroll layout.
  void _clearOnScroll() {
    if (_selected == null) return;
    if (!(_scroll.hasClients && _scroll.position.isScrollingNotifier.value)) {
      return;
    }
    setState(() => _selected = null);
  }

  /// The floating detail bubble anchored to the selected cell (design §2.2):
  /// above the cell when its top has [_kBubbleAboveMin] of room — anchored
  /// by its bottom edge so the bubble height never enters the math — below
  /// it otherwise. Null when nothing is selected, the cell is empty, or the
  /// render boxes are not ready yet.
  Widget? _bubble(
    BuildContext context,
    List<List<UsageHeatmapCell?>> grid,
    double stackW,
    double bubbleW,
  ) {
    if (_selected case (final week, final day)) {
      if (week >= grid.length ||
          day >= grid[week].length ||
          grid[week][day] == null) {
        return null;
      }
      final gridBox =
          _gridBoxKey.currentContext?.findRenderObject() as RenderBox?;
      final stackBox =
          _stackKey.currentContext?.findRenderObject() as RenderBox?;
      if (gridBox == null ||
          stackBox == null ||
          !gridBox.hasSize ||
          !stackBox.hasSize) {
        return null;
      }
      final cell = math.max(
        kHeatmapMinCell,
        (gridBox.size.width - (kHeatmapWeeks - 1) * kHeatmapGap) / kHeatmapWeeks,
      );
      final step = cell + kHeatmapGap;
      // The grid box's local coordinates carry the horizontal scroll
      // translation; routing through the global space lands in Stack
      // coordinates regardless of the scroll offset.
      final top = stackBox.globalToLocal(
        gridBox.localToGlobal(Offset(week * step, day * step)),
      );
      final left = (top.dx + cell / 2 - bubbleW / 2)
          .clamp(
            ZSpacing.card,
            math.max(ZSpacing.card, stackW - ZSpacing.card - bubbleW),
          )
          .toDouble();
      final above = top.dy >= _kBubbleAboveMin;
      return Positioned(
        left: left,
        width: bubbleW,
        top: above ? null : top.dy + cell + _kBubbleOffset,
        bottom: above ? stackBox.size.height - top.dy + _kBubbleOffset : null,
        child: _bubbleCard(context, grid, week, day),
      );
    }
    return null;
  }

  /// The bubble body: the official mode×metric template the old bottom
  /// panel used (unchanged copy), as a Material elevation card — a date
  /// line ([ZType.sub]) over a value line with the token count emphasised
  /// and the message/tool counts in caption. The template's first ' · '
  /// splits the value line (both locales share that separator).
  Widget _bubbleCard(
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
    final text = trP(context, key, [
      date,
      compactTokens(context, tokens),
      '$turns',
      '$tools',
    ]);
    final lines = text.split('\n');
    final value = lines.length > 1 ? lines.sublist(1).join('\n') : '';
    final split = value.indexOf(' · ');
    final strong = split < 0 ? value : value.substring(0, split);
    final rest = split < 0 ? '' : value.substring(split);
    return Semantics(
      label: text,
      child: Material(
        color: ZInk.tile(context),
        elevation: 4,
        borderRadius: BorderRadius.circular(ZRadius.field),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                lines.first,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: ZType.sub.copyWith(color: ZInk.solid(context)),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      strong,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style:
                          ZType.bodyStrong.copyWith(color: ZInk.solid(context)),
                    ),
                  ),
                  if (rest.isNotEmpty)
                    Flexible(
                      child: Text(
                        rest,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            ZType.caption.copyWith(color: ZInk.muted(context)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
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
