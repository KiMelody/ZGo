import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';

import '../helpers/fake_device_session.dart';

/// Sidecar sessions-index subscriptions (design 10-28): the DeviceSession
/// manager that keeps recently active NON-active workspaces live, diffs the
/// set on every relay overview landing, and degrades a cold runtime
/// benignly. TaskDirectory's merge rules live in task_directory_test.dart.
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.16.2',
  )!;

  const activeWs = {'workspacePath': '/repo/active'};
  const wsB = {'workspacePath': '/repo/b'};
  const wsC = {'workspacePath': '/repo/c'};
  const wsD = {'workspacePath': '/repo/d'};
  const wsE = {'workspacePath': '/repo/e'};
  const wsF = {'workspacePath': '/repo/f'};
  const wsG = {'workspacePath': '/repo/g'};

  Map<String, dynamic> task(String id, String path, int updatedAt) => {
        'taskId': id,
        'title': id,
        'workspacePath': path,
        'updatedAt': updatedAt,
        'displayStatus': 'completed',
      };

  FakeDeviceSession session({
    Duration cooldown = const Duration(minutes: 10),
  }) =>
      FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        workspaces: [activeWs, wsB, wsC, wsD, wsE, wsF, wsG],
        sidecarCooldown: cooldown,
      );

  /// Lets the unawaited subscribe futures (and the fake's async seam)
  /// settle.
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('the set is the top-5 non-active workspaces by newest relay row — the '
      'active workspace and the tail never subscribe', () async {
    final s = session();
    s.applyRelayOverview([
      task('t-active', '/repo/active', 700),
      task('t-b', '/repo/b', 600),
      task('t-c', '/repo/c', 500),
      task('t-d', '/repo/d', 400),
      task('t-e', '/repo/e', 300),
      task('t-f', '/repo/f', 200),
      task('t-g', '/repo/g', 100),
    ]);
    await settle();
    expect(
      [for (final (key, _) in s.sidecarSubscribeCalls) key],
      ['/repo/b', '/repo/c', '/repo/d', '/repo/e', '/repo/f'],
      reason: 'newest first, capped at 5, active workspace excluded',
    );
    // The subscribe scope is the row's own workspace (same shape as the
    // live-probed cross-workspace subscribe).
    expect(s.sidecarSubscribeCalls.first.$2, {
      'workspacePath': '/repo/b',
    });
    // The manager records the subscription identity on each state, which is
    // what the merge layer falls back to for attribution.
    expect(s.sidecarStates['/repo/b']!.subscribedWorkspaceKey, '/repo/b');
    // The active workspace's row never becomes a sidecar.
    expect(
      [for (final (key, _) in s.sidecarSubscribeCalls) key],
      isNot(contains('/repo/active')),
    );
  });

  test('a workspace that becomes the ACTIVE one drops out of the set and its '
      'rows fall back to the relay layer', () async {
    final s = session();
    s.applyRelayOverview([
      task('t-b', '/repo/b', 100),
      task('t-c', '/repo/c', 90),
    ]);
    await settle();
    expect(s.sidecarStates.keys.toSet(), {'/repo/b', '/repo/c'});

    // Live row for the non-active workspace shows the real phase.
    s.sidecarStates['/repo/b']!.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'workspaceId': 'ws-b',
          'sessions': [
            {
              'sessionId': 't-b',
              'title': 'live-t-b',
              'phase': 'running',
              'pendingInteraction': {'kind': 'permission'},
            },
          ],
        },
      },
    }, onGap: () {});
    var row = s.taskDirectory.allEntries().singleWhere(
          (e) => e.$1.sessionId == 't-b',
        );
    expect(row.$1.phase, 'running');
    expect(row.$1.pendingInteraction, isNotNull);

    // Opening B as the active workspace (production's openWorkspace ends
    // with a recompute) retires its sidecar subscription.
    await s.openWorkspace(wsB);
    s.sidecarManager.reconcile();
    await settle();
    expect(s.sidecarDisposed, contains('/repo/b'));
    expect(s.taskDirectory.sidecarIndexes.containsKey('/repo/b'), isFalse);
    row = s.taskDirectory.allEntries().singleWhere(
          (e) => e.$1.sessionId == 't-b',
        );
    expect(row.$1.phase, 'completedSuccess',
        reason: 'registry status is the fallback once the sidecar is gone');
    expect(s.taskDirectory.sidecarIndexes.containsKey('/repo/c'), isTrue,
        reason: 'sibling sidecars survive the switch');
  });

  test('cold runtime: the refusal cools the workspace down and never enters '
      'the retry path until the window expires or the set changes', () async {
    final s = session(cooldown: const Duration(milliseconds: 80));
    s.sidecarColdRuntime = true;
    s.applyRelayOverview([task('t-b', '/repo/b', 100)]);
    await settle();
    expect(s.sidecarSubscribeCalls, hasLength(1));

    // Same set, new row activity — still cooling down, no retry.
    s.applyRelayOverview([task('t-b', '/repo/b', 200)]);
    await settle();
    expect(s.sidecarSubscribeCalls, hasLength(1));

    // Window expiry retries once.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    s.sidecarManager.reconcile();
    await settle();
    expect(s.sidecarSubscribeCalls, hasLength(2));

    // A set change clears the (fresh) cooldown: dropping and re-entering
    // the workspace subscribes immediately.
    s.applyRelayOverview([]);
    await settle();
    s.applyRelayOverview([task('t-b', '/repo/b', 300)]);
    await settle();
    expect(s.sidecarSubscribeCalls, hasLength(3));
  });

  test('a sidecar frame notifies the session and surfaces the live row in '
      'the merged directory', () async {
    final s = session();
    s.applyRelayOverview([task('t-b', '/repo/b', 100)]);
    await settle();
    expect(s.taskDirectory.sidecarIndexes.keys, ['/repo/b']);

    var notifies = 0;
    s.addListener(() => notifies++);
    s.sidecarStates['/repo/b']!.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'workspaceId': 'ws-b',
          'sessions': [
            {
              'sessionId': 't-b',
              'title': 'live-t-b',
              'phase': 'running',
            },
          ],
        },
      },
    }, onGap: () {});
    expect(notifies, greaterThan(0));
    final row = s.taskDirectory.allEntries().singleWhere(
          (e) => e.$1.sessionId == 't-b',
        );
    expect(row.$1.phase, 'running');
    expect(row.$2, '/repo/b', reason: 'attribution = the layer key');
  });

  test('suspend tears every sidecar subscription down', () async {
    final s = session();
    s.applyRelayOverview([
      task('t-b', '/repo/b', 100),
      task('t-c', '/repo/c', 90),
    ]);
    await settle();
    expect(s.sidecarStates, hasLength(2));

    await s.suspend();
    expect(s.sidecarDisposed.toSet(), {'/repo/b', '/repo/c'});
    expect(s.sidecarStates, isEmpty);
    expect(s.taskDirectory.sidecarIndexes, isEmpty);
  });

  test('a workspace that leaves the set while its subscribe is in flight is '
      'disposed instead of installed (check P2-2)', () async {
    final s = session();
    final gate = Completer<void>();
    s.sidecarSubscribeGate = gate.future;
    s.applyRelayOverview([
      task('t-b', '/repo/b', 700),
      task('t-c', '/repo/c', 600),
      task('t-d', '/repo/d', 500),
      task('t-e', '/repo/e', 400),
      task('t-f', '/repo/f', 300),
      task('t-g', '/repo/g', 200),
    ]);
    await settle();
    expect(s.sidecarSubscribeCalls, hasLength(5));
    // While every subscribe is parked, /repo/b falls to rank 6 and /repo/g
    // enters the top-5 (its own subscribe starts and parks too).
    s.applyRelayOverview([
      task('t-b', '/repo/b', 100),
      task('t-c', '/repo/c', 600),
      task('t-d', '/repo/d', 500),
      task('t-e', '/repo/e', 400),
      task('t-f', '/repo/f', 300),
      task('t-g', '/repo/g', 200),
    ]);
    await settle();
    expect(s.sidecarSubscribeCalls, hasLength(6));
    gate.complete();
    await settle();
    expect(s.taskDirectory.sidecarIndexes.keys.toSet(),
        {'/repo/c', '/repo/d', '/repo/e', '/repo/f', '/repo/g'});
    expect(s.sidecarDisposed, contains('/repo/b'));
  });

  test('a running row keeps its workspace layer after it falls out of the '
      'top-5, and the drop happens once the run ends (check P2-6)', () async {
    final s = session();
    List<Map<String, dynamic>> overview(int bActivity) => [
          task('t-b', '/repo/b', bActivity),
          task('t-c', '/repo/c', 600),
          task('t-d', '/repo/d', 500),
          task('t-e', '/repo/e', 400),
          task('t-f', '/repo/f', 300),
          task('t-g', '/repo/g', 200),
        ];
    s.applyRelayOverview(overview(700));
    await settle();
    expect(s.taskDirectory.sidecarIndexes.containsKey('/repo/b'), isTrue);

    void frame(String phase) => s.sidecarStates['/repo/b']!.applyFrame({
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
    // A newer relay row in /repo/g pushes /repo/b out of the top-5.
    s.applyRelayOverview(overview(100));
    await settle();
    expect(s.taskDirectory.sidecarIndexes.containsKey('/repo/b'), isTrue,
        reason: 'dropping a running row would flip it back to the relay '
            'last-turn outcome (false completion)');

    // The run ends; the next relay landing retires the extra layer.
    frame('completedSuccess');
    s.applyRelayOverview(overview(100));
    await settle();
    expect(s.taskDirectory.sidecarIndexes.containsKey('/repo/b'), isFalse);
  });
}
