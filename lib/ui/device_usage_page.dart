import 'package:flutter/material.dart';

import '../state/device_session.dart';
import '../state/entitlement_poller.dart';
import '../state/quota_reset.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// IANA `Etc/GMT` zone name for the device's UTC offset, for the
/// `getAppUsageSnapshot {timeZone}` argument: the desktop resolves it via
/// `Intl.DateTimeFormat` into `tzOffsetMs`, which drives the day-boundary
/// grouping — bare abbreviations like the Windows `"CST"` are ambiguous
/// (ICU reads them as US Central, UTC-6, skewing the day index by 14h).
///
/// POSIX `Etc/GMT` zones carry an inverted sign: UTC+8 → `Etc/GMT-8`,
/// UTC-6 → `Etc/GMT+6`. Whole-hour offsets map to the matching zone;
/// fractional ones (e.g. +05:30) have no `Etc/GMT` zone and fall back to
/// `UTC` — a UTC day boundary beats a 14h-skewed one.
String ianaEtcTimeZone(Duration offset) {
  if (offset.inMinutes % 60 != 0) return 'UTC';
  if (offset.inHours == 0) return 'UTC';
  final hours = offset.inHours.abs();
  return 'Etc/GMT${offset.inHours > 0 ? '-' : '+'}$hours';
}

/// Entitlement / quota usage of one device
/// (usage-stats.getEntitlementSnapshot over the workspace bridge).
class DeviceUsagePage extends StatefulWidget {
  final DeviceSession session;
  const DeviceUsagePage({super.key, required this.session});

  @override
  State<DeviceUsagePage> createState() => _DeviceUsagePageState();
}

class _DeviceUsagePageState extends State<DeviceUsagePage> {
  /// Last entitlement view from the session-wide poller (null = first
  /// fetch still in flight).
  EntitlementView? _view;

  /// App-usage snapshot (`getAppUsageSnapshot {range, timeZone}`) — the
  /// local-session-based estimation tab of the web settings usage page.
  String _appRange = '7d';
  Map<String, dynamic>? _appUsage;
  bool _appLoading = false;

  /// Last app-usage load failure (`null` = ok). Kept separate from
  /// [_appUsage] so a failed range switch keeps the previous chart visible
  /// instead of rendering it as「暂无用量」(misleading: failure ≠ no data).
  String? _appError;

  // Official zod enum is `all|7d|30d` — anything else is rejected.
  static const _appRanges = ['7d', '30d', 'all'];

  @override
  void initState() {
    super.initState();
    _load();
    _loadAppUsage();
  }

  Future<void> _loadAppUsage() async {
    if (!mounted) return;
    setState(() {
      _appLoading = true;
      _appError = null;
    });
    try {
      final res = await widget.session.callChannel(
        'usage-stats',
        'getAppUsageSnapshot',
        [
          {
            'range': _appRange,
            // IANA form: `timeZoneName` yields bare abbreviations ("CST")
            // that desktop ICU misreads as US Central (UTC-6).
            'timeZone': ianaEtcTimeZone(DateTime.now().timeZoneOffset),
          },
        ],
      );
      if (mounted) {
        setState(() {
          _appUsage = res is Map ? res.cast<String, dynamic>() : {};
          _appLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[usage] app snapshot failed: $e');
      if (mounted) {
        setState(() {
          _appError = e.toString();
          _appLoading = false;
        });
      }
    }
  }

  /// Entitlement via the session-wide poller: opening reuses the cache
  /// within the staleness window, refresh (button / pull) forces a fetch.
  /// The call never throws — failures land in the view as phase=error.
  /// The reset-opportunity scope rides the session's [DeviceSession.
  /// entitlementSnapshot] (injected there); the plain refresh below picks
  /// the pools up.
  Future<void> _load({bool force = false}) async {
    final view = await widget.session.entitlementSnapshot(force: force);
    if (!mounted) return;
    setState(() => _view = view);
    await _reset.refresh(force: force);
  }

  QuotaResetController get _reset => widget.session.quotaResetController;

  String _fmtTime(Object? millis) {
    if (millis is! num) return '-';
    final t = DateTime.fromMillisecondsSinceEpoch(millis.toInt()).toLocal();
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'usageRpc.title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(force: true),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _load(force: true);
          await _loadAppUsage();
        },
        child: _buildEntitlementBody(),
      ),
    );
  }

