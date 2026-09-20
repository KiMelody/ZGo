import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/state/entitlement_poller.dart';
import 'package:zlinker/state/quota_reset.dart';
import 'package:zlinker/state/quota_watch.dart';

/// Fixed "now" for every test ([quotaTest] runs each body inside the clock
/// zone — spec §8: inject time via package:clock, never fake timers).
/// [advanceClock] moves it for cache-staleness sensitive cases.
DateTime _currentNow = DateTime(2026, 9, 20, 12);
final _clock = Clock(() => _currentNow);
void advanceClock(Duration delta) => _currentNow = _currentNow.add(delta);
const _hour = 3600000;
const _min = 60000;

void quotaTest(String description, dynamic Function() body) {
  test(description, () => withClock(_clock, body));
}

Map<String, dynamic> _limit(
  String type,
  int unit,
  int? number,
  double usedPercent, {
  int? nextResetMs,
}) =>
    {
      'type': type,
      'unit': unit,
      if (number != null) 'number': number,
      'percentage': usedPercent,
      if (nextResetMs != null) 'nextResetTime': nextResetMs,
    };

EntitlementView _view(
  List<Map<String, dynamic>> limits, {
  EntitlementPhase phase = EntitlementPhase.ok,
}) =>
    EntitlementView(
      phase: phase,
      data: {
        'authenticated': true,
        'provider': {'id': 'prov-1'},
        'quota': {'limits': limits},
      },
      fetchedAt: _currentNow,
    );

QuotaResetPools _pools({
  int fiveHourCount = 0,
  int? fiveHourExpiryMs,
  int weekCount = 0,
  int? weekExpiryMs,
}) =>
    QuotaResetPools(
      fiveHour: QuotaResetPool(
        count: fiveHourCount,
        earliestExpireAt: fiveHourExpiryMs,
      ),
      week: QuotaResetPool(count: weekCount, earliestExpireAt: weekExpiryMs),
      hasData: true,
    );

QuotaWatchJudgement _judge(
  EntitlementView? view,
  QuotaResetPools? pools, {
  QuotaWatchEdgeState edges = const QuotaWatchEdgeState(),
  bool calibrated = true,
  int threshold = 20,
  bool expiryReminder = true,
  int fiveHourExpiryLeadMinutes = 60,
  int weeklyExpiryLeadHours = 6,
  Duration retryEvery = const Duration(minutes: 5),
}) =>
    judgeQuotaWatch(
      view: view,
      pools: pools,
      edges: edges,
      calibrated: calibrated,
      thresholdPercent: threshold,
      expiryReminderEnabled: expiryReminder,
      fiveHourExpiryLeadMinutes: fiveHourExpiryLeadMinutes,
      weeklyExpiryLeadHours: weeklyExpiryLeadHours,
      retryEvery: retryEvery,
    );

/// Dual-window plan fixture: a 5h row used [fiveHourUsed] (reset in ~2h35m)
/// and a week row used [weekUsed] (reset in ~3d2h, exercising the days-tier
/// data shape).
EntitlementView _dualPlan({
  double fiveHourUsed = 28,
  double weekUsed = 28,
}) =>
    _view([
      _limit('TOKENS_LIMIT', 3, 5, fiveHourUsed,
          nextResetMs: _currentNow.millisecondsSinceEpoch +
              2 * _hour +
              35 * 60000),
      _limit('TOKENS_LIMIT', 6, null, weekUsed,
          nextResetMs:
              _currentNow.millisecondsSinceEpoch + 3 * 24 * _hour + 2 * _hour),
      _limit('TIME_LIMIT', 5, 1, 41,
          nextResetMs: _currentNow.millisecondsSinceEpoch + 10 * 24 * _hour),
    ]);

