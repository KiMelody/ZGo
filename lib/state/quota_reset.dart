import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import 'entitlement_poller.dart';

/// Reset-pool identifiers accepted by `useCodingPlanReset`
/// (research/quota-reset-bundle-analysis.md).
const quotaResetTypeFiveHour = 'FIVE_HOUR';
const quotaResetTypeWeek = 'WEEK';

/// Gateway surface the reset controller needs — implemented by
/// [ChatGateway] (device_session.dart); fakes implement just these three.
abstract interface class QuotaResetGateway {
  /// Raw `getCodingPlanResetStatus` payload; caching lives in
  /// [QuotaResetController].
  Future<Object?> quotaResetStatus({bool force = false});

  /// Consumes one reset opportunity (`useCodingPlanReset`).
  Future<void> useQuotaReset(
    String resetType,
    String idempotencyKey, {
    String? preferredProviderId,
  });

  Future<EntitlementView> entitlementSnapshot({bool force = false});
}

/// One reset pool (5-hour / weekly) projected from the status snapshot.
class QuotaResetPool {
  /// Unexpired opportunities (`expireAt` > now, bundle aggregation
  /// semantics).
  final int count;

  /// Earliest expiry (ms epoch) among the unexpired opportunities.
  final int? earliestExpireAt;

  /// When this pool was last reset via a consumed opportunity
  /// (`latestXxxResetHistory.usedAt`, ms epoch; null = never / unreadable).
  final int? lastUsedAt;

  /// Optimistic in-flight flag — set locally while `useCodingPlanReset`
  /// runs, merged over the parsed snapshot by the controller.
  final bool processing;

  const QuotaResetPool({
    this.count = 0,
    this.earliestExpireAt,
    this.lastUsedAt,
    this.processing = false,
  });

  QuotaResetPool withProcessing(bool value) => QuotaResetPool(
        count: count,
        earliestExpireAt: earliestExpireAt,
        lastUsedAt: lastUsedAt,
        processing: value,
      );
}

/// Both pools projected from one status snapshot.
class QuotaResetPools {
  final QuotaResetPool fiveHour;
  final QuotaResetPool week;

  /// True when any whitelisted pool field was readable in the snapshot —
  /// distinguishes "no opportunities" from "no usable desktop data".
  final bool hasData;

  const QuotaResetPools({
    this.fiveHour = const QuotaResetPool(),
    this.week = const QuotaResetPool(),
    this.hasData = false,
  });

  bool get hasAnyOpportunity => fiveHour.count > 0 || week.count > 0;

  QuotaResetPools withProcessing(Set<String> processing) => QuotaResetPools(
        fiveHour: fiveHour.withProcessing(
            processing.contains(quotaResetTypeFiveHour)),
        week: week.withProcessing(processing.contains(quotaResetTypeWeek)),
        hasData: hasData,
      );
}

/// Defensive projection over the raw `getCodingPlanResetStatus` payload.
/// Only the research whitelist is read (`availableFiveHourResets` /
/// `availableWeekResets` with each item's `expireAt`, plus the pools'
/// `latestFiveHourResetHistory` / `latestWeekResetHistory` `usedAt`);
/// missing or mistyped fields degrade that pool to count=0 — never throws.
QuotaResetPools parseQuotaResetPools(Map? raw, {DateTime? now}) {
  final at = now ?? clock.now();

  QuotaResetPool poolOf(String key, String historyKey) {
    final entries = raw?[key];
    int? lastUsedAt;
    final history = raw?[historyKey];
    if (history is Map && history['usedAt'] is num) {
      lastUsedAt = (history['usedAt'] as num).toInt();
    }
    if (entries is! List) {
      return QuotaResetPool(lastUsedAt: lastUsedAt);
    }
    final unexpired = <int>[];
    for (final e in entries) {
      if (e is! Map) continue;
      final expireAt = e['expireAt'];
      if (expireAt is! num) continue;
      if (DateTime.fromMillisecondsSinceEpoch(expireAt.toInt()).isAfter(at)) {
        unexpired.add(expireAt.toInt());
      }
    }
    return QuotaResetPool(
      count: unexpired.length,
      earliestExpireAt:
          unexpired.isEmpty ? null : unexpired.reduce(min),
      lastUsedAt: lastUsedAt,
    );
  }

  return QuotaResetPools(
    fiveHour: poolOf('availableFiveHourResets', 'latestFiveHourResetHistory'),
    week: poolOf('availableWeekResets', 'latestWeekResetHistory'),
    hasData: raw?['availableFiveHourResets'] is List ||
        raw?['availableWeekResets'] is List,
  );
}