  Widget _buildEntitlementBody() {
    final view = _view;
    if (view == null || view.phase == EntitlementPhase.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    switch (view.phase) {
      case EntitlementPhase.notConfigured:
      case EntitlementPhase.noPlan:
      case EntitlementPhase.loginRequired:
      case EntitlementPhase.error:
        return _statusView(view);
      case EntitlementPhase.ok:
        return _buildBody(view.data ?? const {});
      case EntitlementPhase.loading:
        return const Center(child: CircularProgressIndicator());
    }
  }

  /// Status copy + retry for the four non-data phases (design.md table) —
  /// never a blank page or a misleading card.
  Widget _statusView(EntitlementView view) {
    final String message;
    switch (view.phase) {
      case EntitlementPhase.notConfigured:
        message = tr(context, 'usageRpc.notConfigured');
      case EntitlementPhase.noPlan:
        message = tr(context, 'usageRpc.noPlan');
      case EntitlementPhase.loginRequired:
        message = tr(context, 'usageRpc.loginRequired');
      default:
        message = trP(context, 'usageRpc.loadFailed', [view.error ?? '-']);
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: ZType.body.copyWith(color: ZInk.muted(context)),
            ),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            icon: const Icon(Icons.refresh, size: 16),
            onPressed: () => _load(force: true),
            label: Text(tr(context, 'tasks.retry')),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(Map<String, dynamic> data) {
    final context_ = data['context'];
    final provider = data['provider'];
    final remaining = data['remaining'];
    final subscription = data['subscription'];
    final quota = data['quota'];
    final mcpQuota = data['mcpQuota'];
    final mcpAggregate = mcpQuota is Map && mcpQuota['aggregate'] is Map
        ? Map<String, dynamic>.from(mcpQuota['aggregate'] as Map)
        : null;

    return RefreshIndicator(
      onRefresh: () async {
        await _load();
        await _loadAppUsage();
      },
      child: ListView(
        padding: const EdgeInsets.all(ZSpacing.screen),
        children: [
          _appUsageCard(context),
          const SizedBox(height: ZSpacing.cardGap),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: ZColors.sky500.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(ZRadius.tile),
                    ),
                    child: const Icon(Icons.bolt, color: ZColors.sky500),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context_ is Map
                              ? '${context_['displayName'] ?? '-'}'
                              : '-',
                          style: ZType.heading,
                        ),
                        Text(
                          [
                            if (provider is Map) '${provider['name'] ?? ''}',
                            if (quota is Map && quota['level'] != null)
                              '${quota['level']}',
                          ].join(' · '),
                          style: ZType.sub.copyWith(color: ZInk.faint(context)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: ZSpacing.cardGap),
          if (remaining is Map && remaining['isShow'] == true)
            _remainingCard(remaining.cast<String, dynamic>()),
          if ((quota is Map && quota['limits'] is List) ||
              mcpAggregate != null) ...[
            const SizedBox(height: ZSpacing.cardGap),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, 'usageRpc.limits'),
                        style: ZType.bodyStrong),
                    const SizedBox(height: 8),
                    if (quota is Map && quota['limits'] is List)
                      for (final limit in quota['limits'] as List)
                        if (limit is Map)
                          _LimitRow(
                              limit: limit.cast<String, dynamic>()),
                    if (mcpAggregate != null)
                      _LimitRow(
                        limit: mcpAggregate,
                        label: tr(context, 'usageRpc.serverMcp'),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (subscription is Map &&
              subscription['details'] is List &&
              (subscription['details'] as List).isNotEmpty) ...[
            const SizedBox(height: ZSpacing.cardGap),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, 'usageRpc.subscription'),
                        style: ZType.bodyStrong),
                    const SizedBox(height: 8),
                    for (final d in subscription['details'] as List)
                      if (d is Map) ...[
                        _kv(tr(context, 'usageRpc.product'),
                            '${d['productName'] ?? '-'}'),
                        _kv(tr(context, 'usageRpc.billing'),
                            '${d['billingCycle'] ?? '-'}'),
                        _kv(tr(context, 'usageRpc.renew'),
                            '${d['renewTime'] ?? '-'}'),
                        _kv(tr(context, 'usageRpc.expire'),
                            '${d['expireTime'] ?? '-'}'),
                      ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: ZSpacing.cardGap),
          _resetCard(),
        ],
      ),
    );
  }

