// Ported verbatim from the reference implementation; newer style lints
// are suppressed so the file stays diffable against it.
// ignore_for_file: use_null_aware_elements, prefer_initializing_formals
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/channel_client.dart';
import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/protocol/ipc_codec.dart';
import 'package:zlinker/protocol/remote_client.dart';

void main() {
  group('ConversationState delta application', () {
    late ConversationState state;

    setUp(() {
      state = ConversationState();
    });

    test('snapshot clears and replaces state', () {
      state.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'logEpoch': 'epoch-1',
            'revision': 5,
            'rows': {
              'window': [
                {'rowId': 1, 'kind': 'user', 'text': 'hello'},
                {'rowId': 2, 'kind': 'assistant', 'text': 'hi'},
              ],
              'totalCount': 2,
              'firstRowId': 1,
            },
          },
        },
        'toSeq': 10,
      }, onGap: () => fail('should not gap on snapshot'));

      expect(state.rows, hasLength(2));
      expect(state.rows[0]['text'], 'hello');
      expect(state.seq, 10);
      expect(state.logEpoch, 'epoch-1');
      expect(state.revision, 5);
      expect(state.firstRowId, 1);
      expect(state.totalCount, 2);
      expect(state.ready, isTrue);
    });

    test('bridge-crash resubscribe snapshot keeps the prepended history '
        'page across log epochs', () {
      // The desktop bridge crash-loop re-subscribes every ~10s and re-sends
      // the full snapshot; replacing rows wholesale dropped every loaded
      // older page and clamped the viewport to the (collapsed) bottom
      // (2026-09-22 device report). Round 23 removed the same-epoch gate:
      // a STREAMING desktop advances the log epoch on every ~10s snapshot
      // too, and each such refresh then threw the older pages away — the
      // viewport clamped ("jumping"), the paging cursor rewound to the
      // window head so the next load re-fetched the same page ("the top
      // timestamp never changes"), and the fetch race then died silently
      // to the epoch check ("stuck loading"). The held rows are immutable
      // log entries; an epoch drift does not invalidate them.
      Map<String, dynamic> snapFrame(
        String epoch,
        List<int> rowIds,
        int toSeq,
      ) =>
          {
            'payload': {
              'kind': 'snapshot',
              'snapshot': {
                'logEpoch': epoch,
                'rows': {
                  'window': [
                    for (final id in rowIds)
                      {'rowId': id, 'kind': 'user', 'text': 'r$id'},
                  ],
                  'totalCount': rowIds.length,
                  // No explicit firstRowId: the merged head then becomes the
                  // cursor (an explicit declaration would still win).
                },
              },
            },
            'toSeq': toSeq,
          };

      state.applyFrame(snapFrame('epoch-1', [50, 51], 1), onGap: () {});
      state.prependOlderRows([
        {'rowId': 40, 'kind': 'user', 'text': 'r40'},
        {'rowId': 41, 'kind': 'user', 'text': 'r41'},
      ]);
      // Resubscribe: fresh tail window (50..52), same epoch.
      state.applyFrame(snapFrame('epoch-1', [50, 51, 52], 5), onGap: () {});

      expect(
        [for (final r in state.rows) r['rowId']],
        [40, 41, 50, 51, 52],
        reason: 'held older rows survive the resubscribe',
      );
      expect(state.firstRowId, 40);

      // An epoch move (streaming log advance / rewrite) keeps them too:
      // every row OLDER than the fresh window head survives — both the
      // prepended pages and the previous window's rows (now history) —
      // and the cursor must not rewind past what the reader already
      // paged through.
      state.applyFrame(snapFrame('epoch-2', [60, 61], 9), onGap: () {});
      expect([for (final r in state.rows) r['rowId']],
          [40, 41, 50, 51, 52, 60, 61]);
      expect(state.firstRowId, 40,
          reason: 'cursor stays at the oldest held row');
    });

    test('row.appended adds to end', () {
      _injectSnapshot(state, seq: 1);
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.appended', 'row': {'rowId': 99, 'kind': 'user', 'text': 'new'}},
          ],
        },
        'fromSeq': 1,
        'toSeq': 2,
      }, onGap: () => fail('should not gap'));

      expect(state.rows, hasLength(1));
      expect(state.rows[0]['rowId'], 99);
      expect(state.seq, 2);
      expect(state.totalCount, 1);
    });

    test('row.upserted replaces existing row', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'user', 'text': 'old'},
      ]);

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.upserted', 'row': {'rowId': 1, 'kind': 'user', 'text': 'updated'}},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      expect(state.rows, hasLength(1));
      expect(state.rows[0]['text'], 'updated');
    });

    test('row.removed removes from rowId upward', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'user', 'text': 'a'},
        {'rowId': 2, 'kind': 'assistant', 'text': 'b'},
        {'rowId': 3, 'kind': 'user', 'text': 'c'},
      ], totalCount: 3);

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.removed', 'fromRowId': 2},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      expect(state.rows, hasLength(1));
      expect(state.rows[0]['rowId'], 1);
      // totalCount was 3, 2 rows removed (rowId>=2), so remaining = 1
      // clamp: (3-2).clamp(0, 1<<31) = 1
      expect(state.totalCount, 1);
    });

    test('row.delta appends text', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'assistantText', 'text': 'Hello'},
      ]);

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.delta', 'rowId': 1, 'path': 'text', 'append': ' World'},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      expect(state.rows[0]['text'], 'Hello World');
    });

    test('row.delta on toolCall inputText', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'toolCall', 'inputText': 'ls'},
      ]);

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.delta', 'rowId': 1, 'path': 'inputText', 'append': ' -la'},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      expect(state.rows[0]['inputText'], 'ls -la');
    });

    test('row.delta on toolCall output.text merges into nested map', () {
      _injectSnapshot(state, rows: [
        {
          'rowId': 1,
          'kind': 'toolCall',
          'output': {'text': 'file1'},
        },
      ]);

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.delta', 'rowId': 1, 'path': 'output.text', 'append': '\nfile2'},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      final output = state.rows[0]['output'] as Map;
      expect(output['text'], 'file1\nfile2');
    });

    test('state.updated merges into snapshot', () {
      _injectSnapshot(state, revision: 5, snapshot: {
        'control': {'phase': 'idle', 'canStop': false},
      });

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'state.updated', 'patch': {'revision': 6}},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      expect(state.revision, 6);
      expect(state.phase, 'idle'); // phase lives under control, not top-level
    });

    test('state.updated before snapshot is buffered', () {
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'state.updated', 'patch': {'revision': 3}},
          ],
        },
        'fromSeq': 0,
        'toSeq': 1,
      }, onGap: () => fail('should not gap'));

      // Still pending, snapshot not yet arrived
      expect(state.revision, 0);

      // Snapshot arrives — buffered patch merges
      _injectSnapshot(state, revision: 1, seq: 2);
      expect(state.revision, 3);
    });

    test('fromSeq mismatch triggers onGap', () {
      _injectSnapshot(state, seq: 10);

      var gapCalled = false;
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [],
        },
        'fromSeq': 5, // mismatch — current seq is 10
        'toSeq': 11,
      }, onGap: () => gapCalled = true);

      expect(gapCalled, isTrue);
      expect(state.seq, 10); // unchanged
    });

    test('optimisticRowUpdate mutates in place', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'assistant', 'feedback': null},
      ]);

      state.optimisticRowUpdate(1, {'feedback': 'like'});
      expect(state.rows[0]['feedback'], 'like');
    });

    test('optimisticRemoveQueueItem removes from queue items', () {
      _injectSnapshot(state, snapshot: {
        'revision': 1,
        'rows': {'window': [], 'totalCount': 0},
        'queue': {
          'items': [
            {'queueItemId': 'q1', 'text': 'a'},
            {'queueItemId': 'q2', 'text': 'b'},
          ],
        },
      });

      state.optimisticRemoveQueueItem('q1');
      final q = state.queue;
      final items = q?['items'] as List;
      expect(items, hasLength(1));
      expect(items[0]['queueItemId'], 'q2');
    });

    test('canLoadOlder is true when more rows exist', () {
      _injectSnapshot(state, rows: [
        {'rowId': 10, 'kind': 'user', 'text': 'latest'},
      ], totalCount: 100, firstRowId: 10);

      expect(state.canLoadOlder, isTrue);
    });

    test('canLoadOlder is false when all rows loaded', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'user', 'text': 'first'},
      ], totalCount: 1, firstRowId: 1);

      expect(state.canLoadOlder, isFalse);
    });

    test('prependOlderRows inserts before existing', () {
      _injectSnapshot(state, rows: [
        {'rowId': 3, 'kind': 'assistant', 'text': 'c'},
      ], totalCount: 3, firstRowId: 3);

      state.prependOlderRows([
        {'rowId': 1, 'kind': 'user', 'text': 'a'},
        {'rowId': 2, 'kind': 'assistant', 'text': 'b'},
      ]);

      expect(state.rows, hasLength(3));
      expect(state.rows[0]['rowId'], 1);
      expect(state.rows[1]['rowId'], 2);
      expect(state.rows[2]['rowId'], 3);
      expect(state.firstRowId, 1);
    });

    test('prependOlderRows deduplicates by rowId', () {
      _injectSnapshot(state, rows: [
        {'rowId': 2, 'kind': 'assistant', 'text': 'existing'},
      ]);

      state.prependOlderRows([
        {'rowId': 1, 'kind': 'user', 'text': 'old'},
        {'rowId': 2, 'kind': 'user', 'text': 'dup'},
      ]);

      expect(state.rows, hasLength(2));
      expect(state.rows[0]['text'], 'old');
      expect(state.rows[1]['text'], 'existing');
    });

    test('prependOlderRows reports zero inserted for a full duplicate page',
        () {
      _injectSnapshot(state, rows: [
        {'rowId': 2, 'kind': 'assistant', 'text': 'existing'},
      ]);

      final inserted = state.prependOlderRows([
        {'rowId': 2, 'kind': 'user', 'text': 'dup'},
      ]);

      // The caller anchors off this count: a no-op prepend must read as
      // "nothing shifted" or the UI pre-jumps a full page out and the
      // landing drags it back (09-22 round 14 device log).
      expect(inserted, 0);
      expect(state.rows, hasLength(1));
      expect(state.rows[0]['text'], 'existing');
    });

    test('computed properties from snapshot', () {
      _injectSnapshot(state, snapshot: {
        'revision': 5,
        'control': {'phase': 'running', 'canStop': true},
        'config': {'model': 'GLM-5.2', 'thought': 'max', 'mode': 'build'},
        'usage': {'contextWindow': {'usedTokens': 100, 'maxTokens': 200000}},
      });

      expect(state.isRunning, isTrue);
      expect(state.canStop, isTrue);
      expect(state.currentModel, 'GLM-5.2');
      expect(state.currentThought, 'max');
      expect(state.currentMode, 'build');
      expect(state.usage, isNotNull);
    });

    test('subagentsInfo exposes running entries from the snapshot', () {
      _injectSnapshot(state, snapshot: {
        'subagents': {
          'revision': 2,
          'childSessionIds': [
            'sess_subagent_agent_a',
            'sess_subagent_agent_b',
          ],
          'running': [
            {
              'childSessionId': 'sess_subagent_agent_a',
              'agentId': 'agent_1',
              'toolCallId': 'call_1',
              'subagentType': 'general-purpose',
              'title': '实现通道失败隔离加固',
              'status': 'running',
              'startedAt': 1789279676224,
            },
          ],
          'endedTotal': 2,
        },
      });

      final sub = state.subagentsInfo;
      expect(sub, isNotNull);
      expect(sub!['revision'], 2);
      expect(sub['endedTotal'], 2);
      expect((sub['childSessionIds'] as List), hasLength(2));
      final running = sub['running'] as List;
      expect(running, hasLength(1));
      expect(running[0]['childSessionId'], 'sess_subagent_agent_a');
      expect(running[0]['subagentType'], 'general-purpose');
    });

    test('subagentsInfo is null without the subagents field', () {
      _injectSnapshot(state, snapshot: {'revision': 1});

      expect(state.subagentsInfo, isNull);
    });

    test('draft phase is not running', () {
      _injectSnapshot(state, snapshot: {
        'revision': 1,
        'control': {'phase': 'draft'},
        'rows': {'window': [], 'totalCount': 0},
      });

      expect(state.isRunning, isFalse);
      expect(state.canStop, isFalse);
    });
  });

  group('optimistic config trace & revert detection (design 09-25 D3)', () {
    late ConversationState state;

    setUp(() {
      state = ConversationState();
    });

    Map<String, dynamic> config(String model) => {
      'provider': 'builtin',
      'model': model,
      'thought': 'enabled',
    };

    test('optimistic patch confirmed by a same-value snapshot raises no flag',
        () {
      _injectSnapshot(state, snapshot: {'config': config('A')});
      state.optimisticPatch({'config': config('B')});
      expect(state.currentModel, 'B');

      _injectSnapshot(state, snapshot: {'config': config('B')});
      expect(state.consumeConfigReverted(), isFalse,
          reason: 'the authoritative snapshot agrees with the optimism');
      expect(state.currentModel, 'B');
    });

    test('authoritative snapshot with a different value within 60s sets the '
        'one-shot flag; the state.updated merge path never does', () {
      _injectSnapshot(state, snapshot: {'config': config('A')});
      state.optimisticPatch({'config': config('B')});

      // Incremental confirmation (the normal accepted path): merging a
      // patch — even with a different config — must not count as a revert.
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'state.updated', 'patch': {'config': config('A')}},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('unexpected gap'));
      expect(state.consumeConfigReverted(), isFalse);

      // Whole-snapshot replacement with the desktop's old config: the
      // switch command was lost — one flag, consumed on read.
      _injectSnapshot(state, seq: 7, snapshot: {'config': config('A')});
      expect(state.consumeConfigReverted(), isTrue);
      expect(state.consumeConfigReverted(), isFalse,
          reason: 'one-shot: consumed on read');
    });

    test('a differing snapshot past the 60s window raises no flag', () {
      var now = DateTime(2026, 9, 25, 12);
      withClock(Clock(() => now), () {
        _injectSnapshot(state, snapshot: {'config': config('A')});
        state.optimisticPatch({'config': config('B')});

        now = now.add(const Duration(seconds: 61));
        _injectSnapshot(state, snapshot: {'config': config('A')});
        expect(state.consumeConfigReverted(), isFalse,
            reason: 'stale optimism is not worth mentioning');
      });
    });

    test('a second optimistic patch re-bases the trace on the newest value',
        () {
      _injectSnapshot(state, snapshot: {'config': config('A')});
      state.optimisticPatch({'config': config('B')});
      state.optimisticPatch({'config': config('C')});

      // A snapshot with B differs from the LATEST optimistic value (C) —
      // the verdict must be computed against the new trace.
      _injectSnapshot(state, snapshot: {'config': config('B')});
      expect(state.consumeConfigReverted(), isTrue);
    });
  });

  group('pendingInteractions wire forms', () {
    late ConversationState state;

    setUp(() {
      state = ConversationState();
    });

    /// A pending AskUserQuestion tool call row exactly as the desktop pushes
    /// it (`onPermissionRequested`): status + the resolveInteraction id, the
    /// tool input carrying the questions.
    Map<String, dynamic> pendingAskRow({
      String interactionId = 'perm-call_7',
      bool pending = true,
      List<Object?>? questions,
    }) => {
      'rowId': 12,
      'kind': 'toolCall',
      'toolCallId': 'call_7',
      'toolName': 'AskUserQuestion',
      'status': pending ? 'pendingApproval' : 'success',
      if (pending) 'approvalInteractionId': interactionId,
      'input': {
        'questions': questions ??
            [
              {
                'question': '选择环境',
                'header': '环境',
                'options': [
                  {'value': 'dev', 'label': '开发'},
                  {'value': 'prod', 'label': '生产'},
                ],
              },
            ],
      },
    };

    test('full list form is returned as-is (online delta form)', () {
      final interaction = {
        'interactionId': 'i1',
        'kind': 'permission',
        'payload': {
          'kind': 'permission',
          'toolName': 'Bash',
          'summary': 'rm -rf',
          'options': [
            {'optionId': 'o1', 'kind': 'allowOnce'},
          ],
        },
      };
      _injectSnapshot(state, snapshot: {
        'pendingInteractions': [interaction],
      });

      expect(state.pendingInteractions, [interaction]);
    });

    test(
      'summary count object is never parsed as a list — cards rebuild from rows',
      () {
        // 3.12.3 snapshot assembly: the relay snapshot projects the summary
        // into `pendingInteractions` (session overlay), never a list.
        _injectSnapshot(state, rows: [pendingAskRow()], snapshot: {
          'pendingInteractions': {'permissionCount': 0, 'userInputCount': 1},
        });

        final interactions = state.pendingInteractions;
        expect(interactions, hasLength(1));
        final interaction = interactions.single;
        expect(interaction['interactionId'], 'perm-call_7');
        expect(interaction['kind'], 'userInput');
        expect(interaction['anchorRowId'], 12);
        final payload = interaction['payload'] as Map;
        expect(payload['kind'], 'userInput');
        expect(payload['toolCallId'], 'call_7');
        expect(payload['toolName'], 'AskUserQuestion');
        final questions = payload['questions'] as List;
        expect(questions.single['question'], '选择环境');
        expect((questions.single['options'] as List).first['value'], 'dev');
      },
    );

    test('summary form without pending rows yields no interactions', () {
      _injectSnapshot(state, snapshot: {
        'pendingInteractions': {'permissionCount': 1, 'userInputCount': 0},
      });

      expect(state.pendingInteractions, isEmpty);
    });

    test('rebuild skips settled rows, other tools and plain rows', () {
      _injectSnapshot(state, rows: [
        pendingAskRow(pending: false), // resolved: id cleared server-side
        {
          ...pendingAskRow(interactionId: 'perm-call_8'),
          'rowId': 13,
          'toolCallId': 'call_8',
          'toolName': 'Bash', // permission-kind: not rebuildable from rows
        },
        {'rowId': 14, 'kind': 'userInput', 'text': 'hi'},
      ]);

      expect(state.pendingInteractions, isEmpty);
    });

    test('question normalization mirrors the agent core oIs', () {
      _injectSnapshot(
        state,
        rows: [
          pendingAskRow(questions: [
            // valid: header falls back to nothing present → question text
            {
              'question': 'q1',
              'options': [
                {'label': '仅标签'},
                {'value': 'v2'},
                {'label': 'l3', 'value': 'v3', 'description': '描述'},
                {}, // dropped: no value/label
              ],
            },
            // dropped: no question text
            {
              'header': 'h',
              'options': [
                {'value': 'x'},
              ],
            },
            // dropped: no options
            {'question': 'q3', 'options': []},
          ]),
        ],
      );

      final questions =
          (state.pendingInteractions.single['payload'] as Map)['questions']
              as List;
      expect(questions, hasLength(1));
      final q1 = questions.single;
      expect(q1['question'], 'q1');
      expect(q1['header'], 'q1');
      expect(q1['multiSelect'], isNull);
      expect(q1['options'], [
        {'value': '仅标签', 'label': '仅标签'},
        {'value': 'v2', 'label': 'v2'},
        {'value': 'v3', 'label': 'l3', 'description': '描述'},
      ]);
    });

    test('resolve clears the rebuilt card through the row update', () {
      _injectSnapshot(state, rows: [pendingAskRow()]);
      expect(state.pendingInteractions, hasLength(1));

      // settlePermission: the row upsert arrives with the id deleted.
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'row.upserted',
              'row': pendingAskRow(pending: false),
            },
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      expect(state.pendingInteractions, isEmpty);
    });
  });

  group('usage_update events & contextUsage', () {
    late ConversationState state;

    setUp(() {
      state = ConversationState();
    });

    Map<String, dynamic> usageEvent({
      Object? size = 200000,
      Object? used = 50000,
      Object? cost,
      Object? hitRate,
      Object? breakdown,
    }) =>
        {
          'type': 'usage_update',
          'taskId': 'sess-1',
          if (size != null) 'size': size,
          if (used != null) 'used': used,
          if (cost != null) 'cost': cost,
          if (hitRate != null) 'cache': {'hitRate': hitRate},
          if (breakdown != null) 'breakdown': breakdown,
        };

    test('parses a full event and normalizes the projection', () {
      state.applyUsageUpdate(usageEvent(
        cost: 0.42,
        hitRate: 0.91,
        breakdown: [
          {'chars': 12000, 'source': 'messages'},
          {'chars': 8000, 'source': 'system_prompt'},
        ],
      ));

      final view = state.contextUsage;
      expect(view.used, 50000);
      expect(view.max, 200000);
      expect(view.hasData, isTrue);
      expect(view.ratio, closeTo(0.25, 1e-9));
      expect(view.hitRate, 0.91);
      expect(view.breakdown, hasLength(2));
      expect(view.breakdown[0].source, 'messages');
      expect(view.breakdown[0].chars, 12000);
      expect(view.breakdown[0].percent, closeTo(0.6, 1e-9));
      expect(view.breakdown[1].source, 'system_prompt');
      // cost is parsed into the merged usage (PRD: never rendered).
      expect(state.usage?['cost'], 0.42);
    });

    test('event fields win over the snapshot, snapshot fills the gaps', () {
      _injectSnapshot(state, snapshot: {
        'usage': {
          'contextWindow': {'usedTokens': 100, 'maxTokens': 200000},
          'cumulative': {'inputTokens': 7},
        },
      });

      state.applyUsageUpdate(usageEvent(used: 50000));

      // event `used` overrides the snapshot usedTokens; `max` falls back.
      final view = state.contextUsage;
      expect(view.used, 50000);
      expect(view.max, 200000);
      // the untouched snapshot schema (cumulative) stays visible.
      expect(state.usage?['cumulative'], isNotNull);
    });

    test('deactivateState is a lazy shutdown: listeners detach and reads work',
        () {
      // Modal routes (usage sheet) can outlive the subscription; detaching
      // their listeners and reading fields after shutdown must not throw,
      // and notifications must fall silent instead of firing post-dispose
      // asserts (crash seen: 'A ConversationState was used after being
      // disposed' + '_dependents.isEmpty').
      var notified = 0;
      void listener() => notified++;
      state.addListener(listener);
      state.notifyListeners();
      expect(notified, 1);

      state.deactivateState();

      // detaching a listener after shutdown must not assert.
      state.removeListener(listener);
      // reads keep working for routes still showing the last data.
      expect(state.contextUsage.hasData, isFalse);
      // notifications fall silent.
      state.notifyListeners();
      state.applyUsageUpdate(usageEvent());
      expect(notified, 1);
    });

    test('missing / mistyped fields degrade without throwing', () {
      _injectSnapshot(state, snapshot: {
        'usage': {
          'contextWindow': {'usedTokens': 100, 'maxTokens': 200000},
        },
      });

      // empty event: nothing whitelisted — state untouched.
      state.applyUsageUpdate({'type': 'usage_update'});
      expect(state.contextUsage.used, 100);
      expect(state.contextUsage.max, 200000);

      state.applyUsageUpdate(usageEvent(
        size: 'oops',
        used: null,
        hitRate: 'nope',
        breakdown: [
          'garbage',
          {'chars': 'x', 'source': 'messages'},
          {'chars': 50}, // no source
        ],
      ));
      final view = state.contextUsage;
      expect(view.used, 100); // snapshot fallback
      expect(view.max, 200000);
      expect(view.hitRate, isNull);
      expect(view.breakdown, isEmpty);
    });

    test('an event without a usable used keeps the current usage intact',
        () {
      state.applyUsageUpdate(usageEvent(used: 50000, hitRate: 0.5));
      state.applyUsageUpdate(usageEvent(used: 0, hitRate: 0.99));

      // official s0t: invalid incoming used never clobbers valid usage.
      final view = state.contextUsage;
      expect(view.used, 50000);
      expect(view.hitRate, 0.5);
    });

    test('a breakdown-less event keeps the previous breakdown', () {
      final withBreakdown = usageEvent(
        breakdown: [
          {'chars': 900, 'source': 'skills'},
        ],
      );
      state.applyUsageUpdate(withBreakdown);
      state.applyUsageUpdate(usageEvent()); // same used/size, no breakdown

      expect(state.contextUsage.breakdown.single.source, 'skills');

      // changed used/size → the stale breakdown is dropped.
      state.applyUsageUpdate(usageEvent(used: 60000));
      expect(state.contextUsage.breakdown, isEmpty);
    });

    test('breakdown aggregation: sum, drop <=0, sort desc with weight',
        () {
      state.applyUsageUpdate(usageEvent(breakdown: [
        {'chars': 100, 'source': 'mcp_tool_schemas'},
        {'chars': 50, 'source': 'mcp_tool_schemas'}, // summed → 150
        {'chars': 300, 'source': 'messages'},
        {'chars': 300, 'source': 'system_prompt'}, // tie → weight wins
        {'chars': 0, 'source': 'skills'}, // <=0 dropped
        {'chars': -5, 'source': 'tool_prompt'}, // <=0 dropped
        {'chars': 25, 'source': 'custom_thing'}, // unknown source trails
      ]));

      final view = state.contextUsage;
      expect(view.breakdown.map((e) => e.source).toList(), [
        'messages',
        'system_prompt',
        'mcp_tool_schemas',
        'custom_thing',
      ]);
      expect(view.breakdown[0].percent, closeTo(300 / 775, 1e-9));
      expect(view.breakdown[2].chars, 150);
      expect(view.breakdown[3].chars, 25);
    });

    test('negative hitRate clamps to 0 (official Math.max)', () {
      state.applyUsageUpdate(usageEvent(hitRate: -0.2));
      expect(state.contextUsage.hitRate, 0);
    });

    test('snapshot contextWindow carries cache+breakdown (3.11.2 shape)',
        () {
      // Live-probed: 3.11.2 desktops never emit the task-stream broadcast;
      // usage rides state.updated patches into the snapshot's
      // contextWindow, cache/breakdown included.
      _injectSnapshot(state, snapshot: {
        'usage': {
          'contextWindow': {
            'usedTokens': 53684,
            'maxTokens': 300000,
            'cache': {'hitRate': 0.95, 'latestHitRate': 0.99},
            'breakdown': [
              {'chars': 85522, 'source': 'system_tool_schemas'},
              {'chars': 12000, 'source': 'messages'},
              {'chars': 10597, 'source': 'system_prompt'},
            ],
          },
          'cumulative': {'inputTokens': 1088590, 'outputTokens': 14603},
        },
      });

      final view = state.contextUsage;
      expect(view.used, 53684);
      expect(view.max, 300000);
      expect(view.hitRate, 0.95);
      expect(view.breakdown, hasLength(3));
      // chars-descending: the big system_tool_schemas block ranks first.
      expect(view.breakdown.first.source, 'system_tool_schemas');
      expect(state.usage?['cumulative'], isNotNull);
    });

    test('event cache shadows the snapshot; gaps fall back to it', () {
      _injectSnapshot(state, snapshot: {
        'usage': {
          'contextWindow': {
            'usedTokens': 100,
            'maxTokens': 200000,
            'cache': {'hitRate': 0.95},
            'breakdown': [
              {'chars': 100, 'source': 'messages'},
            ],
          },
        },
      });

      state.applyUsageUpdate(usageEvent(hitRate: 0.99));

      final view = state.contextUsage;
      expect(view.hitRate, 0.99); // event wins
      expect(view.used, 50000); // event used
      // the event carried no breakdown → snapshot breakdown fills in.
      expect(view.breakdown, hasLength(1));
      expect(view.breakdown.single.source, 'messages');
    });

    test('a fresh snapshot re-apply clears the merged event', () {
      state.applyUsageUpdate(usageEvent(used: 50000));
      expect(state.contextUsage.used, 50000);

      _injectSnapshot(state, snapshot: {
        'usage': {
          'contextWindow': {'usedTokens': 100, 'maxTokens': 200000},
        },
      });
      expect(state.contextUsage.used, 100);
    });

    test('usage stays null with neither snapshot nor event data', () {
      _injectSnapshot(state);
      expect(state.usage, isNull);
      expect(state.contextUsage.hasData, isFalse);
      expect(state.contextUsage.ratio, isNull);
    });
  });

  group('SessionsIndexState delta application', () {
    late SessionsIndexState state;
    late int gapCount;

    void onGap() => gapCount++;

    setUp(() {
      state = SessionsIndexState();
      gapCount = 0;
    });

    test('snapshot loads sessions', () {
      state.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': 'ws-1',
            'logEpoch': 'epoch-1',
            'sessions': [
              {
                'sessionId': 's1',
                'title': 'Task A',
                'phase': 'running',
                'lastActivityAt': 1000,
                'createdAt': 900,
              },
              {
                'sessionId': 's2',
                'title': 'Task B',
                'phase': 'completed',
                'lastActivityAt': 2000,
                'createdAt': 800,
              },
            ],
          },
        },
        'toSeq': 5,
      }, onGap: onGap);

      expect(state.sessions, hasLength(2));
      expect(state.ready, isTrue);
      expect(state.workspaceId, 'ws-1');
      expect(gapCount, 0);
    });

    test('list is sorted by lastActivityAt descending', () {
      state.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'sessions': [
              {'sessionId': 'older', 'lastActivityAt': 100, 'createdAt': 50, 'phase': 'draft', 'title': 'Old'},
              {'sessionId': 'newer', 'lastActivityAt': 200, 'createdAt': 50, 'phase': 'draft', 'title': 'New'},
            ],
          },
        },
        'toSeq': 1,
      }, onGap: onGap);

      final list = state.list;
      expect(list[0].sessionId, 'newer');
      expect(list[1].sessionId, 'older');
    });

    test('session.upserted delta', () {
      _injectSessionsSnapshot(state);
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'session.upserted',
              'session': {
                'sessionId': 'new-task',
                'title': 'Fresh',
                'phase': 'draft',
                'lastActivityAt': 500,
                'createdAt': 400,
              },
            },
          ],
        },
        'fromSeq': 1,
        'toSeq': 2,
      }, onGap: onGap);

      expect(state.sessions, hasLength(1));
      expect(state.sessions['new-task']!.title, 'Fresh');
    });

    test('session.removed delta', () {
      _injectSessionsSnapshot(state, sessions: [
        {'sessionId': 's1', 'title': 'T1', 'phase': 'draft', 'lastActivityAt': 0, 'createdAt': 0},
        {'sessionId': 's2', 'title': 'T2', 'phase': 'draft', 'lastActivityAt': 0, 'createdAt': 0},
      ]);

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'session.removed', 'sessionId': 's1'},
          ],
        },
        'fromSeq': 1,
        'toSeq': 2,
      }, onGap: onGap);

      expect(state.sessions, hasLength(1));
      expect(state.sessions.containsKey('s1'), isFalse);
      expect(state.sessions.containsKey('s2'), isTrue);
    });

    test('session entry parses parentSessionId (side chat marker)', () {
      state.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'sessions': [
              {
                'sessionId': 'side-1',
                'parentSessionId': 'main-1',
                'title': 'Side chat',
                'phase': 'running',
                'lastActivityAt': 100,
                'createdAt': 90,
              },
              {
                'sessionId': 'main-1',
                'title': 'Main task',
                'phase': 'draft',
                'lastActivityAt': 200,
                'createdAt': 50,
              },
            ],
          },
        },
        'toSeq': 1,
      }, onGap: onGap);

      expect(state.sessions['side-1']!.parentSessionId, 'main-1');
      expect(state.sessions['main-1']!.parentSessionId, isNull);
    });
  });

  group('readWorkspacePresentation', () {
    test('HIT answers the presentation map via the agent channel', () async {
      final calls = <(String, String, List<Object?>)>[];
      final transport = _presentationTransport((channel, method, args) {
        calls.add((channel, method, args));
        return {
          'workspace': {'workspacePath': '/repo'},
          'mode': 'build',
          'slashCommands': [
            {'name': 'compact', 'description': 'Compress context', 'source': 'builtin'},
            {'name': 'project:continue', 'description': 'd', 'source': 'custom'},
          ],
        };
      });

      final res = await transport.readWorkspacePresentation();

      expect(calls, hasLength(1));
      expect(calls.single.$1, Channels.zcodeAgent);
      expect(calls.single.$2, 'readWorkspacePresentation');
      expect(calls.single.$3, [
        {'workspacePath': '/repo'}
      ]);
      expect(res, isNotNull);
      expect(res!['mode'], 'build');
      expect(res['slashCommands'], hasLength(2));
    });

    test('non-Map answer is a miss (null)', () async {
      final transport =
          _presentationTransport((channel, method, args) => 'nope');
      expect(transport.readWorkspacePresentation(), completion(isNull));
    });

    test('channel rejection is a miss (null), never throws', () async {
      final transport = _presentationTransport((channel, method, args) {
        throw ChannelRpcError('method not found', null);
      });
      expect(transport.readWorkspacePresentation(), completion(isNull));
    });
  });

  group('clientHello capabilities', () {
    Future<Map<Object?, Object?>> handshakeHello(bool gate) async {
      final calls = <(String, String, List<Object?>)>[];
      final transport = ConversationTransport(
        session: _FakeBridgeSession(
          _respondingChannelClient((channel, method, args) {
            calls.add((channel, method, args));
            return method == 'helloConversationV4'
                ? {'connectionId': 'c1'}
                : const {};
          }),
        ),
        scope: {'workspacePath': '/repo'},
        workspaceHookReviewUi: gate,
      );
      await transport.handshake();
      return calls
          .firstWhere((c) => c.$2 == 'initializeConversationV4')
          .$3
          .single as Map;
    }

    test('gate on: capabilities declares exactly workspaceHookReviewUi', () async {
      final hello = await handshakeHello(true);
      expect(hello['kind'], 'clientHello');
      expect(hello['protocolVersion'], 3);
      expect(hello['clientKind'], 'mobileApp');
      // 3.12.3 strict schema: the whole capabilities map must equal this —
      // any extra key rejects the hello server-side.
      expect(hello['capabilities'], {
        'workspaceHookReviewUi': true,
      });
    });

    test('gate off (<3.12.3): no capabilities key at all', () async {
      final hello = await handshakeHello(false);
      expect(hello.containsKey('capabilities'), isFalse);
    });
  });

  group('respondWorkspaceHookReview', () {
    Future<Map<Object?, Object?>> sendEnvelope(Map<String, dynamic> frame,
        List<String> reviewItemIds) async {
      final calls = <(String, String, List<Object?>)>[];
      final transport = ConversationTransport(
        session: _FakeBridgeSession(
          _respondingChannelClient((channel, method, args) {
            calls.add((channel, method, args));
            return const {'status': 'accepted'};
          }),
        ),
        scope: {'workspacePath': '/repo'},
      );
      await transport.respondWorkspaceHookReview('s1', frame, reviewItemIds);
      final arg = calls
          .firstWhere((c) => c.$2 == 'sendConversationCommandV4')
          .$3
          .single;
      return (arg as Map)['envelope'] as Map;
    }

    test('strict payload: identity fields verbatim + trust_selected', () async {
      final envelope = await sendEnvelope(const {
        'kind': 'workspaceHookReview',
        'sessionId': 's1',
        'taskId': 't1',
        'runId': 'r1',
        'remoteSessionId': 'rs9',
        'workspaceIdentity': 'wid',
        'bundleDigest':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'reviewFlowId': 'rf1',
        'generation': 2,
        'interactionId': 'i1',
        'workspaceLabel': 'repo',
      }, ['item1', 'item2']);

      expect(envelope['sessionId'], 's1');
      expect(envelope['type'], 'respondWorkspaceHookReview');
      // .strict() schema — exact field set, no extras.
      expect(envelope['payload'], {
        'sessionId': 's1',
        'taskId': 't1',
        'runId': 'r1',
        'remoteSessionId': 'rs9',
        'workspaceIdentity': 'wid',
        'bundleDigest':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'reviewFlowId': 'rf1',
        'generation': 2,
        'interactionId': 'i1',
        'decision': {
          'action': 'trust_selected',
          'reviewItemIds': ['item1', 'item2'],
        },
      });
    });

    test('remoteSessionId omitted when absent; ids deduped in order',
        () async {
      final envelope = await sendEnvelope(const {
        'kind': 'workspaceHookReview',
        'sessionId': 's1',
        'taskId': 't1',
        'runId': 'r1',
        'workspaceIdentity': 'wid',
        'bundleDigest': 'digest',
        'reviewFlowId': 'rf1',
        'generation': 1,
        'interactionId': 'i1',
      }, ['a', 'a', 'b']);

      final payload = envelope['payload'] as Map;
      expect(payload.containsKey('remoteSessionId'), isFalse);
      expect(payload['decision'], {
        'action': 'trust_selected',
        'reviewItemIds': ['a', 'b'],
      });
    });
  });

  group('subscribe stall defenses', () {
    late _ManualChannels channels;
    late List<String> logs;

    ConversationTransport stalledTransport() {
      logs = [];
      channels = _ManualChannels();
      return ConversationTransport(
        session: _FakeBridgeSession(channels.client),
        scope: {'workspacePath': '/repo'},
        // Shrunk watchdog bound: protocol tests drive real timers, no
        // fake_async (see spec/protocol/protocol-guidelines.md §7).
        subscribeAckTimeout: const Duration(milliseconds: 100),
        onLog: (line) => logs.add(line),
      );
    }

    void answerSubscribe(String subscriptionId, String logEpoch, {int at = 0}) =>
        channels.answer(
          'subscribeConversationV4',
          {
            'ack': {'subscriptionId': subscriptionId, 'logEpoch': logEpoch},
          },
          at: at,
        );

    test('watchdog resubscribes a stalled ack; its late ack never wins',
        () async {
      final transport = stalledTransport();
      final done = transport.subscribe('s1');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(channels.count('subscribeConversationV4'), 1);

      // Before the bound: no watchdog fire, no second subscribe.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(channels.count('subscribeConversationV4'), 1);

      // Past the bound: the stalled attempt is abandoned and resubscribed.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(channels.count('subscribeConversationV4'), 2);
      expect(logs.join('\n'), contains('subscribe ack stalled'));

      // The new attempt acks and adopts the subscription…
      answerSubscribe('sub-2', 'epoch-fresh', at: 1);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // …then the abandoned attempt acks late — dropped, no takeover.
      answerSubscribe('sub-1', 'epoch-stale', at: 0);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final sub = await done;
      expect(sub.subscriptionId, 'sub-2');
      expect(sub.state.logEpoch, 'epoch-fresh');
      expect(logs.join('\n'), contains('dropped late subscribe ack'));
      // No extra resubscribe was triggered by the dropped ack.
      expect(channels.count('subscribeConversationV4'), 2);
      await sub.dispose();
    });

    test('bridge recovery racing an in-flight subscribe keeps the newer attempt',
        () async {
      final transport = stalledTransport();
      final done = transport.subscribe('s1');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(channels.count('subscribeConversationV4'), 1);

      // The bridge rebuilds before the first ack: the recovery resubscribe
      // races the still-pending attempt (generation guard's live race).
      transport.session.recovered.value++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(channels.count('subscribeConversationV4'), 2);

      // New attempt acks first; the abandoned attempt's ack lands after.
      answerSubscribe('sub-2', 'epoch-fresh', at: 1);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      answerSubscribe('sub-1', 'epoch-stale', at: 0);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final sub = await done;
      expect(sub.subscriptionId, 'sub-2');
      expect(sub.state.logEpoch, 'epoch-fresh');
      expect(logs.join('\n'), contains('dropped late subscribe ack'));
      await sub.dispose();
    });

    test('fast ack: single subscribe, id adopted, no watchdog noise', () async {
      final transport = stalledTransport();
      final done = transport.subscribe('s1');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      answerSubscribe('sub-1', 'epoch-1');
      final sub = await done;

      expect(sub.subscriptionId, 'sub-1');
      // Well past the watchdog bound: nothing resubscribed, nothing logged.
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(channels.count('subscribeConversationV4'), 1);
      final joined = logs.join('\n');
      expect(joined, isNot(contains('subscribe ack stalled')));
      expect(joined, isNot(contains('dropped late subscribe ack')));
      expect(joined, isNot(contains('resubscribe failed')));
      await sub.dispose();
    });
  });

  group('command timeout vs pendulum degradation', () {
    // The desktop 45.3s pendulum: bridge-degraded kills in-flight RPCs and
    // the bridge recovers within 1-2s — by the time a long-flying command
    // times out, `degraded` is null again. These tests drive that window
    // with real timers: the first send parks, degrades + recovers
    // mid-flight, and the timeout fires against an already-recovered bridge.
    late _RetryChannels channels;
    late _FakeBridgeSession session;
    late ConversationTransport transport;

    setUp(() {
      channels = _RetryChannels();
      session = _FakeBridgeSession(channels.client);
      transport = ConversationTransport(
        session: session,
        scope: {'workspacePath': '/repo'},
      );
    });

    /// Deadline-bounded wait for [test] to hold (the parked channel drives
    /// everything else deterministically).
    Future<void> pumpUntil(
      bool Function() test, {
      Duration timeout = const Duration(seconds: 5),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (!test()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('pumpUntil: condition not met within $timeout');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    /// Answers the [at]-th parked command once it appears. Register before
    /// awaiting the command future: the retry only parks after the first
    /// call's timeout fires.
    Future<void> answerWhenParked(int at, Object? payload) async {
      await pumpUntil(() => channels.envelopes.length > at);
      channels.answer(at, payload);
    }

    test('degraded mid-flight, recovered at catch: createSession retries '
        'with the same commandId and succeeds', () async {
      final done = transport.createSession(
        'ws1',
        firstText: 'hi',
        timeout: const Duration(milliseconds: 80),
      );
      await pumpUntil(() => channels.envelopes.isNotEmpty);
      // Pendulum: degrade, then recover long before the 80ms timeout fires.
      session.markDegraded('rpc-transport-fault');
      session.degraded.value = null;

      final answering = answerWhenParked(
        1,
        {
          'status': 'accepted',
          'result': {'sessionId': 's-new'},
        },
      );
      expect(await done, 's-new');
      await answering;
      expect(channels.envelopes, hasLength(2));
      // Session creation is idempotent server-side (retryAck dedupes by
      // commandId): the replay keeps the original commandId so a timed-out
      // command that did reach the server cannot create a second session.
      expect(channels.envelopes[1]['commandId'],
          channels.envelopes[0]['commandId']);
      expect('${channels.envelopes[1]['type']}', 'createSession');
    });

    test('no degradation during flight: timeout rethrows, no retry',
        () async {
      final done = transport.createSession(
        'ws1',
        firstText: 'hi',
        timeout: const Duration(milliseconds: 80),
      );
      await pumpUntil(() => channels.envelopes.isNotEmpty);
      await expectLater(done, throwsA(isA<TimeoutException>()));
      expect(channels.envelopes, hasLength(1));
    });

    test('retry answered duplicate: createSession takes sessionId from the '
        'carried original result', () async {
      final done = transport.createSession(
        'ws1',
        firstText: 'hi',
        timeout: const Duration(milliseconds: 80),
      );
      await pumpUntil(() => channels.envelopes.isNotEmpty);
      session.markDegraded('rpc-transport-fault');
      session.degraded.value = null;

      final answering = answerWhenParked(
        1,
        {
          'status': 'duplicate',
          'result': {'sessionId': 's-orig'},
        },
      );
      expect(await done, 's-orig');
      await answering;
      expect(channels.envelopes[1]['commandId'],
          channels.envelopes[0]['commandId']);
    });

    test('createSelectionSideSession retries with the same commandId too',
        () async {
      final done = transport.createSelectionSideSession(
        'parent-1',
        timeout: const Duration(milliseconds: 80),
      );
      await pumpUntil(() => channels.envelopes.isNotEmpty);
      session.markDegraded('rpc-transport-fault');
      session.degraded.value = null;

      final answering = answerWhenParked(
        1,
        {
          'status': 'accepted',
          'result': {'sessionId': 's-side'},
        },
      );
      expect(await done, 's-side');
      await answering;
      expect(channels.envelopes[1]['commandId'],
          channels.envelopes[0]['commandId']);
    });

    test('sendText regression: pendulum retry keeps the fresh-commandId '
        'semantics', () async {
      final done = transport.sendCommand(
        's1',
        'sendText',
        {'text': 'hi'},
        timeout: const Duration(milliseconds: 80),
      );
      await pumpUntil(() => channels.envelopes.isNotEmpty);
      session.markDegraded('rpc-transport-fault');
      session.degraded.value = null;

      final answering = answerWhenParked(1, const {'status': 'accepted'});
      await done;
      await answering;
      expect(channels.envelopes, hasLength(2));
      // Not an idempotent session-creating command: the replay still carries
      // a fresh commandId (the conservative double-delivery guard).
      expect(channels.envelopes[1]['commandId'],
          isNot(channels.envelopes[0]['commandId']));
      expect('${channels.envelopes[1]['type']}', 'sendText');
    });

    test('sendText with a degradation predating the send: timeout rethrows, '
        'no retry', () async {
      session.lastDegradedAt =
          DateTime.now().subtract(const Duration(hours: 1));
      final done = transport.sendCommand(
        's1',
        'sendText',
        {'text': 'hi'},
        timeout: const Duration(milliseconds: 80),
      );
      await pumpUntil(() => channels.envelopes.isNotEmpty);
      await expectLater(done, throwsA(isA<TimeoutException>()));
      expect(channels.envelopes, hasLength(1));
    });
  });
}

/// Channel client with test-driven responses: handshake (and unsubscribe)
/// calls answer immediately; every other call parks as (method, id) until
/// [answer] completes the [at]-th (0-based from oldest) parked call of that
/// method — how subscribe-stall races are driven.
class _ManualChannels {
  final parked = <(String, int)>[];

  /// Every call handed to [ChannelClient] (parked or auto-answered) —
  /// [count] reads this so answered calls still count.
  final sent = <String>[];
  late final ChannelClient client;

  _ManualChannels() {
    late final ChannelClient c;
    c = ChannelClient(sendBody: (body) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      final method = '${header[3]}';
      final id = header[1] as int;
      sent.add(method);
      switch (method) {
        case 'helloConversationV4':
          _reply(c, id, {'connectionId': 'conn-test'});
        case 'initializeConversationV4':
        case 'unsubscribeConversationV4':
          _reply(c, id, const {'status': 'accepted'});
        default:
          parked.add((method, id));
      }
    });
    final init = ValueWriter();
    encodeValue(init, [ChannelClient.resInitialize, 0]);
    c.handleMessage(init.toBytes());
    client = c;
  }

  void _reply(ChannelClient c, int id, Object? payload) {
    final w = ValueWriter();
    encodeValue(w, [ChannelClient.resPromiseSuccess, id]);
    encodeValue(w, payload);
    c.handleMessage(w.toBytes());
  }

  void answer(String method, Object? payload, {int at = 0}) {
    var seen = 0;
    for (var i = 0; i < parked.length; i++) {
      if (parked[i].$1 != method) continue;
      if (seen++ != at) continue;
      final (_, id) = parked.removeAt(i);
      _reply(client, id, payload);
      return;
    }
    fail('no parked call #$at for $method');
  }

  int count(String method) => sent.where((m) => m == method).length;
}

/// Parked-command channel for retry-timing tests: handshake answers
/// immediately; every `sendConversationCommandV4` parks (envelope recorded)
/// until [answer] completes the [at]-th parked call.
class _RetryChannels {
  /// Envelope of every parked `sendConversationCommandV4`, in call order.
  final List<Map> envelopes = [];
  final _parkedIds = <int>[];
  late final ChannelClient client;

  _RetryChannels() {
    late final ChannelClient c;
    c = ChannelClient(sendBody: (body) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      final method = '${header[3]}';
      final id = header[1] as int;
      switch (method) {
        case 'helloConversationV4':
          _reply(c, id, {'connectionId': 'conn-test'});
        case 'initializeConversationV4':
          _reply(c, id, const {'status': 'accepted'});
        case 'sendConversationCommandV4':
          final arg = decodeValue(reader);
          final request = (arg is List ? arg : <Object?>[arg]).single as Map;
          envelopes.add((request['envelope'] ?? const {}) as Map);
          _parkedIds.add(id);
      }
    });
    final init = ValueWriter();
    encodeValue(init, [ChannelClient.resInitialize, 0]);
    c.handleMessage(init.toBytes());
    client = c;
  }

  void answer(int at, Object? payload) {
    final id = _parkedIds.removeAt(at);
    _reply(client, id, payload);
  }

  void _reply(ChannelClient c, int id, Object? payload) {
    final w = ValueWriter();
    encodeValue(w, [ChannelClient.resPromiseSuccess, id]);
    encodeValue(w, payload);
    c.handleMessage(w.toBytes());
  }
}

