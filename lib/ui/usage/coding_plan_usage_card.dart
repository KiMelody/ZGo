import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../protocol/usage_stats.dart';
import '../../state/entitlement_poller.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'usage_stat_grid.dart';
import 'usage_trend_chart.dart';

/// codingPlan usage card (web 个人套餐 tab, task 10-08-parity-usage D6).
/// Presentation only — the page owns the conditional display: the card
/// mounts on success and is silently absent on the two credential errors
/// (`no_bigmodel_api_key` / `*_coding_plan_api_key_required`) or any
/// other failure, mirroring the entitlement phase precedents
/// (spec protocol/entitlement-quota-semantics.md).
///
/// Sections follow the desktop form (research/design-inputs.md §4.3):
/// three quota cards (5h / weekly / monthly tools, remaining semantics
/// per the entitlement contract) + activity stats + usage trend.

/// One plan quota card's projected data — remaining percent via the
/// `clamp(100 - percentage)` contract, window rollover clock included.
class PlanQuotaCard {
  final String labelKey;
  final double? remainingPercent;
  final int? nextResetTime;

  /// [ZInk.usageChart] slot: 5h → chart-1, weekly → chart-2, tools →
  /// chart-5 (official column colors, fixed — not threshold-driven).
  final int colorIndex;

  const PlanQuotaCard({
    required this.labelKey,
    required this.colorIndex,
    this.remainingPercent,
    this.nextResetTime,
  });
}

/// Quota-card projection over the snapshot's raw `quota.limits` — exact
/// type+unit+number matching, the same discipline as
/// [quotaWindowKindOf] / the entitlement limit lookups.
List<PlanQuotaCard> buildPlanQuotaCards(Map<String, dynamic>? quota) {
  final limits = quota?['limits'];
  if (limits is! List) return const [];
  Map<String, dynamic>? find(String type, {int? unit, int? number}) {
    for (final e in limits) {
      if (e is! Map) continue;
      if (e['type'] != type) continue;
      if (unit != null && e['unit'] != unit) continue;
      if (number != null && e['number'] != number) continue;
      return Map<String, dynamic>.from(e);
    }
    return null;
  }

  PlanQuotaCard? project(
    Map<String, dynamic>? limit, {
    required String labelKey,
    required int colorIndex,
  }) {
    final used = (limit?['percentage'] as num?)?.toDouble();
    final reset = limit?['nextResetTime'];
    return PlanQuotaCard(
      labelKey: labelKey,
      colorIndex: colorIndex,
      remainingPercent: used == null ? null : (100 - used).clamp(0.0, 100.0),
      nextResetTime: reset is num ? reset.toInt() : null,
    );
  }

  return [
    project(
      find('TOKENS_LIMIT', unit: 3, number: 5),
      labelKey: 'usageRpc.primaryFiveHour',
      colorIndex: 0,
    ),
    project(
      find('TOKENS_LIMIT', unit: 6),
      labelKey: 'usageRpc.primaryWeekly',
      colorIndex: 1,
    ),
    project(
      find('TIME_LIMIT'),
      labelKey: 'usageRpc.primaryToolCalls',
      colorIndex: 4,
    ),
  ].whereType<PlanQuotaCard>().toList();
}

class CodingPlanUsageCard extends StatelessWidget {
  final CodingPlanUsageSnapshot snapshot;

  const CodingPlanUsageCard({super.key, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final quotaCards = buildPlanQuotaCards(snapshot.quota);
    final activity = snapshot.activity;
    final modelUsage = snapshot.modelUsage;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZSpacing.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'usage.plan.title'), style: ZType.bodyStrong),
            if (quotaCards.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final card in quotaCards)
                    Expanded(child: _quotaCell(context, card)),
                ],
              ),
            ],
            if (activity != null) ...[
              const SizedBox(height: 12),
              UsageStatGrid(items: _activityItems(context, activity)),
            ],
            if (modelUsage != null && modelUsage.series.isNotEmpty) ...[
              const SizedBox(height: 16),
              // The desktop trend shows ≤3 series at once (`u7`=3); the
              // toggles/clickable legend are cut from the ZGo v1 card.
              Text(tr(context, 'usage.plan.trend'),
                  style: ZType.bodyStrong),
              const SizedBox(height: 8),
              UsageLineChart(
                xLabels: _trendLabels(modelUsage),
                series: _trendSeries(modelUsage),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _quotaCell(BuildContext context, PlanQuotaCard card) {
    final remaining = card.remainingPercent;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr(context, card.labelKey),
            style: ZType.sub.copyWith(color: ZInk.muted(context)),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            remaining == null ? '--' : _fmtPct(remaining),
            style: ZType.title.copyWith(
              color: ZInk.usageChart(context, card.colorIndex),
            ),
          ),
          if (card.nextResetTime case final ms?) ...[
            const SizedBox(height: 2),
            Text(
              EntitlementView.fmtResetClock(
                DateTime.fromMillisecondsSinceEpoch(ms),
              ),
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
            ),
          ],
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(ZRadius.mini),
            child: LinearProgressIndicator(
              value: remaining == null ? 0 : (remaining / 100).clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: ZInk.barTrack(context),
              valueColor: AlwaysStoppedAnimation(
                ZInk.usageChart(context, card.colorIndex),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<(String, String)> _activityItems(
    BuildContext context,
    CodingPlanActivitySummary activity,
  ) {
    String? fav = activity.favoriteModelName;
    if (fav != null && fav.isEmpty) fav = null;
    return [
      (
        compactTokens(context, activity.totalTokens),
        tr(context, 'usage.stat.totalTokens'),
      ),
      (
        compactTokens(context, activity.peakDailyTokens),
        [
          tr(context, 'usage.stat.peakTokens'),
          if (activity.peakDailyTokensDate case final date?) ' · $date',
        ].join(),
      ),
      (
        usageDuration(context, activity.totalUsageDurationMs),
        tr(context, 'usage.plan.totalDuration'),
      ),
      (
        trP(context, 'usage.duration.days', ['${activity.currentStreakDays}']),
        tr(context, 'usage.stat.currentStreak'),
      ),
      (
        trP(context, 'usage.duration.days', ['${activity.longestStreakDays}']),
        tr(context, 'usage.stat.longestStreak'),
      ),
      (
        fav ?? '--',
        tr(context, 'usage.plan.favoriteModel'),
      ),
    ];
  }

  /// Trend series capped at 3 (official simultaneous-series bound),
  /// strongest first by series total.
  List<UsageLineSeries> _trendSeries(CodingPlanModelUsage modelUsage) {
    final sorted = [...modelUsage.series]..sort((a, b) => b.total.compareTo(a.total));
    return [
      for (final s in sorted.take(3))
        (
          modelId: s.modelName.isEmpty ? null : s.modelName,
          values: s.tokensUsage,
        ),
    ];
  }

  List<String> _trendLabels(CodingPlanModelUsage modelUsage) {
    if (modelUsage.xLabels.isNotEmpty) return modelUsage.xLabels;
    final len = modelUsage.series.fold(0, (a, s) => math.max(a, s.tokensUsage.length));
    return [for (var i = 0; i < len; i++) '${i + 1}'];
  }

  static String _fmtPct(double p) => p == p.roundToDouble()
      ? '${p.round()}%'
      : '${p.toStringAsFixed(1)}%';
}
