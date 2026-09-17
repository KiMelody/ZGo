import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import 'quota_reset.dart';

/// Phase of one entitlement snapshot — mirrors the web entitlement panel's
/// status enum (Active/Error/Loading/LoginRequired/NoPlan/NotConfigured);
/// the desktop's `unavailableReason` maps onto these.
enum EntitlementPhase {
  loading,
  ok,
  notConfigured,
  noPlan,
  loginRequired,
  error,
}

/// One `quota.limits` row as a value carrier — the projection's currency
/// between the snapshot and the rendering surfaces. Pure carrier: only
/// typed reads of the raw row, no decisions.
class Limit {
  /// The raw `quota.limits` entry (live-probed field structure only).
  final Map<String, dynamic> raw;

  const Limit(this.raw);

  /// Used percent of the window; null when absent / mistyped (official PF
  /// answers null → the surface hides the metric instead of guessing).
  double? get percentage {
    final p = raw['percentage'];
    return p is num ? p.toDouble() : null;
  }

  /// Window rollover time (ms epoch); null when absent / mistyped.
  int? get nextResetTime {
    final t = raw['nextResetTime'];
    return t is num ? t.toInt() : null;
  }
}

/// One pool the projection credited as resettable: the reset type (the
/// `useCodingPlanReset` argument) with its live pool numbers.
typedef ResettablePool = ({String type, QuotaResetPool pool});

/// Immutable result of one entitlement fetch, shared by the usage page and
/// the chat warning banner.
class EntitlementView {
  final EntitlementPhase phase;

  /// Raw snapshot (generatedAt / authenticated / unavailableReason /
  /// provider / remaining / subscription / quota). Rendering stays limited
  /// to the live-probed field structure — no invented fields.
  final Map<String, dynamic>? data;
  final DateTime? fetchedAt;
  final String? error;

  const EntitlementView({
    required this.phase,
    this.data,
    this.fetchedAt,
    this.error,
  });

  /// Token/credit limit types whose exhaustion drives the chat warning
  /// banner — the official bundle's token-class group. `TIME_LIMIT` is the
  /// monthly built-in MCP tool quota (search-prime / web-reader / zread)
  /// and is deliberately excluded: it does not limit LLM chat, so topping
  /// it out must not raise the "switch model" banner
  /// (research/entitlement-limits-probe.md).
  static const _tokenLimitTypes = {'TOKENS_LIMIT', 'CREDIT_LIMIT'};

  /// Whether the snapshot reports a token/credit limit topped out.
  ///
  /// The top-level `remaining` block is the `TIME_LIMIT` aggregate mirror
  /// and never participates: a zero count there means the monthly MCP
  /// calls ran out, not the chat plan.
  bool get exhausted {
    final quota = data?['quota'];
    if (quota is! Map || quota['limits'] is! List) return false;
    for (final limit in quota['limits'] as List) {
      if (limit is! Map) continue;
      if (!_tokenLimitTypes.contains(limit['type'])) continue;
      final percentage = limit['percentage'];
      if (percentage is num && percentage >= 100) return true;
    }
    return false;
  }

  // ----------------------------------------------------------- projection
  //
  // The official entitlement / reset semantics are encoded exactly once,
  // here: limits mining, the PF remaining clamp, the reset scope, the
  // resettable composition and the expiry clock. The UI surfaces only read
  // these — no raw-map assembly in lib/ui (C1 收口).

  /// The snapshot's `quota.limits`; null when absent or mistyped.
  List? get _limits {
    final quota = data?['quota'];
    return quota is Map && quota['limits'] is List
        ? quota['limits'] as List
        : null;
  }

  /// Exact `type`(+`unit`/`number`) lookup over `quota.limits` (the
  /// official `MF`); null when the row is absent.
  Limit? limitFor(String type, {int? unit, int? number}) {
    final limits = _limits;
    if (limits == null) return null;
    for (final e in limits) {
      if (e is! Map) continue;
      if (e['type'] != type) continue;
      if (unit != null && e['unit'] != unit) continue;
      if (number != null && e['number'] != number) continue;
      return Limit(e.cast<String, dynamic>());
    }
    return null;
  }

