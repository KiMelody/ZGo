import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../protocol/usage_stats.dart';
import '../theme.dart';
import '../ui_settings.dart';

/// 「每日 Token 趋势图」line chart (web `AppUsageDailyModelTrendChart`,
/// task 10-08-parity-usage D4) — replaces the retired stacked bars. One
/// monotone curve per model ([ZInk.usageChart] palette, server share
/// order), x tick thinning and a color-dot legend, mirroring the
/// official Recharts form. Also reused by the coding-plan card's
/// 用量趋势 section.
///
/// Tapping (or long-pressing) the plot picks the nearest day and floats
/// the official tooltip bubble — 「date - total tokens」 over one row per
/// model with usage that day — with the official `activeDot` (no vertical
/// cursor line) on every curve (task 10-16-usage-chart-tooltips §3).

/// Series cap — official `snapshot.models.slice(0, 6)`.
const int kTrendMaxModels = 6;

/// One plotted series; a null/empty name renders as 未知模型
/// (official `unknownModel`).
typedef UsageLineSeries = ({String? modelId, List<double> values});

/// X tick thinning (official rule): ≤14 labels all shown, >45 every 7th,
/// else every 5th.
/// Tick indices for the trend X axis, thinned by label footprint: the
/// start and end labels are always kept (the densest information —
/// recharts `preserveStartEnd` semantics); a middle label is kept only
/// when its footprint clears the previously kept one by [minGap].
/// Footprints follow the painter's alignment — first = left-aligned
/// [x, x+w], last = right-aligned [x-w, x], middle = centered. Replaces
/// the count-based rule (≤14 all / step 5|7), which overlapped the
/// left-aligned first label onto the centered second on 360dp
/// (「10-1010-11」, 10-17 真机取证).
List<int> trendTickIndices(
  int n, {
  required double spacing,
  required double labelWidth,
  double minGap = 8,
}) {
  if (n <= 0) return const [];
  if (n == 1) return const [0];
  double left(int i) => switch (i) {
        0 => 0.0,
        _ when i == n - 1 => i * spacing - labelWidth,
        _ => i * spacing - labelWidth / 2,
      };
  double right(int i) => left(i) + labelWidth;
  final kept = <int>[0];
  for (var i = 1; i < n - 1; i++) {
    if (left(i) >= right(kept.last) + minGap) kept.add(i);
  }
  final last = n - 1;
  // The end label always stays; the last kept middle tick yields on a
  // collision — unless it is [0] (dropping both ends would lose the range).
  if (left(last) < right(kept.last) + minGap && kept.length > 1) {
    kept.removeLast();
  }
  kept.add(last);
  return kept;
}

/// Horizontal inset of the plot inside the chart box — painter and tap hit
/// test ([trendIndexAt]) share it so taps and curves agree on where day 0
/// and day n-1 sit.
const double kTrendXPad = 2;

/// Nearest day index for a local [dx] in a chart box [width] wide carrying
/// [n] day labels (official tooltip triggers on the nearest point). The
/// plot spans [kTrendXPad] .. width - [kTrendXPad], the painter's frame;
/// points outside it clamp to the nearest end — a tap still means "show
/// the closest day". Null when there is nothing to plot. Pure so the
/// tap→day mapping stays unit-testable (design §3.1).
int? trendIndexAt(double dx, double width, int n) {
  if (n <= 0) return null;
  if (n == 1) return 0;
  final plotWidth = width - 2 * kTrendXPad;
  if (plotWidth <= 0) return 0;
  final i = ((dx - kTrendXPad) / plotWidth * (n - 1)).round();
  return i.clamp(0, n - 1);
}

/// Trend inputs from the app snapshot: the top models in server order
/// crossed with the per-day usage rows (dates sorted ascending, missing
/// days plot as 0 — same data the retired stacked bars read).
(List<String> dates, List<UsageLineSeries> series) buildTrendSeries(
  List<AppModelUsage> models,
  List<AppDailyUsage> daily,
) {
  final top = models.take(kTrendMaxModels).toList();
  final dates = [for (final d in daily) d.date]..sort();
  final byDate = {for (final d in daily) d.date: d};
  final series = <UsageLineSeries>[
    for (final model in top)
      (
        modelId: model.modelId,
        values: [
          for (final date in dates)
            0.0 +
                (byDate[date]?.models ?? const [])
                    .where((m) => m.modelId == model.modelId)
                    .fold(0.0, (a, m) => a + m.totalTokens),
        ],
      ),
  ];
  return (dates, series);
}

