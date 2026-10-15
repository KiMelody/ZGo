import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';

import '../helpers/fake_device_session.dart';

/// Per-workspace live 快照缓存的生命周期（design 10-15-task-live-snapshot-
/// cache §测试矩阵）：切走保留/切回整体覆盖（含首帧移除）、切回首帧未到
/// 不闪空、relay 接管、墓碑读点过滤、probe 写点过滤、sessionOnly 延续、
/// suspend 清空、缓存不建锚。切区一律「改 subscribedWorkspaceKey 再投新键
/// 帧」驱动（空快照投原键=权威空重种子，check P2-1）。断言一律走
/// `taskDirectory` 投影与 `taskHomeStore` 测试缝——行为才是契约。
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.14.0',
  )!;

  final wsAlpha = {
    'workspacePath': '/repo/alpha',
    'workspaceIdentity': 'alpha',
  };
  final wsBeta = {
    'workspacePath': '/repo/beta',
    'workspaceIdentity': 'beta',
  };

  Map<String, dynamic> liveRow(String id, {String title = 'live'}) =>
      {'sessionId': id, 'title': '$title-$id', 'phase': 'running'};

  Map<String, dynamic> snapshot(List<Map<String, dynamic>> entries) => {
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {'workspaceId': 'ws-x', 'sessions': entries},
        },
      };

  FakeDeviceSession seeded({
    List<Map<String, dynamic>> entries = const [],
    List<Map<String, dynamic>> workspaces = const [],
  }) =>
      FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        entries: entries,
        workspaces: workspaces,
      );

  test('#1 切走保留：t1 留在 alpha 组（缓存补底），B 区行独立归组', () {
    final session = seeded(
      entries: [liveRow('t1')],
      workspaces: [wsAlpha, wsBeta],
    );
    // 切到 beta：改键 + 投新键帧（种子缓存 alpha 不被触碰）。
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.deliver(snapshot([liveRow('tB')]));
    final all = session.taskDirectory.allEntries();
    final t1 = all.firstWhere((e) => e.$1.sessionId == 't1');
    expect(t1.$2, 'alpha', reason: '缓存行归快照键组，分组零漂移');
    expect(t1.$1.title, 'live-t1', reason: '缓存的行体=最后快照');
    final tB = all.firstWhere((e) => e.$1.sessionId == 'tB');
    expect(tB.$2, 'beta');
  });

  test('#1b 切回覆盖：同 id 新首帧整体接管缓存行', () {
    final session = seeded(
      entries: [liveRow('t1')],
      workspaces: [wsAlpha, wsBeta],
    );
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.deliver(snapshot([]));
    session.sessions.subscribedWorkspaceKey = 'alpha';
    session.deliver(snapshot([liveRow('t1', title: 'fresh')]));
    final t1 = session.taskDirectory.allEntries()
        .firstWhere((e) => e.$1.sessionId == 't1');
    expect(t1.$1.title, 'fresh-t1', reason: '活跃 live 胜缓存');
  });

  test('#2 relay 接管：overview 带上 t1 后缓存行退位', () {
    final session = seeded(
      entries: [liveRow('t1')],
      workspaces: [wsAlpha, wsBeta],
    );
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.deliver(snapshot([]));
    session.applyRelayOverview([
      {
        'taskId': 't1',
        'title': 'relay-t1',
        'workspacePath': '/repo/alpha',
        'displayStatus': 'idle',
        'createdAt': 1,
        'updatedAt': 1,
      },
    ]);
    final t1 = session.taskDirectory.allEntries()
        .firstWhere((e) => e.$1.sessionId == 't1');
    expect(t1.$1.title, 'relay-t1', reason: 'relay 行体胜缓存补底');
  });

  test('#3 墓碑读点过滤：本机确认删除立即清掉缓存补底行', () {
    final session = seeded(
      entries: [liveRow('t1'), liveRow('t2')],
      workspaces: [wsAlpha, wsBeta],
    );
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.deliver(snapshot([]));
    session.taskHomeStore.addLocalDelete('t1');
    expect(
      session.taskDirectory.allEntries().map((e) => e.$1.sessionId),
      isNot(contains('t1')),
    );
  });

  test('#4 probe 写点过滤：deletedTaskIds 不进缓存', () {
    final session = seeded(
      entries: [liveRow('t1')],
      workspaces: [wsAlpha, wsBeta],
    );
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.sessions.deletedTaskIds = const {'t2'};
    session.deliver(snapshot([liveRow('t2'), liveRow('t3')]));
    session.sessions.subscribedWorkspaceKey = 'alpha';
    session.sessions.ready = false; // 只看缓存，隔离 live 层
    final ids = session.taskDirectory.allEntries().map((e) => e.$1.sessionId);
    expect(ids, isNot(contains('t2')), reason: '写点已滤 probe 集');
    expect(ids, containsAll(<String>['t1', 't3']),
        reason: '过滤不误伤：同帧的未删行照常入缓存');
  });

  test('#5 sessionOnly 延续：切走后无 relay 锚的缓存行仍带标记', () {
    final session = seeded(
      entries: [liveRow('t1')],
      workspaces: [wsAlpha, wsBeta],
    );
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.deliver(snapshot([]));
    expect(session.taskDirectory.sessionOnlyIds, contains('t1'));
  });

  test('#6 suspend 清空：目录状态整体归零', () async {
    final session = seeded(
      entries: [liveRow('t1')],
      workspaces: [wsAlpha, wsBeta],
    );
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.deliver(snapshot([]));
    session.sessions.ready = false; // fake live 层常驻，模拟 sessions=null
    await session.suspend();
    expect(session.taskDirectory.allEntries(), isEmpty);
  });

  test('#7 缓存不建锚：写入前后锚集无变化（防污染门回归守护）', () {
    final session = seeded(
      entries: [liveRow('t1')],
      workspaces: [wsAlpha, wsBeta],
    );
    expect(session.taskHomeStore.homeKeys, isEmpty,
        reason: '种子帧无 relay 行——不建锚（no relay row → no establish）');
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.deliver(snapshot([]));
    expect(session.taskHomeStore.homeKeys, isEmpty,
        reason: '缓存补底行在场也不触碰锚定通道');
  });

  test('#9 切回不闪空：首帧未到（ready=false）行仍经缓存在场', () {
    final session = seeded(
      entries: [liveRow('t1')],
      workspaces: [wsAlpha, wsBeta],
    );
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.deliver(snapshot([]));
    session.sessions.subscribedWorkspaceKey = 'alpha';
    session.sessions.ready = false; // 重进瞬间，新订阅首帧未到
    final all = session.taskDirectory.allEntries();
    expect(all.map((e) => e.$1.sessionId), contains('t1'),
        reason: '「重进不闪空」的单测钉子');
  });

  test('#10 重进首帧移除行：空快照整体覆盖缓存，行消失', () {
    final session = seeded(
      entries: [liveRow('t1')],
      workspaces: [wsAlpha, wsBeta],
    );
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.deliver(snapshot([]));
    session.sessions.subscribedWorkspaceKey = 'alpha';
    session.deliver(snapshot(const [])); // 远端已删——权威空重种子
    expect(
      session.taskDirectory.allEntries().map((e) => e.$1.sessionId),
      isNot(contains('t1')),
    );
  });

  Map<String, dynamic> relayRow(String id, String path) => {
        'taskId': id,
        'title': 'relay-$id',
        'workspacePath': path,
        'displayStatus': 'idle',
        'createdAt': 1,
        'updatedAt': 1,
      };

  test('#M1 多副本行切区不迁移：组键恒=冷选（PMA110 round-2 回归钉子）', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      relayTasks: [relayRow('t1', '/repo/mirror'), relayRow('t1', '/repo/real')],
      entries: [liveRow('t1')],
      workspaces: [wsAlpha, wsBeta],
    );
    expect(session.taskDirectory.allEntries().single.$2, '/repo/mirror',
        reason: '多副本冷选=字典序 mirror，不随种子帧的 alpha 键');
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.deliver(snapshot([liveRow('t1')])); // B 区 live 也声称成员资格
    expect(session.taskDirectory.allEntries().single.$2, '/repo/mirror',
        reason: '切区后组键不变——不再迁移');
  });

  test('#M2 锚定多副本行切区不翻转：组键=锚', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      relayTasks: [relayRow('t1', '/repo/mirror'), relayRow('t1', '/repo/real')],
      entries: [liveRow('t1')],
      workspaces: [wsAlpha, wsBeta],
    );
    session.taskHomeStore.anchorHome('t1', 'alpha');
    expect(session.taskDirectory.allEntries().single.$2, 'alpha');
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.deliver(snapshot([liveRow('t1')]));
    expect(session.taskDirectory.allEntries().single.$2, 'alpha',
        reason: '锚钉组，活跃区无关');
  });
}
