import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import 'device_session.dart';
import 'entitlement_poller.dart';
import 'quota_reset.dart';

/// Hysteresis above the threshold (PRD R2): after a low-quota alert fired,
/// the remaining percent must climb back to threshold + this margin before
/// the alert rearms — an edge fires once per arm, and repeat polls at a
/// jittering value around the threshold never re-fire (宁漏勿延).
const quotaWatchAlertHysteresis = 5.0;

/// Stale tolerance (2026-09-20 真机诊断): a failed fetch keeps the last
/// success in the error view ([EntitlementPoller._fetchNow]), so the judge
/// keeps trusting it for this long instead of flipping the notice to
/// N6「无法获取」. Fixed — doze stalls start at ~2 min but the quota
/// windows move on hour scales, so 15 min of held data stays honest, and
/// a settings field for it would only invite thrash.
const quotaWatchStaleWindow = Duration(minutes: 15);

/// A device link the quota watch can poll — the seam [DeviceSession]
/// already satisfies (live status + the session-wide entitlement poller and
/// reset controller, so polling shares the pages' cache and in-flight
/// dedupe); tests fake it directly.
abstract interface class QuotaWatchSource {
  String get deviceId;
  DeviceStatus get status;
  Future<EntitlementView> entitlementSnapshot({bool force = false});
  QuotaResetController get quotaResetController;
}

/// Render phase of the persistent notice (mock N-states): [normal] is N1,
/// [lowQuota] covers N2/N2-w/N2-nr (variants follow from the pool fields),
/// [expiring] is N4, [unavailable] is N6, [noPlan] is N7 (nothing is
/// posted) and [disabled] is the switch-off state (notice withdrawn).
enum QuotaWatchPhase {
  normal,
  lowQuota,
  expiring,
  unavailable,
  noPlan,
  disabled,
}

/// One poll's projection, fully judged. The presenter assembles all copy
/// from these values and never re-derives anything (data layer carries
/// values and kinds, display layer translates — i18n checklist §2.7).
class QuotaWatchSnapshot {
  final QuotaWatchPhase phase;

  /// Bottleneck window (ring + main line); null when there is no ring to
  /// render (unavailable / no plan).
  final QuotaWindowKind? bottleneckKind;

  /// Bottleneck remaining percent (0–100, the same clamp).
  final double? bottleneckRemaining;

  /// Bottleneck window's natural rollover (main-line countdown).
  final DateTime? bottleneckResetAt;

  /// The bottleneck window's coupon pool (N2 subline + button); null when
  /// the window maps to no pool, the pools are unknown, or the pool holds
  /// no coupon (N2-nr).
  final int? bottleneckCouponCount;
  final DateTime? bottleneckCouponExpiry;

  /// The coupon the N4 expiring state is about (null outside that state).
  final QuotaWindowKind? expiringKind;
  final DateTime? expiringAt;

  /// The window the visible button would consume; null → no button.
  final QuotaWindowKind? buttonKind;

  /// Expanded-view detail: the NON-bottleneck window's row (null = the
  /// plan has no such row → the line is dropped), plus whether the plan
  /// has a weekly window at all (a V1 plan hides its weekly coupons
  /// entirely) and the two raw pool counts.
  final QuotaWindowKind? detailKind;
  final double? detailRemaining;
  final DateTime? detailResetAt;
  final bool hasWeekWindow;
  final int fiveHourCoupons;
  final int weekCoupons;

  /// When the displayed data landed (N6's「{time} 更新」stamped with the
  /// last SUCCESS even while failing — the poller keeps it); null when
  /// nothing ever arrived.
  final DateTime? updatedAt;

  /// Poll cadence (N6's retry copy — the value the timer actually runs
  /// at, so failure backoff / background slowdown show through).
  final Duration retryEvery;

