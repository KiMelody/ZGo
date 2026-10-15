import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/connection_params.dart';

import '../helpers/fake_device_session.dart';

/// 持久任务锚的生命周期（design 10-15，task 10-15-task-directory-stable-
/// anchor）：防污染门三态（多副本 live 不建立/一致仅刷新/单副本建立）、
/// 对账自愈（锚服从单副本 relay 证据）、墓碑即删锚、合成状态一致性
/// （taskDisplayStatus 与可见行同一选择）、锚与墓碑落盘-重启恢复、fake
/// session 多副本回放、键别名规范化（check P1-2）与墓碑 add-only + TTL
/// （check P1-1）。断言一律走 `taskDirectory` 投影与 `taskHomeStore`
/// 测试缝——行为才是契约。
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.14.0',
  )!;

  Map<String, dynamic> relayRow(
    String id,
    String key, {
    int updatedAt = 1,
    String displayStatus = 'idle',
  }) =>
      {
        'taskId': id,
        'title': 'relay-$id',
        'workspacePath': key,
        'displayStatus': displayStatus,
        'createdAt': 1,
        'updatedAt': updatedAt,
      };

  Map<String, dynamic> liveRow(String id) =>
      {'sessionId': id, 'title': 'live-$id', 'phase': 'running'};

  Map<String, dynamic> snapshot(List<Map<String, dynamic>> entries) => {
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {'workspaceId': 'ws-x', 'sessions': entries},
        },
      };

  group('anti-pollution gate (design §1.1 防污染门三态)', () {
    test('multi-copy live frames never ESTABLISH an anchor — coverage drop '
        'falls back to the cold pick', () {
      // The polluted registry lists t1 in two workspaces; the live index
      // of the active workspace confirms it in alpha. Membership evidence
      // is untrusted while the copies disagree — no anchor may be written.
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [
          relayRow('t1', '/repo/stale', updatedAt: 200),
          relayRow('t1', '/repo/other', updatedAt: 100),
        ],
        entries: [liveRow('t1')],
        workspaces: const [
          {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
        ],
      );
      expect(session.taskHomeStore.homeKeys, isEmpty,
          reason: 'multi-copy relay + live confirm → the gate refuses');
      // 开窗在 live 组（R4 live 覆盖照旧）。
      expect(session.taskDirectory.allEntries().single.$2, 'alpha');
      // 关窗回冷选组：确定性两态，不是回归（R4）——分组由稳定 pick 决定。
      session.sessions.applyFrame(snapshot(const []), onGap: () {});
      expect(session.taskDirectory.allEntries().single.$2, '/repo/other',
          reason: 'no anchor was established; the cold pick (key lex) rules');
    });

    test('multi-copy live confirmation agreeing with an existing anchor only '
        'REFRESHES it (source ③ — the anchor survives)', () {
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [
          relayRow('t1', '/repo/alpha', updatedAt: 200),
          relayRow('t1', '/repo/beta', updatedAt: 100),
        ],
        entries: [liveRow('t1')],
        workspaces: const [
          {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
        ],
      );
      // Seed the anchor the gate is allowed to keep (not flip): alpha was
      // confirmed while the registry was still single-copy.
      session.taskHomeStore.anchorHome('t1', 'alpha');
      session.sessions.applyFrame(
        snapshot([liveRow('t1')]),
        onGap: () {},
      ); // multi-copy now — a live frame agreeing with alpha
      expect(session.taskHomeStore.homeKeys['t1'], 'alpha',
          reason: 'agreeing confirmation refreshes, never flips (source ③)');

      // The same multi-copy frame DISAGREEING must not flip either.
      session.sessions.subscribedWorkspaceKey = 'beta';
      session.sessions.applyFrame(
        snapshot([liveRow('t1')]),
        onGap: () {},
      );
      expect(session.taskHomeStore.homeKeys['t1'], 'alpha',
          reason: 'gate: a disagreeing live frame on a multi-copy id '
              'establishes and flips nothing');
    });

    test('single-copy relay + live confirmation ESTABLISHES the anchor '
        '(source ②)', () {
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [relayRow('t1', '/repo/stale', updatedAt: 200)],
        entries: [liveRow('t1')],
        workspaces: const [
          {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
        ],
      );
      expect(session.taskHomeStore.homeKeys['t1'], 'alpha',
          reason: 'an unambiguous registry cannot be mirror pollution — '
              'membership is the ground truth');
      // Coverage drop: the anchor now carries the group (AC1/AC4).
      session.sessions.applyFrame(snapshot(const []), onGap: () {});
      expect(session.taskDirectory.allEntries().single.$2, 'alpha');
    });
  });

  group('reconcile self-heal (design §1.1 对账自愈)', () {
    test('an anchored id whose relay set collapsed to a single foreign copy '
        'obeys the relay', () {
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [relayRow('t1', '/repo/alpha')],
      );
      session.taskHomeStore.anchorHome('t1', 'beta');
      expect(session.taskDirectory.allEntries().single.$2, 'beta');

      session.applyRelayOverview([relayRow('t1', '/repo/alpha', updatedAt: 5)]);

      expect(session.taskHomeStore.homeKeys['t1'], '/repo/alpha',
          reason: 'single-copy relay evidence wins — post-cleanup stale '
              'anchors AND real moves both land here');
      expect(session.taskDirectory.allEntries().single.$2, '/repo/alpha');
    });

    test('live-visible anchored ids are skipped — the live channel owns '
        'them (the two channels never fight)', () {
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [relayRow('t1', '/repo/alpha')],
        entries: [liveRow('t1')],
        workspaces: const [
          {'workspacePath': '/repo/live-ws', 'workspaceIdentity': 'live-ws'},
        ],
      );
      session.taskHomeStore.anchorHome('t1', 'old-ws');
      session.reconcileTaskHomes();
      expect(session.taskHomeStore.homeKeys['t1'], 'old-ws',
          reason: 'confirmLiveHomes manages live-visible ids; reconcile '
              'must not overwrite the anchor with the relay key');
    });

    test('a deleted id drops its anchor at once (墓碑即删锚)', () async {
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [relayRow('t1', '/repo/alpha')],
      );
      session.taskHomeStore.anchorHome('t1', 'alpha');
      await session.deleteTask('t1'); // default handler answers success
      expect(session.taskHomeStore.homeKeys.containsKey('t1'), isFalse);
      expect(session.taskHomeStore.locallyDeletedTaskIds, {'t1'});
    });

    test('a re-listed id does NOT untombstone — stale frame or surviving '
        'copy alike (check P1-1: add-only + TTL)', () {
      // 场景 A：stale 总览帧仍带该行（内存概览滞后于删除，30s 刷新节拍
      // 内最常见）——旧行为会在 reconcile 时剥掉墓碑，live 索引随即复活它。
      final staleFrame = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [relayRow('t2', '/repo/alpha')],
      );
      staleFrame.taskHomeStore.addLocalDelete('t2');
      staleFrame.applyRelayOverview(
          [relayRow('t2', '/repo/alpha', updatedAt: 9)]);
      expect(staleFrame.taskHomeStore.locallyDeletedTaskIds, {'t2'},
          reason: 'a re-listing overview is too weak to lift a tombstone — '
              'surviving copies and stale cache frames re-list deleted ids '
              'legitimately while the live index keeps serving them');
      expect(staleFrame.taskDirectory.allEntries(), isEmpty,
          reason: 'the tombstoned row stays hidden through the reconcile');

      // 场景 B：删除只杀了 A 副本，幸存镜像副本在新总览里重列同一 id。
      final survivingCopy = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: const [],
      );
      survivingCopy.taskHomeStore.addLocalDelete('t3');
      survivingCopy
          .applyRelayOverview([relayRow('t3', '/repo/mirror', updatedAt: 3)]);
      expect(survivingCopy.taskHomeStore.locallyDeletedTaskIds, {'t3'});
      expect(survivingCopy.taskDirectory.allEntries(), isEmpty,
          reason: 'the surviving mirror copy cannot resurrect the task');
    });

    test('TTL expiry self-clears: past 7 days the tombstone is pruned and '
        'the row becomes visible again', () {
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: const [],
      );
      session.taskHomeStore.addLocalDelete(
        't2',
        now: clock.now().subtract(const Duration(days: 8)),
      );
      session.applyRelayOverview([relayRow('t2', '/repo/alpha')]);
      expect(session.taskHomeStore.locallyDeletedTaskIds, isEmpty,
          reason: 'the expired tombstone is the one removal path — reconcile '
              'prunes it');
      expect(session.taskDirectory.allEntries(), hasLength(1),
          reason: 'expired: the row is visible again');
    });
  });

  group('field-level synthesis (design §2.2, 两套择优合一)', () {
    test('the visible row carries the M1 winner status; taskDisplayStatus '
        'reads the same selection', () {
      // Mirror twins with drifted displayStatus (spec §3.6's sess_3e50d44f
      // shape): the terminal copy wins the STATUS even though the body /
      // group come from the cold pick's home copy — and
      // taskDisplayStatus returns exactly what the row shows.
      for (final rows in [
        [
          relayRow('t1', '/repo/a', updatedAt: 999, displayStatus: 'running'),
          relayRow('t1', '/repo/b', updatedAt: 1, displayStatus: 'completed'),
        ],
        [
          relayRow('t1', '/repo/b', updatedAt: 1, displayStatus: 'completed'),
          relayRow('t1', '/repo/a', updatedAt: 999, displayStatus: 'running'),
        ],
      ]) {
        final session = FakeDeviceSession(
          deviceId: 'd1',
          params: params,
          relayTasks: rows,
        );
        final row = session.taskDirectory.allEntries().single;
        expect(row.$1.phase, 'completedSuccess',
            reason: 'field synthesis: terminal-first status on the row');
        expect(session.taskDisplayStatus('t1'), 'completed',
            reason: 'the two former picks are one selection now');
      }
    });

    test('body fields ride the home copy while the status is synthesized',
        () {
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [
          {
            ...relayRow('t1', '/repo/a', updatedAt: 1),
            'title': 'home-title',
            'lastError': {'message': 'boom', 'traceId': 'tr-1'},
          },
          relayRow('t1', '/repo/b', updatedAt: 999, displayStatus: 'error'),
        ],
      );
      final row = session.taskDirectory.allEntries().single;
      // Cold pick: error copy is terminal → home; status winner also the
      // error copy — body and status agree here.
      expect(row.$2, '/repo/b');
      expect(row.$1.title, 'relay-t1');
      // The anchored home overrides the body source without touching the
      // synthesized status.
      session.taskHomeStore.anchorHome('t1', '/repo/a');
      final anchored = session.taskDirectory.allEntries().single;
      expect(anchored.$1.title, 'home-title',
          reason: 'body fields (title/lastError/…) ride the anchored copy');
      expect(anchored.$1.lastErrorTraceId, 'tr-1');
      expect(anchored.$2, '/repo/a');
      expect(session.taskDisplayStatus('t1'), 'error',
          reason: 'the M1 winner is anchor-independent');
    });
  });

  group('persistence (design §1.1/§1.2 落盘-重启恢复)', () {
    test('anchors and tombstones survive a session restart; the restored '
        'anchor pins the group', () async {
      SharedPreferences.setMockInitialValues({});
      final first = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [
          relayRow('t1', '/repo/alpha', updatedAt: 1),
          relayRow('t1', '/repo/beta', updatedAt: 999),
        ],
      );
      first.taskHomeStore.anchorHome('t1', '/repo/beta');
      first.taskHomeStore.addLocalDelete('t2');
      await first.taskHomeStore.load(); // flush: merge is a no-op, saves land

      final restarted = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [
          relayRow('t1', '/repo/alpha', updatedAt: 1),
          relayRow('t1', '/repo/beta', updatedAt: 999),
        ],
      );
      await restarted.taskHomeStore.load();
      expect(restarted.taskHomeStore.homeKeys, {'t1': '/repo/beta'},
          reason: 'R1: anchors survive restarts');
      expect(restarted.taskHomeStore.locallyDeletedTaskIds, {'t2'},
          reason: 'R1: tombstones survive restarts');
      // The restored anchor selects the home copy — the cold pick would
      // say '/repo/alpha' (lex-smaller key); the anchored '/repo/beta'
      // copy must win body AND group instead.
      expect(restarted.taskDirectory.allEntries().single.$2, '/repo/beta');
      expect(restarted.taskDirectory.allEntries().single.$1.lastActivityAt,
          999);
    });
  });

  group('fake-session multi-copy replay (模拟器快验的 fake 覆盖)', () {
    test('pollution replay: touches never flip the group; cleanup '
        '(single copy) reconciles the anchor home', () {
      // Seed: single copy (real) + the live confirm anchors it — the
      // pre-pollution state. Path-only workspaces keep the live key and
      // the relay row key in the same string form (identity-carrying
      // workspaces would anchor the identity instead — same workspace,
      // different spelling).
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [relayRow('t1', '/repo/real', updatedAt: 100)],
        entries: [liveRow('t1')],
        workspaces: const [
          {'workspacePath': '/repo/real'},
        ],
      );
      expect(session.taskHomeStore.homeKeys['t1'], '/repo/real',
          reason: 'source ②: single-copy relay + live confirm anchors');

      // Pollution regenerates: a second copy appears; touches flip
      // updatedAt constantly — the anchor holds the group through all of
      // it (coverage on: live wins; coverage off: the anchor pins real).
      session.applyRelayOverview([
        relayRow('t1', '/repo/real', updatedAt: 100),
        relayRow('t1', '/repo/mirror', updatedAt: 200),
      ]);
      session.sessions.applyFrame(snapshot(const []), onGap: () {});
      expect(session.taskDirectory.allEntries().single.$2, '/repo/real',
          reason: 'anchor pins the group while the copies disagree');
      session.applyRelayOverview([
        relayRow('t1', '/repo/real', updatedAt: 300),
        relayRow('t1', '/repo/mirror', updatedAt: 400),
      ]);
      expect(session.taskHomeStore.homeKeys['t1'], '/repo/real',
          reason: 'multi-copy reconcile keeps the anchor (gate)');
      expect(session.taskDirectory.allEntries().single.$2, '/repo/real');

      // Upstream cleanup: the mirror copy goes away, the surviving real
      // copy agrees — the anchor is confirmed, not moved.
      session.applyRelayOverview([relayRow('t1', '/repo/real', updatedAt: 500)]);
      expect(session.taskHomeStore.homeKeys['t1'], '/repo/real');
      expect(session.taskDirectory.allEntries().single.$2, '/repo/real');
    });
  });

  group('key alias normalization (check P1-2)', () {
    test('identity-vs-path spelling of the SAME workspace never reads as a '
        'move: anchor holds, no group disappears', () {
      // The check's实证案例: workspace 'alpha' is listed with
      // workspaceIdentity while the relay row carries only the path
      // '/repo/alpha'. The live confirm anchors the workspaceKeyOf
      // spelling ('alpha'); the reconcile's single-copy relay key arrives
      // path-spelled — canonicalized, it is the SAME workspace, so the
      // pre-fix false move (anchor flip → row vanishing from every group)
      // cannot happen.
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [relayRow('t1', '/repo/alpha')],
        entries: [liveRow('t1')],
        workspaces: const [
          {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
        ],
      );
      expect(session.taskHomeStore.homeKeys['t1'], 'alpha',
          reason: 'source ②: the live confirm anchors the canonical '
              '(workspaceKeyOf) spelling');

      // 关窗 + reconcile（对账的单副本 key 是 path 拼写）。
      session.sessions.applyFrame(snapshot(const []), onGap: () {});
      session.reconcileTaskHomes();
      expect(session.taskHomeStore.homeKeys['t1'], 'alpha',
          reason: 'canonicalized relay key == anchor: no flip');
      expect(session.taskDirectory.entriesFor('alpha'), hasLength(1),
          reason: 'the anchored group still holds the row');
      expect(session.taskDirectory.allEntries(), hasLength(1),
          reason: 'no group disappearance');
    });

    test('reconcile follows a REAL move across spellings: single path-only '
        'copy in a new workspace wins over the old identity anchor', () {
      // The alias table must not swallow genuine moves: a single copy in a
      // DIFFERENT workspace canonicalizes to a different key and the
      // self-heal overwrites the anchor as before.
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: [relayRow('t1', '/repo/alpha')],
        workspaces: const [
          {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
        ],
      );
      session.taskHomeStore.anchorHome('t1', 'alpha');

      session.applyRelayOverview([
        {...relayRow('t1', '/repo/moved'), 'workspaceIdentity': 'moved'},
      ]);

      expect(session.taskHomeStore.homeKeys['t1'], 'moved',
          reason: 'the single copy now lists workspaceIdentity=moved — a '
              'real move, not a spelling alias');
      expect(session.taskDirectory.allEntries().single.$2, 'moved');
    });
  });
}
