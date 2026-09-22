import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/state/task_directory.dart';

/// TaskDirectory 的直穿测试：relay⊕live 合并规则、归档两态、置顶、计数、
/// notificationRows 含归档的显式语义（Q3a 裁决）。

SessionsIndexState _liveIndex(
  List<Map<String, dynamic>> entries, {
  String? subscribedWorkspaceKey,
  Set<String> deletedTaskIds = const {},
}) {
  final state = SessionsIndexState();
  state.subscribedWorkspaceKey = subscribedWorkspaceKey;
  state.deletedTaskIds = deletedTaskIds;
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
  int updatedAt = 1,
}) =>
    {
      'taskId': id,
      'title': 'relay-$id',
      'workspaceIdentity': key,
      'displayStatus': displayStatus,
      'createdAt': 1,
      'updatedAt': updatedAt,
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
      ], subscribedWorkspaceKey: 'alpha'),
    );
    final all = dir.allEntries();
    expect(all, hasLength(2));
    final t1 = all.firstWhere((e) => e.$1.sessionId == 't1');
    expect(t1.$1.phase, 'running'); // live wins per task id
    expect(t1.$1.title, 'live-t1');
    expect(t1.$2, 'alpha'); // live rows attribute by the index's identity
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
      ], subscribedWorkspaceKey: 'alpha'),
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
    );
    expect(dir.allEntries(), isEmpty);
    expect(dir.entriesFor('alpha'), isEmpty);
    expect(dir.entriesFor('alpha', includeArchived: true), hasLength(1));
    // Q3a: archived tasks stay in the notification scope — the signature
    // makes the choice explicit (default true).
    expect(dir.notificationRows(), hasLength(1));
    expect(dir.notificationRows(includeArchived: false), isEmpty);
  });

  test('a live row cannot set archived — the relay bit is the authority', () {
    // R1 (2026-09-17): the relay `archived` field is the sole authority;
    // the old live-frame fallback (entry.raw['archived']) is deleted. A
    // live row carrying the field must neither hide nor archive itself.
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
    );
    expect(dir.allEntries(), hasLength(1));
    expect(dir.entriesFor('alpha', includeArchived: true), isEmpty);
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
      ], subscribedWorkspaceKey: 'alpha'),
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
      ], subscribedWorkspaceKey: 'alpha'),
    );
    final pinned = dir.pinnedEntries();
    expect(pinned, hasLength(1));
    expect(pinned.single.$1.title, 'live-t1');
    expect(pinned.single.$2, 'alpha');
  });

  test('live rows attribute by the index subscription identity, not the '
      'relay pick key', () {
    // 2026-09-23 mirror-row fix: the relay key can be a desktop mirror
    // row (wrong group), while the live sessions-index is the product of
    // `listSessions(directory = workspace)` — membership in it is the
    // ground truth of the session's home. The live row therefore
    // attributes by the index's subscription identity and ignores the
    // relay pick key entirely.
    final dir = TaskDirectory(
      relayTasks: [_relayTask('t1', 'beta')],
      sessions: _liveIndex([
        {
          'sessionId': 't1',
          'title': 'live-t1',
          'phase': 'running',
          'lastActivityAt': 5,
        },
      ], subscribedWorkspaceKey: 'alpha'), // the index is subscribed to alpha
    );
    final t1 = dir.allEntries().single;
    expect(t1.$1.phase, 'running'); // live data still wins
    expect(t1.$2, 'alpha'); // the index's membership, not the relay's beta
  });

  test('live-only rows key off their own workspace fields, then the '
      'subscription key', () {
    final dir = TaskDirectory(
      relayTasks: const [],
      sessions: _liveIndex([
        {
          'sessionId': 't1',
          'title': 'live-only',
          'phase': 'running',
          'workspaceIdentity': 'beta',
        },
        {
          'sessionId': 't2',
          'title': 'live-no-fields',
          'phase': 'running',
        },
      ], subscribedWorkspaceKey: 'alpha'),
    );
    final byId = {
      for (final (e, k) in dir.allEntries()) e.sessionId: k,
    };
    expect(byId['t1'], 'beta');
    expect(byId['t2'], 'alpha');
  });

  test('live-only rows attribute to the index subscription identity even '
      'when it disagrees with nothing else on the page', () {
    // 2026-09-22 device report: a live-only row (the relay overview does
    // not know it yet) used to fall back to the PAGE-level active
    // workspace, so a switch / bridge re-subscribe window misattributed it
    // to a foreign group. The fallback now reads the identity recorded on
    // the index at subscribe time — the data self-certifies its home.
    final dir = TaskDirectory(
      relayTasks: const [],
      sessions: _liveIndex(
        [
          {
            'sessionId': 't1',
            'title': 'live-new',
            'phase': 'running',
            'lastActivityAt': 5,
          },
        ],
        subscribedWorkspaceKey: 'alpha',
      ),
    );
    final row = dir.allEntries().single;
    expect(row.$1.title, 'live-new');
    expect(row.$2, 'alpha'); // the index's own subscription identity
  });

  test('a live row with its own workspaceIdentity beats the subscription '
      'identity', () {
    // Regression guard: the row's own fields keep precedence over the
    // recorded subscription identity, same rule as before.
    final dir = TaskDirectory(
      relayTasks: const [],
      sessions: _liveIndex(
        [
          {
            'sessionId': 't1',
            'title': 'live-with-identity',
            'phase': 'running',
            'workspaceIdentity': 'beta',
          },
        ],
        subscribedWorkspaceKey: 'alpha',
      ),
    );
    expect(dir.allEntries().single.$2, 'beta');
  });

  test('duplicate relay rows (desktop mirror) pick the greatest updatedAt',
      () {
    // 2026-09-23: the desktop registry mirrors every task into
    // remote-enabled workspaces — two active rows per id, and their order
    // in the bootstrap frame varies between snapshots. The real row keeps
    // receiving activity updates while the mirror freezes at registration,
    // so the newer row must win in either frame order.
    for (final rows in [
      [
        _relayTask('t1', 'mirror', updatedAt: 100),
        _relayTask('t1', 'real', updatedAt: 200),
      ],
      [
        _relayTask('t1', 'real', updatedAt: 200),
        _relayTask('t1', 'mirror', updatedAt: 100),
      ],
    ]) {
      final dir = TaskDirectory(relayTasks: rows);
      final row = dir.allEntries().single;
      expect(row.$2, 'real');
      expect(row.$1.lastActivityAt, 200);
    }
  });

  test('duplicate relay rows with equal updatedAt pick the smaller key', () {
    // Theoretical tie: the lexicographically smaller workspace key wins so
    // the grouping stays a pure function of the row set — no frame-order
    // flip, ever.
    for (final rows in [
      [
        _relayTask('t1', 'zeta', updatedAt: 5),
        _relayTask('t1', 'alpha', updatedAt: 5),
      ],
      [
        _relayTask('t1', 'alpha', updatedAt: 5),
        _relayTask('t1', 'zeta', updatedAt: 5),
      ],
    ]) {
      expect(
        TaskDirectory(relayTasks: rows).allEntries().single.$2,
        'alpha',
      );
    }
  });

  test('with duplicate relay rows, the live row still wins per task id', () {
    // Live override precedence is unchanged by the mirror-row dedup: the
    // live row refreshes the data and attributes by the index's own
    // subscription identity — listSessions membership beats the relay
    // pick key.
    final dir = TaskDirectory(
      relayTasks: [
        _relayTask('t1', 'mirror', updatedAt: 100),
        _relayTask('t1', 'real', updatedAt: 200),
      ],
      sessions: _liveIndex([
        {
          'sessionId': 't1',
          'title': 'live-t1',
          'phase': 'running',
          'lastActivityAt': 1,
        },
      ], subscribedWorkspaceKey: 'subscribed'),
    );
    final row = dir.allEntries().single;
    expect(row.$1.phase, 'running'); // live data wins
    expect(row.$2, 'subscribed'); // the index's membership, not the pick key
  });

  test('live membership beats a relay pick won by the mirror row', () {
    // 2026-09-23 emulator acceptance, direct regression: the session
    // really lives in the real workspace, but its desktop mirror row
    // (stale foreign key) had the greater updatedAt and won the relay
    // pick — the live row then inherited that mirror key and the session
    // stayed in the wrong group, viewable there but unoperable. The live
    // index of the real workspace self-certifies the home: it must win.
    final dir = TaskDirectory(
      relayTasks: [
        _relayTask('t1', 'stale_zlinker', updatedAt: 200),
        _relayTask('t1', 'real_ws', updatedAt: 100),
      ],
      sessions: _liveIndex([
        {
          'sessionId': 't1',
          'title': 'live-t1',
          'phase': 'running',
          'lastActivityAt': 1,
        },
      ], subscribedWorkspaceKey: 'real_ws'),
    );
    final row = dir.allEntries().single;
    expect(row.$1.phase, 'running'); // live data wins
    expect(row.$2, 'real_ws'); // live membership beats the mirror pick key
  });

  test('pinned: duplicate relay rows pick the greatest updatedAt too', () {
    // Same duplicate-row rule in the pinned base phase ([TaskDirectory
    // .pinnedEntries] keeps its own relay loop).
    final dir = TaskDirectory(relayTasks: [
      _relayTask('t1', 'zeta', pinned: true, updatedAt: 5),
      _relayTask('t1', 'alpha', pinned: true, updatedAt: 9),
    ]);
    final pinned = dir.pinnedEntries();
    expect(pinned, hasLength(1));
    expect(pinned.single.$2, 'alpha');
  });

  test('deleted-tombstone live rows are dropped, untombstoned ones stay',
      () {
    // Addendum 2 (2026-09-23 device report): the desktop registry keeps
    // deleted=1 rows while the live sessions-index still lists them and
    // the relay overview omits them — without the tombstone filter the
    // live merge resurrects deleted tasks (default 12 → 22 after leaving
    // a conversation).
    final dir = TaskDirectory(
      relayTasks: const [],
      sessions: _liveIndex([
        {'sessionId': 'a', 'title': 'deleted-on-desktop', 'phase': 'running'},
        {'sessionId': 'b', 'title': 'alive', 'phase': 'running'},
      ], subscribedWorkspaceKey: 'alpha', deletedTaskIds: {'a'}),
    );
    expect(
      [for (final (e, _) in dir.allEntries()) e.sessionId],
      ['b'],
    );
    expect(
      [for (final (e, _) in dir.entriesFor('alpha')) e.sessionId],
      ['b'],
    );
    expect(dir.notificationRows(), hasLength(1));
  });

  test('a deleted pinned live row never pins', () {
    final dir = TaskDirectory(
      relayTasks: const [],
      sessions: _liveIndex([
        {
          'sessionId': 'a',
          'title': 'deleted-pinned',
          'phase': 'running',
          'pinned': true,
        },
      ], subscribedWorkspaceKey: 'alpha', deletedTaskIds: {'a'}),
    );
    expect(dir.pinnedEntries(), isEmpty);
  });

  test('tombstones never drop a relay base row (defensive)', () {
    // The relay overview does not serve deleted rows today, but if one
    // ever did, the tombstone must not hide a relay-anchored task: the
    // filter guards the live-override loops only, so the relay base row
    // survives and the live override is skipped.
    final dir = TaskDirectory(
      relayTasks: [_relayTask('a', 'alpha')],
      sessions: _liveIndex(
        [{'sessionId': 'a', 'title': 'live-a', 'phase': 'running'}],
        subscribedWorkspaceKey: 'alpha',
        deletedTaskIds: {'a'},
      ),
    );
    final row = dir.allEntries().single;
    expect(row.$1.title, 'relay-a'); // relay base row survives un-overridden
    expect(row.$2, 'alpha');
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