  /// Whether the values above come from the stale tolerance (2026-09-20
  /// 真机诊断): a failed poll judged on its retained data — the subline
  /// stamps the fetch time so the frozen numbers read as old. Only ever
  /// true on the data-bearing phases; false elsewhere.
  final bool stale;

  const QuotaWatchSnapshot({
    required this.phase,
    this.bottleneckKind,
    this.bottleneckRemaining,
    this.bottleneckResetAt,
    this.bottleneckCouponCount,
    this.bottleneckCouponExpiry,
    this.expiringKind,
    this.expiringAt,
    this.buttonKind,
    this.detailKind,
    this.detailRemaining,
    this.detailResetAt,
    this.hasWeekWindow = false,
    this.fiveHourCoupons = 0,
    this.weekCoupons = 0,
    this.updatedAt,
    this.retryEvery = const Duration(minutes: 5),
    this.stale = false,
  });
}

/// One-shot, edge-triggered watch events (N3 / N4 / N5). The persistent
/// notice is NOT an event — the presenter re-renders it from the
/// controller's snapshot notifier on every poll.
sealed class QuotaWatchEvent {
  const QuotaWatchEvent();
}

/// N3: the bottleneck remaining crossed below the threshold (downward,
/// once per armed period). [kind] null is the N3b degrade shape (the
/// bottleneck row maps to no reset window → deep-link + in-app dialog).
class QuotaLowAlertEvent extends QuotaWatchEvent {
  final QuotaWindowKind? kind;
  final double remaining;

  /// The bottleneck window's coupon pool (0 → the N3-nr no-coupon copy).
  final int couponCount;
  final DateTime? couponExpiry;

  /// The bottleneck window's natural rollover (N3-nr countdown).
  final DateTime? naturalResetAt;

  /// Whether any resettable pool exists at all — drives the N3b
  /// "choose a reset type" shape when [kind] is null.
  final bool hasAnyPool;

  const QuotaLowAlertEvent({
    required this.kind,
    required this.remaining,
    required this.couponCount,
    required this.couponExpiry,
    required this.naturalResetAt,
    required this.hasAnyPool,
  });
}

/// N4: the earliest coupon entered the expiry window (fires once per
/// coupon — see [QuotaWatchEdgeState.expiryNotifiedKey]).
class QuotaExpiryEvent extends QuotaWatchEvent {
  final QuotaWindowKind kind;
  final DateTime expiry;

  /// Bottleneck remaining at fire time (reminder body's 当前剩余).
  final double remaining;

  const QuotaExpiryEvent({
    required this.kind,
    required this.expiry,
    required this.remaining,
  });
}

/// N5: feedback of a direct reset fired from a notice button.
class QuotaResetResultEvent extends QuotaWatchEvent {
  final bool ok;
  final QuotaWindowKind? kind;

  const QuotaResetResultEvent({required this.ok, required this.kind});
}

/// The edge state threaded between polls.
class QuotaWatchEdgeState {
  /// Whether the N3 alert is armed (fires on the next downward crossing).
  final bool lowArmed;

  /// `'{expiryMs}:{totalCoupons}'` of the coupon batch the N4 reminder
  /// already fired for. Keyed by expiry AND pool total so a consumed
  /// coupon (total drops, same batch expiry) rearms the reminder for the
  /// next one — the mock's 「该券被消耗或过期后，下一张券重新武装」.
  final String? expiryNotifiedKey;

  const QuotaWatchEdgeState({this.lowArmed = true, this.expiryNotifiedKey});
}

/// Result of one pure judging pass.
class QuotaWatchJudgement {
  final QuotaWatchSnapshot snapshot;
  final List<QuotaWatchEvent> events;
  final QuotaWatchEdgeState edges;

  const QuotaWatchJudgement({
    required this.snapshot,
    required this.events,
    required this.edges,
  });
}

