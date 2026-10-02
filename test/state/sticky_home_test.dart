import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';

import '../helpers/fake_device_session.dart';

/// sticky live-confirmed home（design 10-02）：live 快照到达把成员资格
/// 铁证写进会话级缓存，relay 择优键不再裸奔；换工作区的新快照覆盖缓存
/// （真搬家，AC2）。断言一律走 `taskDirectory` 投影——缓存私有，行为
/// 才是契约。
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.14.0',
  )!;

  const wsAlpha = {
    'workspacePath': '/repo/alpha',
    'workspaceIdentity': 'alpha',
  };
  const wsBeta = {
    'workspacePath': '/repo/beta',
    'workspaceIdentity': 'beta',
  };

  Map<String, dynamic> relayRow(String id, String path, {int updatedAt = 1}) =>
      {
        'taskId': id,
        'title': 'relay-$id',
        'workspacePath': path,
        'displayStatus': 'idle',
        'updatedAt': updatedAt,
      };

  Map<String, dynamic> liveRow(String id) =>
      {'sessionId': id, 'title': 'live-$id', 'phase': 'running'};

  /// A fresh snapshot frame replacing the index contents wholesale.
  Map<String, dynamic> snapshot(List<Map<String, dynamic>> entries) => {
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {'workspaceId': 'ws-x', 'sessions': entries},
        },
      };

  test('live snapshot pins the confirmed home over the relay pick key', () {
    // The stale copy row (/repo/stale) wins the relay pick by updatedAt,
    // but the live index of the active workspace confirms t1 in alpha.
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      relayTasks: [relayRow('t1', '/repo/stale', updatedAt: 200)],
      entries: [liveRow('t1')],
      workspaces: [wsAlpha],
    );
    expect(
      session.taskDirectory.allEntries().single.$2,
      'alpha',
      reason: 'membership IS the ground truth of the home',
    );

    // Refresh without t1 in the index (live coverage drops): the row must
    // stay in its confirmed group — this projection now reads the cache
    // alone (the live loop has nothing to override with).
    session.sessions.applyFrame(snapshot(const []), onGap: () {});
    expect(
      session.taskDirectory.allEntries().single.$2,
      'alpha',
      reason: 'the confirmed home survives the coverage drop (AC1/AC4)',
    );
  });

  test('a new workspace snapshot overwrites the confirmed home (AC2)',
      () async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      relayTasks: [relayRow('t1', '/repo/stale', updatedAt: 200)],
      entries: [liveRow('t1')],
      workspaces: [wsAlpha, wsBeta],
    );
    expect(session.taskDirectory.allEntries().single.$2, 'alpha');

    // Real move: the bridge opens beta and its live index confirms t1
    // there — the opener records the new subscription identity, then the
    // snapshot lands.
    await session.openWorkspace(wsBeta);
    session.sessions.subscribedWorkspaceKey = 'beta';
    session.sessions.applyFrame(snapshot([liveRow('t1')]), onGap: () {});
    expect(session.taskDirectory.allEntries().single.$2, 'beta');

    // Coverage drops again: the row follows the NEW home, not alpha.
    session.sessions.applyFrame(snapshot(const []), onGap: () {});
    expect(session.taskDirectory.allEntries().single.$2, 'beta');
  });
}
