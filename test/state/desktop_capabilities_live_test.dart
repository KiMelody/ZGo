import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/project_resolver.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';

import '../helpers/fake_device_session.dart';

/// Consumer-level matrix for the three abilities flipped to live-then-
/// snapshot (design 10-29 §5.2): `quotaWire` (5 sites), `projectCreate
/// Addressing` (1), `prepareWorkspaceTaskOptions` (1).
///
/// Rows (shared by every site):
/// - old snapshot + no live → legacy wire
/// - old snapshot + new live → new wire
/// - new snapshot + old live → legacy wire (live reverse)
/// - new snapshot + malformed live → legacy wire, NO snapshot fallback
///
/// Observables are wire shapes / resolver calls, never the capability value
/// itself — an unmigrated site reading the snapshot would fail these rows.
const _fastTimings = StallTimings(
  healthyWaitTimeout: Duration(milliseconds: 40),
  rpcTimeout: Duration(milliseconds: 200),
  dialTimeout: Duration(milliseconds: 60),
  listReadyTimeout: Duration(seconds: 300),
  minRebuildInterval: Duration(milliseconds: 5),
  retryBackoff: Duration(milliseconds: 60),
);

RemoteConnectionParams _paramsOf(String? version) =>
    RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=m&name=test'
      '${version == null ? '' : '&app_version=$version'}',
    )!;

class _Row {
  final String name;
  final String? snapshot;
  final String? live;
  final bool expectNew;

  const _Row(this.name, this.snapshot, this.live, this.expectNew);
}

const _rows = [
  _Row('old snapshot + no live', '3.12.2', null, false),
  _Row('old snapshot + new live', '3.12.2', '3.16.3', true),
  _Row('new snapshot + old live', '3.16.3', '3.12.2', false),
  _Row('new snapshot + malformed live', '3.16.3', '3.16.3-beta', false),
];

const _codingId = 'account:zai-individual-coding-plan';
const _startId = 'account:zai-start-plan';

Map<String, dynamic> _accountProvider(String id) => {
      'providerId': id,
      'providerName': id,
      'enabled': true,
      'executable': true,
      'accountState': {
        'access': {'type': 'zhipu-account'},
      },
      'effectiveConfig': {
        'access': {'type': 'zhipu-account', 'entitled': true},
      },
      'issues': <Object>[],
      'models': <Object>[],
    };

Map<String, dynamic> _providerView() => {
      'revision': '[1,1]',
      'providerTemplates': <Object>[],
      'providerOrder': <Object>[],
      'providers': [
        _accountProvider(_codingId),
        _accountProvider(_startId),
      ],
    };

const _snapshotPayload = {
  'authenticated': true,
  'provider': {'id': 'prov-1'},
};

Future<dynamic> _quotaAnswer(
  String channel,
  String method,
  List<Object?> args,
) async {
  switch (method) {
    case 'getView':
      return _providerView();
    case 'getEntitlementSnapshot':
      return _snapshotPayload;
    case 'getCodingPlanResetStatus':
      return const {'ok': true};
    case 'useCodingPlanReset':
      return null;
  }
  return null;
}

FakeDeviceSession _quotaSession(_Row row) => FakeDeviceSession(
      deviceId: 'd1',
      params: _paramsOf(row.snapshot),
      desktopVersionOverride: row.live,
      channelHandler: _quotaAnswer,
    );

Map<String, dynamic> _lastCall(
  FakeDeviceSession session,
  String channel,
  String method,
) {
  final call = session.channelCalls.lastWhere(
    (c) => c.$1 == channel && c.$2 == method,
  );
  return call.$3.single as Map<String, dynamic>;
}

int _callCount(FakeDeviceSession session, String channel, String method) =>
    session.channelCalls.where((c) => c.$1 == channel && c.$2 == method).length;

/// The full 3.12.3 quota parameter set for [plan] (one source).
Map<String, dynamic> _fullArgs(String providerId, Map<String, dynamic> access) =>
    {
      'includeSubscription': true,
      'preferredProviderId': providerId,
      'accountAccess': access,
      'allowDisabledPreferredProvider': true,
      'requirePreferredProvider': true,
      'allowEnvApiKey': false,
    };

const _codingAccess = {
  'type': 'zhipu-account',
  'family': 'zai',
  'planKind': 'individual-coding-plan',
};
const _startAccess = {
  'type': 'zhipu-account',
  'family': 'zai',
  'planKind': 'start-plan',
};