/// Pure judge of one poll (mock 规则表): picks the persistent-notice phase,
/// the button and the edge events from a snapshot + pools. [calibrated] is
/// false until the first bottleneck-bearing snapshot lands — during
/// calibration the edges only BASELINE (cold start stays silent, no
/// replayed alerts), per the mock's lifecycle row.
QuotaWatchJudgement judgeQuotaWatch({
  required EntitlementView? view,
  required QuotaResetPools? pools,
  required QuotaWatchEdgeState edges,
  required bool calibrated,
  required int thresholdPercent,
  required bool expiryReminderEnabled,
  required int fiveHourExpiryLeadMinutes,
  required int weeklyExpiryLeadHours,
  Duration retryEvery = const Duration(minutes: 5),
}) {
  final now = clock.now();
  var stale = false;

  // Stale tolerance (2026-09-20 真机诊断): a failed fetch keeps the last
  // success payload in the error view, so while it is young enough keep
  // judging it instead of blanking the notice to N6. The error view only
  // swapped the phase — re-derive it from the payload and mark the result
  // stale. Edge events ride the same data: unchanged values re-fire no
  // edge, so stale needs no suppression of its own.
  if (view != null &&
      view.phase == EntitlementPhase.error &&
      view.data != null &&
      view.fetchedAt != null &&
      now.difference(view.fetchedAt!) <= quotaWatchStaleWindow) {
    view = EntitlementView(
      phase: EntitlementPoller.phaseOf(view.data!),
      data: view.data,
      fetchedAt: view.fetchedAt,
    );
    stale = true;
  }

  // N6 / N7: no data, still loading, or a failed poll with nothing (or
  // nothing inside the stale window) retained. An error view that reaches
  // here is by definition outside the stale window (the swap above
  // replaced the young ones) — it must stay N6, not fall through to the
  // noPlan check below, which would misread the retained payload as a
  // plan-less plan.
  if (view == null ||
      view.phase == EntitlementPhase.loading ||
      view.phase == EntitlementPhase.error) {
    return QuotaWatchJudgement(
      snapshot: QuotaWatchSnapshot(
        phase: QuotaWatchPhase.unavailable,
        updatedAt: view?.fetchedAt,
        retryEvery: retryEvery,
      ),
      events: const [],
      edges: edges,
    );
  }
  final bottleneck = view.chatBottleneckLimit;
  if (view.phase != EntitlementPhase.ok || bottleneck == null) {
    return QuotaWatchJudgement(
      snapshot: QuotaWatchSnapshot(phase: QuotaWatchPhase.noPlan),
      events: const [],
      edges: edges,
    );
  }

  final kind = bottleneck.kind;
  final remaining = view.remainingPercent(bottleneck)!;
  final resettable = view.resettablePools(pools);
  final hasWeekWindow = view.windowRow(QuotaWindowKind.week) != null;

  QuotaResetPool? poolOf(QuotaWindowKind target) {
    final type = quotaResetTypeOf(target);
    for (final r in resettable) {
      if (r.type == type) return r.pool;
    }
    return null;
  }

  final bottleneckPool = kind == null ? null : poolOf(kind);

  // N4 candidate: earliest expiring coupon among the resettable pools,
  // each type judged against its own lead (2026-09-20 用户裁定).
  final expiringCandidate = _expiringCoupon(
    resettable,
    now,
    fiveHourLead: Duration(minutes: fiveHourExpiryLeadMinutes),
    weekLead: Duration(hours: weeklyExpiryLeadHours),
  );

  // N4 exception (2026-09-20 用户裁定): a FIVE-HOUR coupon expiring while
  // the weekly window sits at 0% and its natural rollover is more than 5h
  // away buys nothing — chat stays blocked by the dead week quota, so no
  // reminder / button either. V1 plans (no weekly row) never suppress; a
  // WEEK coupon expiring never suppresses.
  final suppressedByDeadWeek = _suppressedByDeadWeek(
    view,
    expiringCandidate,
    hasWeekWindow: hasWeekWindow,
    now: now,
  );
  final expiringActive = expiringCandidate != null &&
      !suppressedByDeadWeek &&
      expiryReminderEnabled;

  // ---- N3 edge + hysteresis ----
  var lowArmed = edges.lowArmed;
  final lowNow = remaining < thresholdPercent;
  final events = <QuotaWatchEvent>[];
  final bottleneckResetMs = bottleneck.nextResetTime;
  final bottleneckExpiryMs = bottleneckPool?.earliestExpireAt;
  if (lowNow) {
    if (calibrated && lowArmed) {
      events.add(QuotaLowAlertEvent(
        kind: kind,
        remaining: remaining,
        couponCount: bottleneckPool?.count ?? 0,
        couponExpiry: bottleneckExpiryMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(bottleneckExpiryMs),
        naturalResetAt: bottleneckResetMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(bottleneckResetMs),
        hasAnyPool: resettable.any((r) => r.pool.count > 0),
      ));
    }
    lowArmed = false;
  } else if (remaining >= thresholdPercent + quotaWatchAlertHysteresis) {
    lowArmed = true;
  }

  // ---- N4 edge: once per (expiry, pool total) batch ----
  var expiryNotifiedKey = edges.expiryNotifiedKey;
  final totalCoupons = (pools?.fiveHour.count ?? 0) + (pools?.week.count ?? 0);
  // expiringActive ⇒ expiringCandidate != null; hoisted so everything
  // below reads without bangs.
  final activeExpiring = expiringActive ? expiringCandidate : null;
  if (activeExpiring != null) {
    final key =
        '${activeExpiring.expiry.millisecondsSinceEpoch}:$totalCoupons';
    if (calibrated && expiryNotifiedKey != key) {
      events.add(QuotaExpiryEvent(
        kind: activeExpiring.kind,
        expiry: activeExpiring.expiry,
        remaining: remaining,
      ));
    }
    expiryNotifiedKey = key;
  } else {
    expiryNotifiedKey = null;
  }

  // ---- phase + button ----
  final phase = lowNow
      ? QuotaWatchPhase.lowQuota
      : (activeExpiring != null
          ? QuotaWatchPhase.expiring
          : QuotaWatchPhase.normal);
  QuotaWindowKind? buttonKind;
  if (lowNow) {
    // The button resets exactly the bottleneck type, and only when that
    // type's pool holds a coupon (the other type's pool cannot save the
    // bottleneck — N2-nr renders no button).
    if (kind != null && bottleneckPool != null && bottleneckPool.count > 0) {
      buttonKind = kind;
    }
  } else if (activeExpiring != null) {
    buttonKind = activeExpiring.kind;
  }

  // Expanded detail: the non-bottleneck window's row (null → dropped).
  QuotaWindowKind? detailKind;
  Limit? detailRow;
  if (kind != null) {
    final other = kind == QuotaWindowKind.fiveHour
        ? (hasWeekWindow ? QuotaWindowKind.week : null)
        : QuotaWindowKind.fiveHour;
    detailRow = other == null ? null : view.windowRow(other);
    if (detailRow != null) detailKind = other;
  }

  return QuotaWatchJudgement(
    snapshot: _snapshot(
      phase: phase,
      view: view,
      bottleneck: bottleneck,
      kind: kind,
      remaining: remaining,
      bottleneckPool: bottleneckPool,
      expiring: activeExpiring,
      buttonKind: buttonKind,
      detailKind: detailKind,
      detailRow: detailRow,
      hasWeekWindow: hasWeekWindow,
      pools: pools,
      retryEvery: retryEvery,
      stale: stale,
    ),
    events: events,
    edges: QuotaWatchEdgeState(
      lowArmed: lowArmed,
      expiryNotifiedKey: expiryNotifiedKey,
    ),
  );
}

