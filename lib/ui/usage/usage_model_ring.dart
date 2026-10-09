import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../protocol/usage_stats.dart';
import '../theme.dart';
import '../ui_settings.dart';

/// 「模型用量」donut (web `AppUsageModelUsagePieChart`, task
/// 10-08-parity-usage D5): ≤6 slices in server share order, the overflow
/// aggregated into 其他模型, compact total in the hole and a share list
/// beside it (two-column on wide surfaces like the official `md:` grid).

/// Slice cap — official `modelUsage` slice limit; when more models carry
/// usage the tail collapses into the「其他模型」aggregate slice.
const int kRingMaxSlices = 6;

/// One donut slice. [isOther] marks the overflow aggregate (rendered
/// with the 其他模型 label regardless of its null modelId).
class RingSlice {
  final String? modelId;
  final int totalTokens;
  final bool isOther;

  /// Client-recomputed share (`totalTokens / Σ`) — official recomputes
  /// rather than trusting the server `share`, which is computed over all
  /// models before the slice cap.
  final double share;

  const RingSlice({
    required this.modelId,
    required this.totalTokens,
    required this.share,
    this.isOther = false,
  });
}

/// Slice building (official rule): drop zero-token models, keep the
/// first 5, aggregate the tail into one slice, recompute shares. Server
/// order (share-descending) is preserved; the aggregate lands last.
List<RingSlice> buildRingSlices(List<AppModelUsage> models) {
  final used = models.where((m) => m.totalTokens > 0).toList();
  if (used.isEmpty) return const [];
  final kept = used.take(kRingMaxSlices - 1).toList();
  final restTotal =
      used.skip(kRingMaxSlices - 1).fold(0, (a, m) => a + m.totalTokens);
  final grand = used.fold(0, (a, m) => a + m.totalTokens);
  return [
    for (final m in kept)
      RingSlice(
        modelId: m.modelId,
        totalTokens: m.totalTokens,
        share: grand > 0 ? m.totalTokens / grand : 0,
      ),
    if (restTotal > 0)
      RingSlice(
        modelId: null,
        totalTokens: restTotal,
        share: grand > 0 ? restTotal / grand : 0,
        isOther: true,
      ),
  ];
}

class UsageModelRing extends StatelessWidget {
  final List<AppModelUsage> models;

  const UsageModelRing({super.key, required this.models});

  @override
  Widget build(BuildContext context) {
    final slices = buildRingSlices(models);
    if (slices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(tr(context, 'usageRpc.appUsageEmpty'),
            style: ZType.sub.copyWith(color: ZInk.faint(context))),
      );
    }
    final total = slices.fold(0, (a, s) => a + s.totalTokens);
    final list = _sliceList(context, slices);

    // Official `md:grid-cols-2`: ring left, share list right on wide
    // surfaces; stacked below the md breakpoint.
    return LayoutBuilder(builder: (context, constraints) {
      final ring = SizedBox(
        width: 168,
        height: 168,
        child: CustomPaint(
          painter: _RingSlicesPainter(
            slices: slices,
            colors: [
              for (var i = 0; i < slices.length; i++)
                ZInk.usageChart(context, i),
            ],
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  compactTokens(context, total),
                  style: ZType.title,
                ),
                Text(
                  'tokens',
                  style: ZType.caption.copyWith(color: ZInk.faint(context)),
                ),
              ],
            ),
          ),
        ),
      );
      if (constraints.maxWidth >= 560) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ring,
            const SizedBox(width: 16),
            Expanded(child: list),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Center(child: ring),
          const SizedBox(height: 12),
          list,
        ],
      );
    });
  }

  Widget _sliceList(BuildContext context, List<RingSlice> slices) {
    final top = slices.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Official description: {model} 当前占比最高，约 {share}。
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            trP(context, 'usage.modelChart.description', [
              top.isOther
                  ? tr(context, 'usage.modelChart.other')
                  : (top.modelId ?? tr(context, 'usage.unknownModel')),
              _fmtShare(top.share),
            ]),
            style: ZType.caption.copyWith(color: ZInk.faint(context)),
          ),
        ),
        for (var i = 0; i < slices.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: ZInk.usageChart(context, i),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        slices[i].isOther
                            ? tr(context, 'usage.modelChart.other')
                            : (slices[i].modelId ??
                                tr(context, 'usage.unknownModel')),
                        style: ZType.sub,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        compactTokens(context, slices[i].totalTokens),
                        style:
                            ZType.caption.copyWith(color: ZInk.faint(context)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(_fmtShare(slices[i].share), style: ZType.bodyStrong),
              ],
            ),
          ),
      ],
    );
  }

  /// Percent with at most one decimal, matching the page's `_fmtPct`.
  static String _fmtShare(double share) {
    final p = share * 100;
    return p == p.roundToDouble() ? '${p.round()}%' : '${p.toStringAsFixed(1)}%';
  }
}

/// Donut painter: inner 56% / outer 86% radius (official), 2° gaps
/// between slices when there is more than one — the gaps read the card
/// surface through, which is the official surface-colored seam.
class _RingSlicesPainter extends CustomPainter {
  final List<RingSlice> slices;
  final List<Color> colors;

  _RingSlicesPainter({
    required this.slices,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final outer = radius * 0.86;
    final inner = radius * 0.56;
    final rect = Rect.fromCircle(center: center, radius: (outer + inner) / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = outer - inner;
    const full = 2 * math.pi;
    // Official paddingAngle: 2° only when several slices are visible.
    final gap = slices.length > 1 ? 2 * math.pi / 180 : 0.0;
    var start = -math.pi / 2;
    for (var i = 0; i < slices.length; i++) {
      final sweep = slices[i].share * full;
      final drawn = math.max(sweep - gap, 0.0);
      canvas.drawArc(rect, start + gap / 2, drawn, false, paint..color = colors[i]);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_RingSlicesPainter old) =>
      old.slices != slices || old.colors != colors;
}
