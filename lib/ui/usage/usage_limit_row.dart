import 'package:flutter/material.dart';

import '../../state/entitlement_poller.dart';
import '../theme.dart';
import '../ui_settings.dart';

/// One 「配额限制」row (web `settings.usage` quota limits; extracted from
/// device_usage_page in 10-16-narrow-screen-overflow so the narrow-width
/// smoke test can cover the surface directly).
///
/// Two-level flex with an explicit sacrifice order — title tail > clock >
/// right value (task 10-16 R1): the spaceBetween ends each sit in a loose
/// [Flexible] and shrink to their own content, the title ellipsizes first
/// (its tail goes before anything else), the reset clock caption stays
/// whole, and the used/remaining/percent caption only ellipsizes as the
/// last resort for saturating value strings (「用量 1,234,567 · 剩余
/// 9,999,999 · 100.0%」). No wrap — the ends are tabular, a folded form
/// reads wrong.
///
/// The two flex-1 ends cap at half the row width each, so a left segment
/// over that half trims the title even while the right side has slack to
/// spare — the sanctioned first sacrifice (2026-10-16 implementation note).
class UsageLimitRow extends StatelessWidget {
  final Map<String, dynamic> limit;

  /// Row title override (the server MCP aggregate carries no type of its
  /// own). Absent, the label is derived from the limit type.
  final String? label;

  const UsageLimitRow({super.key, required this.limit, this.label});

  /// Human label for a limit type (research/entitlement-limits-probe.md):
  /// `TIME_LIMIT` is the monthly built-in MCP tool quota, the token-class
  /// types are the chat windows. Unknown types keep the raw enum string.
  static String? _semanticLabel(BuildContext context, Map<String, dynamic> l) {
    switch (l['type']) {
      case 'TIME_LIMIT':
        return tr(context, 'usageRpc.limitMonthlyTools');
      case 'TOKENS_LIMIT':
        if (l['unit'] == 6) return tr(context, 'usageRpc.limitTokenWeek');
        if (l['unit'] == 3 && l['number'] == 5) {
          return tr(context, 'usageRpc.limitToken5h');
        }
        return tr(context, 'usageRpc.limitToken');
      case 'CREDIT_LIMIT':
        return tr(context, 'usageRpc.limitToken');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final type = '${limit['type'] ?? ''}';
    final title = label ??
        _semanticLabel(context, limit) ??
        '$type · unit ${limit['unit'] ?? '-'}';
    final percentage = (limit['percentage'] as num?)?.toDouble();
    final usageDetails = limit['usageDetails'];
    // Window-rollover clock via the projection's single formatting copy
    // (「重置」stays reserved for reset opportunities, 2026-09-16).
    final nextReset = limit['nextResetTime'];
    final clock = nextReset is num
        ? EntitlementView.fmtResetClock(
            DateTime.fromMillisecondsSinceEpoch(nextReset.toInt()))
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: ZType.sub,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (clock case final rollover?)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          rollover,
                          style: ZType.caption
                              .copyWith(color: ZInk.faint(context)),
                        ),
                      ),
                  ],
                ),
              ),
              Flexible(
                child: Text(
                  [
                    if (limit['usage'] != null)
                      trP(context, 'usageRpc.used', ['${limit['usage']}']),
                    if (limit['remaining'] != null)
                      trP(context, 'usageRpc.left', ['${limit['remaining']}']),
                    if (percentage != null) '$percentage%',
                  ].join(' · '),
                  style: ZType.caption.copyWith(color: ZInk.muted(context)),
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (percentage != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(ZRadius.mini),
                child: LinearProgressIndicator(
                  value: (percentage / 100).clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(
                    percentage > 80 ? ZInk.dangerTone(context) : ZColors.sky500,
                  ),
                ),
              ),
            ),
          if (usageDetails is List && usageDetails.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                usageDetails
                    .whereType<Map>()
                    .map((u) => '${u['modelCode']}: ${u['usage']}')
                    .join('  '),
                style:
                    ZType.caption.copyWith(color: ZInk.faint(context)),
              ),
            ),
        ],
      ),
    );
  }
}
