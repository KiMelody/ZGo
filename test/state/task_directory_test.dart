import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/state/task_directory.dart';

/// TaskDirectory 的直穿测试：relay⊕live 合并规则、归档两态、置顶、计数、
/// notificationRows 含归档的显式语义（Q3a 裁决）。

SessionsIndexState _liveIndex(List<Map<String, dynamic>> entries) {
  final state = SessionsIndexState();
  state.applyFrame({
    'toSeq': 1,
    'payload': {
      'kind': 'snapshot',
      'snapshot': {'workspaceId': 'ws-1', 'sessions': entries},
    },
  }, onGap: () {});
  return state;
}

Map<String, dynamic> _relayTask(
  String id,
  String key, {
  bool archived = false,
  bool pinned = false,
  String displayStatus = 'idle',
}) =>
    {
      'taskId': id,
      'title': 'relay-$id',
      'workspaceIdentity': key,
      'displayStatus': displayStatus,
      'createdAt': 1,
      'updatedAt': 1,
      if (archived) 'archived': true,
      if (pinned) 'pinned': true,
    };

void main() {
  test('live sessions-index overrides the relay row per task id', () {
    final dir = TaskDirectory(
      relayTasks: [
        _relayTask('t1', 'alpha'),
        _relayTask('t2', 'alpha'),
      ],
      sessions: _liveIndex([
        {
          'sessionId': 't1',
          'title': 'live-t1',
          'phase': 'running',
          'lastActivityAt': 5,
        },
      ]),
      activeWorkspaceKey: 'alpha',
    );
    final all = dir.allEntries();
    expect(all, hasLength(2));
    final t1 = all.firstWhere((e) => e.$1.sessionId == 't1');
    expect(t1.$1.phase, 'running'); // live wins per task id
    expect(t1.$1.title, 'live-t1');
    expect(t1.$2, 'alpha'); // live rows attribute to the active workspace
    final t2 = all.firstWhere((e) => e.$1.sessionId == 't2');
    expect(t2.$1.phase, 'idle'); // relay base row survives
    expect(t2.$2, 'alpha');
  });

  test('entriesFor: relay rows of other workspaces stay out', () {
    final dir = TaskDirectory(
      relayTasks: [
        _relayTask('t1', 'alpha'),
        _relayTask('t2', 'beta'),
      ],
      sessions: _liveIndex([
        {'sessionId': 't3', 'title': 'live-t3', 'phase': 'running'},
      ]),
      activeWorkspaceKey: 'alpha',
    );
    expect(
      [for (final (e, _) in dir.entriesFor('alpha')) e.sessionId],
      ['t1', 't3'], // relay base + live rows of the active workspace
    );
    expect(
      [for (final (e, _) in dir.entriesFor('beta')) e.sessionId],
      ['t2'],
    );
  });

  test('archived: page views exclude, notificationRows include by default', () {
    final dir = TaskDirectory(
      relayTasks: [_relayTask('t1', 'alpha', archived: true)],
      activeWorkspaceKey: 'alpha',
    );
    expect(dir.allEntries(), isEmpty);
    expect(dir.entriesFor('alpha'), isEmpty);
    expect(dir.entriesFor('alpha', includeArchived: true), hasLength(1));
    // Q3a: archived tasks stay in the notification scope — the signature
    // makes the choice explicit (default true).
    expect(dir.notificationRows(), hasLength(1));
    expect(dir.notificationRows(includeArchived: false), isEmpty);
  });

  test('a live archived row wins the id and hides like any archived row', () {
    final dir = TaskDirectory(
      relayTasks: [_relayTask('t1', 'alpha')],
      sessions: _liveIndex([
        {
          'sessionId': 't1',
          'title': 'live-t1',
          'phase': 'completedSuccess',
          'archived': true,
        },
      ]),
      activeWorkspaceKey: 'alpha',
    );
    expect(dir.allEntries(), isEmpty);
    expect(dir.entriesFor('alpha', includeArchived: true), hasLength(1));
    expect(dir.notificationRows(), hasLength(1));
  });

  test('relay-archived survives a live row that omits the archived field', () {
    // Probed on desktop 3.12.1 (2026-09-17): archived sessions ride the
    // live sessions-index WITHOUT the archived field. The live override
    // must not clear the relay bit — relay owns archived, live can only
    // set it; unarchive propagates back via workspace-list-updated.
    final dir = TaskDirectory(
      relayTasks: [_relayTask('t1', 'alpha', archived: true)],
      sessions: _liveIndex([
        {
          'sessionId': 't1',
          'title': 'live-t1',
          'phase': 'completedSuccess',
          'lastActivityAt': 5,
        },
      ]),
      activeWorkspaceKey: 'alpha',
    );
    expect(dir.allEntries(), isEmpty);
    expect(dir.entriesFor('alpha', includeArchived: true), hasLength(1));
    expect(dir.notificationRows(), hasLength(1));
  });

  test('pinned: live entries win, archived relay rows never pin', () {
    final dir = TaskDirectory(
      relayTasks: [
        _relayTask('t1', 'alpha', pinned: true),
        _relayTask('t2', 'alpha', pinned: true, archived: true),
      ],
      sessions: _liveIndex([
        {
          'sessionId': 't1',
          'title': 'live-t1',
          'phase': 'running',
          'pinned': true,
          'lastActivityAt': 9,
        },
      ]),
      activeWorkspaceKey: 'alpha',
    );
    final pinned = dir.pinnedEntries();
    expect(pinned, hasLength(1));
    expect(pinned.single.$1.title, 'live-t1');
    expect(pinned.single.$2, 'alpha');
  });

  test('totalTaskCount: relay overview wins, live list is the fallback', () {
    expect(
      TaskDirectory(relayTasks: [
        _relayTask('t1', 'a'),
        _relayTask('t2', 'a', archived: true),
      ]).totalTaskCount,
      1,
    );
    expect(
      TaskDirectory(
        sessions: _liveIndex([
          {'sessionId': 's1', 'title': 'x', 'phase': 'running'},
        ]),
      ).totalTaskCount,
      1,
    );
  });
}
