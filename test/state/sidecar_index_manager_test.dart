import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/state/sidecar_index_manager.dart';

/// Unit tests of [SidecarIndexManager]'s six strategies (design 10-29 §1.3)
/// through pure capability closures — no bridge, no session. The
/// DeviceSession-level wiring is covered by task_live_sidecar_test.dart.
void main() {
  Map<String, dynamic> task(
    String id,
    String path,
    int updatedAt, {
    String? identity,
  }) =>
      {
        'taskId': id,
        'title': id,
        'workspacePath': path,
        'updatedAt': updatedAt,
        'displayStatus': 'completed',
        if (identity != null) 'workspaceIdentity': identity,
      };

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  late _Harness h;

  setUp(() => h = _Harness());

  test('reconcile: top-N by newest relay row, active and conversation '
      'workspaces excluded, scope from the row', () async {
    h.limit = 2;
    h.active = '/repo/active';
    h.rows = [
      task('t-active', '/repo/active', 700),
      task('t-draft', '/home/.zcode/workspace/draft-1', 650),
      task('t-b', '/repo/b', 600, identity: 'b-id'),
      task('t-c', '/repo/c', 500),
      task('t-d', '/repo/d', 400),
    ];
    h.aliases = {'b-id': '/repo/b'};

    h.manager.reconcile();
    await settle();

    expect([for (final (key, _) in h.subscribeCalls) key], ['/repo/b', '/repo/c'],
        reason: 'newest first, capped at limit, active + draft paths excluded');
    expect(h.subscribeCalls.first.$2, {
      'workspacePath': '/repo/b',
      'workspaceIdentity': 'b-id',
    });
    expect(h.states['/repo/b']!.subscribedWorkspaceKey, '/repo/b',
        reason: 'the manager records the subscription identity on the state');
    expect(h.manager.indexes.keys.toSet(), {'/repo/b', '/repo/c'});
  });

  test('limit boundary: the 12th ranked workspace subscribes and the 13th is '
      'taken off; a tail overtake evicts the non-running 12th (R1)', () async {
    h.limit = 12;
    h.rows = [
      for (var i = 0; i < 13; i++) task('t-w$i', '/repo/w$i', 1300 - i),
    ];
    h.manager.reconcile();
    await settle();
    expect(
      [for (final (key, _) in h.subscribeCalls) key],
      [for (var i = 0; i < 12; i++) '/repo/w$i'],
      reason: 'newest first, capped at 12; the 13th (w12) never subscribes',
    );
    expect(h.manager.indexes.keys.toSet(),
        {for (var i = 0; i < 12; i++) '/repo/w$i'});

    // The 13th overtakes the newest slot: the workspace that falls to rank
    // 13 has no running row, so the normal eviction applies.
    h.rows[12] = task('t-w12', '/repo/w12', 2000);
    h.manager.reconcile();
    await settle();
    expect([for (final (key, _) in h.subscribeCalls) key], hasLength(13));
    expect(h.disposed, contains('/repo/w11'));
    expect(h.manager.indexes.containsKey('/repo/w11'), isFalse,
        reason: 'rank 13 without a running row is taken off');
    expect(h.manager.indexes.keys.toSet(), {
      for (var i = 0; i < 11; i++) '/repo/w$i',
      '/repo/w12',
    });
  });

  test('equal updatedAt ranks by key lexicographic order: the 12/13 boundary '
      'is deterministic (R1 tie-break)', () async {
    h.limit = 12;
    // 13 candidates tied on updatedAt, supplied in REVERSE key order: the
    // relay row order (List.sort is unstable and _latestByKey keeps the
    // first row per key) must not decide the contested 12th slot.
    h.rows = [
      for (var code = 'm'.codeUnitAt(0); code >= 'a'.codeUnitAt(0); code--)
        task('t-${String.fromCharCode(code)}',
            '/repo/${String.fromCharCode(code)}', 500),
    ];
    h.manager.reconcile();
    await settle();
    expect(
      [for (final (key, _) in h.subscribeCalls) key],
      [
        for (var code = 'a'.codeUnitAt(0); code <= 'l'.codeUnitAt(0); code++)
          '/repo/${String.fromCharCode(code)}',
      ],
      reason: 'ties resolve on the key in ascending lexicographic order, so '
          'the same 12 always win regardless of relay row order',
    );
    expect(h.manager.indexes.containsKey('/repo/m'), isFalse,
        reason: 'the lexicographically last key loses the only contested '
            'slot');
    expect(h.subscribeCalls, hasLength(12));
  });

  test('limit boundary: a 13th-ranked running row keeps its layer until the '
      'run ends (R1 + running slot)', () async {
    h.limit = 12;
    List<Map<String, dynamic>> overview(int w10Activity) => [
          task('t-b', '/repo/b', 2000),
          for (var i = 0; i < 10; i++)
            task('t-w$i', '/repo/w$i', 1900 - i * 100),
          task('t-w10', '/repo/w10', w10Activity),
          task('t-n', '/repo/n', 800),
        ];
    h.rows = overview(900);
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/w10'), isTrue,
        reason: 'w10 is rank 12 among the 13 candidates');
    expect(h.manager.indexes.containsKey('/repo/n'), isFalse);

    void frame(String phase) =>
        h.states['/repo/w10']!.applyFrame({
              'toSeq': 1,
              'payload': {
                'kind': 'snapshot',
                'snapshot': {
                  'workspaceId': 'ws-w10',
                  'sessions': [
                    {
                      'sessionId': 't-w10',
                      'title': 'live-t-w10',
                      'phase': phase,
                    },
                  ],
                },
              },
            }, onGap: () {});
    frame('running');

    // w10's activity drops to 100 so it falls below the ranked ceiling;
    // /repo/n (still 800) takes the freed rank-12 slot, and the running row
    // keeps its layer past the ranked ceiling.
    h.rows = overview(100);
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/w10'), isTrue,
        reason: 'dropping a running row would flip it back to the relay '
            'last-turn outcome (false completion)');
    expect(h.manager.indexes.containsKey('/repo/n'), isTrue,
        reason: 'the 13th-ranked entrant subscribes');
    expect(h.disposed, isNot(contains('/repo/w10')));

    // The run ends; the next reconcile retires the extra layer.
    frame('completedSuccess');
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/w10'), isFalse);
  });

  test('aliases normalize candidate keys (identity spelling → path key)',
      () async {
    h.rows = [task('t1', '/repo/b', 100, identity: '/repo/b-id')];
    h.aliases = {'/repo/b-id': '/repo/b'};
    h.manager.reconcile();
    await settle();
    expect([for (final (key, _) in h.subscribeCalls) key], ['/repo/b']);
  });

  test('in-flight dedup: overlapping reconciles start one subscribe per key',
      () async {
    h.rows = [task('t1', '/repo/b', 100), task('t2', '/repo/c', 90)];
    h.gate = Completer<void>();
    h.manager.reconcile();
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2));
    h.gate!.complete();
    await settle();
    expect(h.manager.indexes.keys.toSet(), {'/repo/b', '/repo/c'});
  });

  test('candidate recheck after the await drops a key that left the set',
      () async {
    h.rows = [task('t1', '/repo/b', 100), task('t2', '/repo/c', 90)];
    h.limit = 1;
    h.gate = Completer<void>();
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(1));
    // /repo/c overtakes /repo/b while the subscribe is in flight.
    h.rows = [task('t1', '/repo/b', 100), task('t2', '/repo/c', 200)];
    h.gate!.complete();
    await settle();
    expect(h.disposed, contains('/repo/b'));
    expect(h.manager.indexes.containsKey('/repo/b'), isFalse);
    expect(h.logs.join('\n'), contains('left the set while subscribing'));
  });

  test('cold runtime: cooldown blocks retries, expiry retries once, a set '
      'change clears the window', () async {
    h.cooldown = const Duration(minutes: 10);
    h.coldRuntime = true;
    // Clock-relative relay timestamps (relay epoch ms, same domain as the
    // 2026 harness clock): the old 100/200 values were 1970 rows paired with
    // a 2026 clock — assertions passed on the number ordering alone.
    final base = h.now.millisecondsSinceEpoch;
    h.rows = [task('t1', '/repo/b', base - 60000)];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(1));
    expect(h.logs.join('\n'), contains('cold runtime, cooling down 10min'));

    // Same set, same row activity — still cooling down.
    h.now = h.now.add(const Duration(minutes: 5));
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(1));

    // Window expiry retries once.
    h.now = h.now.add(const Duration(minutes: 6));
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2));

    // A set change clears the (fresh) cooldown.
    h.rows = const [];
    h.manager.reconcile();
    h.rows = [task('t1', '/repo/b', base - 30000)];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(3));
  });

  test('a running row keeps its workspace layer after falling out of the '
      'top-N until the run ends', () async {
    h.limit = 2;
    List<Map<String, dynamic>> overview(int bActivity) => [
          task('t-b', '/repo/b', bActivity),
          task('t-c', '/repo/c', bActivity == 100 ? 50 : 600),
          task('t-d', '/repo/d', 500),
          task('t-e', '/repo/e', 400),
        ];
    h.rows = overview(700);
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/b'), isTrue);

    void frame(String phase) => h.states['/repo/b']!.applyFrame({
          'toSeq': 1,
          'payload': {
            'kind': 'snapshot',
            'snapshot': {
              'workspaceId': 'ws-b',
              'sessions': [
                {'sessionId': 't-b', 'title': 'live-t-b', 'phase': phase},
              ],
            },
          },
        }, onGap: () {});
    frame('running');
    // /repo/d overtakes /repo/b.
    h.rows = overview(100);
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/b'), isTrue,
        reason: 'dropping a running row would flip it back to the relay '
            'last-turn outcome (false completion)');
    expect(h.manager.indexes.containsKey('/repo/c'), isFalse,
        reason: 'the non-running tail leaves the set');

    // The run ends; the next reconcile retires the extra layer.
    frame('completedSuccess');
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/b'), isFalse);
  });

  test('becoming the ACTIVE workspace drops the layer even while running',
      () async {
    h.rows = [task('t-b', '/repo/b', 100)];
    h.manager.reconcile();
    await settle();
    h.states['/repo/b']!.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'workspaceId': 'ws-b',
          'sessions': [
            {'sessionId': 't-b', 'title': 'live-t-b', 'phase': 'running'},
          ],
        },
      },
    }, onGap: () {});
    h.active = '/repo/b';
    h.manager.reconcile();
    await settle();
    expect(h.disposed, contains('/repo/b'));
    expect(h.manager.indexes, isEmpty,
        reason: 'the active index covers the same rows');
  });

  test('resubscribe failure hook: cold runtime cools down and drops, other '
      'errors keep the built-in retry', () async {
    h.rows = [task('t1', '/repo/b', h.now.millisecondsSinceEpoch - 60000)];
    h.coldRuntime = false;
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/b'), isTrue);
    final failure = h.failures['/repo/b']!;

    failure(ChannelRpcError('bridge blip', null));
    await settle();
    expect(h.disposed, isEmpty, reason: 'only cold runtime is classified');

    failure(ChannelRpcError('ZCode Agent runtime is not running', null));
    await settle();
    expect(h.disposed, contains('/repo/b'));
    expect(h.manager.indexes.containsKey('/repo/b'), isFalse);
    expect(h.changed, greaterThanOrEqualTo(2),
        reason: 'subscribe install + cold drop each notify once');
    expect(h.logs.join('\n'), contains('cold runtime on resubscribe'));
  });

  // ---- 11-02 §2: cooldown = deadline OR newer relay activity ----
  test('cooldown lifted by newer relay activity (subscribe refusal): one '
      'retry; an unchanged row stays blocked', () async {
    h.coldRuntime = true;
    final base = h.now.millisecondsSinceEpoch;
    h.rows = [task('t1', '/repo/b', base - 60000)];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(1));

    // Same relay row: the watermark holds — a fake unlock must not retry.
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(1),
        reason: 'unchanged updatedAt = no new activity = the deadline rules');

    // The desktop touched the row after the cooldown: retry right away.
    h.coldRuntime = false;
    h.rows = [task('t1', '/repo/b', base - 30000)];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2),
        reason: 'newer updatedAt than the stored watermark lifts the cooldown');
    expect(h.manager.indexes.containsKey('/repo/b'), isTrue);
  });

  test('cooldown lifted by newer relay activity (resubscribe failure): one '
      'retry; an unchanged row stays blocked', () async {
    final base = h.now.millisecondsSinceEpoch;
    h.rows = [task('t1', '/repo/b', base - 60000)];
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/b'), isTrue);

    h.failures['/repo/b']!(
      ChannelRpcError('ZCode Agent runtime is not running', null),
    );
    await settle();
    expect(h.manager.indexes.containsKey('/repo/b'), isFalse);
    expect(h.disposed, contains('/repo/b'));

    // Same relay row: the cooldown still blocks the resubscribe.
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(1),
        reason: 'the resubscribe-failure write point records the same '
            'watermark semantics');

    // Newer row activity: the workspace resubscribes before the deadline.
    h.rows = [task('t1', '/repo/b', base - 10000)];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2));
    expect(h.manager.indexes.containsKey('/repo/b'), isTrue);
  });

  test('a cooldown key falling out of the desired set clears the cooldown; '
      're-entry starts a fresh window', () async {
    h.limit = 1;
    h.coldRuntime = true;
    final base = h.now.millisecondsSinceEpoch;
    h.rows = [task('t-b', '/repo/b', base - 60000)];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(1));

    // A newer workspace takes the only slot: /repo/b leaves `desired`, so
    // its cooldown + watermark are pruned (pre-existing set-change rule).
    h.rows = [
      task('t-b', '/repo/b', base - 60000),
      task('t-c', '/repo/c', base - 30000),
    ];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2));

    // /repo/b re-enters inside the old 10-minute window: the pruned
    // cooldown no longer blocks, so it starts over immediately.
    h.rows = [
      task('t-b', '/repo/b', base - 20000),
      task('t-c', '/repo/c', base - 30000),
    ];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(3),
        reason: 're-entering the set starts a new cooldown window');
  });

  test('restart-scan row refresh: one retry then a fresh watermark — the '
      'retry loop stays bounded', () async {
    h.coldRuntime = true;
    final base = h.now.millisecondsSinceEpoch;
    h.rows = [task('t1', '/repo/b', base - 60000)];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(1));

    // A desktop restart scan touches the row: one benign retry, refused
    // again (the runtime is still cold).
    h.rows = [task('t1', '/repo/b', base - 30000)];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2));

    // The refreshed row is now the watermark of the NEW cooldown: later
    // cadences with the same activity stay blocked — bounded, no cycle.
    h.manager.reconcile();
    await settle();
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2),
        reason: 'each refusal re-records the current watermark, so a restart '
            'scan costs one retry, not an open retry loop');
  });

  test('tombstone probe writes deletedTaskIds and notifies once; a replaced '
      'layer ignores the late answer', () async {
    h.rows = [task('t1', '/repo/b', 100)];
    h.probeResults = {
      '/repo/b': {'gone'},
    };
    h.manager.reconcile();
    await settle();
    expect(h.states['/repo/b']!.deletedTaskIds, {'gone'});
    expect(h.changed, 2, reason: 'subscribe + probe write');

    // A late probe for a dropped layer must not touch anything.
    h.probeResults = const {};
    h.probeGate = Completer<void>();
    h.rows = [task('t2', '/repo/c', 100)];
    h.manager.reconcile();
    await settle();
    final before = h.changed;
    h.manager.disposeAll();
    await settle();
    h.probeGate!.complete();
    await settle();
    expect(h.changed, before,
        reason: 'disposeAll is silent and the stale probe is dropped');
  });

  test('available() false starts nothing; disposeAll is silent and clears '
      'indexes', () async {
    h.available = false;
    h.rows = [task('t1', '/repo/b', 100)];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, isEmpty);

    h.available = true;
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.keys, ['/repo/b']);
    final changed = h.changed;
    h.manager.disposeAll();
    expect(h.disposed, ['/repo/b']);
    expect(h.manager.indexes, isEmpty);
    expect(h.changed, changed, reason: 'teardown must not notify');
    expect(h.logs.join('\n'), contains('sidecars cleared (1)'));

    // A freshly entered key still subscribes at once after disposeAll.
    h.coldRuntime = true;
    h.rows = [task('t2', '/repo/c', 200)];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2));
  });

  // ---- 11-02 §3: workspace-switch carry-over (stale layers) ----
  Map<String, dynamic> frame(
    String phase, {
    String id = 't-b',
  }) =>
      {
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': 'ws-b',
            'sessions': [
              {'sessionId': id, 'title': 'live-$id', 'phase': phase},
            ],
          },
        },
      };

  test('detach keeps the layer as stale; reconcile re-subscribes and only a '
      'ready fresh frame replaces it (P1-1/P2-3)', () async {
    h.rows = [task('t1', '/repo/b', 100)];
    h.manager.reconcile();
    await settle();
    final stale = h.manager.indexes['/repo/b']!;
    stale.applyFrame(frame('running'), onGap: () {});
    expect(h.manager.readinessByWorkspace['/repo/b'], isTrue);

    final changedAfterInstall = h.changed;
    h.manager.detachAll();
    expect(h.manager.indexes['/repo/b'], same(stale));
    expect(h.manager.readinessByWorkspace['/repo/b'], isTrue,
        reason: 'ready carry-over data keeps reporting ready (readiness zero '
            'change, P2-5)');
    expect(h.changed, changedAfterInstall, reason: 'detach is silent');

    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2),
        reason: 'a stale key counts as NOT installed — the wire must be '
            're-subscribed on the new bridge (P1-1 regression lock)');
    expect(h.manager.indexes['/repo/b'], same(stale),
        reason: 'an ack alone must not replace the carry-over data (P2-3)');

    final fresh = h.states['/repo/b']!;
    expect(fresh, isNot(same(stale)));
    fresh.applyFrame(frame('completedSuccess'), onGap: () {});
    expect(h.manager.indexes['/repo/b'], same(fresh),
        reason: 'the first ready frame replaces the stale layer');
    expect(h.logs.join('\n'), contains('stale layer replaced'));

    // The stale mark is gone: a later TTL sweep keeps the fresh layer.
    h.now = h.now.add(const Duration(minutes: 2));
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes['/repo/b'], same(fresh));
    expect(h.subscribeCalls, hasLength(2));
  });

  test('a cold refusal against a stale key keeps the carry-over layer '
      '(fresh wire dies, stale serves until TTL)', () async {
    h.cooldown = const Duration(minutes: 10);
    final base = h.now.millisecondsSinceEpoch;
    h.rows = [task('t1', '/repo/b', base - 60000)];
    h.manager.reconcile();
    await settle();
    final stale = h.manager.indexes['/repo/b']!;
    stale.applyFrame(frame('running'), onGap: () {});

    h.manager.detachAll();

    // Fresh subscribe lands on the new bridge (state pending, stale still
    // serving), then its resubscribe hook reports a cold runtime: the
    // refusal must drop the WIRE only — dropping the state would reopen
    // the phase-regression window the carry-over just closed.
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2),
        reason: 'stale counts as not installed — a fresh wire is attempted');
    h.failures['/repo/b']!(
      ChannelRpcError('ZCode Agent runtime is not running', null),
    );
    await settle();
    expect(h.manager.indexes['/repo/b'], same(stale),
        reason: 'the refusal drops the wire, not the carry-over data');
    expect(h.disposed, contains('/repo/b'),
        reason: 'the fresh wire itself IS disposed — only the layer data '
            'survives for the merge');
    expect(h.manager.readinessByWorkspace['/repo/b'], isTrue,
        reason: 'the running row keeps serving from the stale layer');
    expect(h.logs.join('\n'), contains('cold runtime on resubscribe'));

    // The cooldown was written: the same watermark does not burn retries.
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2));
  });

  test('seedStale accepts only ready states and rewrites the subscription '
      'identity to the canonical key (P2-5/P3-9)', () async {
    final notReady = SessionsIndexState();
    h.manager.seedStale('/repo/b', notReady, now: h.now);
    expect(h.manager.indexes, isEmpty,
        reason: 'an unsnapshotted state has nothing to carry and would paint '
            'a fake empty card');
    expect(h.manager.readinessByWorkspace, isEmpty);
    expect(h.changed, 0);

    final ready = SessionsIndexState()
      ..subscribedWorkspaceKey = '/repo/raw-b';
    ready.applyFrame(frame('running'), onGap: () {});
    h.manager.seedStale('/repo/b', ready, now: h.now);
    expect(h.manager.indexes['/repo/b'], same(ready));
    expect(ready.subscribedWorkspaceKey, '/repo/b',
        reason: 'the open path records the raw active key; the manager map '
            'key is the normalized spelling (P3-9)');
    expect(h.manager.readinessByWorkspace['/repo/b'], isTrue);
    expect(h.changed, 0, reason: 'seeding rides the switch path notify');
  });

  test('stale TTL retires the layer through the drop path (repaint), and '
      'disposeAll clears stale carry-over too', () async {
    h.staleTtl = const Duration(seconds: 30);
    h.rows = [task('t1', '/repo/b', 100)];
    h.manager.reconcile();
    await settle();
    h.manager.indexes['/repo/b']!.applyFrame(
      frame('completedSuccess'),
      onGap: () {},
    );
    final changed = h.changed;
    h.manager.detachAll();
    expect(h.manager.indexes, contains('/repo/b'));

    h.now = h.now.add(const Duration(seconds: 31));
    h.available = false; // isolate the TTL sweep from re-subscription
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes, isEmpty);
    expect(h.manager.readinessByWorkspace, isEmpty);
    expect(h.changed, greaterThan(changed),
        reason: 'TTL removal goes through _drop, so the list repaints '
            '(P3-11)');
    expect(h.logs.join('\n'), contains('stale TTL expired'));

    // detachAll keeps the data, disposeAll (suspend/dispose) does not.
    h.available = true;
    h.now = h.now.add(const Duration(seconds: 61));
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes, contains('/repo/b'));
    h.manager.detachAll();
    expect(h.manager.indexes, contains('/repo/b'));
    h.manager.disposeAll();
    expect(h.manager.indexes, isEmpty);
    expect(h.manager.readinessByWorkspace, isEmpty);
  });

  test('a stale layer with a running row stays desired beyond the top-N and '
      'survives TTL (P2-4 regression lock)', () async {
    h.limit = 1;
    h.rows = [task('t-b', '/repo/b', 700)];
    h.manager.reconcile();
    await settle();
    final stale = h.manager.indexes['/repo/b']!;
    stale.applyFrame(frame('running'), onGap: () {});
    h.manager.detachAll();

    // A newer workspace takes the only ranked slot: /repo/b is stale and
    // out of the top-N, but its run is still live.
    h.rows = [
      task('t-c', '/repo/c', 900),
      task('t-b', '/repo/b', 700),
    ];
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/b'), isTrue,
        reason: 'eviction must not flip a running row to the relay outcome');
    expect([for (final (key, _) in h.subscribeCalls) key],
        containsAll(<String>['/repo/c', '/repo/b']),
        reason: 'the stale-running key is desired, so it re-subscribes');

    h.now = h.now.add(const Duration(minutes: 2));
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/b'), isTrue,
        reason: 'TTL must not clear a frozen running row (P2-4)');

    // The run ends; the layer is already past its TTL (2min > 60s), so the
    // exemption is gone and the next sweep retires it through the TTL path.
    stale.applyFrame(frame('completedSuccess'), onGap: () {});
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/b'), isFalse);
  });

  test('the running-row TTL exemption has a hard cap: a stale running layer '
      'that never resubscribes drops at the cap (check P2-1)', () async {
    h.limit = 1;
    h.staleTtl = const Duration(seconds: 30);
    h.staleRunningCap = const Duration(minutes: 5);
    h.rows = [task('t-b', '/repo/b', 700)];
    h.manager.reconcile();
    await settle();
    h.manager.indexes['/repo/b']!.applyFrame(
      frame('running'),
      onGap: () {},
    );
    h.manager.detachAll();
    // Freeze resubscription from here: the stale layer never refreshes.
    h.available = false;

    // Past the TTL but inside the cap: the running layer stays (P2-4).
    h.now = h.now.add(const Duration(minutes: 1));
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/b'), isTrue,
        reason: 'inside the cap the running exemption holds');

    // Past the cap: the layer drops — the run must have ended (a live run
    // implies a warm runtime, which implies the resubscribe would have
    // succeeded), so the relay fallback is the real terminal state.
    final changed = h.changed;
    h.now = h.now.add(const Duration(minutes: 5));
    h.manager.reconcile();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/b'), isFalse);
    expect(h.changed, greaterThan(changed),
        reason: 'the capped drop repaints (drop path)');
    expect(h.logs.join('\n'), contains('stale TTL expired'));
  });

  test('teardown clears the in-flight set: reconcile re-subscribes at once '
      'and the late first continuation is disposed, not installed', () async {
    h.rows = [task('t1', '/repo/b', 100)];
    h.gate = Completer<void>();
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(1));

    h.manager.detachAll();
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2),
        reason: 'waiting for the dead bridge\'s 60s ack timeout would keep '
            'the key un-subscribable');

    h.gate!.complete();
    await settle();
    expect(h.manager.indexes.containsKey('/repo/b'), isTrue,
        reason: 'the post-switch attempt installs the layer');
    expect(h.disposed, contains('/repo/b'),
        reason: 'the pre-switch continuation disposed its wire via the '
            'teardown epoch guard');
  });

  test('teardown keeps the cooldown + watermark (a bridge swing is not a '
      'policy change)', () async {
    h.coldRuntime = true;
    final base = h.now.millisecondsSinceEpoch;
    h.rows = [task('t1', '/repo/b', base - 60000)];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(1));

    h.manager.detachAll();
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(1),
        reason: 'the same-row cooldown still gates the new bridge');

    h.manager.disposeAll();
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(1),
        reason: 'suspend teardown keeps the runtime cooldown too');
  });
}