/// Fritsch–Carlson monotone cubic through [points] — the official
/// `monotone` curve interpolation; overshoot-free so a spike cannot dip
/// below the zero baseline. Pure, unit-tested for band containment.
Path monotonePath(List<Offset> points) {
  final n = points.length;
  final path = Path();
  if (n == 0) return path;
  path.moveTo(points.first.dx, points.first.dy);
  if (n == 1) return path;
  final delta = <double>[
    for (var i = 0; i < n - 1; i++)
      (points[i + 1].dy - points[i].dy) / (points[i + 1].dx - points[i].dx),
  ];
  final m = List<double>.filled(n, 0);
  m[0] = delta[0];
  m[n - 1] = delta[n - 2];
  for (var i = 1; i < n - 1; i++) {
    m[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2;
  }
  for (var i = 0; i < n - 1; i++) {
    if (delta[i] == 0) {
      m[i] = 0;
      m[i + 1] = 0;
      continue;
    }
    final a = m[i] / delta[i];
    final b = m[i + 1] / delta[i];
    final s = a * a + b * b;
    if (s > 9) {
      final t = 3 / math.sqrt(s);
      m[i] = t * a * delta[i];
      m[i + 1] = t * b * delta[i];
    }
  }
  for (var i = 0; i < n - 1; i++) {
    final dx = (points[i + 1].dx - points[i].dx) / 3;
    path.cubicTo(
      points[i].dx + dx,
      points[i].dy + m[i] * dx,
      points[i + 1].dx - dx,
      points[i + 1].dy - m[i + 1] * dx,
      points[i + 1].dx,
      points[i + 1].dy,
    );
  }
  return path;
}

/// Bubble width cap; on narrow screens the bubble shrinks with the card
/// (`min(260, width - 16)`), and the horizontal anchor stays [_kBubbleMargin]
/// inside both chart edges (design §3.2).
const double _kBubbleMaxWidth = 260;
const double _kBubbleMargin = 8;

/// Minimum free space above the touch point before the bubble anchors above
/// it — roughly a bubble's height, so the anchor edge can be picked blindly.
const double _kBubbleAboveMin = 72;

/// Gap between the touch point and the bubble edge.
const double _kBubbleOffset = 8;

class UsageLineChart extends StatefulWidget {
  final List<String> xLabels;
  final List<UsageLineSeries> series;

  /// Chart-surface painter key — tests locate the painted 200dp plot by it
  /// (the bubble's Material carries a shape-border CustomPaint too).
  static const Key chartKey = ValueKey('usage-trend-chart');

  const UsageLineChart({
    super.key,
    required this.xLabels,
    required this.series,
  });

  @override
  State<UsageLineChart> createState() => _UsageLineChartState();
}

class _UsageLineChartState extends State<UsageLineChart> {
  /// Selected day index (null = no bubble) and the chart-local touch that
  /// picked it — the bubble anchors to that point.
  int? _selected;
  Offset? _touchLocal;

  /// The widget's own box: the chart surface is its first child at the
  /// origin, so chart-local touch coordinates double as Stack coordinates
  /// and its width is the frame the painter and [trendIndexAt] share.
  final GlobalKey _stackKey = GlobalKey();

  @override
  void didUpdateWidget(covariant UsageLineChart old) {
    super.didUpdateWidget(old);
    // New labels or series (range switch, refresh) re-point every index at
    // another day — the old selection no longer maps to the same date.
    if (old.xLabels != widget.xLabels || old.series != widget.series) {
      _selected = null;
      _touchLocal = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.xLabels.isEmpty || widget.series.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(tr(context, 'usageRpc.appUsageEmpty'),
            style: ZType.sub.copyWith(color: ZInk.faint(context))),
      );
    }
    final bubble = _bubble(context);
    return Stack(
      key: _stackKey,
      // The bubble may poke past the 200dp chart frame — it still lands
      // inside the card (design §3.2).
      clipBehavior: Clip.none,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 200,
              width: double.infinity,
              // Only the plot reacts: the legend (and the empty state above)
              // stays free of the tap handler.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // onTapUp, not onTapDown: a slow drag that starts on the
                // chart would otherwise leave a stray bubble behind
                // (long-press still picks).
                onTapUp: (d) => _pickDay(d.localPosition),
                onLongPressStart: (d) => _pickDay(d.localPosition),
                child: CustomPaint(
                  key: UsageLineChart.chartKey,
                  painter: _LineChartPainter(
                    xLabels: widget.xLabels,
                    series: widget.series,
                    lineColors: [
                      for (var i = 0; i < widget.series.length; i++)
                        ZInk.usageChart(context, i),
                    ],
                    tickColor: ZInk.hairline(context),
                    labelColor: ZInk.muted(context),
                    selectedIndex: _selected,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _legend(context),
          ],
        ),
        if (bubble != null) bubble,
      ],
    );
  }

  /// Series display name — shared by the legend and the bubble rows; a
  /// null/empty model id renders as 未知模型 (official `unknownModel`).
  String _modelName(BuildContext context, UsageLineSeries s) =>
      s.modelId == null || s.modelId!.isEmpty
          ? tr(context, 'usage.unknownModel')
          : s.modelId!;

  Widget _legend(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (var i = 0; i < widget.series.length; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: ZInk.usageChart(context, i),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                _modelName(context, widget.series[i]),
                style: ZType.caption.copyWith(color: ZInk.muted(context)),
              ),
            ],
          ),
      ],
    );
  }

  void _pickDay(Offset local) {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.width <= 0) return;
    final hit = trendIndexAt(local.dx, box.size.width, widget.xLabels.length);
    if (hit == null) return;
    // A repeat tap on the selected day closes the bubble; any other point
    // re-anchors it to that day.
    if (_selected == hit) {
      setState(() {
        _selected = null;
        _touchLocal = null;
      });
      return;
    }
    setState(() {
      _selected = hit;
      _touchLocal = local;
    });
  }

  /// The floating day-detail bubble anchored to the picked touch point
  /// (design §3.2): above the point when [_kBubbleAboveMin] of room is left
  /// — anchored by its bottom edge so the bubble height never enters the
  /// math — below it otherwise. Null when nothing is selected or the render
  /// box is not ready yet.
  Widget? _bubble(BuildContext context) {
    final index = _selected;
    final touch = _touchLocal;
    if (index == null || touch == null) return null;
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final width = box.size.width;
    final bubbleW = math.min(
      _kBubbleMaxWidth,
      math.max(0.0, width - 2 * _kBubbleMargin),
    );
    final left = (touch.dx - bubbleW / 2)
        .clamp(
          _kBubbleMargin,
          math.max(_kBubbleMargin, width - _kBubbleMargin - bubbleW),
        )
        .toDouble();
    // The chart box sits at the Stack origin, so the chart-local touch also
    // reads as a Stack-space anchor: `bottom: stackH - touch.dy + gap`
    // flips into "the bubble's bottom edge stays [_kBubbleOffset] above the
    // touch point" without measuring the bubble.
    final above = touch.dy >= _kBubbleAboveMin;
    return Positioned(
      left: left,
      width: bubbleW,
      top: above ? null : touch.dy + _kBubbleOffset,
      bottom: above ? box.size.height - touch.dy + _kBubbleOffset : null,
      child: _bubbleCard(context, index),
    );
  }

  /// The bubble body (official tooltip structure): a 「date - total tokens」
  /// header over one row per model with usage that day — color dot, name
  /// and compact value, series order, `> 0` only.
  Widget _bubbleCard(BuildContext context, int index) {
    var total = 0.0;
    for (final s in widget.series) {
      if (index < s.values.length) total += s.values[index];
    }
    return Material(
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
              trP(context, 'usage.trend.tooltipTotal', [
                widget.xLabels[index],
                compactTokens(context, total.round()),
              ]),
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: ZType.sub.copyWith(color: ZInk.solid(context)),
            ),
            for (var s = 0; s < widget.series.length; s++)
              if (index < widget.series[s].values.length &&
                  widget.series[s].values[index] > 0) ...[
                const SizedBox(height: 2),
                _modelRow(context, s, index),
              ],
          ],
        ),
      ),
    );
  }

  /// One model row of the bubble (official formatter): series color dot,
  /// the model name, then the compact value on the right.
  Widget _modelRow(BuildContext context, int s, int index) {
    final value = widget.series[s].values[index];
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: ZInk.usageChart(context, s),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _modelName(context, widget.series[s]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ZType.caption.copyWith(color: ZInk.muted(context)),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          compactTokens(context, value.round()),
          style: ZType.caption.copyWith(color: ZInk.faint(context)),
        ),
      ],
    );
  }
}