/// Session-wide reset-opportunity controller (usage page card + chat
/// banner action). Same shape as EntitlementPoller: staleness-cached
/// status fetch, force bypass, errors never cached and never thrown —
/// plus the official optimistic-use flow (research 状态机): validate →
/// fresh idempotency key → optimistic processing → RPC → on success
/// force-confirm the status and force-refresh the entitlement so the
/// pill/banner flip immediately; on failure roll the flag back and
/// surface [error] for the failed toast.
class QuotaResetController extends ChangeNotifier {
  final QuotaResetGateway gateway;
  final Duration staleness;

  static const defaultStaleness = Duration(seconds: 10);

  QuotaResetPools? _pools;
  DateTime? _fetchedAt;
  String? _scopeProviderId;
  final Set<String> _processing = {};
  String? _error;
  Future<void>? _inFlight;

  QuotaResetController({
    required this.gateway,
    this.staleness = defaultStaleness,
  });

  /// Latest pools with the optimistic processing flags merged in; null
  /// until a snapshot landed or while the scope is unavailable.
  QuotaResetPools? get pools => _pools?.withProcessing(_processing);

  /// Last failure of a status fetch or use call (UI renders the failed
  /// toast / degraded copy from it; nothing is ever thrown).
  String? get error => _error;

  /// `preferredProviderId` injected from the entitlement ok snapshot;
  /// null disables the feature — no request is issued and [pools] reads
  /// null (the UI shows the degraded copy instead of hiding the entry).
  String? get scopeProviderId => _scopeProviderId;

  bool get _cacheFresh {
    final at = _fetchedAt;
    return at != null && clock.now().difference(at) < staleness;
  }

  /// Called after each entitlement fetch: injects the provider id and
  /// drops stale state when it changes. Same value is a no-op.
  void updateScope(String? preferredProviderId) {
    if (_scopeProviderId == preferredProviderId) return;
    _scopeProviderId = preferredProviderId;
    _pools = null;
    _fetchedAt = null;
    _error = null;
    notifyListeners();
  }

  /// Status fetch with a staleness cache; [force] bypasses it. Skipped
  /// entirely when the scope is unavailable. Concurrent callers share one
  /// in-flight fetch.
  Future<void> refresh({bool force = false}) async {
    if (_scopeProviderId == null) return;
    if (!force && _cacheFresh) return;
    return _inFlight ??= _fetchNow();
  }

  Future<void> _fetchNow() async {
    try {
      final res = await gateway.quotaResetStatus();
      _pools = parseQuotaResetPools(res is Map ? res : null);
      _fetchedAt = clock.now();
      _error = null;
    } catch (e) {
      // Keep the previous pools visible, but never cache the failure:
      // the next plain refresh re-fetches.
      _fetchedAt = null;
      _error = '$e';
    } finally {
      _inFlight = null;
    }
    notifyListeners();
  }

  /// Consumes one opportunity of [resetType]. Returns whether the reset
  /// went through; the confirmation refresh failures never flip it.
  Future<bool> use(String resetType) async {
    if (resetType != quotaResetTypeFiveHour &&
        resetType != quotaResetTypeWeek) {
      return false;
    }
    final scope = _scopeProviderId;
    final pools = this.pools;
    final pool =
        resetType == quotaResetTypeWeek ? pools?.week : pools?.fiveHour;
    if (scope == null ||
        pools == null ||
        pool == null ||
        pool.count <= 0 ||
        pool.processing) {
      return false;
    }
    final key = _generateIdempotencyKey();
    _processing.add(resetType);
    _error = null;
    notifyListeners();
    try {
      await gateway.useQuotaReset(resetType, key, preferredProviderId: scope);
    } catch (e) {
      _processing.remove(resetType);
      _error = '$e';
      notifyListeners();
      return false;
    }
    _processing.remove(resetType);
    await refresh(force: true);
    // The poller itself never throws; a hiccup there must not report the
    // (already successful) reset as failed.
    try {
      await gateway.entitlementSnapshot(force: true);
    } catch (_) {}
    notifyListeners();
    return true;
  }
}

/// Hand-rolled idempotency key (ms epoch hex + random hex) — one call
/// site, no uuid dependency.
String _generateIdempotencyKey() {
  final rnd = Random();
  final rand =
      List.generate(8, (_) => rnd.nextInt(16).toRadixString(16)).join();
  return '${clock.now().millisecondsSinceEpoch.toRadixString(16)}-$rand';
}