class _ExpiringCoupon {
  final QuotaWindowKind kind;
  final DateTime expiry;

  const _ExpiringCoupon({required this.kind, required this.expiry});
}

_ExpiringCoupon? _expiringCoupon(
  List<ResettablePool> resettable,
  DateTime now, {
  required Duration fiveHourLead,
  required Duration weekLead,
}) {
  _ExpiringCoupon? best;
  for (final r in resettable) {
    final ms = r.pool.earliestExpireAt;
    if (ms == null) continue;
    final expiry = DateTime.fromMillisecondsSinceEpoch(ms);
    final kind = r.type == quotaResetTypeWeek
        ? QuotaWindowKind.week
        : QuotaWindowKind.fiveHour;
    final lead = kind == QuotaWindowKind.week ? weekLead : fiveHourLead;
    if (!expiry.isAfter(now.add(lead))) {
      if (best == null || expiry.isBefore(best.expiry)) {
        best = _ExpiringCoupon(kind: kind, expiry: expiry);
      }
    }
  }
  return best;
}

bool _suppressedByDeadWeek(
  EntitlementView view,
  _ExpiringCoupon? candidate, {
  required bool hasWeekWindow,
  required DateTime now,
}) {
  if (candidate == null ||
      candidate.kind != QuotaWindowKind.fiveHour ||
      !hasWeekWindow) {
    return false;
  }
  final weekRow = view.windowRow(QuotaWindowKind.week);
  if (weekRow == null) return false;
  final weekRemaining = view.remainingPercent(weekRow);
  final resetAt = weekRow.nextResetTime;
  return weekRemaining != null &&
      weekRemaining <= 0 &&
      resetAt != null &&
      DateTime.fromMillisecondsSinceEpoch(resetAt)
          .isAfter(now.add(const Duration(hours: 5)));
}