class _LineChartPainter extends CustomPainter {
  final List<String> xLabels;
  final List<UsageLineSeries> series;
  final List<Color> lineColors;
  final Color tickColor;
  final Color labelColor;
  final int? selectedIndex;

  static const _topPad = 16.0;
  static const _bottomPad = 16.0;

  _LineChartPainter({
    required this.xLabels,
    required this.series,
    required this.lineColors,
    required this.tickColor,
    required this.labelColor,
    required this.selectedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      kTrendXPad,
      _topPad,
      size.width - kTrendXPad,
      size.height - _bottomPad,
    );
    final n = xLabels.length;
    double x(int i) =>
        n == 1 ? plot.center.dx : plot.left + (plot.width) * i / (n - 1);
    var maxV = 0.0;
    for (final s in series) {
      for (final v in s.values) {
        if (v > maxV) maxV = v;
      }
    }
    if (maxV <= 0) maxV = 1;
    double yOf(double v) => plot.bottom - plot.height * (v / maxV);

    // Zero baseline + y-max label (official y domain [0, maxTokens]).
    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.right, plot.bottom),
      Paint()..color = tickColor,
    );
    _label(canvas, compactNumber(maxV), Offset(plot.left, 2),
        align: TextAlign.left);

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final dot = Paint()..style = PaintingStyle.fill;
    for (var s = 0; s < series.length; s++) {
      final values = series[s].values;
      if (values.isEmpty) continue;
      final points = [
        for (var i = 0; i < math.min(n, values.length); i++)
          Offset(x(i), yOf(values[i])),
      ];
      final color = lineColors[s % lineColors.length];
      canvas.drawPath(monotonePath(points), line..color = color);
      // Official `activeDot={r:4}`: the selected day carries a filled dot on
      // every curve. No vertical cursor line — official `cursor={false}`.
      final selected = selectedIndex;
      if (selected != null && selected < points.length) {
        canvas.drawCircle(points[selected], 4, dot..color = color);
      }
    }

    // Label footprint for tick thinning: the widest shortened date across
    // the range (same-width pattern in practice; max stays honest across a
    // month boundary like 10-31 → 11-01). TextPainter layouts of ~30 short
    // strings are microsecond-scale and only run on repaint.
    var labelW = 0.0;
    for (final l in xLabels) {
      labelW = math.max(labelW, _measure(_shortDate(l)));
    }
    final indices = trendTickIndices(
      n,
      spacing: plot.width / (n - 1),
      labelWidth: labelW,
    );
    for (final i in indices) {
      final anchor = x(i);
      final align = i == 0
          ? TextAlign.left
          : i == n - 1
              ? TextAlign.right
              : TextAlign.center;
      _label(canvas, _shortDate(xLabels[i]), Offset(anchor, plot.bottom + 4),
          align: align);
    }
  }

  void _label(Canvas canvas, String text, Offset pos,
      {required TextAlign align}) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: ZType.caption.copyWith(color: labelColor)),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout();
    final dx = switch (align) {
      TextAlign.left => pos.dx,
      TextAlign.right => pos.dx - tp.width,
      _ => pos.dx - tp.width / 2,
    };
    tp.paint(canvas, Offset(dx, pos.dy));
  }

  /// Unpainted [_label]: just the laid-out width (color-independent).
  double _measure(String text) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: ZType.caption.copyWith(color: labelColor)),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  /// Compact axis number (official compact formatter, en-style k/M keeps
  /// tick labels short in both locales).
  static String compactNumber(double v) {
    if (v >= 1000000) return '${_trim(v / 1000000)}M';
    if (v >= 1000) return '${_trim(v / 1000)}k';
    return v.round().toString();
  }

  static String _trim(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  /// MM-dd from an ISO date — the x strip stays readable at 52 points.
  static String _shortDate(String iso) =>
      iso.length >= 10 ? iso.substring(5, 10) : iso;

  @override
  bool shouldRepaint(_LineChartPainter old) =>
      old.xLabels != xLabels ||
      old.series != series ||
      old.lineColors != lineColors ||
      old.selectedIndex != selectedIndex;
}
