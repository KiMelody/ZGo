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
      'indexes + cooldowns', () async {
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

    // Cooldowns were cleared too: a re-entering key starts at once.
    h.coldRuntime = true;
    h.rows = [task('t2', '/repo/c', 200)];
    h.manager.reconcile();
    await settle();
    expect(h.subscribeCalls, hasLength(2));
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
  int limit = 5;
  Duration cooldown = const Duration(minutes: 10);
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
  );
}
