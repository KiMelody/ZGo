import 'package:flutter/material.dart';

import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/markdown_view.dart';
import 'package:zgo/ui/chat/subagent_feed.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/chat/workflow_card.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

/// Task 11-19 chat-scroll wave 2 step 2: the [ChatTurnGroup] body memo.
/// Unchanged row instances across parent rebuilds must not re-enter the
/// group build (zero subtree rebuild, markdown parses included); any row
/// change (tail OR middle), any plumbing change, and any non-row state the
/// subtree reads must invalidate. Theme flips reach the cached subtree
/// through the child elements' own inherited dependencies — asserted by the
/// rendered colour actually changing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => debugTurnGroupBuilds = 0);

  Widget wrap(Widget child, {ThemeData? theme}) => MaterialApp(
    theme: buildDarkTheme(),
    darkTheme: buildDarkTheme(),
    builder: (context, inner) =>
        UiSettingsProvider(settings: UiSettings(), child: inner!),
    // Explicit Theme avoids MaterialApp's 200 ms AnimatedTheme.
    home: Theme(
      data: theme ?? buildDarkTheme(),
      child: Scaffold(body: child),
    ),
  );

  late FakeConversation conversation;
  late SubagentFeed feed;
  late ChatPreview preview;
  late Future<void> Function(String, Future<dynamic> Function()) onAction;

  setUp(() {
    conversation = FakeConversation(RecordingCalls());
    feed = SubagentFeed(conversation: conversation);
    preview = ChatPreview(FakeWorkspaceContext(RecordingCalls()));
    onAction = (label, action) async => action();
  });

  tearDown(() {
    feed.dispose();
    conversation.dispose();
  });

  Future<void> pumpGroup(
    WidgetTester tester,
    List<Map<String, dynamic>> rows, {
    Map<String, dynamic>? lastError,
    ThemeData? theme,
    ValueNotifier<String?>? editingRowId,
    Future<void> Function(Map<String, dynamic>, String, bool)? onEditSend,
  }) async {
    await tester.pumpWidget(
      wrap(
        ChatTurnGroup(
          key: const ValueKey('turn-1'),
          rows: rows,
          conversation: conversation,
          sessionId: 's1',
          onAction: onAction,
          state: conversation.state,
          feed: feed,
          preview: preview,
          confirmWindow: const Duration(seconds: 3),
          lastError: lastError,
          editingRowId: editingRowId,
          onEditSend: onEditSend,
        ),
        theme: theme,
      ),
    );
    await tester.pump();
  }

  /// Applies a `workflowRun.updated` delta carrying a complete run header —
  /// the wire path that replaces the state's `workflowRuns` with a new
  /// instance.
  void feedWorkflowRun(String runId) {
    final state = conversation.state;
    state.applyFrame({
      'fromSeq': state.seq,
      'toSeq': state.seq + 1,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {
            'op': 'workflowRun.updated',
            'revision': state.workflowRuns.revision + 1,
            'runId': runId,
            'run': {
              'runId': runId,
              'status': 'running',
              'usage': <String, dynamic>{},
              'lastEventSequence': 0,
            },
          },
        ],
      },
    }, onGap: () => fail('unexpected gap'));
  }

  List<Map<String, dynamic>> turnRows() => [
    {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
    {'rowId': 2, 'kind': 'assistantText', 'text': '已修复 **登录** 问题'},
    {'rowId': 3, 'kind': 'toolCall', 'toolName': 'Read', 'status': 'success'},
    {
      'rowId': 4,
      'kind': 'turnHeader',
      'state': 'completedSuccess',
      'activeMs': 1200,
    },
  ];

  testWidgets('unchanged rows skip the group build entirely', (tester) async {
    final rows = turnRows();
    await pumpGroup(tester, rows);
    expect(debugTurnGroupBuilds, 1);

    for (var i = 0; i < 3; i++) {
      await pumpGroup(tester, rows);
      expect(debugTurnGroupBuilds, 1,
          reason: 'same row instances → cached subtree handed back');
    }

    // A rebuilt list holding the same row maps is equally unchanged.
    await pumpGroup(tester, List<Map<String, dynamic>>.of(rows));
    expect(debugTurnGroupBuilds, 1);
  });

  testWidgets('a tail row change rebuilds the group', (tester) async {
    final rows = turnRows();
    await pumpGroup(tester, rows);
    expect(debugTurnGroupBuilds, 1);

    final updated = [
      ...rows.sublist(0, 3),
      {...rows[3], 'activeMs': 1300},
    ];
    await pumpGroup(tester, updated);
    expect(debugTurnGroupBuilds, 2);
    expect(find.textContaining('已修复'), findsOneWidget);
  });

  testWidgets('a MIDDLE row change rebuilds the group (full fingerprint)',
      (tester) async {
    final rows = turnRows();
    await pumpGroup(tester, rows);
    expect(debugTurnGroupBuilds, 1);

    // Only the assistant row (index 1) is replaced — first and last row
    // instances, and the length, all stay the same. The old first+last
    // shortcut would miss this; the full reference scan must not.
    final updated = [
      rows[0],
      {...rows[1], 'feedback': 'like'},
      rows[2],
      rows[3],
    ];
    await pumpGroup(tester, updated);
    expect(debugTurnGroupBuilds, 2);
  });

  testWidgets('a plumbing change (lastError) rebuilds the group',
      (tester) async {
    final rows = turnRows();
    await pumpGroup(tester, rows);
    expect(debugTurnGroupBuilds, 1);

    await pumpGroup(tester, rows, lastError: {'message': 'boom'});
    expect(debugTurnGroupBuilds, 2,
        reason: 'the error preview rides widget.lastError, not the rows');
  });

  testWidgets('a non-row state flip (isRunning) rebuilds the group',
      (tester) async {
    final rows = turnRows();
    await pumpGroup(tester, rows);
    expect(debugTurnGroupBuilds, 1);

    // Same row maps, but the conversation starts running: user bubbles in
    // earlier turns read `state.isRunning` for the rewind disabled state.
    conversation.snapshotExtra = {
      'control': {'phase': 'running'},
    };
    conversation.feedSnapshot(rows);
    await pumpGroup(tester, conversation.state.rows);
    expect(debugTurnGroupBuilds, 2);
  });

  testWidgets('a sawRowActions flip re-renders the cached subtree, tightened',
      (tester) async {
    conversation.feedSnapshot(turnRows());
    final rows = conversation.state.rows;
    final editing = ValueNotifier<String?>(null);
    Future<void> onEditSend(
      Map<String, dynamic> target,
      String newText,
      bool rewind,
    ) async {}

    await pumpGroup(
      tester,
      rows,
      editingRowId: editing,
      onEditSend: onEditSend,
    );
    expect(debugTurnGroupBuilds, 1);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget,
        reason: 'sawRowActions=false keeps the pre-existing edit affordance');

    // The desktop establishes its row-action surface: a row OUTSIDE this
    // turn carries an `actions` map, so `sawRowActions` flips on while every
    // row instance this group renders stays untouched (an out-of-window
    // upsert replaces no row). Only the memo's extra state key moves.
    final state = conversation.state;
    state.applyFrame({
      'fromSeq': state.seq,
      'toSeq': state.seq + 1,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {
            'op': 'row.upserted',
            'row': {
              'rowId': 999,
              'kind': 'assistantText',
              'actions': {'canEdit': true},
            },
          },
        ],
      },
    }, onGap: () => fail('unexpected gap'));
    expect(state.sawRowActions, isTrue);
    expect(identical(rows, state.rows), isTrue,
        reason: 'an out-of-window upsert must not replace rendered rows');

    await pumpGroup(
      tester,
      state.rows,
      editingRowId: editing,
      onEditSend: onEditSend,
    );
    expect(debugTurnGroupBuilds, 2,
        reason: 'sawRowActions is part of the memo fingerprint');
    expect(find.byIcon(Icons.edit_outlined), findsNothing,
        reason: 'the rebuilt subtree re-renders tightened; a cache hit would '
            'leave the stale affordance on screen');
  });

  testWidgets('only workflow-row groups rebuild on a workflowRuns change',
      (tester) async {
    // A plain turn and a turn holding a workflow tool row, fed through one
    // snapshot so both groups read the same live conversation state.
    conversation.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'plain question'},
      {'rowId': 2, 'kind': 'assistantText', 'text': 'plain answer'},
      {
        'rowId': 3,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'activeMs': 10,
      },
      {'rowId': 11, 'kind': 'userInput', 'text': 'run the workflow'},
      {
        'rowId': 12,
        'kind': 'toolCall',
        'toolName': 'create_workflow',
        'status': 'success',
      },
      {
        'rowId': 13,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'activeMs': 10,
      },
    ]);
    final plainRows = [
      for (final row in conversation.state.rows)
        if ((row['rowId'] as num) < 10) row,
    ];
    final workflowRows = [
      for (final row in conversation.state.rows)
        if ((row['rowId'] as num) > 10) row,
    ];
    expect(workflowRows.any(isWorkflowToolRow), isTrue);

    Future<void> pumpRows(Key key, List<Map<String, dynamic>> rows) async {
      await tester.pumpWidget(
        wrap(
          ChatTurnGroup(
            key: key,
            rows: rows,
            conversation: conversation,
            sessionId: 's1',
            onAction: onAction,
            state: conversation.state,
            feed: feed,
            preview: preview,
            confirmWindow: const Duration(seconds: 3),
          ),
        ),
      );
      await tester.pump();
    }

    // The plain group never reads the mirror family: a new instance is not
    // one of its inputs, so the cached subtree must be handed back.
    await pumpRows(const ValueKey('turn-1'), plainRows);
    expect(debugTurnGroupBuilds, 1);
    debugTurnGroupBuilds = 0;
    feedWorkflowRun('run-1');
    await pumpRows(const ValueKey('turn-1'), plainRows);
    expect(debugTurnGroupBuilds, 0,
        reason: 'a group without workflow rows ignores workflowRuns');

    // The workflow-row group dispatches its row against the mirror: a new
    // instance must re-enter the build (a cache hit would serve a stale card).
    await pumpRows(const ValueKey('turn-11'), workflowRows);
    expect(debugTurnGroupBuilds, 1);
    debugTurnGroupBuilds = 0;
    feedWorkflowRun('run-2');
    await pumpRows(const ValueKey('turn-11'), workflowRows);
    expect(debugTurnGroupBuilds, 1,
        reason: 'the workflow-row group must rebuild on a new mirror instance');
  });

  testWidgets('theme flip re-renders cached content through child deps',
      (tester) async {
    final rows = turnRows();
    await pumpGroup(tester, rows);
    expect(debugTurnGroupBuilds, 1);
    debugMarkdownBodiesBuilt = 0;

    await pumpGroup(tester, rows, theme: buildLightTheme());
    // The group body may shortcut (children carry their own Theme deps), but
    // the markdown must restyle, not keep the dark-theme colours.
    expect(debugMarkdownBodiesBuilt, greaterThan(0),
        reason: 'theme change must not leave the dark style sheet cached');
    final styles = [
      for (final body in tester.widgetList<MarkdownBody>(
        find.byType(MarkdownBody),
      ))
        body.styleSheet?.p?.color,
    ];
    expect(
      styles,
      contains(ZColors.neutral700),
      reason: 'light theme resolves the prose ink to neutral700',
    );
    expect(styles, isNot(contains(ZColors.neutral200)));
  });
}