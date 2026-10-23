import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/project_resolver.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/task_directory.dart';

import '../helpers/fake_device_session.dart';

/// 3.16.2 workspace-list completion (research/07 方案 A): bootstrap
/// `workspaces` is the BOUND window's registry only, so the resolver's
/// `projects ⋈ project_roots` rows complete it. The merged list feeds the
/// cards AND the listTaskList scopes (timeline/pinned/archived share one
/// scope list), so tasks of uncovered workspaces become visible.
///
/// The resolver's own parsing/cache contract lives in
/// test/protocol/project_resolver_test.dart; here a stub resolver stands in
/// for the async answer (the real read needs an open bridge).

const _fastTimings = StallTimings(
  healthyWaitTimeout: Duration(milliseconds: 40),
  rpcTimeout: Duration(milliseconds: 200),
  dialTimeout: Duration(milliseconds: 60),
  listReadyTimeout: Duration(seconds: 300),
  minRebuildInterval: Duration(milliseconds: 5),
  retryBackoff: Duration(milliseconds: 60),
);

class _StubClient extends RemoteClient {
  _StubClient(super.params);

  Map<String, dynamic> bootstrapResult = {
    'workspaces': [
      {
        'workspacePath': '/home/.zcode/workspace/default',
        'workspaceIdentity': 'default-id',
        'label': 'default',
      },
    ],
  };

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
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      throw StateError('openBridge is not expected in this test');

  @override
  Future<void> dispose() => Future.value();
}

class _FakeGate implements WorkspaceGate {
  final calls = <(String, String, List<Object?>)>[];

  Future<dynamic> Function(String method, List<Object?> args)? handler;

  @override
  Future<void> waitHealthy({required Duration timeout}) => Future.value();

  @override
  Future<dynamic> call(String channel, String method, List<Object?> args) {
    calls.add((channel, method, List<Object?>.from(args)));
    final h = handler;
    if (h == null) throw StateError('no handler for $channel.$method');
    return h(method, args);
  }
}

/// Answers the mapping without touching the file channel; counts calls so
/// the version gate can be asserted (an old desktop must never build it).
class _StubResolver extends ProjectResolver {
  _StubResolver(this.mappingResult)
      : super(
          workspaces: () => const [],
          readRange: (path, offset, length) async => Uint8List(0),
        );

  final ProjectMapping? mappingResult;
  int mappingCalls = 0;
  bool _resolved = false;

  @override
  Future<ProjectMapping?> mapping() async {
    mappingCalls++;
    _resolved = true;
    return mappingResult;
  }

  /// Models the real resolver: roots exist only AFTER the read answered.
  @override
  List<ProjectRoot> get projectRoots =>
      _resolved ? mappingResult?.roots ?? const <ProjectRoot>[] : const [];
}

/// A resolver whose read parks until the test answers it — the real read
/// takes seconds over the relay, during which the link may suspend.
class _DeferredResolver extends ProjectResolver {
  _DeferredResolver(this._roots)
      : super(
          workspaces: () => const [],
          readRange: (path, offset, length) async => Uint8List(0),
        );

  final List<ProjectRoot> _roots;
  final Completer<ProjectMapping?> _answer = Completer<ProjectMapping?>();

  @override
  Future<ProjectMapping?> mapping() => _answer.future;

  @override
  List<ProjectRoot> get projectRoots =>
      _answer.isCompleted ? _roots : const <ProjectRoot>[];

  void answer() => _answer.complete(
        ProjectMapping(byRootPath: const {}, roots: _roots),
      );
}

RemoteConnectionParams _params(String appVersion) =>
    RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=m'
      '&app_version=$appVersion',
    )!;

Future<DeviceSession> _connected(
  _StubClient stub, {
  ProjectResolver Function(List<Map<String, dynamic>> Function())?
  resolverFactory,
}) async {
  final session = DeviceSession(
    deviceId: 'd1',
    params: _params(stub.params.appVersion ?? '3.16.2'),
    timings: _fastTimings,
    clientFactory: () => stub,
    projectResolverFactory: resolverFactory,
  );
  await session.connect();
  return session;
}

Map<String, dynamic> _legResponse({
  required String taskId,
  String workspacePath = '/server/default',
}) =>
    {
      'items': [
        {
          'taskId': taskId,
          'title': 'from $taskId',
          'workspacePath': workspacePath,
          'status': 'completed',
          'updatedAt': 2,
        },
      ],
      'total': 1,
      'hasMore': false,
    };

