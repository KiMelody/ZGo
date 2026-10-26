import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/entitlement_poller.dart';

import '../helpers/fake_device_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parsePlanAccess', () {
    test('zai coding-plan id → accountAccess pair', () {
      final plan = DeviceSession.parsePlanAccess(
          'account:zai-individual-coding-plan');
      expect(plan, {
        'providerId': 'account:zai-individual-coding-plan',
        'accountAccess': {
          'type': 'zhipu-account',
          'family': 'zai',
          'planKind': 'individual-coding-plan',
        },
      });
    });

    test('bigmodel family parses', () {
      final plan =
          DeviceSession.parsePlanAccess('account:bigmodel-team-coding-plan');
      expect(plan!['accountAccess'],
          {'type': 'zhipu-account', 'family': 'bigmodel', 'planKind': 'team-coding-plan'});
    });

    test('non-account provider → null', () {
      expect(DeviceSession.parsePlanAccess('openrouter/glm-4.6'), isNull);
      expect(DeviceSession.parsePlanAccess(''), isNull);
    });

    test('account prefix with unknown family → null', () {
      // The family enum is zai|bigmodel; anything else is not a coding-plan
      // route and must fall back, not send a bogus accountAccess.
      expect(DeviceSession.parsePlanAccess('account:claude-max'), isNull);
      expect(DeviceSession.parsePlanAccess('account:zai'), isNull);
    });
  });

  // ------------------------------------------------- entitledPlanAccesses

  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=s&mid=m&name=desk&app_version=3.16.2',
  )!;

  /// One provider-settings `providers[]` account row. Entitlement rides
  /// `effectiveConfig.access.entitled` (or `accountState.access.entitled`
  /// when [viaAccountState] — the parser accepts either).
  Map<String, dynamic> accountProvider(
    String id, {
    required bool entitled,
    bool viaAccountState = false,
  }) =>
      {
        'providerId': id,
        'providerName': id,
        'enabled': true,
        'executable': true,
        'accountState': {
          'access': {
            'type': 'zhipu-account',
            if (viaAccountState) 'entitled': entitled,
          },
        },
        'effectiveConfig': {
          'access': {
            'type': 'zhipu-account',
            if (!viaAccountState) 'entitled': entitled,
          },
        },
        'issues': <Object>[],
        'models': <Object>[],
      };

  Map<String, dynamic> personalProvider(String id, {bool entitled = false}) =>
      {
        'providerId': id,
        'providerName': id,
        'enabled': true,
        'executable': true,
        'personalConfig': {
          'access': {'type': 'api-key'},
        },
        'effectiveConfig': {
          'access': {'type': 'api-key', 'entitled': entitled},
        },
        'issues': <Object>[],
        'models': <Object>[],
      };

  Map<String, dynamic> viewOf(List<Map<String, dynamic>> providers) => {
        'revision': '[1,1]',
        'providerTemplates': <Object>[],
        'providerOrder': <Object>[],
        'providers': providers,
      };

  /// A never-connected session answering channel RPCs from [view] /
  /// [selection]; every call is recorded on `channelCalls`.
  FakeDeviceSession sessionOf({
    Object? view,
    Object? viewError,
    Object? selection,
    Object? selectionError,
    List<Map<String, dynamic>> relayTasks = const [],
  }) {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      relayTasks: relayTasks,
      channelHandler: (channel, method, args) async {
        switch (method) {
          case 'getView':
            if (viewError != null) throw viewError;
            return view;
          case 'getTaskModelSelection':
            if (selectionError != null) throw selectionError;
            return selection;
          case 'getEntitlementSnapshot':
            return <String, dynamic>{
              'authenticated': true,
              'provider': {'id': 'prov-1'},
            };
        }
        return null;
      },
    );
    addTearDown(session.dispose);
    return session;
  }

  Map<String, dynamic> snapshotArgs(FakeDeviceSession session) {
    final call = session.channelCalls.lastWhere(
      (c) => c.$1 == 'usage-stats' && c.$2 == 'getEntitlementSnapshot',
    );
    return call.$3.single as Map<String, dynamic>;
  }

  group('entitledPlanAccesses', () {
    test('keeps only entitled account providers that parse, in view order',
        () async {
      final session = sessionOf(
        view: viewOf([
          personalProvider('personal-gateway', entitled: true),
          accountProvider('account:zai-off-peak', entitled: true),
          accountProvider('account:zai-individual-coding-plan',
              entitled: false),
          accountProvider('account:zai-start-plan',
              entitled: true, viaAccountState: true),
          accountProvider('account:zai-team-coding-plan', entitled: true),
          // Parses onto no known family → not a plan route.
          accountProvider('account:other-plan', entitled: true),
          // No access block at all → not entitled.
          {'providerId': 'account:zai-no-access'},
        ]),
      );

      final plans = await session.entitledPlanAccesses();

      expect([for (final p in plans) p['providerId']], [
        'account:zai-off-peak',
        'account:zai-start-plan',
        'account:zai-team-coding-plan',
      ]);
      expect((plans[1]['accountAccess'] as Map)['planKind'], 'start-plan');
    });

    test('a failing getView answers an empty list (never throws)', () async {
      final session =
          sessionOf(viewError: StateError('provider-settings unavailable'));
      expect(await session.entitledPlanAccesses(), isEmpty);
    });

    test('is not cached across reads (a plan change heals on the next read)',
        () async {
      var entitled = <String>{'account:zai-individual-coding-plan'};
      final session = FakeDeviceSession(
        deviceId: 'd2',
        params: params,
        channelHandler: (channel, method, args) async {
          if (method == 'getView') {
            return viewOf([
              for (final id in const [
                'account:zai-individual-coding-plan',
                'account:zai-start-plan',
              ])
                accountProvider(id, entitled: entitled.contains(id)),
            ]);
          }
          return null;
        },
      );
      addTearDown(session.dispose);

      expect(
        [for (final p in await session.entitledPlanAccesses()) p['providerId']],
        ['account:zai-individual-coding-plan'],
      );
      entitled = {'account:zai-start-plan'};
      expect(
        [for (final p in await session.entitledPlanAccesses()) p['providerId']],
        ['account:zai-start-plan'],
      );
    });
  });

  // ------------------------------------- entitledProviderIds (10-24 B filter)

  group('entitledProviderIds', () {
    test('projects entitled account providers onto their ids', () async {
      final session = sessionOf(
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
          accountProvider('account:zai-off-peak', entitled: false),
          accountProvider('account:zai-individual-coding-plan',
              entitled: true),
          personalProvider('personal-gateway', entitled: true),
        ]),
      );

      expect(await session.entitledProviderIds(), {
        'account:zai-start-plan',
        'account:zai-individual-coding-plan',
      });
    });

    test('a successful view with zero entitled answers an empty set, not '
        'null (the filter must hide every account group)', () async {
      final session = sessionOf(
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: false),
        ]),
      );

      final ids = await session.entitledProviderIds();
      expect(ids, isNotNull);
      expect(ids, isEmpty);
    });

    test('a failing getView answers null (entitlement unknown → no '
        'filtering)', () async {
      final session =
          sessionOf(viewError: StateError('provider-settings unavailable'));

      expect(await session.entitledProviderIds(), isNull);
    });
  });

  // --------------------------------------------------- resolution matrix

  group('enumerated plan resolution', () {
    const relayTasks = [
      {'taskId': 't1', 'workspacePath': '/repo'},
    ];

    test('a derived provider that is entitled wins', () async {
      final session = sessionOf(
        relayTasks: relayTasks,
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
          accountProvider('account:zai-individual-coding-plan', entitled: true),
          accountProvider('account:zai-team-coding-plan', entitled: true),
        ]),
        selection: {'providerId': 'account:zai-team-coding-plan'},
      );

      await session.entitlementSnapshot();

      final args = snapshotArgs(session);
      expect(args['preferredProviderId'], 'account:zai-team-coding-plan');
      expect(args['accountAccess'], {
        'type': 'zhipu-account',
        'family': 'zai',
        'planKind': 'team-coding-plan',
      });
    });

    test('an entitled off-peak derivation never outranks a snapshot target',
        () async {
      // The session runs an idle-plan task: getTaskModelSelection answers an
      // entitled `account:zai-off-peak`. The desktop cannot snapshot idle
      // plans, so priority 1 must skip it and the entitled Start plan wins.
      final session = sessionOf(
        relayTasks: relayTasks,
        view: viewOf([
          accountProvider('account:zai-off-peak', entitled: true),
          accountProvider('account:zai-start-plan', entitled: true),
        ]),
        selection: {'providerId': 'account:zai-off-peak'},
      );

      await session.entitlementSnapshot();

      final args = snapshotArgs(session);
      expect(args['preferredProviderId'], 'account:zai-start-plan');
      expect((args['accountAccess'] as Map)['planKind'], 'start-plan');
    });

    test('an entitled coding plan outranks an entitled Start plan', () async {
      final session = sessionOf(
        relayTasks: relayTasks,
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
          accountProvider('account:zai-individual-coding-plan', entitled: true),
        ]),
        // Non-account selection → no derivation; the entitled set decides.
        selection: {'providerId': 'openrouter/glm-4.6'},
      );

      await session.entitlementSnapshot();

      final args = snapshotArgs(session);
      expect(
          args['preferredProviderId'], 'account:zai-individual-coding-plan');
      expect((args['accountAccess'] as Map)['planKind'],
          'individual-coding-plan');
    });

    test('starter-only account routes to the entitled Start plan', () async {
      final session = sessionOf(
        relayTasks: relayTasks,
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
        ]),
        selectionError: StateError('selection unavailable'),
      );

      await session.entitlementSnapshot();

      final args = snapshotArgs(session);
      expect(args['preferredProviderId'], 'account:zai-start-plan');
      expect((args['accountAccess'] as Map)['planKind'], 'start-plan');
    });

    test('no entitled provider degrades to the legacy derivation', () async {
      final session = sessionOf(
        relayTasks: relayTasks,
        view: viewOf([
          accountProvider('account:zai-individual-coding-plan',
              entitled: false),
          personalProvider('personal-gateway', entitled: true),
        ]),
        selection: {'providerId': 'account:zai-team-coding-plan'},
      );

      await session.entitlementSnapshot();

      final args = snapshotArgs(session);
      expect(args['preferredProviderId'], 'account:zai-team-coding-plan');
      expect((args['accountAccess'] as Map)['planKind'], 'team-coding-plan');
    });

    test('a failing getView falls back to the legacy derivation without '
        'crashing', () async {
      final session = sessionOf(
        relayTasks: relayTasks,
        viewError: StateError('provider-settings unavailable'),
        selection: {'providerId': 'account:zai-start-plan'},
      );

      await session.entitlementSnapshot();

      final args = snapshotArgs(session);
      expect(args['preferredProviderId'], 'account:zai-start-plan');
      expect((args['accountAccess'] as Map)['planKind'], 'start-plan');
    });

    test('no entitled provider and no derivation probes the coding-plan '
        'route', () async {
      final session = sessionOf(
        relayTasks: relayTasks,
        view: viewOf(const []),
        selectionError: StateError('selection unavailable'),
      );

      await session.entitlementSnapshot();

      final args = snapshotArgs(session);
      expect(
          args['preferredProviderId'], 'account:zai-individual-coding-plan');
      expect((args['accountAccess'] as Map)['planKind'],
          'individual-coding-plan');
    });
  });

  // -------------------------------- derived plan: newest relay task (10-25)

  Map<String, dynamic> relayTask(String id, {int? updatedAt}) => {
        'taskId': id,
        'workspacePath': '/repo/$id',
        if (updatedAt != null) 'updatedAt': updatedAt,
      };

  /// Session whose `getTaskModelSelection` answers per task id (a null
  /// entry throws — the RPC-failure shape) and records the probe order.
  ({FakeDeviceSession session, List<String> probes}) derivedSession({
    required List<Map<String, dynamic>> relayTasks,
    required Map<String, Map<String, dynamic>?> selections,
    Object? view,
  }) {
    final probes = <String>[];
    final session = FakeDeviceSession(
      deviceId: 'd-derived',
      params: params,
      relayTasks: relayTasks,
      channelHandler: (channel, method, args) async {
        switch (method) {
          case 'getView':
            return view;
          case 'getTaskModelSelection':
            final taskId = '${(args.single as Map)['taskId']}';
            probes.add(taskId);
            final selection = selections[taskId];
            if (selection == null) {
              throw StateError('selection unavailable for $taskId');
            }
            return selection;
          case 'getEntitlementSnapshot':
            return <String, dynamic>{
              'authenticated': true,
              'provider': {'id': 'prov-1'},
            };
        }
        return null;
      },
    );
    addTearDown(session.dispose);
    return (session: session, probes: probes);
  }

  group('derived plan access follows the newest relay task', () {
    test('the greatest updatedAt wins over list order', () async {
      final env = derivedSession(
        relayTasks: [
          relayTask('old', updatedAt: 10),
          relayTask('new', updatedAt: 20),
        ],
        selections: {
          'old': {'providerId': 'account:zai-start-plan'},
          'new': {'providerId': 'account:zai-team-coding-plan'},
        },
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
          accountProvider('account:zai-team-coding-plan', entitled: true),
        ]),
      );

      await env.session.entitlementSnapshot();

      expect(env.probes, ['new']);
      expect(snapshotArgs(env.session)['preferredProviderId'],
          'account:zai-team-coding-plan');
    });

    test('a failing newest selection falls back to the first task', () async {
      final env = derivedSession(
        relayTasks: [
          relayTask('first', updatedAt: 10),
          relayTask('newest', updatedAt: 20),
        ],
        selections: {
          'first': {'providerId': 'account:zai-start-plan'},
          'newest': null,
        },
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
        ]),
      );

      await env.session.entitlementSnapshot();

      expect(env.probes, ['newest', 'first']);
      expect(snapshotArgs(env.session)['preferredProviderId'],
          'account:zai-start-plan');
    });

    test('a newest selection answering a non-account provider falls back '
        'to the first task', () async {
      final env = derivedSession(
        relayTasks: [
          relayTask('first', updatedAt: 10),
          relayTask('newest', updatedAt: 20),
        ],
        selections: {
          'first': {'providerId': 'account:zai-team-coding-plan'},
          'newest': {'providerId': 'openrouter/glm-4.6'},
        },
        view: viewOf([
          accountProvider('account:zai-team-coding-plan', entitled: true),
        ]),
      );

      await env.session.entitlementSnapshot();

      expect(env.probes, ['newest', 'first']);
      expect(snapshotArgs(env.session)['preferredProviderId'],
          'account:zai-team-coding-plan');
    });

    test('rows without updatedAt keep list order and probe the first once',
        () async {
      final env = derivedSession(
        relayTasks: [relayTask('t1'), relayTask('t2')],
        selections: {
          't1': {'providerId': 'account:zai-start-plan'},
        },
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
        ]),
      );

      await env.session.entitlementSnapshot();

      expect(env.probes, ['t1']);
    });
  });

  // ------------------------------------ dual routes for the usage page (10-25)

  /// Session answering provider-settings + per-provider snapshots; every
  /// snapshot request body lands in [snapshotBodies].
  ({
    FakeDeviceSession session,
    List<Map<String, dynamic>> snapshotBodies,
  }) routesSession({
    Object? view,
    Object? viewError,
    List<Map<String, dynamic>> relayTasks = const [],
    Object? selection,
    Map<String, dynamic> Function(String providerId)? snapshotFor,
  }) {
    final bodies = <Map<String, dynamic>>[];
    final session = FakeDeviceSession(
      deviceId: 'd-routes',
      params: params,
      relayTasks: relayTasks,
      channelHandler: (channel, method, args) async {
        switch (method) {
          case 'getView':
            if (viewError != null) throw viewError;
            return view;
          case 'getTaskModelSelection':
            return selection;
          case 'getEntitlementSnapshot':
            final body = (args.single as Map).cast<String, dynamic>();
            bodies.add(body);
            final providerId = '${body['preferredProviderId']}';
            return snapshotFor?.call(providerId) ??
                <String, dynamic>{
                  'authenticated': true,
                  'provider': {'id': providerId},
                };
        }
        return null;
      },
    );
    addTearDown(session.dispose);
    return (session: session, snapshotBodies: bodies);
  }

  group('entitlementSnapshots dual routes', () {
    test('entitled coding + Start answer two routes, coding first, each '
        'with its own wire args', () async {
      final env = routesSession(
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
          accountProvider('account:zai-individual-coding-plan',
              entitled: true),
          accountProvider('account:zai-team-coding-plan', entitled: true),
        ]),
      );

      final routes = await env.session.entitlementSnapshots();

      expect(
        [for (final r in routes) r.plan!['providerId']],
        ['account:zai-individual-coding-plan', 'account:zai-start-plan'],
      );
      expect(
        [for (final r in routes) r.view.phase],
        [EntitlementPhase.ok, EntitlementPhase.ok],
      );
      expect(
        [for (final b in env.snapshotBodies) b['preferredProviderId']],
        ['account:zai-individual-coding-plan', 'account:zai-start-plan'],
      );
      expect((env.snapshotBodies[0]['accountAccess'] as Map)['planKind'],
          'individual-coding-plan');
      expect((env.snapshotBodies[1]['accountAccess'] as Map)['planKind'],
          'start-plan');
    });

    test('each route caches independently; force refreshes both', () async {
      final env = routesSession(
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
          accountProvider('account:zai-individual-coding-plan',
              entitled: true),
        ]),
      );

      await env.session.entitlementSnapshots();
      expect(env.snapshotBodies, hasLength(2));
      // Both pollers are fresh → no wire traffic.
      await env.session.entitlementSnapshots();
      expect(env.snapshotBodies, hasLength(2));
      // Force bypasses every route's staleness window.
      await env.session.entitlementSnapshots(force: true);
      expect(env.snapshotBodies, hasLength(4));
    });

    test('a starter-only view answers one Start route', () async {
      final env = routesSession(
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
          accountProvider('account:zai-individual-coding-plan',
              entitled: false),
        ]),
      );

      final routes = await env.session.entitlementSnapshots();

      expect(routes, hasLength(1));
      expect(routes.single.plan!['providerId'], 'account:zai-start-plan');
      expect(env.snapshotBodies, hasLength(1));
    });

    test('a coding-only view answers one subscription route', () async {
      final env = routesSession(
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: false),
          accountProvider('account:zai-individual-coding-plan',
              entitled: true),
        ]),
      );

      final routes = await env.session.entitlementSnapshots();

      expect(routes, hasLength(1));
      expect(routes.single.plan!['providerId'],
          'account:zai-individual-coding-plan');
    });

    test('a failing getView falls back to the single main route', () async {
      final env = routesSession(
        viewError: StateError('provider-settings unavailable'),
        relayTasks: [
          {'taskId': 't1', 'workspacePath': '/repo'},
        ],
        selection: {'providerId': 'account:zai-start-plan'},
      );

      final routes = await env.session.entitlementSnapshots();

      expect(routes, hasLength(1));
      expect(routes.single.plan!['providerId'], 'account:zai-start-plan');
      expect(env.snapshotBodies.single['preferredProviderId'],
          'account:zai-start-plan');
    });

    test('a view without snapshot targets falls back to the main route',
        () async {
      final env = routesSession(
        view: viewOf([
          accountProvider('account:zai-off-peak', entitled: true),
        ]),
        relayTasks: [
          {'taskId': 't1', 'workspacePath': '/repo'},
        ],
        selection: {'providerId': 'account:zai-team-coding-plan'},
      );

      final routes = await env.session.entitlementSnapshots();

      expect(routes, hasLength(1));
      expect(routes.single.plan!['providerId'],
          'account:zai-team-coding-plan');
    });

    test('the Start route normalizes its 0..1 remaining ratio while the '
        'coding route stays 0..100 used', () async {
      final env = routesSession(
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
          accountProvider('account:zai-individual-coding-plan',
              entitled: true),
        ]),
        snapshotFor: (providerId) => providerId == 'account:zai-start-plan'
            ? {
                'authenticated': true,
                'provider': {'id': providerId},
                'quota': {
                  'level': 'Start',
                  'limits': [
                    {'type': 'ent-1', 'percentage': 0.9493},
                  ],
                },
              }
            : {
                'authenticated': true,
                'provider': {'id': providerId},
                'quota': {
                  'level': 'pro',
                  'limits': [
                    {
                      'type': 'TOKENS_LIMIT',
                      'unit': 3,
                      'number': 5,
                      'percentage': 51,
                    },
                  ],
                },
              },
      );

      final routes = await env.session.entitlementSnapshots();
      final coding = routes.first.view;
      final start = routes.last.view;

      expect(
        coding.remainingPercent(
            coding.limitFor('TOKENS_LIMIT', unit: 3, number: 5)),
        closeTo(49, 0.001),
      );
      // Wire 0.9493 (remaining ratio, 0..1) → used 5.07% → left 94.93%.
      expect(start.limitFor('ent-1')!.percentage, closeTo(5.07, 0.001));
      expect(start.remainingPercent(start.limitFor('ent-1')),
          closeTo(94.93, 0.001));
    });

    test('entitlementSnapshot reuses the route poller (no duplicate fetch) '
        'and keeps the main route', () async {
      final env = routesSession(
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
          accountProvider('account:zai-individual-coding-plan',
              entitled: true),
        ]),
      );

      await env.session.entitlementSnapshots();
      expect(env.snapshotBodies, hasLength(2));

      final view = await env.session.entitlementSnapshot();

      expect(view.phase, EntitlementPhase.ok);
      // The main route resolved to the coding representative, whose poller
      // is the same fresh instance the page just used.
      expect(env.snapshotBodies, hasLength(2));
      expect(env.snapshotBodies.first['preferredProviderId'],
          'account:zai-individual-coding-plan');
    });

    test('dual plans with a derived Start main route keep the reset RPC '
        'same-source (coding scope with coding accountAccess)', () async {
      final env = routesSession(
        view: viewOf([
          accountProvider('account:zai-start-plan', entitled: true),
          accountProvider('account:zai-individual-coding-plan',
              entitled: true),
        ]),
        relayTasks: [
          {'taskId': 't1', 'workspacePath': '/repo', 'updatedAt': 1},
        ],
        selection: {'providerId': 'account:zai-start-plan'},
      );

      // The main route (what quotaResetStatus used to re-resolve) is the
      // derived Start plan...
      final main = await env.session.entitlementSnapshot();
      expect(main.phase, EntitlementPhase.ok);
      expect(env.snapshotBodies.single['preferredProviderId'],
          'account:zai-start-plan');

      // ...while the usage page's primary group is the subscription plan.
      await env.session.entitlementSnapshots();
      expect(env.session.quotaResetController.scopeProviderId,
          'account:zai-individual-coding-plan');

      final viewCallsBefore = env.session.channelCalls
          .where((c) => c.$2 == 'getView')
          .length;
      await env.session.quotaResetController.refresh();

      final resetCall = env.session.channelCalls
          .lastWhere((c) => c.$2 == 'getCodingPlanResetStatus');
      expect(resetCall.$3.single, {
        'preferredProviderId': 'account:zai-individual-coding-plan',
        'accountAccess': {
          'type': 'zhipu-account',
          'family': 'zai',
          'planKind': 'individual-coding-plan',
        },
      });
      // Same-source fields are already on the scope — no plan re-resolution.
      expect(
        env.session.channelCalls.where((c) => c.$2 == 'getView').length,
        viewCallsBefore,
      );
    });
  });
}
