import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';

/// Millisecond-level timings (stall_test pattern: real delays, no fake
/// clock); the list watchdog is parked far out of the way.
const StallTimings fastTimings = StallTimings(
  healthyWaitTimeout: Duration(milliseconds: 40),
  rpcTimeout: Duration(milliseconds: 70),
  dialTimeout: Duration(milliseconds: 60),
  listReadyTimeout: Duration(seconds: 300),
  minRebuildInterval: Duration(milliseconds: 5),
  retryBackoff: Duration(milliseconds: 60),
);

/// Client stub recording `bootstrap` / `openBridge`: refreshTaskOverview
/// must ride bootstrap ONLY — an openWorkspace (bridge churn) interrupts
/// the live sessions-index subscription, exactly what the method exists to
/// avoid (Addendum 3).
class OverviewStubClient extends RemoteClient {
  OverviewStubClient(super.params);

  bool failBootstrap = false;

  /// When set, bootstrap parks on this completer (concurrency dedup test).
  Completer<Map<String, dynamic>>? hangBootstrap;
  int bootstrapCalls = 0;
  int openBridgeCalls = 0;

  Map<String, dynamic> bootstrapResult = {
    'workspaces': [
      {'workspacePath': '/repo', 'workspaceIdentity': 'repo-id'},
    ],
    'tasks': [
      {
        'taskId': 't1',
        'title': 'first',
        'workspacePath': '/repo',
        'workspaceIdentity': 'repo-id',
        'displayStatus': 'idle',
        'updatedAt': 1,
      },
    ],
  };

  @override
  Future<void> connect() => Future.value();

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() {
    bootstrapCalls += 1;
    final hang = hangBootstrap;
    if (hang != null) return hang.future;
    if (failBootstrap) throw StateError('bootstrap exploded');
    return Future.value(bootstrapResult);
  }

  @override
  Future<BridgeSession> openBridge(
    String workspaceKey, {
    String? taskId,
    Map<String, dynamic>? project,
    String? taskHostId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    openBridgeCalls += 1;
    throw StateError('openBridge is not expected in this test');
  }

  @override
  Future<void> dispose() => Future.value();
}

RemoteConnectionParams paramsOf() => RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
    )!;

Future<void> until(bool Function() condition,
        {int maxMs = 2500, String? because}) =>
    () async {
      var waited = 0;
      while (!condition()) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        waited += 10;
        if (waited > maxMs) break;
      }
      if (because != null && !condition()) {
        fail('condition not met within ${maxMs}ms: $because');
      }
    }();