/// Builds a [ConversationTransport] over a hand-rolled bridge whose channel
/// client answers each RPC from [respond]; a throw from [respond] becomes a
/// resPromiseError frame (channel rejection).
ConversationTransport _presentationTransport(
  Object? Function(String channel, String method, List<Object?> args) respond,
) {
  return ConversationTransport(
    session: _FakeBridgeSession(_respondingChannelClient(respond)),
    scope: {'workspacePath': '/repo'},
  );
}

/// Channel client that resolves every `call` synchronously out of [respond].
ChannelClient _respondingChannelClient(
  Object? Function(String channel, String method, List<Object?> args) respond,
) {
  late final ChannelClient client;
  client = ChannelClient(sendBody: (body) {
    final reader = ValueReader(body);
    final header = decodeValue(reader) as List;
    final arg = decodeValue(reader);
    final id = header[1] as int;
    Object? payload;
    var type = ChannelClient.resPromiseSuccess;
    try {
      payload = respond(
        '${header[2]}',
        '${header[3]}',
        arg is List ? arg : <Object?>[arg],
      );
    } catch (e) {
      type = ChannelClient.resPromiseError;
      payload = {'message': '$e'};
    }
    final w = ValueWriter();
    encodeValue(w, [type, id]);
    encodeValue(w, payload);
    client.handleMessage(w.toBytes());
  });
  final init = ValueWriter();
  encodeValue(init, [ChannelClient.resInitialize, 0]);
  client.handleMessage(init.toBytes());
  return client;
}