  /// `mcpQuota.aggregate` as a limit-shaped carrier so the usage surfaces
  /// read the server-side MCP total through [remainingPercent] too (the
  /// aggregate is not a `quota.limits` row of its own).
  Limit? get serverMcpLimit {
    final mcpQuota = data?['mcpQuota'];
    final aggregate = mcpQuota is Map ? mcpQuota['aggregate'] : null;
    return aggregate is Map ? Limit(aggregate.cast<String, dynamic>()) : null;
  }

  /// Official PF: remaining% = clamp(100 - percentage) — every quota
  /// metric shows what is LEFT of the limit, never what is used. A null
  /// limit or an unreadable percentage answers null.
  double? remainingPercent(Limit? limit) {
    final used = limit?.percentage;
    if (used == null) return null;
    return (100 - used).clamp(0.0, 100.0);
  }

  /// A2 primary-limit projection (usage page summary card, 09-19): the
  /// most-tense `quota.limits` row — highest used percent — drives the
  /// card; ties break to the nearest window rollover (a row without one
  /// loses). Rows without a usable percentage cannot rank. Null when no
  /// row ranks: the card then falls back to the top-level `remaining`
  /// mirror (the TIME_LIMIT aggregate whose count/bar mislead as
  /// 「0 / 100%」 on plans without a monthly tool quota).
  Limit? get primaryLimit {
    Limit? best;
    for (final e in _limits ?? const []) {
      if (e is! Map) continue;
      final candidate = Limit(e.cast<String, dynamic>());
      final used = candidate.percentage;
      if (used == null) continue;
      final bestUsed = best?.percentage;
      if (best == null || bestUsed == null || used > bestUsed) {
        best = candidate;
        continue;
      }
      if (used < bestUsed) continue;
      final reset = candidate.nextResetTime;
      final bestReset = best.nextResetTime;
      if (reset != null && (bestReset == null || reset < bestReset)) {
        best = candidate;
      }
    }
    return best;
  }

  /// `provider.id` of the snapshot — the reset controller's scope
  /// (`preferredProviderId`); null (feature disabled) without a usable id.
  String? get resetScopeProviderId {
    final provider = data?['provider'];
    final id = provider is Map ? provider['id'] : null;
    return id is String && id.isNotEmpty ? id : null;
  }

  /// Pools the plan can actually reset — the official `_I` composition
  /// ([poolVisible] over `quota.limits` × the live pools): the plan must
  /// expose the pool's window row, an unexpired opportunity must exist and
  /// the window must not be untouched (processing pools stay visible).
  /// A pool without a plan window (a V1 plan's weekly coupon) is never
  /// credited; null / unreadable pools credit nothing.
  List<ResettablePool> resettablePools(QuotaResetPools? pools) {
    if (pools == null) return const [];
    final limits = _limits;
    return [
      if (poolVisible(
        limits: limits,
        poolType: quotaResetTypeFiveHour,
        count: pools.fiveHour.count,
        processing: pools.fiveHour.processing,
      ))
        (type: quotaResetTypeFiveHour, pool: pools.fiveHour),
      if (poolVisible(
        limits: limits,
        poolType: quotaResetTypeWeek,
        count: pools.week.count,
        processing: pools.week.processing,
      ))
        (type: quotaResetTypeWeek, pool: pools.week),
    ];
  }

