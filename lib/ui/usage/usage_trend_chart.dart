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

/// Series cap — official `snapshot.models.slice(0, 6)`.
const int kTrendMaxModels = 6;

/// One plotted series; a null/empty name renders as 未知模型
/// (official `unknownModel`).
typedef UsageLineSeries = ({String? modelId, List<double> values});

/// X tick thinning (official rule): ≤14 labels all shown, >45 every 7th,
/// else every 5th.
List<int> trendTickIndices(int n) {
  if (n <= 0) return const [];
  if (n <= 14) return [for (var i = 0; i < n; i++) i];
  final step = n > 45 ? 7 : 5;
  return [for (var i = 0; i < n; i += step) i];
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

class UsageLineChart extends StatelessWidget {
  final List<String> xLabels;
  final List<UsageLineSeries> series;

  const UsageLineChart({
    super.key,
    required this.xLabels,
    required this.series,
  });

  @override
  Widget build(BuildContext context) {
    if (xLabels.isEmpty || series.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(tr(context, 'usageRpc.appUsageEmpty'),
            style: ZType.sub.copyWith(color: ZInk.faint(context))),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 200,
          width: double.infinity,
          child: CustomPaint(
            painter: _LineChartPainter(
              xLabels: xLabels,
              series: series,
              lineColors: [
                for (var i = 0; i < series.length; i++)
                  ZInk.usageChart(context, i),
              ],
              tickColor: ZInk.hairline(context),
              labelColor: ZInk.muted(context),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (var i = 0; i < series.length; i++)
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
                    series[i].modelId == null || series[i].modelId!.isEmpty
                        ? tr(context, 'usage.unknownModel')
                        : series[i].modelId!,
                    style: ZType.caption.copyWith(color: ZInk.muted(context)),
                  ),
                ],
              ),
          ],
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

  static const _topPad = 16.0;
  static const _bottomPad = 16.0;
  static const _xPad = 2.0;

  _LineChartPainter({
    required this.xLabels,
    required this.series,
    required this.lineColors,
    required this.tickColor,
    required this.labelColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      _xPad,
      _topPad,
      size.width - _xPad,
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
    for (var s = 0; s < series.length; s++) {
      final values = series[s].values;
      if (values.isEmpty) continue;
      final points = [
        for (var i = 0; i < math.min(n, values.length); i++)
          Offset(x(i), yOf(values[i])),
      ];
      canvas.drawPath(monotonePath(points), line..color = lineColors[s % lineColors.length]);
    }

    final indices = trendTickIndices(n);
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
      old.lineColors != lineColors;
}