/// Bridge stand-in for transport-level RPC tests: only [channels],
/// [recovered], [degraded] and [waitHealthy] (used by the transport's
/// constructor and send gate) are real; anything else fails loud via
/// noSuchMethod.
class _FakeBridgeSession implements BridgeSession {
  _FakeBridgeSession(this.channels);

  @override
  final ChannelClient channels;

  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);

  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);

  @override
  DateTime? lastDegradedAt;

  @override
  void markDegraded(String reason) {
    lastDegradedAt = DateTime.now();
    degraded.value = reason;
  }

  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _injectSnapshot(
  ConversationState state, {
  int seq = 5,
  int revision = 1,
  List<Map<String, dynamic>>? rows,
  int totalCount = 0,
  int? firstRowId,
  Map<String, dynamic>? snapshot,
}) {
  final snap = {
    'revision': revision,
    'rows': {
      'window': rows ?? [],
      'totalCount': totalCount,
      if (firstRowId != null) 'firstRowId': firstRowId,
    },
    ...?snapshot,
  };
  state.applyFrame({
    'payload': {'kind': 'snapshot', 'snapshot': snap},
    'toSeq': seq,
  }, onGap: () => fail('unexpected gap'));
}

void _injectSessionsSnapshot(
  SessionsIndexState state, {
  List<Map<String, dynamic>>? sessions,
}) {
  final list = sessions ?? [];
  state.applyFrame({
    'payload': {
      'kind': 'snapshot',
      'snapshot': {'sessions': list},
    },
    'toSeq': 1,
  }, onGap: () => fail('unexpected gap'));
}