void main() {
  group('window mapping + chat bottleneck projection', () {
    quotaTest('unit 3 + number 5 maps to fiveHour, unit 6 to week', () {
      expect(quotaWindowKindOf(_limit('TOKENS_LIMIT', 3, 5, 10)),
          QuotaWindowKind.fiveHour);
      expect(quotaWindowKindOf(_limit('CREDIT_LIMIT', 3, 5, 10)),
          QuotaWindowKind.fiveHour);
      expect(quotaWindowKindOf(_limit('TOKENS_LIMIT', 6, null, 10)),
          QuotaWindowKind.week);
      expect(quotaWindowKindOf(_limit('TOKENS_LIMIT', 6, 1, 10)),
          QuotaWindowKind.week);
      // Monthly tool quota and odd shapes map to no reset window.
      expect(quotaWindowKindOf(_limit('TIME_LIMIT', 5, 1, 10)), isNull);
      expect(quotaWindowKindOf(_limit('TOKENS_LIMIT', 3, 1, 10)), isNull);
      expect(quotaResetTypeOf(QuotaWindowKind.fiveHour), 'FIVE_HOUR');
      expect(quotaResetTypeOf(QuotaWindowKind.week), 'WEEK');
    });

    quotaTest('chatBottleneckLimit ranks token rows only, primaryLimit does not',
        () {
      final view = _view([
        _limit('TIME_LIMIT', 5, 1, 99.5),
        _limit('TOKENS_LIMIT', 3, 5, 30),
        _limit('TOKENS_LIMIT', 6, null, 82),
      ]);
      // The A2 card may headline the monthly tool quota…
      expect(view.primaryLimit?.kind, isNull);
      // …but the chat bottleneck must never be it (PRD R2).
      expect(view.chatBottleneckLimit?.kind, QuotaWindowKind.week);
      expect(view.remainingPercent(view.chatBottleneckLimit!), 18.0);
    });

    quotaTest('bottleneck tie breaks to the nearest window rollover', () {
      final view = _view([
        _limit('TOKENS_LIMIT', 3, 5, 80,
            nextResetMs: _currentNow.millisecondsSinceEpoch + 5 * _hour),
        _limit('TOKENS_LIMIT', 6, null, 80,
            nextResetMs: _currentNow.millisecondsSinceEpoch + _hour),
      ]);
      expect(view.chatBottleneckLimit?.kind, QuotaWindowKind.week);
    });

    quotaTest('windowRow mirrors poolVisible window matching', () {
      final view = _dualPlan();
      expect(view.windowRow(QuotaWindowKind.fiveHour)?.kind,
          QuotaWindowKind.fiveHour);
      expect(
          view.windowRow(QuotaWindowKind.week)?.kind, QuotaWindowKind.week);
      // A V1 plan (no weekly row) hides its weekly window.
      expect(
          _view([_limit('TOKENS_LIMIT', 3, 5, 10)])
              .windowRow(QuotaWindowKind.week),
          isNull);
    });
  });

  group('judgeQuotaWatch phases', () {
    quotaTest('N7: no plan / no chat bottleneck → noPlan (hidden)', () {
      expect(_judge(null, null).snapshot.phase, QuotaWatchPhase.unavailable);
      // An error with no payload retained (or nothing inside the stale
      // window) still blanks to unavailable.
      expect(
          _judge(
            EntitlementView(phase: EntitlementPhase.error, fetchedAt: null),
            null,
          ).snapshot.phase,
          QuotaWatchPhase.unavailable);
      // An error holding an empty-plan payload inside the stale window
      // re-derives that payload's phase (noPlan) instead of unavailable —
      // the retained data is the truth (2026-09-20 stale tolerance).
      expect(
          _judge(_view(const [], phase: EntitlementPhase.error), null)
              .snapshot
              .phase,
          QuotaWatchPhase.noPlan);
      expect(
          _judge(_view(const [], phase: EntitlementPhase.loginRequired), null)
              .snapshot
              .phase,
          QuotaWatchPhase.noPlan);
      // A plan whose only rows are TIME_LIMIT: nothing chat-scoped to watch.
      expect(_judge(_view([_limit('TIME_LIMIT', 5, 1, 99)]), null).snapshot.phase,
          QuotaWatchPhase.noPlan);
    });

    quotaTest('N1 normal: ring holds the bottleneck remaining, no button', () {
      final judgement = _judge(_dualPlan(fiveHourUsed: 28), null);
      expect(judgement.snapshot.phase, QuotaWatchPhase.normal);
      expect(judgement.snapshot.bottleneckKind, QuotaWindowKind.fiveHour);
      expect(judgement.snapshot.bottleneckRemaining, 72.0);
      expect(judgement.snapshot.buttonKind, isNull);
      expect(judgement.snapshot.bottleneckCouponCount, isNull);
      expect(judgement.events, isEmpty);
    });

    quotaTest('N2: low quota + coupon → warn phase with a direct-reset button',
        () {
      final view = _dualPlan(fiveHourUsed: 85);
      final pools = _pools(
        fiveHourCount: 1,
        fiveHourExpiryMs: _currentNow.millisecondsSinceEpoch + 3 * _hour,
      );
      final judgement = _judge(view, pools);
      expect(judgement.snapshot.phase, QuotaWatchPhase.lowQuota);
      expect(judgement.snapshot.bottleneckRemaining, 15.0);
      expect(judgement.snapshot.bottleneckCouponCount, 1);
      expect(judgement.snapshot.bottleneckCouponExpiry, isNotNull);
      expect(judgement.snapshot.buttonKind, QuotaWindowKind.fiveHour);
    });

    quotaTest('N2-w: week bottleneck switches kind/button/detail', () {
      final view = _dualPlan(fiveHourUsed: 10, weekUsed: 92);
      final pools = _pools(
        weekCount: 1,
        weekExpiryMs: DateTime(2026, 9, 21, 20).millisecondsSinceEpoch,
      );
      final judgement = _judge(view, pools);
      expect(judgement.snapshot.phase, QuotaWatchPhase.lowQuota);
      expect(judgement.snapshot.bottleneckKind, QuotaWindowKind.week);
      expect(judgement.snapshot.bottleneckRemaining, 8.0);
      expect(judgement.snapshot.buttonKind, QuotaWindowKind.week);
      // Expanded detail shows the OTHER window (five-hour here).
      expect(judgement.snapshot.detailKind, QuotaWindowKind.fiveHour);
      expect(judgement.snapshot.hasWeekWindow, isTrue);
      expect(judgement.snapshot.weekCoupons, 1);
    });

    quotaTest(
        'N2-nr: bottleneck without coupons → no button, honest subline data',
        () {
      final judgement = _judge(_dualPlan(fiveHourUsed: 88), null);
      expect(judgement.snapshot.phase, QuotaWatchPhase.lowQuota);
      expect(judgement.snapshot.buttonKind, isNull);
      expect(judgement.snapshot.bottleneckCouponCount, isNull);
      // The alert still fires with the no-coupon shape (N3-nr).
      expect(judgement.events.single, isA<QuotaLowAlertEvent>());
      final alert = judgement.events.single as QuotaLowAlertEvent;
      expect(alert.couponCount, 0);
      expect(alert.hasAnyPool, isFalse);
    });

    quotaTest(
        'N6 vs stale: an error young enough keeps judging the retained '
        'data (stale=true); past the window it blanks to unavailable', () {
      final failing = EntitlementView(
        phase: EntitlementPhase.error,
        data: _dualPlan().data,
        fetchedAt: _currentNow,
        error: 'boom',
      );
      final fresh = _judge(failing, null,
              retryEvery: const Duration(minutes: 1))
          .snapshot;
      // 2026-09-20 stale tolerance: the notice keeps the last success'
      // numbers, marked stale, instead of flipping to N6.
      expect(fresh.phase, QuotaWatchPhase.normal);
      expect(fresh.stale, isTrue);
      expect(fresh.updatedAt, _currentNow);
      expect(fresh.retryEvery, const Duration(minutes: 1));

      // One minute past the 15-minute window: no more borrowed data —
      // N6 stamps the last success time and carries the retry cadence.
      final fetchedAt = _currentNow;
      advanceClock(quotaWatchStaleWindow);
      // Exactly on the window edge: the endpoint is inclusive.
      final onEdge = _judge(failing, null).snapshot;
      expect(onEdge.phase, QuotaWatchPhase.normal);
      expect(onEdge.stale, isTrue);

      advanceClock(const Duration(minutes: 1));
      final aged = _judge(failing, null,
              retryEvery: const Duration(minutes: 1))
          .snapshot;
      expect(aged.phase, QuotaWatchPhase.unavailable);
      expect(aged.stale, isFalse);
      expect(aged.updatedAt, fetchedAt);
      expect(aged.retryEvery, const Duration(minutes: 1));
    });
  });

  group('N4 expiring coupon', () {
    quotaTest('fires the reminder and renders the expiring state with a button',
        () {
      // remaining 45 — not low; the tie (week also at 55 used) breaks to the
      // nearer five-hour rollover, so the bottleneck is the five-hour row.
      // 45 min to expiry is inside the default five-hour lead (60 min).
      final view = _dualPlan(fiveHourUsed: 55);
      final pools = _pools(
        fiveHourCount: 1,
        fiveHourExpiryMs: _currentNow.millisecondsSinceEpoch + 45 * _min,
      );
      final judgement = _judge(view, pools);
      expect(judgement.snapshot.phase, QuotaWatchPhase.expiring);
      expect(judgement.snapshot.expiringKind, QuotaWindowKind.fiveHour);
      expect(judgement.snapshot.buttonKind, QuotaWindowKind.fiveHour);
      final event = judgement.events.single as QuotaExpiryEvent;
      expect(event.kind, QuotaWindowKind.fiveHour);
      expect(event.remaining, 45.0);
    });

    quotaTest('a coupon past its type lead is not expiring', () {
      final view = _dualPlan(fiveHourUsed: 55);
      final pools = _pools(
        fiveHourCount: 1,
        fiveHourExpiryMs: _currentNow.millisecondsSinceEpoch + 65 * _min,
      );
      expect(_judge(view, pools).snapshot.phase, QuotaWatchPhase.normal);
    });

    quotaTest('the lead boundary is inclusive (exactly at the lead expires)', () {
      final view = _dualPlan(fiveHourUsed: 55);
      final fiveHourPools = _pools(
        fiveHourCount: 1,
        fiveHourExpiryMs: _currentNow.millisecondsSinceEpoch + 60 * _min,
      );
      expect(
          _judge(view, fiveHourPools).snapshot.phase, QuotaWatchPhase.expiring);
      // The weekly side keeps its own default lead (6 h): +6h1m is outside.
      final weekPools = _pools(
        weekCount: 1,
        weekExpiryMs: _currentNow.millisecondsSinceEpoch + 6 * _hour + _min,
      );
      expect(_judge(view, weekPools).snapshot.phase, QuotaWatchPhase.normal);
    });

    quotaTest('leads are per type: tightening one leaves the other armed', () {
      final view = _dualPlan(fiveHourUsed: 55);
      final pools = _pools(
        fiveHourCount: 1,
        fiveHourExpiryMs: _currentNow.millisecondsSinceEpoch + 45 * _min,
      );
      // The five-hour lead shrunk below the coupon's remaining life → quiet.
      expect(
          _judge(view, pools, fiveHourExpiryLeadMinutes: 5).snapshot.phase,
          QuotaWatchPhase.normal);

      // A week coupon 5.5 h out fires at the default 6 h lead…
      final weekView = _dualPlan(fiveHourUsed: 55, weekUsed: 30);
      final weekPools = _pools(
        weekCount: 1,
        weekExpiryMs:
            _currentNow.millisecondsSinceEpoch + 5 * _hour + 30 * _min,
      );
      expect(_judge(weekView, weekPools).snapshot.phase,
          QuotaWatchPhase.expiring);
      // …but not at a 5 h lead.
      expect(
          _judge(weekView, weekPools, weeklyExpiryLeadHours: 5).snapshot.phase,
          QuotaWatchPhase.normal);
    });

    quotaTest('EXCEPTION (2026-09-20): 5h coupon + dead week → no reminder',
        () {
      // Week remaining 0% (used 100) makes the WEEK row the bottleneck at
      // rem 0 — the persistent notice shows N2-w low (no weekly coupon →
      // no button). What the exception kills is the 5h-coupon expiry
      // reminder: consuming it buys nothing while the week window is dead
      // and its rollover (3d2h) is more than 5h away. The coupon is inside
      // the default five-hour lead (45 < 60 min), so suppression — not the
      // lead — is what silences it.
      final view = _dualPlan(fiveHourUsed: 55, weekUsed: 100);
      final pools = _pools(
        fiveHourCount: 1,
        fiveHourExpiryMs: _currentNow.millisecondsSinceEpoch + 45 * _min,
      );
      final judgement = _judge(view, pools);
      expect(judgement.snapshot.bottleneckKind, QuotaWindowKind.week);
      expect(judgement.snapshot.buttonKind, isNull);
      expect(judgement.events.whereType<QuotaExpiryEvent>(), isEmpty);
      expect(judgement.edges.expiryNotifiedKey, isNull);
    });

    quotaTest('EXCEPTION does not apply when the week window resets within 5h',
        () {
      final view = _view([
        _limit('TOKENS_LIMIT', 3, 5, 55,
            nextResetMs: _currentNow.millisecondsSinceEpoch + 4 * _hour),
        _limit('TOKENS_LIMIT', 6, null, 100,
            nextResetMs: _currentNow.millisecondsSinceEpoch + 4 * _hour),
      ]);
      final pools = _pools(
        fiveHourCount: 1,
        fiveHourExpiryMs: _currentNow.millisecondsSinceEpoch + 45 * _min,
      );
      final judgement = _judge(view, pools);
      // The reminder fires (the fresh 5h window still overlaps the short
      // wait for the week rollover); the persistent notice shows the low
      // state (the dead week row is the bottleneck at rem 0).
      expect(judgement.events.whereType<QuotaExpiryEvent>(), isNotEmpty);
      expect(judgement.snapshot.phase, QuotaWatchPhase.lowQuota);
    });

    quotaTest('EXCEPTION does not apply on V1 plans (no weekly row)', () {
      final view = _view([
        _limit('TOKENS_LIMIT', 3, 5, 55,
            nextResetMs: _currentNow.millisecondsSinceEpoch + 4 * _hour),
      ]);
      final pools = _pools(
        fiveHourCount: 1,
        fiveHourExpiryMs: _currentNow.millisecondsSinceEpoch + 45 * _min,
      );
      final judgement = _judge(view, pools);
      expect(judgement.snapshot.hasWeekWindow, isFalse);
      expect(judgement.snapshot.phase, QuotaWatchPhase.expiring);
      expect(judgement.snapshot.detailKind, isNull);
      expect(judgement.snapshot.weekCoupons, 0);
      expect(judgement.events, isNotEmpty);
    });

    quotaTest('the dead-week exception holds regardless of the lead values',
        () {
      // Suppression keys off the dead week window, never off the lead: a
      // non-default lead pair (30 min / 8 h) with a 20-min-out coupon still
      // stays silent.
      final view = _dualPlan(fiveHourUsed: 55, weekUsed: 100);
      final pools = _pools(
        fiveHourCount: 1,
        fiveHourExpiryMs: _currentNow.millisecondsSinceEpoch + 20 * _min,
      );
      final judgement = _judge(
        view,
        pools,
        fiveHourExpiryLeadMinutes: 30,
        weeklyExpiryLeadHours: 8,
      );
      expect(judgement.events.whereType<QuotaExpiryEvent>(), isEmpty);
      expect(judgement.edges.expiryNotifiedKey, isNull);
    });

    quotaTest('a WEEK coupon expiring is never suppressed', () {
      // The expiring coupon is the weekly one — weekly coupons never
      // suppress (even with a dead week window). The five-hour row stays
      // the 55%-used bottleneck (not low) so the phase is expiring.
      final view = _dualPlan(fiveHourUsed: 55, weekUsed: 30);
      final pools = _pools(
        weekCount: 1,
        weekExpiryMs: _currentNow.millisecondsSinceEpoch + 3 * _hour,
      );
      final judgement = _judge(view, pools);
      expect(judgement.snapshot.phase, QuotaWatchPhase.expiring);
      expect(judgement.snapshot.expiringKind, QuotaWindowKind.week);
      expect(judgement.events, isNotEmpty);
    });

    quotaTest('the reminder switch gates both the state and the one-shot', () {
      final view = _dualPlan(fiveHourUsed: 55);
      final pools = _pools(
        fiveHourCount: 1,
        fiveHourExpiryMs: _currentNow.millisecondsSinceEpoch + 45 * _min,
      );
      final judgement = _judge(view, pools, expiryReminder: false);
      expect(judgement.snapshot.phase, QuotaWatchPhase.normal);
      expect(judgement.events, isEmpty);
    });
  });

  group('edges: N3 hysteresis + cold-start calibration', () {
    quotaTest('downward crossing fires once; rearm needs threshold + 5', () {
      var edges = const QuotaWatchEdgeState();
      EntitlementView viewOf(double used) => _dualPlan(fiveHourUsed: used);

      // Cold start already low: baselines silently, no event.
      final cold = _judge(viewOf(85), null, edges: edges, calibrated: false);
      expect(cold.events, isEmpty);
      expect(cold.edges.lowArmed, isFalse);
      edges = cold.edges;

      // Stays low: still silent, still disarmed.
      final still = _judge(viewOf(87), null, edges: edges, calibrated: true);
      expect(still.events, isEmpty);
      expect(still.edges.lowArmed, isFalse);
      edges = still.edges;

      // Creeps back but stays below the threshold: silent, disarmed.
      final below = _judge(viewOf(84), null, edges: edges, calibrated: true);
      expect(below.events, isEmpty);
      expect(below.edges.lowArmed, isFalse);
      edges = below.edges;

      // Recovers past threshold + 5: rearmed without an event.
      final recovered = _judge(viewOf(70), null, edges: edges, calibrated: true);
      expect(recovered.events, isEmpty);
      expect(recovered.edges.lowArmed, isTrue);
      edges = recovered.edges;

      // Crosses below again: the alert fires (with coupon data present).
      // The pool carries no expiry timestamps, so the N4 edge stays quiet
      // and the alert is the single event.
      final pools = _pools(fiveHourCount: 2);
      final again = _judge(viewOf(84), pools, edges: edges, calibrated: true);
      final alert = again.events.single as QuotaLowAlertEvent;
      expect(alert.kind, QuotaWindowKind.fiveHour);
      expect(alert.remaining, 16.0);
      expect(alert.couponCount, 2);
      expect(alert.hasAnyPool, isTrue);
      expect(again.edges.lowArmed, isFalse);
    });

    quotaTest('N4 edge: once per (expiry, pool total) batch, rearmed by usage',
        () {
      var edges = const QuotaWatchEdgeState();
      final view = _dualPlan(fiveHourUsed: 55);
      QuotaResetPools pools(int count) => _pools(
            fiveHourCount: count,
            fiveHourExpiryMs: _currentNow.millisecondsSinceEpoch + 45 * _min,
          );

      // Cold start: baseline silently.
      final cold = _judge(view, pools(2), edges: edges, calibrated: false);
      expect(cold.events, isEmpty);
      expect(cold.edges.expiryNotifiedKey, isNotNull);
      edges = cold.edges;

      // Same batch: no repeat.
      final same = _judge(view, pools(2), edges: edges, calibrated: true);
      expect(same.events, isEmpty);
      edges = same.edges;

      // One coupon consumed (same batch expiry, total drops): rearms.
      final consumed = _judge(view, pools(1), edges: edges, calibrated: true);
      expect(consumed.events.single, isA<QuotaExpiryEvent>());
      edges = consumed.edges;

      // Coupon gone entirely: baseline cleared, nothing fires.
      final gone = _judge(view, _pools(), edges: edges, calibrated: true);
      expect(gone.events, isEmpty);
      expect(gone.edges.expiryNotifiedKey, isNull);
      expect(gone.snapshot.phase, QuotaWatchPhase.normal);
    });

    quotaTest('a failing poll keeps the edge state untouched', () {
      const armed = QuotaWatchEdgeState();
      final failing = EntitlementView(
        phase: EntitlementPhase.error,
        fetchedAt: _currentNow,
      );
      final judgement = _judge(failing, null, edges: armed);
      expect(judgement.edges.lowArmed, armed.lowArmed);
      expect(judgement.edges.expiryNotifiedKey, armed.expiryNotifiedKey);
    });
  });

  group('QuotaWatchController', () {
    FakeSource sourceOf({
      String deviceId = 'dev-1',
      DeviceStatus status = DeviceStatus.connected,
      EntitlementView? view,
      Map<String, dynamic>? statusPayload,
    }) =>
        FakeSource(
          deviceId: deviceId,
          status: status,
          view: view ?? _dualPlan(),
          statusPayload: statusPayload,
        );

    quotaTest('no online session → unavailable snapshot', () async {
      final offline = sourceOf(status: DeviceStatus.disconnected);
      final controller = QuotaWatchController(
        sessionsOf: () => [offline],
        onEvent: (_) {},
      );
      addTearDown(controller.dispose);
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 5),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      await until(
          () => controller.snapshot.phase == QuotaWatchPhase.unavailable);
      expect(controller.monitoredDeviceId, isNull);
      expect(offline.snapshotForces, isEmpty);
    });

    quotaTest('polls the first ONLINE session; offline ones are skipped',
        () async {
      final offline = sourceOf(status: DeviceStatus.disconnected);
      final online = sourceOf(deviceId: 'dev-2');
      final controller = QuotaWatchController(
        sessionsOf: () => [offline, online],
        onEvent: (_) {},
      );
      addTearDown(controller.dispose);
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 5),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      await until(() => controller.monitoredDeviceId == 'dev-2');
      await until(() => controller.snapshot.phase == QuotaWatchPhase.normal);
      expect(offline.snapshotForces, isEmpty);
    });

    quotaTest('force-refresh at 1-minute cadence, plain refresh at 15',
        () async {
      // advanceClock moves the fixed clock past the poller/pools staleness
      // before the second cadence, so the plain (non-forced) refresh is a
      // genuine fetch rather than a cache hit.
      final source = sourceOf();
      final controller = QuotaWatchController(
        sessionsOf: () => [source],
        onEvent: (_) {},
      );
      addTearDown(controller.dispose);
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 1),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      await until(() => source.snapshotForces.isNotEmpty);
      expect(source.snapshotForces.single, isTrue);
      expect(source.poolForces, hasLength(1));
      // Let the first poll COMPLETE (the judge ran, so the pools fetch's
      // _fetchedAt is stamped at the pre-advance time) before moving the
      // clock — otherwise the in-flight dedupe legitimately swallows the
      // second fetch.
      await until(() => controller.snapshot.phase == QuotaWatchPhase.normal);

      advanceClock(const Duration(minutes: 15));
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 15),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      // The pools refresh lands after the snapshot await — gate on it.
      await until(() => source.poolForces.length == 2);
      expect(source.snapshotForces.length, 2);
      expect(source.snapshotForces.last, isFalse);
      // The reset controller bypasses ITS cache via the force flag; the
      // gateway itself never sees a force argument.
      expect(source.poolForces.last, isFalse);
    });

    quotaTest('switch off withdraws the notice; pollNow becomes a no-op',
        () async {
      final source = sourceOf();
      final controller = QuotaWatchController(
        sessionsOf: () => [source],
        onEvent: (_) {},
      );
      addTearDown(controller.dispose);
      controller.configure(
        enabled: false,
        thresholdPercent: 20,
        interval: const Duration(minutes: 5),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      expect(controller.snapshot.phase, QuotaWatchPhase.disabled);
      await controller.pollNow();
      expect(source.snapshotForces, isEmpty);
    });

    quotaTest(
        'failure backoff: two failed ticks slow to 5 min, one success '
        'restores the configured cadence (2026-09-20 真机诊断)', () async {
      final source = sourceOf(view: _dualPlan());
      final controller = QuotaWatchController(
        sessionsOf: () => [source],
        onEvent: (_) {},
      );
      addTearDown(controller.dispose);
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 1),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      await until(() => controller.snapshot.phase == QuotaWatchPhase.normal);
      expect(controller.effectiveInterval, const Duration(minutes: 1));

      // Failed ticks carry the retained ok payload: the notice keeps
      // judging it (stale) while the cadence backs off.
      source.setView(EntitlementView(
        phase: EntitlementPhase.error,
        data: _dualPlan().data,
        fetchedAt: _currentNow,
        error: 'boom',
      ));
      await controller.pollNow();
      await controller.pollNow();
      expect(controller.effectiveInterval,
          QuotaWatchController.backoffInterval);
      expect(controller.snapshot.phase, QuotaWatchPhase.normal);
      expect(controller.snapshot.stale, isTrue);

      // One success drops the backoff at once.
      source.setView(_dualPlan());
      await controller.pollNow();
      expect(controller.effectiveInterval, const Duration(minutes: 1));
      expect(controller.snapshot.stale, isFalse);
    });

    quotaTest(
        'lifecycle seam: backgrounded drops to the slow cadence, '
        'foregrounded re-polls at once and restores it', () async {
      final source = sourceOf();
      final controller = QuotaWatchController(
        sessionsOf: () => [source],
        onEvent: (_) {},
      );
      addTearDown(controller.dispose);
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 1),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      await until(() => controller.snapshot.phase == QuotaWatchPhase.normal);

      controller.backgrounded();
      expect(controller.effectiveInterval,
          QuotaWatchController.backoffInterval);

      // Past the foreground gate window, the resume polls immediately —
      // not gated by the slow timer.
      advanceClock(QuotaWatchController.foregroundRefetchWindow +
          const Duration(seconds: 1));
      final fetches = source.snapshotForces.length;
      controller.foregrounded();
      await until(() => source.snapshotForces.length > fetches);
      expect(controller.effectiveInterval, const Duration(minutes: 1));
    });

    quotaTest(
        'foreground gate: a resume inside 60s of the last SUCCESSFUL poll '
        'skips the re-fetch (official access path parity), a resume after '
        'a failed poll still retries', () async {
      final source = sourceOf();
      final controller = QuotaWatchController(
        sessionsOf: () => [source],
        onEvent: (_) {},
      );
      addTearDown(controller.dispose);
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 15),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      await until(() => controller.snapshot.phase == QuotaWatchPhase.normal);

      // Inside the window: no fetch, but the cadence still restores.
      controller.backgrounded();
      final fetches = source.snapshotForces.length;
      controller.foregrounded();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(source.snapshotForces.length, fetches);
      expect(controller.effectiveInterval, const Duration(minutes: 15));

      // A FAILED poll records nothing: the failure happens past the last
      // success's window, and a resume right after it still retries (were
      // the failure to stamp the gate, this resume would be swallowed).
      advanceClock(QuotaWatchController.foregroundRefetchWindow +
          const Duration(seconds: 1));
      source.setView(EntitlementView(
        phase: EntitlementPhase.error,
        data: _dualPlan().data,
        fetchedAt: _currentNow,
        error: 'boom',
      ));
      await controller.pollNow();
      expect(controller.snapshot.stale, isTrue);
      final afterFailure = source.snapshotForces.length;
      controller.backgrounded();
      controller.foregrounded();
      await until(() => source.snapshotForces.length > afterFailure);
      expect(source.snapshotForces.last, isTrue);
    });

    quotaTest(
        'a stalled RPC abandons the tick at the injected timeout '
        '(doze stalls run tens of seconds)', () async {
      final source = sourceOf();
      final controller = QuotaWatchController(
        sessionsOf: () => [source],
        onEvent: (_) {},
        rpcTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(controller.dispose);
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 1),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      await until(() => controller.snapshot.phase == QuotaWatchPhase.normal);

      source.stallNext = Completer<EntitlementView>();
      final sw = Stopwatch()..start();
      await controller.pollNow();
      sw.stop();
      // The tick is bounded by the timeout, not the stall — and counts as
      // a failure (a second one would back the cadence off).
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expect(controller.effectiveInterval, const Duration(minutes: 1));
      source.stallNext = Completer<EntitlementView>();
      await controller.pollNow();
      expect(controller.effectiveInterval,
          QuotaWatchController.backoffInterval);
    });

    quotaTest('changing an expiry lead re-judges the last view without an RPC',
        () async {
      final source = sourceOf(
        view: _dualPlan(fiveHourUsed: 55),
        statusPayload: {
          'availableFiveHourResets': [
            {'expireAt': _currentNow.millisecondsSinceEpoch + 30 * _min},
          ],
          'availableWeekResets': <Object?>[],
        },
      );
      final controller = QuotaWatchController(
        sessionsOf: () => [source],
        onEvent: (_) {},
      );
      addTearDown(controller.dispose);
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 5),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      // 30 min to expiry is inside the default 60 min lead → expiring.
      await until(() => controller.snapshot.phase == QuotaWatchPhase.expiring);
      final fetches = source.snapshotForces.length;

      // Tighten the five-hour lead below the coupon's remaining life: the
      // persistent notice re-renders as normal with NO further fetch.
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 5),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 5,
        weeklyExpiryLeadHours: 6,
      );
      await until(() => controller.snapshot.phase == QuotaWatchPhase.normal);
      expect(source.snapshotForces.length, fetches);
    });

    quotaTest('cold start with an already-low quota stays silent, then a real '
        're-cross alerts', () async {
      final events = <QuotaWatchEvent>[];
      final source = sourceOf(view: _dualPlan(fiveHourUsed: 85));
      final controller = QuotaWatchController(
        sessionsOf: () => [source],
        onEvent: events.add,
      );
      addTearDown(controller.dispose);
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 5),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      await until(
          () => controller.snapshot.phase == QuotaWatchPhase.lowQuota);
      expect(events, isEmpty); // cold-start baseline, no replayed alert

      // Recover past threshold + 5 (rearms; timer cadence replaced by an
      // explicit poll, the same entry the periodic timer drives).
      source.setView(_dualPlan(fiveHourUsed: 70));
      await controller.pollNow();
      await until(() => controller.snapshot.phase == QuotaWatchPhase.normal);

      // …then a genuine downward crossing fires the alert.
      source.setView(_dualPlan(fiveHourUsed: 85));
      await controller.pollNow();
      await until(() => events.isNotEmpty);
      expect(events.single, isA<QuotaLowAlertEvent>());
    });

    quotaTest('performReset consumes the mapped pool and re-judges from the '
        'refreshed snapshot', () async {
      final events = <QuotaWatchEvent>[];
      final statusPayload = <String, dynamic>{
        'availableFiveHourResets': [
          {'expireAt': _currentNow.millisecondsSinceEpoch + 3 * _hour},
        ],
        'availableWeekResets': <Object?>[],
      };
      final source = sourceOf(
        view: _dualPlan(fiveHourUsed: 85),
        statusPayload: statusPayload,
      );
      final controller = QuotaWatchController(
        sessionsOf: () => [source],
        onEvent: events.add,
      );
      addTearDown(controller.dispose);
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 5),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      await until(
          () => controller.snapshot.phase == QuotaWatchPhase.lowQuota);
      expect(controller.snapshot.buttonKind, QuotaWindowKind.fiveHour);

      // The reset succeeds; the session's refreshed view reads 100% left.
      source.onUse = (_) {
        statusPayload['availableFiveHourResets'] = <Object?>[];
        source.setView(_dualPlan(fiveHourUsed: 0, weekUsed: 0));
      };
      final ok = await controller.performReset(QuotaWindowKind.fiveHour);
      expect(ok, isTrue);
      expect(source.usedTypes, ['FIVE_HOUR']);
      expect(events.whereType<QuotaResetResultEvent>().single.ok, isTrue);
      await until(() => controller.snapshot.phase == QuotaWatchPhase.normal);
      expect(controller.snapshot.bottleneckRemaining, 100.0);
    });

    quotaTest('performReset with a drained pool reports failure', () async {
      final events = <QuotaWatchEvent>[];
      final source = sourceOf(
        view: _dualPlan(fiveHourUsed: 85),
        statusPayload: {
          'availableFiveHourResets': <Object?>[],
          'availableWeekResets': <Object?>[],
        },
      );
      final controller = QuotaWatchController(
        sessionsOf: () => [source],
        onEvent: events.add,
      );
      addTearDown(controller.dispose);
      controller.configure(
        enabled: true,
        thresholdPercent: 20,
        interval: const Duration(minutes: 5),
        expiryReminderEnabled: true,
        fiveHourExpiryLeadMinutes: 60,
        weeklyExpiryLeadHours: 6,
      );
      await until(
          () => controller.snapshot.phase == QuotaWatchPhase.lowQuota);
      final ok = await controller.performReset(QuotaWindowKind.fiveHour);
      expect(ok, isFalse);
      expect(events.whereType<QuotaResetResultEvent>().single.ok, isFalse);
    });
  });
}