Map<String, dynamic> _emptyLeg() =>
    {'items': <Object>[], 'total': 0, 'hasMore': false};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mergeProjectWorkspaces', () {
    test('wire entries win the dedupe across path spellings', () {
      final wire = [
        {
          'workspacePath': r'F:\ZLinker',
          'workspaceIdentity': 'cf77504f',
          'label': 'ZLinker',
        },
        {'workspacePath': '/home/default', 'label': 'default'},
      ];
      final merged = mergeProjectWorkspaces(wire, const [
        // Same directory as the wire entry, different spelling/case.
        ProjectRoot(
          projectId: 'p1',
          name: 'zlinker-project',
          rootPath: 'F:/ZLINKER/',
        ),
        ProjectRoot(projectId: 'p2', name: 'chat', rootPath: r'F:\chat'),
      ]);

      expect(merged, hasLength(3));
      expect(merged[0], same(wire[0]),
          reason: 'the wire entry keeps its label/identity');
      expect(merged[1], same(wire[1]));
      final synthetic = merged.last;
      expect(synthetic, {
        'kind': 'local',
        'label': 'chat',
        'workspacePath': r'F:\chat',
        'workspacePurpose': 'project',
      });
    });

    test('nothing to add leaves the input list untouched', () {
      final wire = [
        {'workspacePath': '/repo', 'label': 'repo'},
      ];
      expect(identical(mergeProjectWorkspaces(wire, const []), wire), isTrue);
      expect(
        identical(
          mergeProjectWorkspaces(wire, const [
            ProjectRoot(
              projectId: 'p1',
              name: 'repo',
              rootPath: '/repo/',
            ),
          ]),
          wire,
        ),
        isTrue,
        reason: 'a fully covered root must not alter the list object',
      );
    });

    test('synthetic project entries never read as conversation workspaces',
        () {
      final merged = mergeProjectWorkspaces(
        [
          {'workspacePath': '/home/default', 'label': 'default'},
        ],
        const [
          ProjectRoot(projectId: 'p1', name: 'chat', rootPath: r'F:\chat'),
        ],
      );
      final synthetic =
          merged.singleWhere((w) => w['workspacePath'] == r'F:\chat');
      expect(isConversationWorkspace(synthetic), isFalse);
      expect(
        isConversationWorkspacePath(synthetic['workspacePath'] as String),
        isFalse,
        reason: 'project roots live outside the draft- directory convention',
      );
    });

    test('project-root rows keep their own display group', () {
      final merged = mergeProjectWorkspaces(
        [
          {
            'workspacePath': '/home/default',
            'workspaceIdentity': 'default-id',
            'label': 'default',
          },
          {
            'workspacePath': '/home/.zcode/workspace/draft-1',
            'label': 'draft-1',
          },
        ],
        const [
          ProjectRoot(projectId: 'p1', name: 'chat', rootPath: r'F:\chat'),
        ],
      );
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: _params('3.16.2'),
        workspaces: merged,
        relayTasks: [
          {
            'taskId': 'chat-task',
            'title': 'chat',
            'workspacePath': r'F:\chat',
            'displayStatus': 'idle',
            'updatedAt': 1,
          },
          {
            'taskId': 'draft-task',
            'title': 'draft',
            'workspacePath': '/home/.zcode/workspace/draft-1',
            'displayStatus': 'idle',
            'updatedAt': 1,
          },
        ],
      );

      final groups = {
        for (final (entry, key) in session.taskDirectory.allEntries())
          entry.sessionId: key,
      };
      expect(groups['chat-task'], r'F:\chat',
          reason: 'the completed workspace owns its rows');
      expect(groups['draft-task'], 'default-id',
          reason: 'the conversation merge is untouched by the completion');
    });
  });

  group('DeviceSession completion', () {
    test('a late resolver answer completes the list and pulls all three legs',
        () async {
      final stub = _StubClient(_params('3.16.2'));
      final resolver = _StubResolver(
        const ProjectMapping(
          byRootPath: {},
          roots: [
            ProjectRoot(projectId: 'p1', name: 'chat', rootPath: r'F:\chat'),
          ],
        ),
      );
      late List<Map<String, dynamic>> Function() resolverWorkspaces;
      final session = await _connected(
        stub,
        resolverFactory: (bootstrap) {
          resolverWorkspaces = bootstrap;
          return resolver;
        },
      );
      addTearDown(session.dispose);

      final gate = _FakeGate()
        ..handler = (method, args) async {
          if (method == 'listPinnedTaskIds') return <String>[];
          final kind = (args.single as Map)['kind'];
          if (kind == 'timeline') {
            return _legResponse(taskId: 'chat-task', workspacePath: r'F:\chat');
          }
          return _emptyLeg();
        };
      session.debugAttachGateForTest(gate);
      var notified = 0;
      session.addListener(() => notified++);

      await session.debugRefreshProjectWorkspacesForTest();

      expect(session.workspaces.map((w) => w['workspacePath']), [
        '/home/.zcode/workspace/default',
        r'F:\chat',
      ]);
      final synthetic = session.workspaces.last;
      expect(synthetic['label'], 'chat', reason: 'label = projects.name');
      expect(synthetic['workspacePurpose'], 'project');
      expect(notified, greaterThan(0), reason: 'the cards must repaint');
      expect(session.relayTasks.map((r) => r['taskId']), contains('chat-task'),
          reason: 'the new scope pulls the missing workspace\'s rows');

      final legCalls =
          gate.calls.where((c) => c.$2 == 'listTaskList').toList();
      expect(
        legCalls.map((c) => (c.$3.single as Map)['kind']),
        ['timeline', 'pinned', 'archived'],
      );
      for (final call in legCalls) {
        final scopes =
            ((call.$3.single as Map)['workspaceScopes'] as List)
                .cast<Map<String, dynamic>>();
        expect(scopes.map((s) => s['workspacePath']), [
          '/home/.zcode/workspace/default',
          r'F:\chat',
        ], reason: 'every leg shares the completed scope list');
      }

      // Anti-loop: the resolver keeps deriving its home from the RAW wire
      // set; feeding it the merged view would make the answer depend on
      // itself.
      expect(
        resolverWorkspaces().map((w) => w['workspacePath']),
        ['/home/.zcode/workspace/default'],
      );
      expect(
        resolverWorkspaces().any((w) => w['workspacePurpose'] == 'project'),
        isFalse,
      );
    });

    test('older desktops never merge project roots (gate off)', () async {
      final stub = _StubClient(_params('3.15.0'));
      final resolver = _StubResolver(
        const ProjectMapping(
          byRootPath: {},
          roots: [
            ProjectRoot(projectId: 'p1', name: 'chat', rootPath: r'F:\chat'),
          ],
        ),
      );
      var factoryCalls = 0;
      final session = await _connected(
        stub,
        resolverFactory: (bootstrap) {
          factoryCalls++;
          return resolver;
        },
      );
      addTearDown(session.dispose);

      final before = session.workspaces.map((w) => w['workspacePath']).toList();
      await session.debugRefreshProjectWorkspacesForTest();

      expect(factoryCalls, 0,
          reason: 'the gate short-circuits before the resolver is built');
      expect(resolver.mappingCalls, 0);
      expect(session.workspaces.map((w) => w['workspacePath']), before);
    });

    test('a bootstrap landing later keeps the completed roots', () async {
      final stub = _StubClient(_params('3.16.2'));
      final resolver = _StubResolver(
        const ProjectMapping(
          byRootPath: {},
          roots: [
            ProjectRoot(projectId: 'p1', name: 'chat', rootPath: r'F:\chat'),
          ],
        ),
      );
      final session = await _connected(
        stub,
        resolverFactory: (bootstrap) => resolver,
      );
      addTearDown(session.dispose);
      final gate = _FakeGate()
        ..handler = (method, args) async {
          if (method == 'listPinnedTaskIds') return <String>[];
          return _emptyLeg();
        };
      session.debugAttachGateForTest(gate);

      await session.debugRefreshProjectWorkspacesForTest();
      expect(session.workspaces, hasLength(2));

      // The 30 s cadence / reconnect replaces the raw registry; the cached
      // mapping must complete the NEW list without another read.
      stub.bootstrapResult = {
        'workspaces': [
          {'workspacePath': '/repo/new', 'label': 'new'},
        ],
      };
      await session.refreshTaskOverview();

      expect(session.workspaces.map((w) => w['workspacePath']), [
        '/repo/new',
        r'F:\chat',
      ], reason: 'a later bootstrap re-merges from the cached roots');
      expect(resolver.mappingCalls, 1,
          reason: 'the bootstrap merge never triggers another read');
    });

    test('a resolver answer landing after suspend must not resurrect the '
        'list', () async {
      final stub = _StubClient(_params('3.16.2'));
      final resolver = _DeferredResolver(const [
        ProjectRoot(projectId: 'p1', name: 'chat', rootPath: r'F:\chat'),
      ]);
      final session = await _connected(
        stub,
        resolverFactory: (_) => resolver,
      );
      addTearDown(session.dispose);

      // The read parks (seconds over the relay); meanwhile the user hands
      // the slot to the WebView — suspend() clears the workspace state
      // (session-lifecycle §2) and the late answer must not rebuild
      // synthetic-only workspaces on top of the cleared list.
      final round = session.debugRefreshProjectWorkspacesForTest();
      await session.suspend();
      resolver.answer();
      await round;

      expect(session.workspaces, isEmpty);
    });
  });
}
