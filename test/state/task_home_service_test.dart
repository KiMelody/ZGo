import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/state/sidecar_index_manager.dart';
import 'package:zgo/state/task_home_service.dart';
import 'package:zgo/state/task_home_store.dart';

import '../helpers/fake_device_session.dart';

/// TaskHomeService: the materialized projection, the full invalidation
/// matrix (design 10-29 §2.5), the two live-frame entry orders and the
/// moved home/scope/adjudication surface. Wired through real stores and a
/// real SidecarIndexManager — only the wire closures are fakes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    h = _Harness();
    await h.store.load();
  });

  Map<String, dynamic> relayTask(
    String id,
    String path, {
    String? identity,
    String status = 'idle',
    bool archived = false,
    bool pinned = false,
    int updatedAt = 1,
    int createdAt = 1,
  }) =>
      {
        'taskId': id,
        'title': 'relay-$id',
        'workspacePath': path,
        if (identity != null) 'workspaceIdentity': identity,
        'displayStatus': status,
        if (archived) 'archived': true,
        if (pinned) 'pinned': true,
        'updatedAt': updatedAt,
        'createdAt': createdAt,
      };

  SessionsIndexState liveIndex(
    List<Map<String, dynamic>> entries, {
    String? key,
    Set<String> deleted = const {},
  }) {
    final state = SessionsIndexState();
    state.subscribedWorkspaceKey = key;
    state.deletedTaskIds = deleted;
    state.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {'workspaceId': 'ws-1', 'sessions': entries},
      },
    }, onGap: () {});
    return state;
  }

  Map<String, dynamic> liveRow(String id, String phase) => {
        'sessionId': id,
        'title': 'live-$id',
        'phase': phase,
        'lastActivityAt': 5,
      };

  group('materialized projection', () {
    test('identical reads on one revision return the same view; the merge '
        'runs once', () {
      h.service.setRelayTasks([relayTask('t1', '/repo/alpha')]);
      final first = h.service.directory;
      for (var i = 0; i < 5; i++) {
        expect(identical(h.service.directory, first), isTrue);
      }
      expect(h.service.materializations, 1);
      expect(first.allEntries(), hasLength(1));
    });

    test('entriesFor / allEntries / notificationRows / sessionOnlyIds / '
        'mergedRows all filter the one merged record (no extra merge per '
        'read)', () {
      final active = liveIndex([
        {'sessionId': 't-live', 'title': 'live', 'phase': 'running'},
      ], key: '/repo/alpha');
      h.service.setRelayTasks([relayTask('t1', '/repo/alpha')]);
      h.service.setActiveSessions(
        active,
        generation: () => 0,
        frameKind: () => null,
      );
      h.service.applyLiveFrame(active, generation: 0);
      final dir = h.service.directory;
      expect(h.service.materializations, 1);
      expect(dir.allEntries(), hasLength(2));
      expect(dir.entriesFor('/repo/alpha'), hasLength(2));
      expect(dir.notificationRows(), hasLength(2));
      expect(dir.sessionOnlyIds, {'t-live'});
      // mergedRows is the per-host-notify path of taskLastError (11-08):
      // it must serve the SAME record, not re-run _merge per call.
      expect(identical(dir.mergedRows(), dir.mergedRows()), isTrue);
      expect(h.service.materializations, 1,
          reason: 'read methods must not re-merge');
    });
  });

  group('invalidation matrix (design §2.5)', () {
    test('relayTasks replacement', () {
      h.service.setRelayTasks([relayTask('t1', '/repo/alpha')]);
      expect(h.service.directory.allEntries(), hasLength(1));
      h.service.setRelayTasks([
        relayTask('t1', '/repo/alpha'),
        relayTask('t2', '/repo/alpha'),
      ]);
      expect(h.service.directory.allEntries(), hasLength(2));
      expect(h.service.materializations, 2);
    });

    test('workspaces change recomputes BOTH alias tables', () {
      h.service.setWorkspaces([
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
      ]);
      expect(h.service.normalizeKey('/repo/alpha'), 'alpha');
      h.service.setRelayTasks([
        relayTask('t1', '/home/.zcode/workspace/draft-1'),
      ]);
      expect(h.service.directory.allEntries().single.$2,
          '/home/.zcode/workspace/draft-1',
          reason: 'no conversation alias before the draft workspace is listed');

      h.service.setWorkspaces([
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
        {'workspacePath': '/home/.zcode/workspace/draft-1'},
        {'workspacePath': '/home/.zcode/workspace/default', 'label': 'default'},
      ]);
      final after = h.service.directory;
      expect(after.allEntries().single.$2, '/home/.zcode/workspace/default',
          reason: 'group aliases redirect conversation rows to the default '
              'group');
      expect(h.service.normalizeKey('/home/.zcode/workspace/draft-1'),
          '/home/.zcode/workspace/default',
          reason: 'the key alias table follows the same list');
    });

    test('active live frame', () {
      final state = liveIndex([
        liveRow('t1', 'running'),
      ], key: '/repo/alpha');
      h.service.setRelayTasks([relayTask('t1', '/repo/alpha')]);
      h.service.setActiveSessions(
        state,
        generation: () => 0,
        frameKind: () => null,
      );
      h.service.applyLiveFrame(state, generation: 0);
      expect(h.service.directory.allEntries().single.$1.phase, 'running');
      final before = h.service.materializations;

      state.applyFrame({
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': 'ws-1',
            'sessions': [
              {...liveRow('t1', 'completedSuccess'), 'title': 'changed'},
            ],
          },
        },
      }, onGap: () {});
      // The state listener inside setActiveSessions already ran the entry.
      expect(h.service.directory.allEntries().single.$1.title, 'changed');
      expect(h.service.materializations, greaterThan(before));
    });

    test('active subscription object replacement', () {
      final stateA = liveIndex([liveRow('t1', 'running')], key: '/repo/a');
      h.service.setActiveSessions(
        stateA,
        generation: () => 0,
        frameKind: () => null,
      );
      h.service.applyLiveFrame(stateA, generation: 0);
      expect(h.service.directory.allEntries().single.$1.phase, 'running');

      final stateB = liveIndex([liveRow('t1', 'completedSuccess')],
          key: '/repo/b');
      h.service.setActiveSessions(
        stateB,
        generation: () => 0,
        frameKind: () => null,
      );
      h.service.applyLiveFrame(stateB, generation: 0);
      expect(h.service.directory.allEntries().single.$1.phase,
          'completedSuccess');
    });

    test('sidecar set and sidecar frames', () async {
      h.rows = [relayTask('t1', '/repo/b', status: 'completed')];
      h.service.setRelayTasks(h.rows);
      h.service.applyRelayOverview(h.rows);
      await _settle();
      expect(h.sidecars.indexes.keys, ['/repo/b']);

      h.sidecarStates['/repo/b']!.applyFrame({
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': 'ws-b',
            'sessions': [liveRow('t1', 'running')],
          },
        },
      }, onGap: () {});
      expect(h.service.directory.allEntries().single.$1.phase, 'running',
          reason: 'the sidecar layer outranks the relay row');
      final before = h.service.materializations;

      h.sidecarStates['/repo/b']!.applyFrame({
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': 'ws-b',
            'sessions': [liveRow('t1', 'completedSuccess')],
          },
        },
      }, onGap: () {});
      expect(h.service.directory.allEntries().single.$1.phase,
          'completedSuccess');
      expect(h.service.materializations, greaterThan(before));
    });

    test('snapshot cache write point', () {
      final state = liveIndex([liveRow('t-cache', 'running')],
          key: '/repo/alpha');
      h.service.setActiveSessions(
        state,
        generation: () => 0,
        frameKind: () => null,
      );
      h.service.snapshotSessionsIntoCache(state);
      // Switch away: the cached row stays visible as the gap filler.
      h.service.setActiveSessions(
        null,
        generation: () => 0,
        frameKind: () => null,
      );
      h.service.setRelayTasks(const []);
      expect(h.service.directory.allEntries().single.$1.sessionId, 't-cache');
    });

    test('store anchor write with no notify', () {
      h.service.setRelayTasks([relayTask('t1', '/repo/beta')]);
      expect(h.service.directory.allEntries().single.$2, '/repo/beta');
      h.store.anchorHome('t1', '/repo/alpha');
      expect(h.service.directory.allEntries().single.$2, '/repo/alpha',
          reason: 'store.revision invalidates even without a notification');
    });

    test('store local delete write with no notify', () {
      h.service.setRelayTasks([relayTask('t1', '/repo/beta')]);
      expect(h.service.directory.allEntries(), hasLength(1));
      h.store.addLocalDelete('t1');
      expect(h.service.directory.allEntries(), isEmpty);
    });

    test('store.load late arrival bumps the revision', () async {
      h.service.setRelayTasks([relayTask('t1', '/repo/beta')]);
      final before = h.service.materializations;
      await h.store.load();
      expect(h.service.directory.allEntries().single.$2, '/repo/beta');
      expect(h.service.materializations, before + 1,
          reason: 'the disk merge is a store write for invalidation purposes');
    });
  });

  group('two live-frame entry orders (design §0.6)', () {
    /// Runs the same three-frame sequence through [entry] and answers the
    /// resulting directory / tombstone / anchor state.
    Future<
        ({
          List<String> ids,
          bool vanished,
          Map<String, String> anchors,
        })> drive(
      Future<void> Function(
        TaskHomeService service,
        SessionsIndexState state,
        int generation,
      ) entry,
    ) async {
      final store = TaskHomeStore(deviceId: 'entry');
      final sidecars = SidecarIndexManager(
        subscribe: (key, scope, onFailure) async => SessionsIndexState(),
        dispose: (key) async {},
        available: () => false,
        probeDeleted: (scope) async => null,
        relayRows: () => const [],
        activeKey: () => null,
        normalizeKey: (raw) => raw,
        onColdRefusal: (_) {},
        onChanged: () {},
        isDisposed: () => false,
        log: (_) {},
        limit: 5,
        cooldown: const Duration(minutes: 10),
        clock: () => DateTime(2026, 10, 29),
      );
      final service = TaskHomeService(
        store: store,
        sidecars: sidecars,
        conversationGroupKey: '__conversations',
        fallbackScope: () => const {'workspacePath': '/repo/active'},
        deleteCopy: (id, scope) async {},
        onActiveFrameApplied: () {},
        onChanged: () {},
        log: (_) {},
      );
      service.setRelayTasks([relayTask('t1', '/repo/alpha')]);
      final state = SessionsIndexState();
      state.subscribedWorkspaceKey = '/repo/alpha';
      state.applyFrame({
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': 'ws',
            'sessions': [
              {'sessionId': 't1', 'title': 't1', 'phase': 'running'},
              {'sessionId': 't2', 'title': 't2', 'phase': 'running'},
            ],
          },
        },
      }, onGap: () {});
      service.setActiveSessions(state,
          generation: () => 0, frameKind: () => null);
      await entry(service, state, 0);

      // Drive the second frame without the automatic listener so the
      // NAMED entry below performs the diff (the production listener is
      // itself applyLiveFrame; the catch-up entry is only reachable from
      // the open path).
      service.setActiveSessions(state,
          generation: () => 0, frameKind: () => null);
      service.setActiveSessions(null,
          generation: () => 0, frameKind: () => null);
      // One id vanishes in a same-generation snapshot.
      state.applyFrame({
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': 'ws',
            'sessions': [
              {'sessionId': 't1', 'title': 't1', 'phase': 'running'},
            ],
          },
        },
      }, onGap: () {});
      service.setActiveSessions(state,
          generation: () => 0, frameKind: () => null);
      await entry(service, state, 0);
      return (
        ids: [for (final (e, _) in service.directory.allEntries()) e.sessionId]
          ..sort(),
        vanished: service.isSessionDeleted('t2'),
        anchors: store.homeKeys,
      );
    }

    test('applyLiveFrame (record → confirm → snapshot)', () async {
      final out = await drive((service, state, generation) async {
        service.applyLiveFrame(state, generation: generation);
      });
      expect(out.ids, ['t1']);
      expect(out.vanished, isTrue);
      expect(out.anchors, {'t1': '/repo/alpha'});
      // Order is load-bearing by design: the tombstone record must run
      // before the notify that follows (the chat banner reads it), and the
      // snapshot write is the tail of the listener sequence. Do not "merge"
      // this with the open-path entry (design §0.6).
    });

    test('applyWorkspaceOpenedCatchUp (confirm → snapshot → record)',
        () async {
      final out = await drive((service, state, generation) async {
        service.applyWorkspaceOpenedCatchUp(state, generation: generation);
      });
      expect(out.ids, ['t1']);
      expect(out.vanished, isTrue);
      expect(out.anchors, {'t1': '/repo/alpha'});
      // Deliberately the OTHER order (design §0.6): open resets the diff
      // baseline first and confirm never reads it, which is why the two
      // entries are output-equivalent today — but both entries stay.
    });

    test('onWorkspaceOpened resets the baseline; clear keeps tombstones',
        () async {
      final state = liveIndex([liveRow('t1', 'running')], key: '/repo/alpha');
      h.service.setActiveSessions(state,
          generation: () => 0, frameKind: () => null);
      h.service.applyLiveFrame(state, generation: 0);
      // Detach so only the manual entry diffs the next frame.
      h.service.setActiveSessions(null,
          generation: () => 0, frameKind: () => null);
      state.applyFrame({
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {'workspaceId': 'ws-1', 'sessions': const []},
        },
      }, onGap: () {});
      h.service.setActiveSessions(state,
          generation: () => 0, frameKind: () => null);
      h.service.applyLiveFrame(state, generation: 0);
      expect(h.service.isSessionDeleted('t1'), isTrue);

      h.service.onWorkspaceOpened();
      // A fresh baseline does not diff: the next frame only establishes.
      final fresh = liveIndex([liveRow('t9', 'running')], key: '/repo/alpha');
      h.service.setActiveSessions(fresh,
          generation: () => 0, frameKind: () => null);
      h.service.applyLiveFrame(fresh, generation: 0);
      expect(h.service.isSessionDeleted('t1'), isTrue,
          reason: 'the tombstone set itself is append-only');

      h.service.clear();
      expect(h.service.isSessionDeleted('t1'), isTrue,
          reason: 'the cross-terminal tombstone set survives suspend');
      expect(h.service.relayTasks, isEmpty);
      expect(h.service.directory.allEntries(), isEmpty);
    });
  });

  group('moved home surface', () {
    test('workspaceOfTask: a relay row resolves through its own key and '
        'never falls back to the active workspace', () {
      h.service.setWorkspaces([
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
        {'workspacePath': '/repo/beta', 'workspaceIdentity': 'beta'},
      ]);
      // The row's own key is the path spelling while the listing is
      // identity-first: [workspaceForKey]'s origin-field fallback answers a
      // minimal path scope (the same scope the list page's rows carried
      // before this task — nothing fabricated).
      h.service.setRelayTasks([relayTask('t1', '/repo/beta')]);
      expect(h.service.workspaceOfTask('t1', activeKey: 'alpha'),
          {'workspacePath': '/repo/beta'});
      // A row whose path matches an identity-first listing still resolves
      // through its own key: [workspaceKeyOf] prefers the identity, so the
      // origin-field scope names the path spelling — the same map the list
      // rows carried before this task.
      h.service.setRelayTasks([relayTask('t2', '/repo/alpha')]);
      expect(h.service.workspaceOfTask('t2', activeKey: 'alpha'),
          {'workspacePath': '/repo/alpha'});
      // …and nothing at all for an id the directory has never seen.
      expect(h.service.workspaceOfTask('missing', activeKey: 'alpha'), isNull);
    });

    test('workspaceOfTask: a live-only row falls back to the active '
        'workspace for its own streamed membership', () {
      h.service.setWorkspaces([
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
      ]);
      final state = liveIndex([liveRow('t-live', 'running')],
          key: '/repo/alpha');
      h.service.setActiveSessions(
        state,
        generation: () => 0,
        frameKind: () => null,
      );
      h.service.applyLiveFrame(state, generation: 0);
      expect(h.service.workspaceOfTask('t-live', activeKey: 'alpha'),
          {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'});
      // No live index either: the id is unknown, not "belongs to active".
      expect(h.service.workspaceOfTask('t-gone', activeKey: 'alpha'), isNull);
    });

    test('taskScopeFor: the layered home row wins, else offPeakScope', () {
      h.service.setRelayTasks([
        relayTask('t1', '/repo/a'),
        relayTask('t1', '/repo/b'),
      ]);
      h.store.anchorHome('t1', '/repo/b');
      expect(h.service.taskScopeFor('t1'), {'workspacePath': '/repo/b'});
      expect(h.service.taskScopeFor('missing'), {
        'workspacePath': '/repo/active',
      });
    });

    test('adjudicate writes the canonical anchor and notifies once', () async {
      h.service.setWorkspaces([
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
      ]);
      final home = relayTask('t1', '/repo/alpha', identity: 'alpha');
      h.service.setRelayTasks([home]);
      await h.service.adjudicate('t1', home);
      expect(h.store.homeKeys['t1'], 'alpha');
      expect(h.changed, 1);
      expect(h.deleteCalls, isEmpty);
    });

    test('adjudicate deletes every OTHER copy with its own scope, keeps '
        'going after a failure', () async {
      final home = relayTask('t1', '/repo/a');
      final mirrorB = relayTask('t1', '/repo/b');
      final mirrorC = relayTask('t1', '/repo/c', identity: 'c-id');
      h.service.setRelayTasks([home, mirrorB, mirrorC]);
      h.deleteFailures = {'/repo/b': StateError('boom')};

      await expectLater(
        h.service.adjudicate('t1', home, deleteOtherCopies: true),
        throwsA(isA<StateError>()),
      );
      expect(
        [for (final (_, scope) in h.deleteCalls) scope['workspacePath']],
        ['/repo/b', '/repo/c'],
        reason: 'the home copy is skipped and both mirrors are addressed '
            'with their own scope',
      );
      expect(h.deleteCalls.last.$2['workspaceIdentity'], 'c-id');
    });
  });

  group('notify exact counts (single owner = DeviceSession)', () {
    final params = RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
      '&name=songsong&app_version=3.16.2',
    )!;

    FakeDeviceSession session({List<Map<String, dynamic>> relayTasks = const []}) =>
        FakeDeviceSession(
          deviceId: 'd1',
          params: params,
          workspaces: const [
            {'workspacePath': '/repo/active'},
            {'workspacePath': '/repo/b'},
          ],
          relayTasks: relayTasks,
        );

    test('one active frame notifies exactly once', () {
      final s = session();
      var notifies = 0;
      s.addListener(() => notifies++);
      s.deliver({
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': 'ws-1',
            'sessions': [
              {'sessionId': 't1', 'title': 't1', 'phase': 'running'},
            ],
          },
        },
      });
      expect(notifies, 1);
    });

    test('a not-ready active frame still notifies exactly once', () {
      final s = session();
      var notifies = 0;
      s.addListener(() => notifies++);
      final notReady = SessionsIndexState();
      s.taskHome.setActiveSessions(
        notReady,
        generation: () => 0,
        frameKind: () => null,
      );
      notReady.notifyListeners();
      expect(notifies, 1,
          reason: 'the pre-extraction listener notified even when the index '
              'was not ready');
    });

    test('one sidecar frame notifies exactly once', () async {
      final s = session(relayTasks: [
        {'taskId': 't-b', 'title': 't-b', 'workspacePath': '/repo/b',
          'updatedAt': 1, 'displayStatus': 'completed'},
      ]);
      s.applyRelayOverview(s.relayTasks);
      await _settle();
      var notifies = 0;
      s.addListener(() => notifies++);
      s.sidecarStates['/repo/b']!.applyFrame({
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': 'ws-b',
            'sessions': [
              {'sessionId': 't-b', 'title': 'live', 'phase': 'running'},
            ],
          },
        },
      }, onGap: () {});
      expect(notifies, 1);
    });

    test('a sidecar subscribe completion notifies exactly once', () async {
      final s = session();
      var notifies = 0;
      s.addListener(() => notifies++);
      s.applyRelayOverview([
        {'taskId': 't-b', 'title': 't-b', 'workspacePath': '/repo/b',
          'updatedAt': 1, 'displayStatus': 'completed'},
      ]);
      await _settle();
      expect(notifies, 1);
    });

    test('a sidecar drop notifies exactly once', () async {
      final s = session(relayTasks: [
        {'taskId': 't-b', 'title': 't-b', 'workspacePath': '/repo/b',
          'updatedAt': 1, 'displayStatus': 'completed'},
      ]);
      s.applyRelayOverview(s.relayTasks);
      await _settle();
      var notifies = 0;
      s.addListener(() => notifies++);
      s.applyRelayOverview(const []);
      await _settle();
      expect(notifies, 1);
    });
  });
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Harness {
  final TaskHomeStore store = TaskHomeStore(deviceId: 'd1');
  final List<String> logs = [];
  final List<(String, Map<String, dynamic>)> deleteCalls = [];
  Map<String, Object> deleteFailures = {};
  final Map<String, SessionsIndexState> sidecarStates = {};
  List<Map<String, dynamic>> rows = const [];
  int changed = 0;

  late final SidecarIndexManager sidecars = SidecarIndexManager(
    subscribe: (key, scope, onFailure) async {
      return sidecarStates[key] ??= SessionsIndexState();
    },
    dispose: (key) async => sidecarStates.remove(key),
    available: () => true,
    probeDeleted: (scope) async => null,
    relayRows: () => rows,
    activeKey: () => null,
    normalizeKey: (raw) => raw,
    onColdRefusal: (_) {},
    onChanged: () {},
    isDisposed: () => false,
    log: logs.add,
    limit: 5,
    cooldown: const Duration(minutes: 10),
    clock: () => DateTime(2026, 10, 29),
  );

  late final TaskHomeService service = TaskHomeService(
    store: store,
    sidecars: sidecars,
    conversationGroupKey: '__conversations',
    fallbackScope: () => const {'workspacePath': '/repo/active'},
    deleteCopy: (taskId, scope) async {
      deleteCalls.add((taskId, scope));
      final failure = deleteFailures[scope['workspacePath']];
      if (failure != null) throw failure;
    },
    onActiveFrameApplied: () {},
    onChanged: () => changed++,
    log: logs.add,
  );
}