/// A fake device link (the [QuotaWatchSource] seam) that also serves as the
/// reset gateway of its own session-wide [QuotaResetController].
class FakeSource implements QuotaWatchSource, QuotaResetGateway {
  FakeSource({
    required this.deviceId,
    this.status = DeviceStatus.connected,
    required EntitlementView view,
    Map<String, dynamic>? statusPayload,
  })  : _view = view,
        _statusPayload =
            statusPayload ?? {'availableFiveHourResets': <Object?>[]} {
    quotaResetController = QuotaResetController(gateway: this)
      ..updateScope('prov-1');
  }

  @override
  final String deviceId;

  @override
  DeviceStatus status;

  EntitlementView _view;
  final Map<String, dynamic> _statusPayload;

  /// Hook simulating the desktop side of a use: adjust the status payload
  /// and the view when a reset goes through.
  void Function(String resetType)? onUse;

  /// When set, the next [entitlementSnapshot] never completes — simulates
  /// a doze-stalled RPC for the controller's timeout bound.
  Completer<EntitlementView>? stallNext;

  final snapshotForces = <bool>[];
  final poolForces = <bool>[];
  final usedTypes = <String>[];

  @override
  late final QuotaResetController quotaResetController;

  void setView(EntitlementView view) => _view = view;

  @override
  Future<EntitlementView> entitlementSnapshot({bool force = false}) async {
    snapshotForces.add(force);
    final stall = stallNext;
    if (stall != null) {
      stallNext = null;
      return stall.future;
    }
    return _view;
  }

  @override
  Future<Object?> quotaResetStatus({bool force = false}) async {
    poolForces.add(force);
    return _statusPayload;
  }

  @override
  Future<void> useQuotaReset(
    String resetType,
    String idempotencyKey, {
    String? preferredProviderId,
  }) async {
    usedTypes.add(resetType);
    onUse?.call(resetType);
  }
}

/// Polls [condition] on a short real-time cadence (spec §8 test pattern).
Future<void> until(bool Function() condition, {int maxMs = 2000}) async {
  for (var waited = 0; waited < maxMs; waited += 10) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not met within ${maxMs}ms');
}
