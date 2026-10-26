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
  int createdAt = 1,
}) =>
    {
      'taskId': id,
      'title': 'relay-$id',
      'workspaceIdentity': key,
      'displayStatus': displayStatus,
      'createdAt': createdAt,
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
    // The replacement row's raw must carry the relay bit UNCHANGED — the
    // live frame's stray `archived: true` is not trusted.
    expect(dir.allEntries().single.$1.raw['archived'], isFalse);
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
    // Consumers (swipe / long-press sheet) read archived off `entry.raw` —
    // the live override must hand the relay bit through, else the archived
    // view offers 「归档」 instead of 「取消归档」.
    expect(
      dir.entriesFor('alpha', includeArchived: true).single.$1.raw['archived'],
      isTrue,
    );
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

  test('duplicate relay rows (desktop mirror) resolve on stable fields: '
      'pinned → createdAt → key lex', () {
    // 2026-10-15 stable-anchor rule (design §2.1, PRD R2) + 10-16 first
    // key: updatedAt EXITED the comparison keys — it changes on every
    // touch, and the touched copy kept re-winning (the group/status
    // flapping this task kills). Mirror copies share the real row's
    // creation millisecond (spec §3.1), so the deterministic tie-break is
    // the lexicographically smaller key. Both frame orders must still
    // agree (the §3.1 frame-order independence is kept).
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
      expect(row.$2, 'mirror');
      expect(row.$1.lastActivityAt, 100);
    }
  });

  test('a copy being touched no longer flips the pick (updatedAt out of the '
      'comparison keys)', () {
    // Cold-pick stability acceptance (PRD R2): bumping one copy's
    // updatedAt — the OLD rule's deciding key — must not move the row;
    // only a change in the row SET may.
    final rows = [
      _relayTask('t1', 'zeta', updatedAt: 1),
      _relayTask('t1', 'alpha', updatedAt: 1),
    ];
    expect(TaskDirectory(relayTasks: rows).allEntries().single.$2, 'alpha');
    final touched = [
      _relayTask('t1', 'zeta', updatedAt: 999),
      _relayTask('t1', 'alpha', updatedAt: 1),
    ];
    expect(TaskDirectory(relayTasks: touched).allEntries().single.$2, 'alpha',
        reason: 'updatedAt is no longer a comparison key (design 10-15)');
  });

  test('a row-SET change is what can still move the pick', () {
    // The other half of the stability acceptance: adding a pinned copy
    // (rule 1) or removing the winning copy may flip the pick — expected,
    // deterministic on the new set, and invisible to anchored ids.
    final base = [_relayTask('t1', 'alpha')];
    expect(TaskDirectory(relayTasks: base).allEntries().single.$2, 'alpha');
    final withPinnedCopy = [
      ...base,
      _relayTask('t1', 'zeta', pinned: true),
    ];
    expect(
      TaskDirectory(relayTasks: withPinnedCopy).allEntries().single.$2,
      'zeta',
      reason: 'a pinned copy beats the unpinned one whatever the key order',
    );
  });

  test('terminal status is OUT of the cold pick — a running true row no '
      'longer loses its group to a frozen mirror', () {
    // 10-16 (design 10-16 multi-copy-home-correction R1): the alive/frozen
    // split never discriminated pollution (both directions occur), and it
    // made a RUNNING true row lose its group to a frozen mirror copy
    // (b6f8f415 showed in artcraft while running). Terminal judgment lives
    // in displayStatusWinner — the STATUS field only.
    for (final rows in [
      [
        _relayTask('t1', 'zeta', displayStatus: 'completed', updatedAt: 1),
        _relayTask('t1', 'alpha', displayStatus: 'running', updatedAt: 999),
      ],
      [
        _relayTask('t1', 'alpha', displayStatus: 'running', updatedAt: 999),
        _relayTask('t1', 'zeta', displayStatus: 'completed', updatedAt: 1),
      ],
    ]) {
      final row = TaskDirectory(relayTasks: rows).allEntries().single;
      expect(row.$2, 'alpha',
          reason: 'lex decides now — the terminal key is gone');
      expect(row.$1.phase, 'completedSuccess',
          reason: 'the STATUS synthesis stays terminal-first (M1)');
    }
  });

  test('cold pick: a pinned copy beats a terminal lex-smaller mirror (the '
      'c881d00e shape)', () {
    // 10-16 pollution forensics: the true row carries the user's pin (pin
    // is a per-workspace registry field and lands on the true home), the
    // mirror is terminal AND lex-smaller ('F:\ZLinker' beats every
    // lowercase-named workspace). Pinned is the only discriminating stable
    // key the wire carries.
    for (final rows in [
      [
        _relayTask('t1', 'F:\\ZLinker', displayStatus: 'completed'),
        _relayTask('t1', 'f:\\chat', pinned: true, displayStatus: 'idle'),
      ],
      [
        _relayTask('t1', 'f:\\chat', pinned: true, displayStatus: 'idle'),
        _relayTask('t1', 'F:\\ZLinker', displayStatus: 'completed'),
      ],
    ]) {
      final row = TaskDirectory(relayTasks: rows).allEntries().single;
      expect(row.$2, 'f:\\chat');
      expect(row.$1.raw['pinned'], isTrue,
          reason: 'the body rides the pinned true row');
    }
  });

  test('both copies pinned (or none): the pinned key is a no-op, createdAt '
      'then lex decide', () {
    // The pinned key only separates a pinned/unpinned split; a both-pinned
    // group (user pinned the row in two workspaces) falls through to the
    // 10-15 rules unchanged.
    for (final rows in [
      [
        _relayTask('t1', 'zeta', pinned: true, createdAt: 100),
        _relayTask('t1', 'alpha', pinned: true, createdAt: 200),
      ],
      [
        _relayTask('t1', 'alpha', pinned: true, createdAt: 200),
        _relayTask('t1', 'zeta', pinned: true, createdAt: 100),
      ],
    ]) {
      expect(
        TaskDirectory(relayTasks: rows).allEntries().single.$2,
        'alpha',
        reason: 'equal pinned → greater createdAt wins',
      );
    }
  });

  test('an anchored multi-copy id stays on the anchor even when another '
      'copy is pinned', () {
    // The anchor layer stays FIRST: the user's persisted adjudication
    // (source ④) outranks the pinned key, mirroring the anchored-copy
    // priority over the cold pick.
    final dir = TaskDirectory(
      relayTasks: [
        _relayTask('t1', 'anchored-ws', updatedAt: 1),
        _relayTask('t1', 'pinned-ws', pinned: true, updatedAt: 2),
      ],
      confirmedHomeKeys: {'t1': 'anchored-ws'},
    );
    final row = dir.allEntries().single;
    expect(row.$2, 'anchored-ws');
    expect(row.$1.raw['pinned'], isNull,
        reason: 'the body rides the anchored copy, not the pinned one');
  });

  test('same class, different createdAt: the later-created row wins', () {
    // Rule 2: mirror copies share the real row's creation millisecond
    // (spec §3.1), so createdAt separates genuinely different ages without
    // ever flipping on activity.
    for (final rows in [
      [
        _relayTask('t1', 'old', updatedAt: 999, createdAt: 100),
        _relayTask('t1', 'new', updatedAt: 1, createdAt: 200),
      ],
      [
        _relayTask('t1', 'new', updatedAt: 1, createdAt: 200),
        _relayTask('t1', 'old', updatedAt: 999, createdAt: 100),
      ],
    ]) {
      expect(TaskDirectory(relayTasks: rows).allEntries().single.$2, 'new');
    }
  });

  test('duplicate relay rows with no stable-field difference pick the '
      'smaller key', () {
    // The tie-break that remains after updatedAt left: equal class + equal
    // createdAt → the lexicographically smaller workspace key wins, so
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

  test('a relay row with a null/missing taskId drops — never a null-assert '
      'crash', () {
    // 2026-10-11 group+pick regression guard: '${task['taskId']}' of a
    // missing/null key interpolates to 'null' (NOT empty), while
    // SessionEntry.sessionId derives '${null ?? ''}' = ''. The grouping key
    // must derive exactly like the entry — otherwise the id-less group
    // reaches the pick, every row fails its sessionId check, and the
    // null-assert on bestRelayRow's result throws.
    final dir = TaskDirectory(relayTasks: [
      {'title': 'no-id', 'workspaceIdentity': 'a', 'updatedAt': 300},
      {'taskId': null, 'title': 'null-id', 'workspaceIdentity': 'b',
          'updatedAt': 300},
      _relayTask('t1', 'real', updatedAt: 200),
    ]);
    final row = dir.allEntries().single;
    expect(row.$1.sessionId, 't1');
    expect(row.$2, 'real');
  });

  test('with duplicate relay rows, the live row still wins per task id', () {
    // Multi-copy semantics (design 10-15 multi-copy-stable-group, check
    // P1-3): the live row still refreshes the DATA, but its group key no
    // longer follows the index's subscription identity — both workspaces'
    // live indexes claim a polluted id, so attribution follows the relay
    // cold pick (equal class + equal createdAt → lexicographic): 'mirror'.
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
    expect(row.$2, 'mirror', // the stable cold pick, not the active index
        reason: 'multi-copy: switching workspaces must not migrate the row');
  });

  test('live membership beats a relay pick won by the mirror row', () {
    // 2026-09-23 emulator acceptance regression. NOTE (design 10-15
    // multi-copy-stable-group #10): under the multi-copy stable-key rule
    // this STILL passes, but by lexicographic luck ('real_ws' <
    // 'stale_zgo') — the single-copy membership doctrine it documents is
    // now guarded by the dedicated single-copy case above
    // ('live rows attribute by the index subscription identity').
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
    expect(row.$2, 'real_ws'); // cold-pick stable key (lex: real_ws < stale_zgo)
  });

  test('pinned: duplicate relay rows resolve on the same stable fields', () {
    // Same layered rule in the pinned base phase ([TaskDirectory
    // .pinnedEntries] groups its own relay loop): both pinned + equal
    // createdAt → the lexicographically smaller key wins — the pinned key
    // is a no-op on an all-pinned group, zeta's higher updatedAt stays
    // irrelevant (2026-10-15 stable-anchor rule).
    final dir = TaskDirectory(relayTasks: [
      _relayTask('t1', 'zeta', pinned: true, updatedAt: 5),
      _relayTask('t1', 'alpha', pinned: true, updatedAt: 9),
    ]);
    final pinned = dir.pinnedEntries();
    expect(pinned, hasLength(1));
    expect(pinned.single.$2, 'alpha');
  });

  test('pinned projection: a multi-copy id whose true row is pinned keys '
      'BOTH projections the same (10-16 two-projection fix)', () {
    // c881d00e forensics: the main list (full-copy cold pick) and the
    // pinned card (pinned-only relay phase / live allCopies pick) used to
    // disagree — terminal-first picked the mirror in one projection while
    // the pinned true row won the other. Pinned-first keys them the same.
    final live = _liveIndex(
      [
        {
          'sessionId': 't1',
          'title': 'live-t1',
          'phase': 'running',
          'lastActivityAt': 5,
          'pinned': true,
        },
      ],
      subscribedWorkspaceKey: 'F:\\ZLinker',
    );
    final dir = TaskDirectory(
      relayTasks: [
        _relayTask('t1', 'F:\\ZLinker', displayStatus: 'completed'),
        _relayTask('t1', 'f:\\chat', pinned: true, displayStatus: 'idle'),
      ],
      sessions: live,
    );
    // Main list: the multi-copy stable key = the cold pick (pinned true row).
    expect(dir.allEntries().single.$2, 'f:\\chat');
    // Pinned card: the live layer's allCopies pick runs the SAME
    // bestRelayRow — same key, no contradiction.
    final pinned = dir.pinnedEntries();
    expect(pinned, hasLength(1));
    expect(pinned.single.$2, 'f:\\chat');
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

  // ---- persistent home anchors (design 10-15, the 10-02 sticky home
  // evolved) --------------------------------------------
  // A live confirmation (relay single-copy) writes a PERSISTED anchor: it
  // now selects the home COPY (first layer ahead of the cold pick) and
  // pins the group past the subscription itself — the bridge swing's
  // resubscribe window (live coverage down) drops rows onto the cold pick
  // instead of the updatedAt-racy old pick, and neither a touched copy nor
  // a restarted process can move a confirmed row's group.

  test('a confirmed home pins the relay pick row (AC1/AC4)', () {
    // The stale desktop copy row (stale_zgo) had the greater updatedAt and
    // won the OLD pick — the anchor selects the real home real_ws copy
    // directly now (2026-10-15 layered home, design §2.1).
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

  test('cold start (no confirmed homes) keeps the pure cold pick (AC3)', () {
    // Empty cache = pre-anchor behavior. 2026-10-15: the pick itself
    // resolves on stable fields (terminal → createdAt → key lex) —
    // mirror/real here share createdAt, so the lex-smaller 'mirror' wins
    // regardless of its lower updatedAt.
    final dir = TaskDirectory(
      relayTasks: [
        _relayTask('t1', 'mirror', updatedAt: 200),
        _relayTask('t1', 'real', updatedAt: 100),
      ],
    );
    expect(dir.allEntries().single.$2, 'mirror');
  });

  test('an anchor matching no copy keeps pinning the group while the cold '
      'pick stands in as the body', () {
    // The anchored key ('a') is carried by NO row ('b', 'c'): the body
    // comes from the stable pick on the raw keys (both orders agree on
    // row-b), while the group stays pinned to the anchor — transient
    // until the relay-reconcile self-heal follows the evidence.
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

  group('cached live snapshots (design 10-15-task-live-snapshot-cache)', () {
    SessionEntry cachedRow(String id, {String? identity, bool pinned = false}) =>
        SessionEntry({
          'sessionId': id,
          'title': 'cached-$id',
          'phase': 'running',
          'lastActivityAt': 5,
          if (identity != null) 'workspaceIdentity': identity,
          if (pinned) 'pinned': true,
        });

    test('cache fills the gap: a row neither relay nor active live carries '
        'survives in its snapshot group', () {
      final dir = TaskDirectory(
        cachedSessions: {
          'alpha': [cachedRow('t1')],
        },
      );
      final all = dir.allEntries();
      expect(all, hasLength(1));
      expect(all.single.$1.title, 'cached-t1');
      expect(all.single.$2, 'alpha',
          reason: 'attribution = liveKeyOf(entry, snapshot key)');
    });

    test('layering: relay and active live both suppress the cached row', () {
      final dir = TaskDirectory(
        relayTasks: [_relayTask('t1', 'alpha')],
        sessions: _liveIndex([
          {'sessionId': 't2', 'title': 'live-t2', 'phase': 'running'},
        ], subscribedWorkspaceKey: 'alpha'),
        cachedSessions: {
          'alpha': [cachedRow('t1'), cachedRow('t2'), cachedRow('t3')],
        },
      );
      final all = dir.allEntries();
      expect(all, hasLength(3));
      // t1: relay wins the body — title is the relay spelling, not cached-.
      expect(
        all.firstWhere((e) => e.$1.sessionId == 't1').$1.title,
        'relay-t1',
      );
      // t2: the ACTIVE live row wins.
      expect(
        all.firstWhere((e) => e.$1.sessionId == 't2').$1.title,
        'live-t2',
      );
      // t3: gap filler only.
      expect(
        all.firstWhere((e) => e.$1.sessionId == 't3').$1.title,
        'cached-t3',
      );
    });

    test('cached gap rows carry the sessionOnly marker', () {
      final dir = TaskDirectory(
        cachedSessions: {
          'alpha': [cachedRow('t1')],
        },
      );
      expect(dir.sessionOnlyIds, contains('t1'));
    });

    test('locally-deleted ids never resurface through the cache', () {
      final dir = TaskDirectory(
        locallyDeletedTaskIds: const {'t1'},
        cachedSessions: {
          'alpha': [cachedRow('t1'), cachedRow('t2')],
        },
      );
      expect(
        dir.allEntries().map((e) => e.$1.sessionId),
        ['t2'],
      );
    });

    test('pinned gap rows pin through the cache, suppressed rows stay with '
        'their layer', () {
      final dir = TaskDirectory(
        relayTasks: [_relayTask('tR', 'alpha', pinned: true)],
        sessions: _liveIndex([
          {
            'sessionId': 'tL',
            'title': 'live-tL',
            'phase': 'running',
            'pinned': true,
          },
        ], subscribedWorkspaceKey: 'alpha'),
        cachedSessions: {
          'alpha': [
            cachedRow('tC', pinned: true),
            cachedRow('tR'),
            cachedRow('tL'),
          ],
        },
      );
      final pinned = dir.pinnedEntries();
      expect(pinned.map((e) => e.$1.sessionId).toSet(), {'tR', 'tL', 'tC'});
      // The cached body loses to both winning layers.
      expect(
        pinned.firstWhere((e) => e.$1.sessionId == 'tR').$1.title,
        'relay-tR',
      );
      expect(
        pinned.firstWhere((e) => e.$1.sessionId == 'tL').$1.title,
        'live-tL',
      );
      expect(
        pinned.firstWhere((e) => e.$1.sessionId == 'tC').$1.title,
        'cached-tC',
      );
    });

    test('a cached row with its own workspaceIdentity keeps it (same rule as '
        'live rows)', () {
      final dir = TaskDirectory(
        cachedSessions: {
          'alpha': [cachedRow('t1', identity: 'beta')],
        },
      );
      expect(dir.allEntries().single.$2, 'beta');
    });
  });

  group('multi-copy stable group key (design 10-15 multi-copy-stable-group)',
      () {
    Map<String, dynamic> livePinned(String id) => {
          'sessionId': id,
          'title': 'live-$id',
          'phase': 'running',
          'lastActivityAt': 1,
          'pinned': true,
        };

    test('#1 multi-copy + live: body is live, key is the canonicalized '
        'cold pick', () {
      final dir = TaskDirectory(
        relayTasks: [
          _relayTask('t1', '/repo/mirror', updatedAt: 100),
          _relayTask('t1', '/repo/real', updatedAt: 200),
        ],
        sessions: _liveIndex([
          {'sessionId': 't1', 'title': 'live-t1', 'phase': 'running'},
        ], subscribedWorkspaceKey: 'active_ws'),
        keyAliases: const {
          'm': 'm',
          '/repo/mirror': 'm',
          'r': 'r',
          '/repo/real': 'r',
        },
      );
      final row = dir.allEntries().single;
      expect(row.$1.title, 'live-t1', reason: 'live body rides the row');
      expect(row.$2, 'm',
          reason: 'cold pick (/repo/mirror, lex) canonicalized through '
              'keyAliases — a raw path key matches no identity folder');
    });

    test('#2 multi-copy + anchor: the anchor pins the group, live never '
        'flips it', () {
      final dir = TaskDirectory(
        relayTasks: [
          _relayTask('t1', '/repo/mirror'),
          _relayTask('t1', '/repo/real'),
        ],
        sessions: _liveIndex([
          {'sessionId': 't1', 'title': 'live-t1', 'phase': 'running'},
        ], subscribedWorkspaceKey: 'active_ws'),
        confirmedHomeKeys: const {'t1': 'm'},
      );
      expect(dir.allEntries().single.$2, 'm');
    });

    test('#3 stable across the ACTIVE workspace: same input, A-live vs '
        'B-live, identical key', () {
      TaskDirectory buildWith(String activeKey) => TaskDirectory(
            relayTasks: [
              _relayTask('t1', '/repo/mirror'),
              _relayTask('t1', '/repo/real'),
            ],
            sessions: _liveIndex([
              {'sessionId': 't1', 'title': 'live-t1', 'phase': 'running'},
            ], subscribedWorkspaceKey: activeKey),
          );
      final keyA = buildWith('alpha').allEntries().single.$2;
      final keyB = buildWith('beta').allEntries().single.$2;
      expect(keyA, '/repo/mirror');
      expect(keyA, keyB,
          reason: 'the PMA110 round-2 migration regression, pinned directly');
    });

    test('#4 single-copy keeps live membership as ground truth', () {
      final dir = TaskDirectory(
        relayTasks: [_relayTask('t1', 'home_ws')],
        sessions: _liveIndex([
          {'sessionId': 't1', 'title': 'live-t1', 'phase': 'running'},
        ], subscribedWorkspaceKey: 'subscribed'),
      );
      expect(dir.allEntries().single.$2, 'subscribed',
          reason: '2026-09-23 doctrine survives for single-copy ids');
    });

    test('#5 session-only rows keep liveKeyOf (multi-copy ids always have '
        'a relay row — the cache/live-only path never meets them)', () {
      final dir = TaskDirectory(
        sessions: _liveIndex([
          {'sessionId': 't1', 'title': 'live-t1', 'phase': 'running'},
        ], subscribedWorkspaceKey: 'solo'),
      );
      expect(dir.allEntries().single.$2, 'solo');
    });

    test('#6 pinned multi-copy with NO pinned relay copy: key from the full '
        'copy set, non-null, openable (check P1-2)', () {
      final dir = TaskDirectory(
        relayTasks: [
          _relayTask('t1', 'mirror', updatedAt: 100), // both UNpinned
          _relayTask('t1', 'real', updatedAt: 200),
        ],
        sessions: _liveIndex([livePinned('t1')],
            subscribedWorkspaceKey: 'subscribed'),
      );
      final pinned = dir.pinnedEntries();
      expect(pinned, hasLength(1));
      expect(pinned.single.$2, 'mirror',
          reason: 'full-set cold pick — not the pinned projection\'s own '
              'grouping, not the active index key');
      expect(
        TaskDirectory.workspaceForKey(
          const [
            {'workspacePath': '/repo/mirror', 'workspaceIdentity': 'mirror'},
          ],
          pinned.single.$1,
          pinned.single.$2,
        ),
        isNotNull,
        reason: 'a null key would make the pinned row unopenable',
      );
    });
  });

  group('isConversationWorkspace: default 组卡不滤（10-26 D6）', () {
    test('wire default 条目（purpose=conversation）渲染为普通组卡', () {
      expect(
        isConversationWorkspace({
          'kind': 'local',
          'label': 'default',
          'workspacePath': r'C:\Users\Melody\.zcode\workspace\default',
          'workspacePurpose': 'conversation',
        }),
        isFalse,
        reason: 'live 3.16.2 bootstrap 原文形态：default 是旧对话的归并容器，'
            '不能被 purpose 过滤掉',
      );
    });

    test('draft 条目（无 purpose）仍按路径过滤', () {
      expect(
        isConversationWorkspace({
          'kind': 'local',
          'label': 'draft-701cf0e6',
          'workspacePath': r'C:\Users\Melody\.zcode\workspace\draft-701cf0e6',
        }),
        isTrue,
      );
    });

    test('purpose=conversation 且路径非 default/draft 仍过滤', () {
      expect(
        isConversationWorkspace({
          'workspacePath': '/home/melody/.zcode/workspace/special',
          'workspacePurpose': 'conversation',
        }),
        isTrue,
        reason: '未来枚举不误放行',
      );
    });

    test('大小写/斜杠混合变体同样识别 default', () {
      expect(
        isConversationWorkspace({
          'workspacePath': r'C:/USERS/Melody\.zcode/workspace\DEFAULT',
          'workspacePurpose': 'conversation',
        }),
        isFalse,
      );
    });

    test('POSIX home 形态同样识别 default', () {
      expect(
        isConversationWorkspace({
          'workspacePath': '/home/x/.zcode/workspace/default',
          'workspacePurpose': 'conversation',
        }),
        isFalse,
      );
      expect(
        isConversationWorkspace({
          'workspacePath': '/home/x/.zcode/workspace/default',
        }),
        isFalse,
        reason: '无 purpose 的 default 本来就不是 conversation',
      );
    });
  });
}