Map<String, dynamic> overviewStubResult(String path, String id, String task) =>
    {
      'workspaces': [
        {'workspacePath': path, 'workspaceIdentity': id},
      ],
      'tasks': [
        {
          'taskId': task,
          'title': task,
          'workspacePath': path,
          'workspaceIdentity': id,
          'displayStatus': 'idle',
          'updatedAt': 2,
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Connected session served by [stub] (connect's auto-open fails on the
  /// stub's openBridge by design — the refresh tests only need `connected`;
  /// the failed open leaves an error string behind, so failure assertions
  /// match on the bootstrap message, not on `error == null`).
  ///
  /// [overviewRefreshThrottle] defaults to zero — the leg tests drive rounds
  /// back to back; the throttle has its own test below.
  Future<DeviceSession> connectSession(
    OverviewStubClient stub, {
    Duration overviewRefreshThrottle = Duration.zero,
  }) async {
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () => stub,
      overviewRefreshThrottle: overviewRefreshThrottle,
    );
    unawaited(session.connect());
    await until(() => session.status == DeviceStatus.connected,
        because: 'session must reach connected');
    stub.openBridgeCalls = 0; // forget connect's auto-open attempt
    return session;
  }

  test('refreshTaskOverview updates workspaces and relay tasks via '
      'bootstrap only — never openWorkspace', () async {
    final stub = OverviewStubClient(paramsOf());
    final session = await connectSession(stub);

    stub.bootstrapResult = overviewStubResult('/repo2', 'repo2-id', 't2');
    await session.refreshTaskOverview();

    expect(stub.openBridgeCalls, 0,
        reason: 'the refresh must not churn bridges or live subscriptions');
    expect(session.workspaces.single['workspacePath'], '/repo2');
    expect(session.relayTasks.single['taskId'], 't2');
    expect(session.status, DeviceStatus.connected);
    await session.dispose();
  });

  test('a failing refresh keeps the old values, stays soft and never '
      'escalates into a rebuild', () async {
    var created = 0;
    final stub = OverviewStubClient(paramsOf());
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () {
        created += 1;
        return stub;
      },
      overviewRefreshThrottle: Duration.zero,
    );
    unawaited(session.connect());
    await until(() => session.status == DeviceStatus.connected,
        because: 'session must reach connected');
    final clientsBefore = created;

    stub.failBootstrap = true;
    await session.refreshTaskOverview();
    await session.refreshTaskOverview(); // reloadTasks would rebuild here

    expect(session.workspaces.single['workspacePath'], '/repo',
        reason: 'the failed refresh must keep the old overview');
    expect(session.relayTasks.single['taskId'], 't1');
    expect(session.error, isNot(contains('bootstrap exploded')),
        reason: 'the silent refresh must not surface an error banner');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(created, clientsBefore,
        reason: 'repeated refresh failures must not rebuild the link');
    await session.dispose();
  });

  test('a call landing on an in-flight round waits it out, then re-dials '
      '(anti-swallow: the old round was built from stale state)', () async {
    final stub = OverviewStubClient(paramsOf());
    final session = await connectSession(stub);
    final bootstrapsBefore = stub.bootstrapCalls;

    stub.hangBootstrap = Completer<Map<String, dynamic>>();
    final f1 = session.refreshTaskOverview();
    final f2 = session.refreshTaskOverview();
    expect(stub.bootstrapCalls, bootstrapsBefore + 1,
        reason: 'the second call must not stack a dial while the round is '
            'still in flight — it waits the stale round out first');

    // Let the second round dial fresh once the parked one settles.
    final hang = stub.hangBootstrap!;
    stub.hangBootstrap = null;
    stub.bootstrapResult = overviewStubResult('/repo2', 'i2', 't2');
    hang.complete(overviewStubResult('/repo2', 'i2', 't2'));
    await Future.wait([f1, f2]);
    expect(stub.bootstrapCalls, bootstrapsBefore + 2,
        reason: 'the second call re-dials instead of joining the stale round '
            '(a create landing mid-refresh must not be swallowed)');
    expect(session.workspaces.single['workspacePath'], '/repo2');
    await session.dispose();
  });

  test('a trigger inside the throttle window joins the round just finished',
      () async {
    final stub = OverviewStubClient(paramsOf());
    final session = await connectSession(
      stub,
      overviewRefreshThrottle: const Duration(minutes: 5),
    );
    final bootstrapsBefore = stub.bootstrapCalls;

    await session.refreshTaskOverview();
    await session.refreshTaskOverview();
    expect(stub.bootstrapCalls, bootstrapsBefore + 1,
        reason: 'the second trigger inside the throttle window must not dial '
            'another three-leg round');
    await session.dispose();
  });

  test('bypassThrottle: a user-action trigger inside the window still waits '
      'the stale round out and then re-dials', () async {
    final stub = OverviewStubClient(paramsOf());
    final session = await connectSession(
      stub,
      overviewRefreshThrottle: const Duration(minutes: 5),
    );
    final bootstrapsBefore = stub.bootstrapCalls;

    // A cadence round parks mid-flight; the create/turn-terminal trigger then
    // lands inside the throttle window. The bypass must neither join the
    // stale round nor stack a dial before it settles.
    stub.hangBootstrap = Completer<Map<String, dynamic>>();
    final cadence = session.refreshTaskOverview();
    final userTrigger = session.refreshTaskOverview(bypassThrottle: true);
    expect(stub.bootstrapCalls, bootstrapsBefore + 1,
        reason: 'the anti-swallow wait is not weakened by the bypass');

    final hang = stub.hangBootstrap!;
    stub.hangBootstrap = null;
    stub.bootstrapResult = overviewStubResult('/repo2', 'i2', 't2');
    hang.complete(overviewStubResult('/repo2', 'i2', 't2'));
    await Future.wait([cadence, userTrigger]);
    expect(stub.bootstrapCalls, bootstrapsBefore + 2,
        reason: 'the bypass re-dials after the stale round settles — the '
            'create row must never be swallowed by a cadence window');
    expect(session.workspaces.single['workspacePath'], '/repo2',
        reason: 'the new round carries the fresh answer');

    // The bypass advances the throttle anchor: a NON-bypass call right after
    // it is throttled again (stable semantics for the 30 s cadence).
    await session.refreshTaskOverview();
    expect(stub.bootstrapCalls, bootstrapsBefore + 2,
        reason: 'the window restarts from the latest trigger');
    await session.dispose();
  });

  test('a session without a client returns immediately (no bootstrap)',
      () async {
    final stub = OverviewStubClient(paramsOf());
    final session = DeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      timings: fastTimings,
      clientFactory: () => stub,
      overviewRefreshThrottle: Duration.zero,
    );
    await session.refreshTaskOverview();
    expect(stub.bootstrapCalls, 0);
    await session.dispose();
  });
}
