import 'package:flutter/material.dart';

import '../state/quota_reset.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// Reset dialog aligned with the official flow (research 状态机): the pools
/// the caller's `poolVisible` predicate approved over the entitlement limits
/// as rows (name + available count + expiry countdown), cancel/reset
/// actions, and processing/failed states rendered live from the controller's
/// notify cycle. [controller.use] runs unchanged inside; resolves with the
/// consumed reset type on success, null otherwise
/// (cancel or failure — a failure stays visible inline for a retry).
Future<String?> showQuotaResetDialog(
  BuildContext context, {
  required QuotaResetController controller,
  required Set<String> resettable,
}) => showDialog<String>(
  context: context,
  useRootNavigator: false,
  builder: (context) =>
      _QuotaResetDialog(controller: controller, resettable: resettable),
);

class _QuotaResetDialog extends StatelessWidget {
  final QuotaResetController controller;

  /// Pool types that may be offered here — the caller applies the same
  /// predicate as the entry that opened this dialog, so a plan without the
  /// weekly window must not offer its (account-held) weekly coupon either.
  final Set<String> resettable;

  const _QuotaResetDialog({required this.controller, required this.resettable});

  bool get _processing {
    final pools = controller.pools;
    return pools?.fiveHour.processing == true ||
        pools?.week.processing == true;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final pools = controller.pools;
        final rows = <(String, String, QuotaResetPool)>[
          if (pools != null && resettable.contains(quotaResetTypeFiveHour))
            (quotaResetTypeFiveHour, 'usage.reset.fiveHour', pools.fiveHour),
          if (pools != null && resettable.contains(quotaResetTypeWeek))
            (quotaResetTypeWeek, 'usage.reset.week', pools.week),
        ];
        return AlertDialog(
          title: Text(tr(context, 'usage.reset.title')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (pools == null)
                Text(
                  tr(context, 'usage.reset.unavailable'),
                  style: ZType.sub.copyWith(color: ZInk.muted(context)),
                )
              else if (rows.isEmpty)
                // Defensive: the entry is gated on the same predicate, so a
                // dialog without a single resettable pool is unreachable.
                Text(
                  tr(context, 'usage.reset.none'),
                  style: ZType.sub.copyWith(color: ZInk.muted(context)),
                )
              else
                for (final (_, nameKey, pool) in rows)
                  _poolRow(context, nameKey, pool),
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    trP(context, 'usage.reset.failed',
                        [controller.error ?? '-']),
                    style: ZType.caption.copyWith(color: ZColors.danger),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, 'common.cancel')),
            ),
            for (final (type, _, pool) in rows)
              if (pool.count > 0)
                _resetAction(context, type, disabled: _processing),
          ],
        );
      },
    );
  }

  Widget _poolRow(
    BuildContext context,
    String nameKey,
    QuotaResetPool pool,
  ) {
    final detail = pool.count > 0
        ? [
            trP(context, 'usage.reset.count', ['${pool.count}']),
            if (pool.earliestExpireAt != null)
              trP(context, 'usage.reset.expiresIn',
                  [relativeTime(context, pool.earliestExpireAt!)]),
          ].join(' · ')
        : tr(context, 'usage.reset.none');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(tr(context, nameKey),
                style: ZType.sub),
          ),
          Text(
            detail,
            style: ZType.caption.copyWith(color: ZInk.muted(context)),
          ),
          if (pool.processing) ...[
            const SizedBox(width: 8),
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
    );
  }

  /// One reset action per pool with opportunities; disabled while any
  /// pool is in flight (the optimistic flow is single-shot).
  Widget _resetAction(
    BuildContext context,
    String resetType, {
    required bool disabled,
  }) => TextButton(
    onPressed: disabled ? null : () => _use(context, resetType),
    child: Text(tr(context, 'usage.reset.action')),
  );

  Future<void> _use(BuildContext context, String resetType) async {
    final ok = await controller.use(resetType);
    if (!context.mounted) return;
    if (ok) Navigator.pop(context, resetType);
    // A failure keeps the dialog open; the controller error renders inline.
  }
}