QuotaWatchSnapshot _snapshot({
  required QuotaWatchPhase phase,
  required EntitlementView view,
  required Limit bottleneck,
  required QuotaWindowKind? kind,
  required double remaining,
  required QuotaResetPool? bottleneckPool,
  required _ExpiringCoupon? expiring,
  required QuotaWindowKind? buttonKind,
  required QuotaWindowKind? detailKind,
  required Limit? detailRow,
  required bool hasWeekWindow,
  required QuotaResetPools? pools,
  required Duration retryEvery,
  required bool stale,
}) {
  final resetMs = bottleneck.nextResetTime;
  final detailMs = detailRow?.nextResetTime;
  final couponMs = bottleneckPool == null || bottleneckPool.count <= 0
      ? null
      : bottleneckPool.earliestExpireAt;
  return QuotaWatchSnapshot(
    phase: phase,
    bottleneckKind: kind,
    bottleneckRemaining: remaining,
    bottleneckResetAt: resetMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(resetMs),
    bottleneckCouponCount: bottleneckPool == null || bottleneckPool.count <= 0
        ? null
        : bottleneckPool.count,
    bottleneckCouponExpiry: couponMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(couponMs),
    expiringKind: expiring?.kind,
    expiringAt: expiring?.expiry,
    buttonKind: buttonKind,
    detailKind: detailKind,
    detailRemaining:
        detailRow == null ? null : view.remainingPercent(detailRow),
    detailResetAt: detailMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(detailMs),
    hasWeekWindow: hasWeekWindow,
    fiveHourCoupons: pools?.fiveHour.count ?? 0,
    weekCoupons: pools?.week.count ?? 0,
    updatedAt: view.fetchedAt,
    retryEvery: retryEvery,
    stale: stale,
  );
}