// ---------------------------------------------------------------- workspace prep

Future<dynamic> _prepAnswer(
  String channel,
  String method,
  List<Object?> args,
) async {
  if (channel == 'zcode-task' && method == 'getTaskConfigOptions') {
    return [
      {
        'id': 'model',
        'name': '模型',
        'category': 'model',
        'type': 'select',
        'currentValue': 'm1',
        'options': <Object>[],
      },
    ];
  }
  return null;
}

FakeDeviceSession _prepSession(_Row row) => FakeDeviceSession(
      deviceId: 'd1',
      params: _paramsOf(row.snapshot),
      desktopVersionOverride: row.live,
      workspaces: [
        {'workspacePath': '/ws'},
      ],
      channelHandler: _prepAnswer,
    );

class _RecordingResolver extends ProjectResolver {
  _RecordingResolver(this.projectId)
      : super(
          workspaces: () => const [],
          readRange: (path, offset, length) async => Uint8List(0),
        );

  final String? projectId;
  int calls = 0;

  @override
  Future<String?> projectIdFor(String workspacePath) async {
    calls++;
    return projectId;
  }
}

FakeDeviceSession _projectSession(_Row row, _RecordingResolver resolver) =>
    FakeDeviceSession(
      deviceId: 'd1',
      params: _paramsOf(row.snapshot),
      desktopVersionOverride: row.live,
      projectResolverFactory: (_) => resolver,
      channelHandler: (channel, method, args) async => null,
    );

/// Scripted client for the end-to-end live-version chain (same pattern as
/// `test/state/project_workspace_completion_test.dart`): the real
/// [DeviceSession.connect] runs, only the network steps are answered.
class _StubClient extends RemoteClient {
  _StubClient(super.params);

  Map<String, dynamic> bootstrapResult = {'workspaces': <Object>[]};

  @override
  Future<void> connect() => Future.value();

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() async => bootstrapResult;

  final workspaceUpdates = StreamController<dynamic>.broadcast();

  @override
  Stream<dynamic> get workspaceListUpdated => workspaceUpdates.stream;

