import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/state/entitlement_poller.dart';
import 'package:zgo/state/quota_reset.dart' show QuotaWindowKind;

/// Fixtures use only the live-probed snapshot structure.
void main() {
  /// Recorded `not_configured` response (probe 2026-09-13).
  final notConfigured = <String, dynamic>{
    'generatedAt': 1789280250549,
    'authenticated': true,
    'unavailableReason': 'not_configured',
    'context': {'scope': 'personal'},
    'provider': null,
    'remaining': null,
    'subscription': null,
    'quota': null,
  };

  Map<String, dynamic> okPayload() => {
        'authenticated': true,
        'provider': {'name': 'BigModel'},
        'remaining': {
          'count': 12,
          'percentage': 40,
          'isShow': true,
          'nextResetTime': 1789300000000,
        },
        'quota': {
          'level': 'pro',
          'limits': [
            {'type': 'requests', 'percentage': 55},
          ],
        },
        'subscription': null,
      };

  EntitlementPoller pollerOf(Future<dynamic> Function() fetch) {
    final poller = EntitlementPoller(fetch: fetch);
    addTearDown(poller.dispose);
    return poller;
  }

  test('initial phase is loading', () {
    final poller = pollerOf(() async => okPayload());
    expect(poller.value.phase, EntitlementPhase.loading);
    expect(poller.value.data, isNull);
  });

  test('maps ok / notConfigured / loginRequired / noPlan', () async {
    Object? answer;
    var calls = 0;
    final poller = pollerOf(() async {
      calls++;
      return answer;
    });

    answer = okPayload();
    expect((await poller.refresh()).phase, EntitlementPhase.ok);

    answer = notConfigured;
    expect((await poller.refresh(force: true)).phase,
        EntitlementPhase.notConfigured);

    answer = {'authenticated': false};
    expect((await poller.refresh(force: true)).phase,
        EntitlementPhase.loginRequired);

    answer = {'authenticated': true};
    expect(
        (await poller.refresh(force: true)).phase, EntitlementPhase.noPlan);
    expect(calls, 4);
  });

  test('staleness window reuses the cache; force bypasses it', () async {
    var now = DateTime(2026, 9, 13, 12);
    var calls = 0;
    await withClock(Clock(() => now), () async {
      final poller = pollerOf(() async {
        calls++;
        return okPayload();
      });

      await poller.refresh();
      expect(calls, 1);

      // 4 minutes later: inside the 5-minute window → cached.
      now = now.add(const Duration(minutes: 4));
      final cached = await poller.refresh();
      expect(calls, 1);
      expect(cached.phase, EntitlementPhase.ok);

      // 6 minutes after the fetch: window expired → re-fetch.
      now = now.add(const Duration(minutes: 2));
      await poller.refresh();
      expect(calls, 2);

      // force re-fetches even inside the window.
      await poller.refresh(force: true);
      expect(calls, 3);
    });
  });

  test('failure keeps the previous payload and reports error', () async {
    var fail = false;
    final poller = pollerOf(() async {
      if (fail) throw StateError('rpc down');
      return okPayload();
    });

    final ok = await poller.refresh();
    expect(ok.phase, EntitlementPhase.ok);

    fail = true;
    final err = await poller.refresh(force: true);
    expect(err.phase, EntitlementPhase.error);
    expect(err.error, contains('rpc down'));
    expect(err.data, same(ok.data)); // previous payload not cleared
    expect(ok.exhausted, isFalse);

    // Errors are never served from cache: a plain refresh re-fetches.
    fail = false;
    final recovered = await poller.refresh();
    expect(recovered.phase, EntitlementPhase.ok);
  });

  test('first-ever failure turns loading into error, retry shows loading',
      () async {
    var gate = Completer<Map<String, dynamic>>();
    var calls = 0;
    final poller = pollerOf(() {
      calls++;
      return gate.future;
    });

    gate.completeError(StateError('down'));
    final err = await poller.refresh();
    expect(err.phase, EntitlementPhase.error);
    expect(err.data, isNull);

    // Retry in flight with no payload ever fetched: phase reads loading.
    gate = Completer<Map<String, dynamic>>();
    final retried = poller.refresh();
    expect(poller.value.phase, EntitlementPhase.loading);
    gate.complete(okPayload());
    expect((await retried).phase, EntitlementPhase.ok);
    expect(calls, 2);
  });

  test('non-map payload becomes an error view', () async {
    final poller = pollerOf(() async => null);
    final view = await poller.refresh();
    expect(view.phase, EntitlementPhase.error);
  });

  test('concurrent refreshes share one in-flight fetch', () async {
    final gate = Completer<Map<String, dynamic>>();
    var calls = 0;
    final poller = pollerOf(() {
      calls++;
      return gate.future;
    });

    final f1 = poller.refresh();
    final f2 = poller.refresh();
    gate.complete(okPayload());
    await f1;
    await f2;
    expect(calls, 1);
  });

  test('a stalled RPC times out, frees the slot, and is re-fetched (09-21)',
      () async {
    var stall = false;
    var calls = 0;
    final poller = EntitlementPoller(
      fetch: () {
        calls++;
        // A bridge rebuild mid-RPC never answers — the raw future hangs.
        if (stall) return Completer<Map<String, dynamic>>().future;
        return Future.value(okPayload());
      },
      timeout: const Duration(milliseconds: 20),
    );
    addTearDown(poller.dispose);

    stall = false;
    final ok = await poller.refresh();
    expect(ok.phase, EntitlementPhase.ok);

    // The timeout must settle the dead fetch as an error view (payload
    // retained) and — crucially — release the in-flight slot.
    stall = true;
    final stalled = await poller.refresh(force: true);
    expect(stalled.phase, EntitlementPhase.error);
    expect(stalled.data, same(ok.data));

    // The next refresh starts a NEW fetch instead of sharing the dead one.
    stall = false;
    final recovered = await poller.refresh(force: true);
    expect(recovered.phase, EntitlementPhase.ok);
    expect(calls, 3);
  });

  test('exhausted ignores a topped-out monthly MCP TIME_LIMIT (bug 09-15)', () {
    // Live-probed 3.11.2 snapshot: the monthly built-in MCP quota
    // (search-prime 100/101) is used up and the top-level `remaining`
    // copy reads 0/100%, while the token window sits at 51%. No banner.
    final view = EntitlementView(
      phase: EntitlementPhase.ok,
      data: {
        'authenticated': true,
        'remaining': {'count': 0, 'percentage': 100, 'isShow': true},
        'quota': {
          'limits': [
            {'type': 'TIME_LIMIT', 'unit': 5, 'number': 1, 'percentage': 100},
            {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 51},
          ],
        },
      },
    );
    expect(view.exhausted, isFalse);
  });

  test('exhausted triggers on a topped-out token / credit limit', () {
    EntitlementView view(List<Object?> limits) => EntitlementView(
          phase: EntitlementPhase.ok,
          data: {
            'quota': {'limits': limits},
          },
        );

    expect(view([{'type': 'TOKENS_LIMIT', 'percentage': 100}]).exhausted, isTrue);
    expect(view([{'type': 'TOKENS_LIMIT', 'percentage': 99}]).exhausted, isFalse);
    expect(view([{'type': 'CREDIT_LIMIT', 'percentage': 100}]).exhausted, isTrue);
    // Unknown limit types never drive the token-class banner.
    expect(view([{'type': 'requests', 'percentage': 100}]).exhausted, isFalse);
  });

  test('exhausted tolerates missing / malformed quota fields', () {
    EntitlementView view(Object? quota) => EntitlementView(
          phase: EntitlementPhase.ok,
          data: {'quota': quota},
        );

    expect(const EntitlementView(phase: EntitlementPhase.ok).exhausted, isFalse);
    expect(view(null).exhausted, isFalse);
    expect(view('not-a-map').exhausted, isFalse);
    expect(view({'limits': 'not-a-list'}).exhausted, isFalse);
    expect(
      view({
        'limits': [
          null,
          'not-a-map',
          {'type': 'TOKENS_LIMIT', 'percentage': 'oops'},
        ],
      }).exhausted,
      isFalse,
    );
  });

  test('top-level remaining at 100% without a token limit is not exhausted',
      () {
    // `remaining` reflects TIME_LIMIT (monthly MCP), so it never raises the
    // token-class banner on its own.
    final view = EntitlementView(
      phase: EntitlementPhase.ok,
      data: {
        'remaining': {'count': 0, 'percentage': 100},
        'quota': {
          'limits': [
            {'type': 'TIME_LIMIT', 'percentage': 100},
          ],
        },
      },
    );
    expect(view.exhausted, isFalse);
  });

  // ------------------------------------------- Start-level normalization

  /// research §7 live fixture shape: two one-time buckets whose wire
  /// `percentage` is the REMAINING ratio in 0..1 (asar
  /// `normalizeZaiStartPlanBalanceLimits`: `remaining_units / total_units`,
  /// no ×100 — 1.0 = untouched, 0.0 = drained).
  Map<String, dynamic> startSnapshot({
    List<num> percentages = const [1.0, 1.0],
  }) =>
      {
        'authenticated': true,
        'provider': {
          'id': 'account:zai-start-plan',
          'name': 'ZCode 1024 Dev Day',
        },
        'remaining': {'count': 2, 'isShow': true, 'percentage': 1.0},
        'quota': {
          'level': 'Start',
          'limits': [
            for (var i = 0; i < percentages.length; i++)
              {
                'bucketId': 'bucket_$i',
                'type': 'ent-zcode-v3-start-plan-1024-${i + 1}',
                'unit': 300000000 - i * 100000000,
                'number': 300000000 - i * 100000000,
                'usage': 0,
                'remaining':
                    percentages[i] * (300000000 - i * 100000000),
                'percentage': percentages[i],
                'nextResetTime': 1792976400000,
              },
          ],
        },
      };

  test('normalizeStartQuota flips the Start remaining ratio into used percent',
      () {
    final source = startSnapshot();
    final data = normalizeStartQuota(source);
    final view = EntitlementView(phase: EntitlementPhase.ok, data: data);

    // Pure helper: the wire payload is not rewritten in place.
    expect(((source['quota'] as Map)['limits'] as List)[0]['percentage'], 1.0);

    // 0 used → used 0 → remaining 100%.
    expect(view.primaryLimit, isNotNull);
    expect(view.primaryLimit!.percentage, 0);
    expect(view.remainingPercent(view.primaryLimit), 100.0);
    expect(view.exhausted, isFalse);
    // Start rows are token-class even though `type` is an entitlement id.
    expect(view.chatBottleneckLimit, isNotNull);
    // One-time buckets match no reset window — the reset surfaces stay off.
    expect(view.windowRow(QuotaWindowKind.fiveHour), isNull);
    expect(view.windowRow(QuotaWindowKind.week), isNull);
  });

  test('normalizeStartQuota maps the live 0..1 ratio onto used percent '
      '(0.9493 remaining → 5.07 used)', () {
    final view = EntitlementView(
      phase: EntitlementPhase.ok,
      data: normalizeStartQuota(
        startSnapshot(percentages: const [0.9493, 1.0]),
      ),
    );
    final limit = ((view.data!['quota'] as Map)['limits'] as List)[0] as Map;
    expect((limit['percentage'] as num).toDouble(), closeTo(5.07, 0.0001));
    expect(view.remainingPercent(view.primaryLimit), closeTo(94.93, 0.0001));
    expect(view.exhausted, isFalse);
  });

  test('a drained Start bucket (wire remaining ratio 0.0) reads exhausted',
      () {
    final view = EntitlementView(
      phase: EntitlementPhase.ok,
      data: normalizeStartQuota(startSnapshot(percentages: const [0.0, 1.0])),
    );
    expect(view.exhausted, isTrue);
  });

  test('coding-plan snapshots pass through normalizeStartQuota unchanged', () {
    final data = <String, dynamic>{
      'authenticated': true,
      'quota': {
        'level': 'pro',
        'limits': [
          {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 40},
        ],
      },
    };
    // No Start level → the very same map comes back (no reversal).
    expect(normalizeStartQuota(data), same(data));

    final view = EntitlementView(phase: EntitlementPhase.ok, data: data);
    expect(view.remainingPercent(view.primaryLimit), 60.0);
    expect(view.exhausted, isFalse);
  });

  test('Start rows without a numeric percentage stay unreadable', () {
    final data = normalizeStartQuota({
      'quota': {
        'level': 'Start',
        'limits': [
          {'type': 'ent-1', 'percentage': null},
          {'type': 'ent-2'},
        ],
      },
    });
    final limits = (data['quota'] as Map)['limits'] as List;
    expect((limits[0] as Map)['percentage'], isNull);
    expect((limits[1] as Map).containsKey('percentage'), isFalse);

    final view = EntitlementView(phase: EntitlementPhase.ok, data: data);
    expect(view.primaryLimit, isNull);
    expect(view.exhausted, isFalse);
  });

  test('the poller normalizes a Start snapshot before projecting', () async {
    final poller = pollerOf(() async => startSnapshot());
    final view = await poller.refresh();

    expect(view.phase, EntitlementPhase.ok);
    final limit = ((view.data!['quota'] as Map)['limits'] as List)[0] as Map;
    expect(limit['percentage'], 0);
    expect(view.remainingPercent(view.primaryLimit), 100.0);
  });

  test('phaseOf keeps a Start snapshot with a provider in the ok phase '
      '(regression)', () {
    expect(
      EntitlementPoller.phaseOf({
        'authenticated': true,
        'provider': {'id': 'account:zai-start-plan'},
        'remaining': null,
        'quota': {'level': 'Start', 'limits': <Object>[]},
      }),
      EntitlementPhase.ok,
    );
  });
}
