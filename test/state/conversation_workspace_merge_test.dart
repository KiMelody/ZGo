import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/task_directory.dart';

import '../helpers/fake_device_session.dart';

/// 3.16.2 conversation 工作区归并（design 10-21 Part 1 / A2a）：desktop
/// "New task" 的 `.zcode/workspace/draft-*` 目录不再各自成组，其行经
/// keyAliases 归到 default 组；default 缺席时落固定合成键（帧序无关）。
/// 行本身保留真实 workspacePath（mutation 寻址/打开作用域依赖它）。
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.16.2',
  )!;

  const defaultPath = '/home/default';
  const defaultKey = 'default-id';
  const draftPath = '/home/.zcode/workspace/draft-1';
  const draftPath2 = '/home/.zcode/workspace/draft-2';

  final wsDefault = {
    'workspacePath': defaultPath,
    'workspaceIdentity': defaultKey,
    'label': 'default',
  };
  // Live 3.16.2 shape (acceptance round 1, 2026-10-22): draft rows carry
  // NO workspacePurpose — only kind/label/workspacePath.
  final wsDraft = {
    'workspacePath': draftPath,
    'label': 'draft-1',
  };
  final wsDraft2 = {
    'workspacePath': draftPath2,
    'label': 'draft-2',
  };
  // Future-compat shape: a desktop that DOES carry the schema enum on a
  // directory outside the draft- convention must merge too.
  const purposePath = '/home/.zcode/workspace/special';
  const wsPurpose = {
    'workspacePath': purposePath,
    'workspacePurpose': 'conversation',
  };

  Map<String, dynamic> task(
    String id,
    String path, {
    String title = 'chat',
    bool pinned = false,
  }) =>
      {
        'taskId': id,
        'title': title,
        'workspacePath': path,
        'pinned': pinned,
        'displayStatus': 'idle',
        'updatedAt': 1,
      };

  FakeDeviceSession seeded({
    List<Map<String, dynamic>> workspaces = const [],
    List<Map<String, dynamic>> relayTasks = const [],
  }) =>
      FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        workspaces: workspaces,
        relayTasks: relayTasks,
      );

  test('the path convention is the live 3.16.2 signal', () {
    expect(
      isConversationWorkspacePath(
          r'C:\Users\Melody\.zcode\workspace\draft-701cf0e6'),
      isTrue,
    );
    expect(
      isConversationWorkspacePath('/home/melody/.zcode/workspace/draft-x'),
      isTrue,
    );
    expect(
      isConversationWorkspacePath(
          r'C:\Users\Melody\.zcode\workspace\default'),
      isFalse,
    );
    expect(isConversationWorkspacePath(r'F:\ZLinker'), isFalse);
    expect(isConversationWorkspacePath('draft-x'), isFalse,
        reason: 'the marker includes the .zcode/workspace segment');
  });

  test('workspacePurpose==conversation still merges (future desktops)', () {
    final session = seeded(
      workspaces: [wsDefault, wsPurpose],
      relayTasks: [task('t1', purposePath)],
    );
    expect(session.taskDirectory.keyAliases[purposePath], defaultKey);
    expect(
      session.taskDirectory.entriesFor(defaultKey).map((e) => e.$1.sessionId),
      ['t1'],
    );
  });

  test('conversation rows merge into the default group', () {
    final session = seeded(
      workspaces: [wsDefault, wsDraft],
      relayTasks: [
        task('t1', draftPath),
        {...task('t2', defaultPath), 'workspaceIdentity': defaultKey},
      ],
    );
    final aliases = session.taskDirectory.keyAliases;
    expect(aliases[draftPath], defaultKey,
        reason: 'conversation path aliases to the default canonical key');
    expect(aliases[conversationsWorkspaceKey], defaultKey,
        reason: 'the synthetic group key normalizes to the same target');
    expect(aliases[defaultKey], defaultKey);

    final defaultRows = session.taskDirectory.entriesFor(defaultKey);
    expect(defaultRows.map((e) => e.$1.sessionId).toSet(), {'t1', 't2'},
        reason: 'draft rows display under the default card');
    expect(session.taskDirectory.entriesFor(draftPath), isEmpty,
        reason: 'no draft group owns the row anymore');
    // The row keeps its real origin for mutation addressing / opening.
    final draftRow =
        defaultRows.firstWhere((e) => e.$1.sessionId == 't1').$1;
    expect(draftRow.raw['workspacePath'], draftPath);
  });

  test('pinned conversation rows merge into the default group', () {
    final session = seeded(
      workspaces: [wsDefault, wsDraft],
      relayTasks: [task('tp', draftPath, pinned: true)],
    );
    final pinned = session.taskDirectory.pinnedEntries();
    expect(pinned.single.$1.sessionId, 'tp');
    expect(pinned.single.$2, defaultKey);
  });

  test('default workspace absent: the fixed synthetic key owns the group', () {
    final session = seeded(
      workspaces: [wsDraft],
      relayTasks: [task('t1', draftPath)],
    );
    final aliases = session.taskDirectory.keyAliases;
    expect(aliases[draftPath], conversationsWorkspaceKey);
    expect(aliases[conversationsWorkspaceKey], conversationsWorkspaceKey);
    expect(
      session.taskDirectory
          .entriesFor(conversationsWorkspaceKey)
          .map((e) => e.$1.sessionId),
      ['t1'],
    );
  });

  test('frame order never moves a conversation row group', () {
    Map<String, String?> groupsOf(List<Map<String, dynamic>> rows) {
      final session = seeded(
        workspaces: [wsDefault, wsDraft, wsDraft2],
        relayTasks: rows,
      );
      return {
        for (final (entry, key) in session.taskDirectory.allEntries())
          entry.sessionId: key,
      };
    }

    final forward = groupsOf([task('ta', draftPath), task('tb', draftPath2)]);
    final reversed = groupsOf([task('tb', draftPath2), task('ta', draftPath)]);
    expect(forward, reversed);
    expect(forward, {'ta': defaultKey, 'tb': defaultKey});
  });

  test('non-conversation workspaces keep their own groups', () {
    const projectPath = '/repo/project';
    const projectKey = 'project-id';
    final session = seeded(
      workspaces: [
        wsDefault,
        {
          'workspacePath': projectPath,
          'workspaceIdentity': projectKey,
          'label': 'project',
        },
        wsDraft,
      ],
      relayTasks: [
        // Production normalizes relay rows with the listed workspace's
        // identity before they reach the directory; the fake seeds raw.
        {...task('t1', projectPath), 'workspaceIdentity': projectKey},
        task('t2', draftPath),
      ],
    );
    final aliases = session.taskDirectory.keyAliases;
    expect(aliases[projectPath], projectKey);
    expect(aliases[projectKey], projectKey);
    expect(
      session.taskDirectory.entriesFor(projectKey).map((e) => e.$1.sessionId),
      ['t1'],
    );
    expect(
      session.taskDirectory.entriesFor(defaultKey).map((e) => e.$1.sessionId),
      ['t2'],
    );
  });

  test('live conversation rows canonicalize through the same alias', () {
    final session = seeded(workspaces: [wsDefault, wsDraft]);
    // Subscribe the draft workspace and deliver its live index: membership
    // alone must not keep the row under the draft path group.
    session.sessions.subscribedWorkspaceKey = draftPath;
    session.deliver({
      'toSeq': 2,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'workspaceId': 'ws-draft',
          'sessions': [
            {
              'sessionId': 'live-1',
              'title': 'live',
              'phase': 'running',
              'lastActivityAt': 1,
            },
          ],
        },
      },
    });
    final row = session.taskDirectory.allEntries().single;
    expect(row.$1.sessionId, 'live-1');
    expect(row.$2, defaultKey);
  });

  Map<String, dynamic> draftIndex(String id) => {
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': 'ws-draft',
            'sessions': [
              // 3.16.2 live index rows carry NO workspacePath (probe3162_p1
              // schema) — the shape the merge layer actually receives.
              {'sessionId': id, 'title': 'live', 'phase': 'running'},
            ],
          },
        },
      };

  test('live-merged conversation rows open under their draft scope', () {
    final session = seeded(
      workspaces: [wsDefault, wsDraft],
      relayTasks: [task('t1', draftPath)],
    );
    // The draft workspace is the ACTIVE subscription (the user just came
    // back from that conversation): the live body — no workspacePath —
    // replaces the relay body in the merge.
    session.sessions.subscribedWorkspaceKey = draftPath;
    session.deliver(draftIndex('t1'));
    final row = session.taskDirectory.allEntries().single;
    expect(row.$2, defaultKey, reason: 'display merge unchanged');
    // Without a stamped origin the row would resolve to the DEFAULT
    // workspace and every command dead-end (proto.sessionNotFound).
    final ws = TaskDirectory.workspaceForKey(
      session.workspaces,
      row.$1,
      row.$2,
    );
    expect(ws?['workspacePath'], draftPath);
  });

  test('cached conversation rows (switched away) open under draft scope',
      () {
    final session = seeded(workspaces: [wsDefault, wsDraft]);
    session.sessions.subscribedWorkspaceKey = draftPath;
    session.deliver(draftIndex('prewarm-1'));
    // Switch away from the draft workspace: the cache leg now supplies the
    // row (the deferred-prewarm shape — no relay anchor).
    session.sessions.subscribedWorkspaceKey = defaultKey;
    session.sessions.ready = false;
    final row = session.taskDirectory.allEntries().single;
    expect(row.$1.sessionId, 'prewarm-1');
    expect(row.$2, defaultKey);
    final ws = TaskDirectory.workspaceForKey(
      session.workspaces,
      row.$1,
      row.$2,
    );
    expect(ws?['workspacePath'], draftPath);
  });
}