/// Android quota-watch engine (PRD internal-task): polls
/// the FIRST online session's entitlement snapshot + reset pools on the
/// configured cadence, judges the persistent-notice state and the one-shot
/// edges through the pure [judgeQuotaWatch], and exposes the reset entry
/// the notification buttons call back into.
///
/// - Settings are pushed in from the composition root ([configure]) — this
///   file never imports the UI layer.
/// - Polling reuses each session's session-wide [EntitlementPoller] and
///   reset controller (shared cache + in-flight dedupe with the usage
///   page, decision #3); when the watch cadence is tighter than the
///   poller's staleness the tick force-refreshes, so a 1-minute watch
///   really fetches every minute.
/// - Multi-device (decision #1): the first online session is monitored;
///   quota is account+provider scoped, and a disconnect rotates to the
///   next online session on the following tick.
class QuotaWatchController extends ChangeNotifier {
  QuotaWatchController({
    required Iterable<QuotaWatchSource> Function() sessionsOf,
    required void Function(QuotaWatchEvent event) onEvent,
    this.rpcTimeout = const Duration(seconds: 12),
  })  : _sessionsOf = sessionsOf,
        _onEvent = onEvent;

  final Iterable<QuotaWatchSource> Function() _sessionsOf;
  final void Function(QuotaWatchEvent event) _onEvent;

  /// Per-RPC bound for one poll tick (2026-09-20 真机诊断): under doze the
  /// desktop judges a stalled RPC failed at ~10s, so waiting longer only
  /// delays the tick — a timeout abandons it while the poller's in-flight
  /// keeps running for the next tick to join. Constructor-injected so
  /// tests shrink it (real timers, spec §8 — no fake async).
  final Duration rpcTimeout;

  /// Fixed slow cadence shared by failure backoff and the backgrounded
  /// app (2026-09-20 真机诊断): doze throttles the CPU enough that RPCs
  /// stall for tens of seconds, so both states settle on 5 min and are
  /// restored independently (a resume / one success) without interacting.
  static const backoffInterval = Duration(minutes: 5);

  /// Failed ticks in a row before the backoff cadence kicks in.
  static const backoffAfterFailures = 2;

  /// Foreground re-fetch gate (2026-09-21 风控对标): the client's
  /// access path (page made visible again) re-fetches only past a 60s window
  /// since the last successful pull (`HHe`/`BHe` in its useUsageEntitlement)
  /// — rapid app switching must not hammer the billing endpoint. A failed
  /// poll records nothing, so a resume right after a failure still retries.
  /// Manual refreshes stay exempt (the manual path bypasses every
  /// gate too).
  static const foregroundRefetchWindow = Duration(seconds: 60);

  DateTime? _lastSuccessfulPollAt;

  bool _enabled = false;
  int _thresholdPercent = 20;
  Duration _interval = const Duration(minutes: 5);
  bool _expiryReminderEnabled = true;
  int _fiveHourExpiryLeadMinutes = 60;
  int _weeklyExpiryLeadHours = 6;

  Timer? _timer;
  QuotaWatchSource? _current;
  EntitlementView? _lastView;
  bool _calibrated = false;
  QuotaWatchEdgeState _edges = const QuotaWatchEdgeState();
  bool _disposed = false;
  bool _backgrounded = false;
  int _consecutiveFailures = 0;

  QuotaWatchSnapshot _snapshot =
      const QuotaWatchSnapshot(phase: QuotaWatchPhase.disabled);

  /// The latest judged projection (the presenter renders the persistent
  /// notice from this).
  QuotaWatchSnapshot get snapshot => _snapshot;

  /// The cadence the periodic timer currently runs at: the configured
  /// interval, unless the app is backgrounded or the poll is in failure
  /// backoff — both slow to the fixed [backoffInterval]. Also the honest
  /// value for the N6 retry copy.
  Duration get effectiveInterval =>
      (_backgrounded || _consecutiveFailures >= backoffAfterFailures)
          ? backoffInterval
          : _interval;

  /// The monitored device (first online session); null while nothing is
  /// online — the deep links (notice body tap / failed-reset retry) open
  /// this device's usage page.
  String? get monitoredDeviceId => _current?.deviceId;