class _Harness {
  final List<(String, Map<String, dynamic>)> subscribeCalls = [];
  final List<String> disposed = [];
  final Map<String, SessionsIndexState> states = {};
  final Map<String, void Function(Object)> failures = {};
  final List<String> logs = [];

  List<Map<String, dynamic>> rows = const [];
  Map<String, String> aliases = const {};
  String? active;
  bool available = true;
  bool disposedFlag = false;
  bool coldRuntime = false;
  int changed = 0;
  int limit = 12; // mirrors DeviceSession.sidecarWorkspaceLimit (R1)
  Duration cooldown = const Duration(minutes: 10);
  Duration staleTtl = const Duration(seconds: 60);
  Duration staleRunningCap = const Duration(minutes: 10);
  DateTime now = DateTime(2026, 10, 29, 12);
  Future<void>? get gateFuture => gate?.future;
  Future<void>? get probeGateFuture => probeGate?.future;
  Completer<void>? gate;
  Completer<void>? probeGate;
  Map<String, Set<String>> probeResults = const {};

  late final SidecarIndexManager manager = SidecarIndexManager(
    subscribe: (key, scope, onSubscribeFailure) async {
      subscribeCalls.add((key, scope));
      failures[key] = onSubscribeFailure;
      final g = gateFuture;
      if (g != null) await g;
      if (coldRuntime) {
        throw ChannelRpcError(
          'ZCode Agent runtime is not running for workspace '
          '${scope['workspacePath']}',
          null,
        );
      }
      return states[key] ??= SessionsIndexState();
    },
    dispose: (key) async {
      disposed.add(key);
      states.remove(key);
    },
    available: () => available,
    probeDeleted: (scope) async {
      final g = probeGateFuture;
      if (g != null) await g;
      return probeResults[scope['workspacePath']];
    },
    relayRows: () => rows,
    activeKey: () => active,
    normalizeKey: (raw) => aliases[raw] ?? raw,
    onChanged: () => changed++,
    isDisposed: () => disposedFlag,
    log: logs.add,
    limit: limit,
    cooldown: cooldown,
    clock: () => now,
    staleTtl: staleTtl,
    staleRunningCap: staleRunningCap,
  );
}