  /// Earliest expiry among the resettable pools ([resettablePools]) — the
  /// summary's reset time is opportunity expiry, and a pool the rendering
  /// hides must not drive it. Null when nothing is usable.
  DateTime? earliestResetExpiry(QuotaResetPools? pools) {
    final times = [
      for (final r in resettablePools(pools))
        if (r.pool.earliestExpireAt case final ms?) ms,
    ]..sort();
    if (times.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(times.first);
  }

  /// Clock for a window / reset-chance expiry — `HH:mm` within 24h, else
  /// `MM-dd HH:mm` (2026-09-16 semantics:「重置」stays reserved for reset
  /// opportunities). Single copy: the two former verbatim `_fmtClock`
  /// duplicates in the usage page and the chat sheet read this.
  static String fmtResetClock(DateTime expiry) {
    final hh = expiry.hour.toString().padLeft(2, '0');
    final mm = expiry.minute.toString().padLeft(2, '0');
    if (expiry
        .isAfter(DateTime.now().subtract(const Duration(hours: 24)))) {
      return '$hh:$mm';
    }
    return '${expiry.month.toString().padLeft(2, '0')}-'
        '${expiry.day.toString().padLeft(2, '0')} $hh:$mm';
  }
}

/// Session-wide entitlement fetch policy: one cached snapshot per device
/// session, refreshed when a page opens (silently reused within
/// [staleness]) or on an explicit force. No background timer — the desktop
/// pushes no quota events (research/entitlement-probe.md), so fetching
/// happens only when a consumer opens or refreshes.
///
/// A failed fetch keeps the previous payload (and its fetch time) and only
/// flips the phase to [EntitlementPhase.error], so a transient RPC error
/// never blanks already-known data. Errors are never served from cache.
class EntitlementPoller extends ValueNotifier<EntitlementView> {
  final Future<dynamic> Function() fetch;
  final Duration staleness;

  static const defaultStaleness = Duration(minutes: 5);

  Future<EntitlementView>? _inFlight;

  EntitlementPoller({
    required this.fetch,
    this.staleness = defaultStaleness,
  }) : super(const EntitlementView(phase: EntitlementPhase.loading));

  /// Whether the current snapshot may stand in for a refresh: fetched
  /// recently enough and not an error (errors must re-fetch).
  bool get _cacheFresh {
    final view = value;
    final at = view.fetchedAt;
    if (at == null || view.phase == EntitlementPhase.error) return false;
    return clock.now().difference(at) < staleness;
  }

  /// Returns the cached snapshot within the staleness window, otherwise
  /// fetches a fresh one. [force] bypasses the cache. Concurrent callers
  /// share one in-flight fetch.
  Future<EntitlementView> refresh({bool force = false}) {
    if (!force && _cacheFresh) return Future.value(value);
    return _inFlight ??= _fetchNow();
  }

  Future<EntitlementView> _fetchNow() async {
    // No payload ever landed (first load, or failures only so far): show
    // loading instead of holding the stale error view. An existing payload
    // stays visible while it refreshes.
    if (value.fetchedAt == null && value.phase != EntitlementPhase.loading) {
      value = const EntitlementView(phase: EntitlementPhase.loading);
    }
    try {
      final res = await fetch();
      if (res is! Map) {
        throw StateError('entitlement: unexpected payload');
      }
      final data = Map<String, dynamic>.from(res);
      value = EntitlementView(
        phase: phaseOf(data),
        data: data,
        fetchedAt: clock.now(),
      );
    } catch (e) {
      // Keep the previous payload visible; only phase and error change.
      value = EntitlementView(
        phase: EntitlementPhase.error,
        data: value.data,
        fetchedAt: value.fetchedAt,
        error: '$e',
      );
    } finally {
      _inFlight = null;
    }
    return value;
  }

  /// Maps a raw snapshot onto the render phases (design.md table):
  /// `unavailableReason=='not_configured'` → [EntitlementPhase.notConfigured],
  /// `authenticated!=true` → [EntitlementPhase.loginRequired],
  /// authenticated without provider and remaining → [EntitlementPhase.noPlan],
  /// else [EntitlementPhase.ok].
  static EntitlementPhase phaseOf(Map<String, dynamic> data) {
    if (data['unavailableReason'] == 'not_configured') {
      return EntitlementPhase.notConfigured;
    }
    if (data['authenticated'] != true) return EntitlementPhase.loginRequired;
    if (data['provider'] == null && data['remaining'] == null) {
      return EntitlementPhase.noPlan;
    }
    return EntitlementPhase.ok;
  }
}