  /// Pushes the settings节 values in (called on every UiSettings change);
  /// enabling starts polling with an immediate tick, disabling stops it
  /// and withdraws the notice. A threshold / reminder / lead change
  /// re-judges the last view without an RPC.
  void configure({
    required bool enabled,
    required int thresholdPercent,
    required Duration interval,
    required bool expiryReminderEnabled,
    required int fiveHourExpiryLeadMinutes,
    required int weeklyExpiryLeadHours,
  }) {
    if (_disposed) return;
    final wasEnabled = _enabled;
    final intervalChanged = _interval != interval;
    final unchanged = !intervalChanged &&
        wasEnabled == enabled &&
        _thresholdPercent == thresholdPercent &&
        _expiryReminderEnabled == expiryReminderEnabled &&
        _fiveHourExpiryLeadMinutes == fiveHourExpiryLeadMinutes &&
        _weeklyExpiryLeadHours == weeklyExpiryLeadHours;
    if (unchanged) return;
    _thresholdPercent = thresholdPercent;
    _interval = interval;
    _expiryReminderEnabled = expiryReminderEnabled;
    _fiveHourExpiryLeadMinutes = fiveHourExpiryLeadMinutes;
    _weeklyExpiryLeadHours = weeklyExpiryLeadHours;
    _enabled = enabled;
    // A fresh enable starts from a clean slate: failures accumulated
    // before the switch-off must not open in backoff.
    if (!wasEnabled && enabled) _consecutiveFailures = 0;
    _syncTimer();
    if (!enabled) {
      _emit(QuotaWatchSnapshot(
        phase: QuotaWatchPhase.disabled,
        retryEvery: _interval,
      ));
      return;
    }
    if (!wasEnabled || intervalChanged) {
      // Fresh enable or a new cadence: poll now (the timer takes over).
      unawaited(pollNow());
    } else if (_lastView != null) {
      _apply(); // settings change only: re-judge the last view, no RPC
    }
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (_enabled) {
      _timer = Timer.periodic(effectiveInterval, (_) => unawaited(pollNow()));
    }
  }

  // ------------------------------------------------- app lifecycle seam
  //
  // main.dart's WidgetsBindingObserver calls these (lifecycle is a
  // widget-layer concept and stays out of the state layer).

  /// App resumed: restore the configured cadence and re-poll at once — the
  /// 2026-09-20 真机诊断 showed doze-stalled ticks leaving old data standing
  /// until the next periodic tick, and a resume must refresh at once. Not
  /// gated by the backoff: it drives [pollNow] directly, off the timer.
  /// Skipped while the last successful poll is younger than
  /// [foregroundRefetchWindow].
  void foregrounded() {
    if (_disposed) return;
    _backgrounded = false;
    _consecutiveFailures = 0;
    _syncTimer();
    final last = _lastSuccessfulPollAt;
    if (last != null &&
        clock.now().difference(last) < foregroundRefetchWindow) {
      return;
    }
    unawaited(pollNow(force: true));
  }

  /// App paused (home screen, app switch, screen off): drop to the fixed
  /// slow cadence — doze throttles the CPU enough that the tight cadence
  /// only burns battery while every RPC stalls anyway.
  void backgrounded() {
    if (_disposed) return;
    _backgrounded = true;
    _syncTimer();
  }

