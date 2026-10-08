import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/state/task_directory.dart';

/// TaskDirectory 的直穿测试：relay⊕live 合并规则、归档两态、置顶、计数、
/// notificationRows 含归档的显式语义（Q3a 裁决）、sticky 确认家（10-02）。

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
    // 2026-09-23 copy-row fix: the relay key can be a desktop
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
    // 2026-09-23: the desktop registry copies every task into
    // remote-enabled workspaces — two active rows per id, and their order
    // in the bootstrap frame varies between snapshots. The real row keeps
    // receiving activity updates while the copy freezes at registration,
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
    // Live override precedence is unchanged by the row dedup: the
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
    // really lives in the real workspace, but its desktop copy row
    // (stale foreign key) had the greater updatedAt and won the relay
    // pick — the live row then inherited that copy key and the session
    // stayed in the wrong group, viewable there but unoperable. The live
    // index of the real workspace self-certifies the home: it must win.
    final dir = TaskDirectory(
      relayTasks: [
        _relayTask('t1', 'stale_zgo', updatedAt: 200),
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

  // ---- locally-confirmed deletes (design 10-02 Step 3 / AC7) -----------
  // Unlike the probe tombstones above (live rows only, the relay base row
  // stays defensive), a delete RPC that returned SUCCESS is definitive:
  // the local set filters the relay rows too — the overview in memory can
  // lag when a reloadTasks response is swallowed by a bridge reopen.

  test('locally-deleted relay rows drop from every list view and the count',
      () {
    final dir = TaskDirectory(
      relayTasks: [_relayTask('a', 'alpha'), _relayTask('b', 'alpha')],
      locallyDeletedTaskIds: {'a'},
    );
    expect(
      [for (final (e, _) in dir.allEntries()) e.sessionId],
      ['b'],
    );
    expect(
      [for (final (e, _) in dir.entriesFor('alpha')) e.sessionId],
      ['b'],
    );
    expect(dir.notificationRows().map((e) => e.sessionId), ['b']);
    expect(dir.totalTaskCount, 1);
  });

  test('a locally-deleted pinned relay row never pins', () {
    final dir = TaskDirectory(
      relayTasks: [_relayTask('a', 'alpha', pinned: true)],
      locallyDeletedTaskIds: {'a'},
    );
    expect(dir.pinnedEntries(), isEmpty);
  });

  test('locally-deleted ids drop the live row even when the stale relay '
      'row and a live row both linger', () {
    // The device bug this fixes: delete succeeded, the desktop's live
    // index re-sent the session (no deleted concept) AND the in-memory
    // relay overview was stale — both paths resurrected the row.
    final dir = TaskDirectory(
      relayTasks: [_relayTask('a', 'alpha')],
      sessions: _liveIndex([
        {
          'sessionId': 'a',
          'title': 'live-a',
          'phase': 'running',
          'pinned': true,
          'lastActivityAt': 9,
        },
      ], subscribedWorkspaceKey: 'alpha'),
      locallyDeletedTaskIds: {'a'},
    );
    expect(dir.allEntries(), isEmpty);
    expect(dir.pinnedEntries(), isEmpty);
    expect(dir.notificationRows(), isEmpty);
  });

  test('without local tombstones nothing changes (default constructor)',
      () {
    final dir = TaskDirectory(
      relayTasks: [_relayTask('a', 'alpha')],
      sessions: _liveIndex([
        {'sessionId': 'a', 'title': 'live-a', 'phase': 'running'},
      ], subscribedWorkspaceKey: 'alpha'),
    );
    expect(dir.allEntries(), hasLength(1));
    expect(dir.totalTaskCount, 1);
  });

  // ---- sticky live-confirmed homes (design 10-02 / AC1-AC4) ------------
  // A live sessions-index confirmation pins the row's group past the
  // subscription itself: the bridge swing's resubscribe window (live
  // coverage down) drops rows back onto the relay pick key — the pick
  // loses mirror rows to stale foreign keys, the row oscillates between
  // groups. The confirmed home overrides the final grouping key only;
  // the pick phase itself still compares raw relay keys.

  test('a confirmed home pins the relay pick row (AC1/AC4)', () {
    // The stale desktop copy row (stale_zgo) has the greater updatedAt and
    // wins the relay pick — live had confirmed the real home real_ws.
    final rows = [
      _relayTask('t1', 'stale_zgo', updatedAt: 200),
      _relayTask('t1', 'real_ws', updatedAt: 100),
    ];
    // While the index is ready, live confirms real_ws anyway.
    final ready = TaskDirectory(
      relayTasks: rows,
      confirmedHomeKeys: {'t1': 'real_ws'},
      sessions: _liveIndex([
        {'sessionId': 't1', 'title': 'live-t1', 'phase': 'running'},
      ], subscribedWorkspaceKey: 'real_ws'),
    );
    expect(ready.allEntries().single.$2, 'real_ws');
    // Resubscribe window: the index drops out entirely — the row must
    // stay in its confirmed group instead of falling back to stale_zgo.
    final window = TaskDirectory(
      relayTasks: rows,
      confirmedHomeKeys: {'t1': 'real_ws'},
    );
    expect(window.allEntries().single.$2, 'real_ws');
    expect(window.entriesFor('stale_zgo'), isEmpty);
  });

  test('cold start (no confirmed homes) keeps the pure relay pick (AC3)',
      () {
    // Empty cache = pre-feature behavior: the pick key rules, no pin.
    final dir = TaskDirectory(
      relayTasks: [
        _relayTask('t1', 'mirror', updatedAt: 200),
        _relayTask('t1', 'real', updatedAt: 100),
      ],
    );
    expect(dir.allEntries().single.$2, 'mirror');
  });

  test('the pick still resolves duplicate rows by RAW relay keys when a '
      'confirmed home exists', () {
    // The home key ('a') sorts below both raw keys ('b', 'c'): if the
    // sticky key leaked into the beats comparison, the equal-updatedAt
    // tie-break would flip with the frame order. Both orders must pick
    // the same row data and pin the group to the confirmed home.
    for (final rows in [
      [
        {
          ..._relayTask('t1', 'c', updatedAt: 5),
          'title': 'row-c',
        },
        {
          ..._relayTask('t1', 'b', updatedAt: 5),
          'title': 'row-b',
        },
      ],
      [
        {
          ..._relayTask('t1', 'b', updatedAt: 5),
          'title': 'row-b',
        },
        {
          ..._relayTask('t1', 'c', updatedAt: 5),
          'title': 'row-c',
        },
      ],
    ]) {
      final dir = TaskDirectory(
        relayTasks: rows,
        confirmedHomeKeys: {'t1': 'a'},
      );
      final row = dir.allEntries().single;
      expect(row.$1.title, 'row-b'); // raw-key tie-break, either order
      expect(row.$2, 'a'); // group pinned by the confirmed home
    }
  });

  test('pinned: a confirmed home pins the relay row the same way', () {
    final dir = TaskDirectory(
      relayTasks: [
        _relayTask('t1', 'stale_zgo', pinned: true, updatedAt: 200),
        _relayTask('t1', 'real_ws', pinned: true, updatedAt: 100),
      ],
      confirmedHomeKeys: {'t1': 'real_ws'},
    );
    final pinned = dir.pinnedEntries();
    expect(pinned, hasLength(1));
    expect(pinned.single.$2, 'real_ws');
  });

  test('a ready live index still outranks the pinned home', () {
    // The live loop is untouched: when the index is ready its membership
    // rules (and the same snapshot has just overwritten the cache — the
    // real move case, AC2), so the pin never blocks a live correction.
    final dir = TaskDirectory(
      relayTasks: [_relayTask('t1', 'stale_zgo')],
      confirmedHomeKeys: {'t1': 'old_ws'},
      sessions: _liveIndex([
        {'sessionId': 't1', 'title': 'live-t1', 'phase': 'running'},
      ], subscribedWorkspaceKey: 'new_ws'),
    );
    final row = dir.allEntries().single;
    expect(row.$1.title, 'live-t1');
    expect(row.$2, 'new_ws');
  });

  // ---- sessions-only source marker (task 10-05 C1-D2) -------------------
  // Rows that exist ONLY in the live sessions-index have no task-registry
  // (relay) anchor: the desktop parks fork drafts in the session library
  // with `persistence:'deferred'`, deliberately skipping the task index
  // (createZCodeDeferredDraftRegistry, research.md R2) — registry
  // mutations (deleteTask…) can never resolve them, so consumers need the
  // marker to route them to session commands. Pure read-only output: the
  // merge rules above are untouched.

  test('a task present in both sources is not sessions-only', () {
    final dir = TaskDirectory(
      relayTasks: [_relayTask('t1', 'alpha')],
      sessions: _liveIndex([
        {'sessionId': 't1', 'title': 'live-t1', 'phase': 'running'},
      ], subscribedWorkspaceKey: 'alpha'),
    );
    expect(dir.sessionOnlyIds, isEmpty);
    expect(dir.allEntries(), hasLength(1)); // merged view unchanged
  });

  test('a live row without a relay anchor is sessions-only', () {
    final dir = TaskDirectory(
      relayTasks: const [],
      sessions: _liveIndex([
        {'sessionId': 'd1', 'title': 'Fork of x', 'phase': 'idle'},
      ], subscribedWorkspaceKey: 'alpha'),
    );
    expect(dir.sessionOnlyIds, {'d1'});
    expect(dir.allEntries(), hasLength(1)); // the row still lists
  });

  test('a late relayTasks arrival unmarks the id (no mislabel)', () {
    // The directory is stateless — every read recomputes. A draft marked
    // session-only while only the live index knew it must lose the marker
    // as soon as the relay overview delivers its registry row, exactly
    // like the row data switches from live to relay-anchored.
    final before = TaskDirectory(
      relayTasks: const [],
      sessions: _liveIndex([
        {'sessionId': 'd1', 'title': 'Fork of x', 'phase': 'idle'},
      ], subscribedWorkspaceKey: 'alpha'),
    );
    expect(before.sessionOnlyIds, {'d1'});
    final after = TaskDirectory(
      relayTasks: [_relayTask('d1', 'alpha')],
      sessions: _liveIndex([
        {'sessionId': 'd1', 'title': 'Fork of x', 'phase': 'idle'},
      ], subscribedWorkspaceKey: 'alpha'),
    );
    expect(after.sessionOnlyIds, isEmpty);
  });

  test('a tombstoned live row never lands in sessionOnlyIds', () {
    // Same deletion semantics as the merge: the probe tombstone skips the
    // live row entirely, so it is neither listed nor marked.
    final dir = TaskDirectory(
      relayTasks: const [],
      sessions: _liveIndex(
        [{'sessionId': 'd1', 'title': 'gone', 'phase': 'idle'}],
        subscribedWorkspaceKey: 'alpha',
        deletedTaskIds: {'d1'},
      ),
    );
    expect(dir.sessionOnlyIds, isEmpty);
    expect(dir.allEntries(), isEmpty);
  });

  test('a locally-deleted id follows the same deletion semantics', () {
    final dir = TaskDirectory(
      relayTasks: const [],
      sessions: _liveIndex([
        {'sessionId': 'd1', 'title': 'gone', 'phase': 'idle'},
      ], subscribedWorkspaceKey: 'alpha'),
      locallyDeletedTaskIds: {'d1'},
    );
    expect(dir.sessionOnlyIds, isEmpty);
    expect(dir.allEntries(), isEmpty);
  });

  test('no live index (or one not ready yet) answers an empty set', () {
    expect(
      TaskDirectory(relayTasks: [_relayTask('t1', 'alpha')]).sessionOnlyIds,
      isEmpty,
    );
    // Fresh index: subscribed but no snapshot applied → not ready.
    expect(
      TaskDirectory(sessions: SessionsIndexState()).sessionOnlyIds,
      isEmpty,
    );
  });

  // ---- workspaceForKey (row → workspace scope, moved from the page) -----
  // The listed workspace whose key matches wins; a row the list doesn't
  // know falls back to its own origin fields; without those the ownership
  // is undeterminable (null = the caller must not open the chat).

  test('workspaceForKey: the listed workspace matching the key wins', () {
    const workspaces = [
      {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
      {'workspacePath': '/repo/beta', 'workspaceIdentity': 'beta'},
    ];
    final entry = SessionEntry({
      'sessionId': 's1',
      'title': 'x',
      'phase': 'idle',
      'workspacePath': '/repo/beta',
      'workspaceIdentity': 'beta',
    });
    final ws = TaskDirectory.workspaceForKey(workspaces, entry, 'beta');
    expect(ws, same(workspaces[1]));
  });

  test('workspaceForKey: an unlisted row assembles its own origin scope', () {
    // Cross-workspace row (key not in the workspace list): the row's own
    // workspacePath (+ identity when present) still scope it — the
    // "can see, can't act" fallback.
    final entry = SessionEntry({
      'sessionId': 's2',
      'title': 'foreign',
      'phase': 'running',
      'workspacePath': '/repo/gamma',
      'workspaceIdentity': 'gamma-id',
    });
    expect(
      TaskDirectory.workspaceForKey(const [], entry, 'gamma-id'),
      {'workspacePath': '/repo/gamma', 'workspaceIdentity': 'gamma-id'},
    );
    // Identity is optional — only the fields the row carries go in.
    final pathOnly = SessionEntry({
      'sessionId': 's3',
      'title': 'foreign-path',
      'phase': 'running',
      'workspacePath': '/repo/delta',
    });
    expect(
      TaskDirectory.workspaceForKey(const [], pathOnly, 'delta'),
      {'workspacePath': '/repo/delta'},
    );
  });

  test('workspaceForKey: no listed match and no origin path → null', () {
    // Ownership undeterminable: the caller must not open the chat.
    final entry = SessionEntry({
      'sessionId': 's4',
      'title': 'homeless',
      'phase': 'idle',
    });
    expect(
      TaskDirectory.workspaceForKey(
        const [
          {'workspacePath': '/repo/alpha'},
        ],
        entry,
        null,
      ),
      isNull,
    );
    // An empty-string path is no path either.
    final blank = SessionEntry({
      'sessionId': 's5',
      'title': 'blank-path',
      'phase': 'idle',
      'workspacePath': '',
    });
    expect(TaskDirectory.workspaceForKey(const [], blank, 'x'), isNull);
  });
}