  @override
  Future<BridgeSession> openBridge(
    String workspaceKey, {
    String? taskId,
    Map<String, dynamic>? project,
    String? taskHostId,
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      throw StateError('openBridge is not expected in this test');

  @override
  Future<void> dispose() => Future.value();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('quotaWire 5 sites', () {
    for (final row in _rows) {
      group(row.name, () {
        test('_fetchEntitlement sends the matching parameter set', () async {
          final session = _quotaSession(row);
          addTearDown(() => session.dispose());
          await session.entitlementSnapshot(force: true);

          final args = _lastCall(
              session, 'usage-stats', 'getEntitlementSnapshot');
          if (row.expectNew) {
            expect(args, _fullArgs(_codingId, _codingAccess));
          } else {
            expect(args, {
              'includeSubscription': true,
            });
          }
        });

        test('entitlementSnapshot routes through the legacy/routed poller',
            () async {
          final session = _quotaSession(row);
          addTearDown(() => session.dispose());
          await session.entitlementSnapshot(force: true);

          final planViews =
              _callCount(session, Channels.providerSettings, 'getView');
          if (row.expectNew) {
            // Routed path resolves the plan from provider-settings first.
            expect(planViews, 1);
          } else {
            expect(planViews, 0);
          }
        });

        test('entitlementSnapshots exposes one legacy or two routed routes',
            () async {
          final session = _quotaSession(row);
          addTearDown(() => session.dispose());
          final routes = await session.entitlementSnapshots(force: true);

          if (row.expectNew) {
            expect(routes, hasLength(2));
            final calls = session.channelCalls
                .where((c) =>
                    c.$1 == 'usage-stats' && c.$2 == 'getEntitlementSnapshot')
                .toList();
            expect(calls, hasLength(2));
            expect(calls[0].$3.single, _fullArgs(_codingId, _codingAccess));
            expect(calls[1].$3.single, _fullArgs(_startId, _startAccess));
          } else {
            expect(routes, hasLength(1));
            final call = _lastCall(
                session, 'usage-stats', 'getEntitlementSnapshot');
            expect(call, {'includeSubscription': true});
          }
        });

        test('quotaResetStatus carries accountAccess only on the new wire',
            () async {
          final session = _quotaSession(row);
          addTearDown(() => session.dispose());
          await session.quotaResetStatus(force: true);

          final args =
              _lastCall(session, 'usage-stats', 'getCodingPlanResetStatus');
          if (row.expectNew) {
            expect(args, {
              'preferredProviderId': _codingId,
              'accountAccess': _codingAccess,
            });
          } else {
            expect(args, {'preferredProviderId': null});
            expect(args.containsKey('accountAccess'), isFalse);
          }
        });

        test('useQuotaReset carries accountAccess only on the new wire',
            () async {
          final session = _quotaSession(row);
          addTearDown(() => session.dispose());
          await session.useQuotaReset('five_hour', 'key-1',
              preferredProviderId: 'ignored-provider');

          final args = _lastCall(session, 'usage-stats', 'useCodingPlanReset');
          if (row.expectNew) {
            expect(args, {
              'preferredProviderId': _codingId,
              'idempotencyKey': 'key-1',
              'resetType': 'five_hour',
              'accountAccess': _codingAccess,
            });
          } else {
            expect(args, {
              'preferredProviderId': 'ignored-provider',
              'idempotencyKey': 'key-1',
              'resetType': 'five_hour',
            });
            expect(args.containsKey('accountAccess'), isFalse);
          }
        });
      });
    }
  });

  group('prepareWorkspaceTaskOptions site', () {
    for (final row in _rows) {
      test(row.name, () async {
        final session = _prepSession(row);
        addTearDown(() => session.dispose());

        if (row.expectNew) {
          final prep = await session.debugPrepareWorkspace();
          expect(prep.configOptions, isNotEmpty);
          expect(
            _callCount(session, 'zcode-task', 'getTaskConfigOptions'),
            1,
          );
        } else {
          // The legacy branch is `_requireConversation.prepareWorkspace()`;
          // this fake never opens a workspace, so the legacy call surfaces
          // as `not connected` — and the task-options channel stays silent.
          await expectLater(
            session.debugPrepareWorkspace(),
            throwsA(isA<StateError>()),
          );
          expect(
            _callCount(session, 'zcode-task', 'getTaskConfigOptions'),
            0,
          );
        }
      });
    }
  });

  group('projectCreateAddressing site', () {
    for (final row in _rows) {
      test(row.name, () async {
        final resolver = _RecordingResolver('proj-1');
        final session = _projectSession(row, resolver);
        addTearDown(() => session.dispose());

        final id = await session.debugProjectIdForCreate('/project/root');
        if (row.expectNew) {
          expect(id, 'proj-1');
          expect(resolver.calls, 1);
        } else {
          expect(id, isNull);
          expect(resolver.calls, 0);
        }
      });
    }
  });

  group('live version lifecycle', () {
    DeviceSession connectedSession(List<_StubClient> clients) => DeviceSession(
          deviceId: 'd1',
          params: _paramsOf('3.12.2'),
          timings: _fastTimings,
          clientFactory: () => clients.removeAt(0),
        );

    test('bootstrap desktopAppVersion -> _applyRelayOverview -> capability',
        () async {
      final client = _StubClient(_paramsOf('3.12.2'));
      client.bootstrapResult = {
        'desktopAppVersion': '3.16.3',
        'workspaces': <Object>[],
      };
      final session = connectedSession([client]);
      addTearDown(() => session.dispose());

      await session.connect();

      expect(session.desktopAppVersion, '3.16.3');
      expect(session.capabilities.bridgeAddressing, isTrue);
      expect(session.capabilities.quotaWire, isTrue);
      expect(session.capabilities.projectCreateAddressing, isTrue);
      expect(session.capabilities.prepareWorkspaceTaskOptions, isTrue);
    });

    test('reconnect to a desktop without the field falls back to snapshot',
        () async {
      final first = _StubClient(_paramsOf('3.12.2'));
      first.bootstrapResult = {
        'desktopAppVersion': '3.16.3',
        'workspaces': <Object>[],
      };
      final second = _StubClient(_paramsOf('3.12.2'));
      second.bootstrapResult = {'workspaces': <Object>[]};
      final session = connectedSession([first, second]);
      addTearDown(() => session.dispose());

      await session.connect();
      expect(session.capabilities.quotaWire, isTrue);

      await session.suspend();
      expect(session.desktopAppVersion, isNull,
          reason: 'suspend clears the live version');

      await session.connect();
      expect(session.desktopAppVersion, isNull);
      expect(session.capabilities.quotaWire, isFalse);
      expect(session.capabilities.projectCreateAddressing, isFalse);
      expect(session.capabilities.prepareWorkspaceTaskOptions, isFalse);
    });
  });
}