  /// One poll + judge cycle (public so tests and manual refreshes drive
  /// it). Never throws — the poller surfaces failures as an error phase.
  /// [force] bypasses the poller's staleness cache for user-visible
  /// triggers (manual tap, app foreground); periodic ticks force only
  /// when the cadence is tighter than the cache window.
  Future<void> pollNow({bool force = false}) async {
    if (_disposed || !_enabled) return;
    final session = _pickSession();
    if (session == null) {
      _current = null;
      _lastView = null;
      _emit(QuotaWatchSnapshot(
        phase: QuotaWatchPhase.unavailable,
        updatedAt: null,
        retryEvery: effectiveInterval,
      ));
      return;
    }
    _current = session;
    // Decision #3: reuse the poller's cache/in-flight, but force when the
    // watch cadence is tighter than the poller's staleness (or the caller
    // is a user-visible trigger — a manual refresh must never read the
    // cache, or the button "does nothing" for up to 5 minutes).
    final effectiveForce =
        force || _interval < EntitlementPoller.defaultStaleness;
    var failed = false;
    try {
      _lastView = await session.entitlementSnapshot(force: effectiveForce)
          .timeout(rpcTimeout);
      await session.quotaResetController.refresh(force: effectiveForce)
          .timeout(rpcTimeout);
    } catch (_) {
      // A failed/stalled RPC abandons the tick (the poller's in-flight
      // keeps running; the next tick joins it) and re-judges on whatever
      // data stands — entitlementSnapshot also reports failures via its
      // error phase below.
      failed = true;
    }
    if (_lastView?.phase == EntitlementPhase.error) failed = true;
    if (!failed) _lastSuccessfulPollAt = clock.now();
    // Failure backoff (2026-09-20 真机诊断): [backoffAfterFailures] failed
    // ticks in a row slow the timer to the fixed backoff cadence; the
    // first success restores the configured one. The timer only re-syncs
    // on the flip — resetting it every tick would postpone periodic polls
    // behind the manual ones.
    final wasBackingOff =
        _consecutiveFailures >= backoffAfterFailures;
    _consecutiveFailures = failed ? _consecutiveFailures + 1 : 0;
    if (wasBackingOff != (_consecutiveFailures >= backoffAfterFailures)) {
      _syncTimer();
    }
    _apply();
  }

  void _apply() {
    if (_disposed || !_enabled) return;
    final judgement = judgeQuotaWatch(
      view: _lastView,
      pools: _current?.quotaResetController.pools,
      edges: _edges,
      calibrated: _calibrated,
      thresholdPercent: _thresholdPercent,
      expiryReminderEnabled: _expiryReminderEnabled,
      fiveHourExpiryLeadMinutes: _fiveHourExpiryLeadMinutes,
      weeklyExpiryLeadHours: _weeklyExpiryLeadHours,
      retryEvery: effectiveInterval,
    );
    _edges = judgement.edges;
    // The first bottleneck-bearing judgement is the cold-start baseline:
    // it baselines the edges silently (judge suppressed firing) and arms
    // the normal edge behaviour from the next poll on.
    if (!_calibrated &&
        judgement.snapshot.phase != QuotaWatchPhase.unavailable &&
        judgement.snapshot.phase != QuotaWatchPhase.noPlan &&
        judgement.snapshot.phase != QuotaWatchPhase.disabled) {
      _calibrated = true;
    }
    _emit(judgement.snapshot);
    for (final event in judgement.events) {
      _onEvent(event);
    }
  }

  QuotaWatchSource? _pickSession() {
    for (final session in _sessionsOf()) {
      if (session.status == DeviceStatus.connected) return session;
    }
    return null;
  }

  /// The notice buttons' reset entry (PRD R3): consumes one coupon of
  /// [kind] from the monitored session's reset controller (idempotency key
  /// minted inside; success force-refreshes pools + snapshot there) and
  /// re-judges so the persistent notice flips immediately. Failure (also
  /// "pool drained since the notice rendered") reports false → the
  /// presenter posts the N5-b feedback.
  Future<bool> performReset(QuotaWindowKind kind) async {
    if (_disposed) return false;
    final session = _current;
    final ok = session == null
        ? false
        : await session.quotaResetController.use(quotaResetTypeOf(kind));
    if (session != null) {
      try {
        _lastView = await session.entitlementSnapshot();
      } catch (_) {
        // Re-judge below still works on the previous view.
      }
    }
    _onEvent(QuotaResetResultEvent(ok: ok, kind: kind));
    _apply();
    return ok;
  }

  void _emit(QuotaWatchSnapshot snapshot) {
    _snapshot = snapshot;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