  /// R1 A2 projection (09-19): the summary card mirrors the most-tense
  /// limit row ([EntitlementView.primaryLimit]) in the official
  /// remainingShort semantics — big number = what's LEFT, label = the
  /// limit type, reset clock = that row's window rollover. The top-level
  /// `remaining` block is only the mirror fallback ([_remainingMirrorCard]):
  /// its count/bar are the TIME_LIMIT aggregate and mislead as「0 + 100%」
  /// on plans without a monthly tool quota.
  Widget _remainingCard(Map<String, dynamic> remaining) {
    final primary = _view?.primaryLimit;
    if (primary == null) return _remainingMirrorCard(remaining);

    final used = primary.percentage!;
    final left = (100 - used).clamp(0.0, 100.0);
    final count = primary.raw['remaining'];
    // count（次数）is the main number only for the tool-calls class
    // (TIME_LIMIT — the monthly built-in tool quota counts calls).
    final countMain = primary.raw['type'] == 'TIME_LIMIT' && count is num;
    final clock = switch (primary.nextResetTime) {
      null => null,
      final ms => EntitlementView.fmtResetClock(
          DateTime.fromMillisecondsSinceEpoch(ms),
        ),
    };
    final caption = [
      if (!countMain) trP(context, 'usageRpc.primaryLeft', [_fmtPct(left)]),
      if (clock != null) clock,
    ].join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, 'usageRpc.remaining'), style: ZType.body),
                    Text(
                      _primaryTypeLabel(primary),
                      style:
                          ZType.caption.copyWith(color: ZInk.muted(context)),
                    ),
                  ],
                ),
                Text(
                  countMain
                      ? trP(context, 'usageRpc.primaryCount', ['$count'])
                      : _fmtPct(left),
                  style: ZType.display.copyWith(color: ZColors.sky500),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(ZRadius.mini),
              child: LinearProgressIndicator(
                value: (used / 100).clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: ZInk.barTrack(context),
                valueColor: const AlwaysStoppedAnimation(ZColors.sky500),
              ),
            ),
            if (caption.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(caption,
                  style: ZType.caption.copyWith(color: ZInk.faint(context))),
            ],
          ],
        ),
      ),
    );
  }

  /// Pre-R1 mirror rendering (limits empty / no rankable row): the
  /// top-level `remaining` count + bar, reset time still anchored on the
  /// earliest usable reset opportunity.
  Widget _remainingMirrorCard(Map<String, dynamic> remaining) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(tr(context, 'usageRpc.remaining'), style: ZType.body),
                Text(
                  '${remaining['count'] ?? '-'}',
                  style: ZType.display.copyWith(
                    color: ZColors.sky500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(ZRadius.mini),
              child: LinearProgressIndicator(
                value: ((remaining['percentage'] as num?) ?? 0) / 100,
                minHeight: 6,
                backgroundColor: ZInk.barTrack(context),
                valueColor: const AlwaysStoppedAnimation(ZColors.sky500),
              ),
            ),
            const SizedBox(height: 6),
            Builder(builder: (context) {
              // Projection: the earliest expiry among the pools
              // the plan can actually use — a hidden card never
              // drives the summary's「重置」time.
              final expiry =
                  _view?.earliestResetExpiry(_reset.pools)?.millisecondsSinceEpoch;
              return Text(
                expiry == null
                    ? trP(context, 'usageRpc.remainingNoReset', [
                        '${remaining['percentage'] ?? '-'}',
                      ])
                    : trP(context, 'usageRpc.remainingDetail', [
                        '${remaining['percentage'] ?? '-'}',
                        relativeTime(context, expiry),
                      ]),
                style: ZType.caption.copyWith(color: ZInk.faint(context)),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// Primary-limit type label — official sidebar key semantics
  /// (weekly / fiveHour / toolCalls / tokensLimit / otherLimit).
  String _primaryTypeLabel(Limit limit) {
    switch (limit.raw['type']) {
      case 'TOKENS_LIMIT':
        if (limit.raw['unit'] == 6) {
          return tr(context, 'usageRpc.primaryWeekly');
        }
        if (limit.raw['unit'] == 3 && limit.raw['number'] == 5) {
          return tr(context, 'usageRpc.primaryFiveHour');
        }
        return tr(context, 'usageRpc.primaryTokens');
      case 'CREDIT_LIMIT':
        return tr(context, 'usageRpc.primaryTokens');
      case 'TIME_LIMIT':
        return tr(context, 'usageRpc.primaryToolCalls');
    }
    return tr(context, 'usageRpc.primaryOther');
  }

  /// Percent with at most one decimal.
  static String _fmtPct(double p) => p == p.roundToDouble()
      ? '${p.round()}%'
      : '${p.toStringAsFixed(1)}%';

  /// Reset opportunities, read-only (PRD: the sheet is the single reset
  /// entry): one row per pool the projection credits ([EntitlementView.
  /// resettablePools] — the official visibility composition over the same
  /// entitlement snapshot the cards above read) — with the count, the
  /// earliest expiry and a 「上次使用重置」 line when the pool has a usage
  /// history. The degraded copy replaces the rows while no usable desktop
  /// data exists, and the 「暂无可用机会」 line replaces them when no pool
  /// is resettable.
  Widget _resetCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListenableBuilder(
          listenable: _reset,
          builder: (context, _) {
            final pools = _reset.pools;
            final resettable = _view?.resettablePools(pools) ?? const [];
            final fiveHour =
                resettable.any((r) => r.type == quotaResetTypeFiveHour);
            final week = resettable.any((r) => r.type == quotaResetTypeWeek);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr(context, 'usage.reset.title'),
                    style: ZType.bodyStrong),
                const SizedBox(height: 8),
                if (pools == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(tr(context, 'usage.reset.unavailable'),
                        style: ZType.sub.copyWith(color: ZInk.faint(context))),
                  )
                else if (!fiveHour && !week)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(tr(context, 'usage.reset.none'),
                        style: ZType.sub.copyWith(color: ZInk.faint(context))),
                  )
                else ...[
                  if (fiveHour)
                    _poolRow(
                      name: tr(context, 'usage.reset.fiveHour'),
                      pool: pools.fiveHour,
                    ),
                  if (week)
                    _poolRow(
                      name: tr(context, 'usage.reset.week'),
                      pool: pools.week,
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _poolRow({
    required String name,
    required QuotaResetPool pool,
  }) {
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 88,
                child: Text(name, style: ZType.sub),
              ),
              Expanded(
                child: Text(detail,
                    style:
                        ZType.caption.copyWith(color: ZInk.muted(context))),
              ),
            ],
          ),
          if (pool.lastUsedAt != null)
            Padding(
              padding: const EdgeInsets.only(left: 88, top: 2),
              child: Text(
                trP(context, 'usage.reset.lastUsed',
                    [_fmtTime(pool.lastUsedAt)]),
                style: ZType.caption.copyWith(color: ZInk.faint(context)),
              ),
            ),
        ],
      ),
    );
  }

  /// 应用用量: dailyModelUsage stacked bars (per-day totals with model
  /// breakdown), web `settings.usage.tab.appUsage` parity.
  Widget _appUsageCard(BuildContext context) {
    final daily = _appUsage?['dailyModelUsage'];
    final days = daily is List ? daily.whereType<Map>().toList() : <Map>[];
    double maxTotal = 0;
    final rows = <(String, double, Map<String, double>)>[];
    for (final d in days) {
      final models = <String, double>{};
      final list = d['models'];
      var total = 0.0;
      if (list is List) {
        for (final m in list.whereType<Map>()) {
          final tokens = ((m['totalTokens'] as num?) ?? 0).toDouble();
          final id = '${m['modelId'] ?? '?'}';
          models[id] = (models[id] ?? 0) + tokens;
          total += tokens;
        }
      }
      if (total > maxTotal) maxTotal = total;
      rows.add(('${d['date'] ?? ''}', total, models));
    }
    final modelIds = <String>{for (final r in rows) for (final k in r.$3.keys) k}.toList()..sort();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(tr(context, 'usageRpc.appUsage'),
                      style: ZType.bodyStrong),
                ),
                for (final r in _appRanges)
                  InkWell(
                    borderRadius: BorderRadius.circular(ZRadius.mini),
                    onTap: () {
                      if (_appRange == r || _appLoading) return;
                      setState(() => _appRange = r);
                      _loadAppUsage();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      child: Text(
                        r == 'all' ? tr(context, 'usageRpc.rangeAll') : r,
                        style: ZType.caption.copyWith(
                          color: _appRange == r
                              ? ZColors.sky500
                              : ZInk.muted(context),
                          fontWeight: _appRange == r
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(tr(context, 'usageRpc.appUsageHint'),
                style: ZType.caption.copyWith(color: ZInk.faint(context))),
            const SizedBox(height: 10),
            if (_appLoading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (rows.isEmpty && _appError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, 'usageRpc.appUsageFailed'),
                        style: ZType.sub.copyWith(color: ZColors.danger)),
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 16),
                      onPressed: _loadAppUsage,
                      label: Text(tr(context, 'tasks.retry')),
                    ),
                  ],
                ),
              )
            else if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(tr(context, 'usageRpc.appUsageEmpty'),
                    style: ZType.sub.copyWith(color: ZInk.faint(context))),
              )
            else ...[
              for (final (date, total, models) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(date,
                              style: ZType.caption.copyWith(
                                  color: ZInk.muted(context),
                              )),
                          Text(_fmtTokens(total),
                              style: ZType.caption),
                        ],
                      ),
                      const SizedBox(height: 2),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(ZRadius.mini),
                        child: SizedBox(
                          height: 5,
                          child: Row(
                            children: [
                              for (final id in modelIds)
                                if ((models[id] ?? 0) > 0 && maxTotal > 0)
                                  Expanded(
                                    flex:
                                        ((models[id]! / maxTotal) * 100)
                                            .round()
                                            .clamp(1, 100),
                                    child: Container(
                                        color:
                                            _modelColor(id, modelIds)),
                                  ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  for (final id in modelIds)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: _modelColor(id, modelIds),
                              shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 4),
                        Text(id,
                            style: ZType.caption.copyWith(
                                color: ZInk.muted(context),
                            )),
                      ],
                    ),
                ],
              ),
              // Stale-chart failure banner: the range switch above failed
              // but the previous chart stays (PRD: failure ≠ no data).
              if (_appError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(tr(context, 'usageRpc.appUsageFailed'),
                            style: ZType.caption
                                .copyWith(color: ZColors.danger)),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.refresh, size: 16),
                        onPressed: _loadAppUsage,
                        label: Text(tr(context, 'tasks.retry')),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  static Color _modelColor(String id, List<String> ids) {
    const palette = [
      ZColors.sky500,
      ZColors.success,
      ZColors.warning,
      ZColors.danger,
      ZColors.neutral500,
    ];
    final i = ids.indexOf(id);
    return palette[i % palette.length];
  }

  static String _fmtTokens(double n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.round().toString();
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: ZType.sub.copyWith(color: ZInk.muted(context))),
          Flexible(
            child: Text(value,
                style: ZType.sub,
                textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}

class _LimitRow extends StatelessWidget {
  final Map<String, dynamic> limit;

  /// Row title override (the server MCP aggregate carries no type of its
  /// own). Absent, the label is derived from the limit type.
  final String? label;

  const _LimitRow({required this.limit, this.label});

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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: ZType.sub),
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
              Text(
                [
                  if (limit['usage'] != null)
                    trP(context, 'usageRpc.used', ['${limit['usage']}']),
                  if (limit['remaining'] != null)
                    trP(context, 'usageRpc.left', ['${limit['remaining']}']),
                  if (percentage != null) '$percentage%',
                ].join(' · '),
                style: ZType.caption.copyWith(color: ZInk.muted(context)),
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
