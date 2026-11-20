import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/markdown_view.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

/// Task 11-19 chat-scroll wave 2 step 3, page level: a wire frame that does
/// not change row instances must reuse the grouping AND the group widget
/// instances (Flutter skips their whole subtree update); a frame touching
/// one turn must rebuild only that turn. Row immutability (chat-conventions
/// §9) is the fingerprint that makes this legal.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => MaterialApp(
    theme: buildDarkTheme(),
    darkTheme: buildDarkTheme(),
    builder: (context, inner) =>
        UiSettingsProvider(settings: UiSettings(), child: inner!),
    home: child,
  );

  List<Map<String, dynamic>> turns() => [
    {'rowId': 1, 'kind': 'userInput', 'text': 'first question'},
    {
      'rowId': 2,
      'kind': 'turnHeader',
      'state': 'completedSuccess',
      'activeMs': 1000,
    },
    {'rowId': 3, 'kind': 'assistantText', 'text': 'first **answer**'},
    {'rowId': 4, 'kind': 'userInput', 'text': 'second question'},
    {
      'rowId': 5,
      'kind': 'turnHeader',
      'state': 'completedSuccess',
      'activeMs': 1000,
    },
    {'rowId': 6, 'kind': 'assistantText', 'text': 'second **answer**'},
    {'rowId': 7, 'kind': 'userInput', 'text': 'third question'},
    {
      'rowId': 8,
      'kind': 'turnHeader',
      'state': 'completedSuccess',
      'activeMs': 1000,
    },
    {'rowId': 9, 'kind': 'assistantText', 'text': 'third **answer**'},
  ];

  ChatTurnGroup groupFor(WidgetTester tester, int rowId) =>
      tester.widget<ChatTurnGroup>(find.byKey(ValueKey('turn-$rowId')));

  testWidgets('a frame touching no row reuses grouping and widget instances',
      (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    final rows = turns();
    gateway.feedSnapshot(rows);
    await tester.pumpAndSettle();

    // The ListView only builds the bottom window; groups 4/5/8 are in it.
    final g4 = groupFor(tester, 4);
    final g5 = groupFor(tester, 5);
    final g8 = groupFor(tester, 8);
    debugGroupingComputations = 0;
    debugTurnGroupBuilds = 0;
    debugMarkdownBodiesBuilt = 0;

    // A wire frame that replaces no row map (a row.delta on a path the row
    // does not own — the state notifies, the rows are untouched).
    final state0 = gateway.state;
    state0.applyFrame({
      'fromSeq': state0.seq,
      'toSeq': state0.seq + 1,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {'op': 'row.delta', 'rowId': 4, 'path': 'text', 'append': ''},
        ],
      },
    }, onGap: () => fail('unexpected gap'));
    await tester.pumpAndSettle();

    expect(debugGroupingComputations, 0,
        reason: 'unchanged rows must reuse the cached groups');
    expect(debugTurnGroupBuilds, 0,
        reason: 'identical group widgets → the whole subtree update is skipped');
    expect(debugMarkdownBodiesBuilt, 0);
    expect(identical(groupFor(tester, 4), g4), isTrue);
    expect(identical(groupFor(tester, 5), g5), isTrue);
    expect(identical(groupFor(tester, 8), g8), isTrue);
  });

  testWidgets('a non-row state frame costs no grouping and no group rebuild',
      (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(turns());
    await tester.pumpAndSettle();
    final before = [
      for (final id in [4, 5, 8]) groupFor(tester, id),
    ];
    debugGroupingComputations = 0;
    debugTurnGroupBuilds = 0;

    final state = gateway.state;
    state.applyFrame({
      'fromSeq': state.seq,
      'toSeq': state.seq + 1,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {
            'op': 'state.updated',
            'patch': {
              'config': {'provider': 'glm', 'model': 'glm-5.2'},
            },
          },
        ],
      },
    }, onGap: () => fail('unexpected gap'));
    await tester.pumpAndSettle();

    expect(debugGroupingComputations, 0,
        reason: 'no row instance changed → the grouping stays cached');
    expect(debugTurnGroupBuilds, 0);
    for (var i = 0; i < before.length; i++) {
      expect(identical(groupFor(tester, [4, 5, 8][i]), before[i]), isTrue);
    }
  });

  testWidgets('a tail-row delta rebuilds only the growing group',
      (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(turns());
    await tester.pumpAndSettle();
    // The ListView only builds the bottom window; groups 4/5/8 are in it.
    final g4 = groupFor(tester, 4);
    final g5 = groupFor(tester, 5);
    final g8 = groupFor(tester, 8);
    debugGroupingComputations = 0;
    debugTurnGroupBuilds = 0;
    debugMarkdownBodiesBuilt = 0;
    final state = gateway.state;
    state.applyFrame({
      'fromSeq': state.seq,
      'toSeq': state.seq + 1,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {
            'op': 'row.delta',
            'rowId': 9,
            'path': 'text',
            'append': ' continued',
          },
        ],
      },
    }, onGap: () => fail('unexpected gap'));
    await tester.pumpAndSettle();

    expect(debugGroupingComputations, 1,
        reason: 'exactly one recompute for one changed row');
    expect(debugTurnGroupBuilds, 1,
        reason: 'only the group owning the changed row rebuilds');
    expect(identical(groupFor(tester, 4), g4), isTrue);
    expect(identical(groupFor(tester, 5), g5), isTrue);
    expect(identical(groupFor(tester, 8), g8), isFalse);
    expect(debugMarkdownBodiesBuilt, 1,
        reason: 'only the changed text re-parses');
  });

  testWidgets('an appended row extends the tail group in place',
      (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(turns());
    await tester.pumpAndSettle();
    // The ListView only builds the bottom window; groups 4/5/8 are in it.
    final g4 = groupFor(tester, 4);
    final g5 = groupFor(tester, 5);
    final g8 = groupFor(tester, 8);
    debugGroupingComputations = 0;
    debugTurnGroupBuilds = 0;

    final state = gateway.state;
    state.applyFrame({
      'fromSeq': state.seq,
      'toSeq': state.seq + 1,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {
            'op': 'row.appended',
            'row': {
              'rowId': 10,
              'kind': 'assistantText',
              'text': 'tail follow-up',
              'assistantResponseId': 'm9',
            },
          },
        ],
      },
    }, onGap: () => fail('unexpected gap'));
    await tester.pumpAndSettle();

    expect(debugGroupingComputations, 1);
    expect(debugTurnGroupBuilds, 1);
    expect(identical(groupFor(tester, 4), g4), isTrue);
    expect(identical(groupFor(tester, 5), g5), isTrue);
    // The tail turn (rowId 8 group) now owns the appended row: new instance.
    expect(identical(groupFor(tester, 8), g8), isFalse);
    expect(groupFor(tester, 8).rows.last['rowId'], 10);
  });

  testWidgets(
      'a subagent row appended to another turn relights the cached Agent '
      'group drill-in arrow', (tester) async {
    // R5/D4 cross-turn path: the Agent card sits in turn 1, the later turn
    // (4) owns the rows that follow, and the subagent row arrives at the
    // tail via row.appended. Turn 1's own row instances therefore do not
    // change; only the shared agent-subagent table instance does. The
    // page-level widget cache must not serve the stale instance — build
    // would never run and the arrow would stay missing.
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'spawn an agent'},
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'activeMs': 1000,
      },
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'Agent',
        'toolCallId': 'call-1',
        'status': 'running',
        'inputText': '{"description": "explore", "prompt": "scan"}',
      },
      {'rowId': 4, 'kind': 'userInput', 'text': 'next question'},
      {
        'rowId': 5,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'activeMs': 1000,
      },
      {'rowId': 6, 'kind': 'assistantText', 'text': 'next answer'},
    ]);
    await tester.pumpAndSettle();

    final agentGroup = groupFor(tester, 2);
    expect(agentGroup.agentSubagentByRowId, isEmpty,
        reason: 'the Agent group pays the shared-table input even before the '
            'spawned row exists');
    final arrow = find.descendant(
      of: find.byKey(const ValueKey('turn-2')),
      matching: find.byIcon(Icons.chevron_right),
    );
    expect(arrow, findsNothing,
        reason: 'without a childSessionId the drill-in arrow is hidden');
    debugTurnGroupBuilds = 0;

    final subagentRow = <String, dynamic>{
      'rowId': 7,
      'kind': 'subagent',
      'parentToolCallId': 'call-1',
      'childSessionId': 'sess_child_1',
      'summaryText': 'explore',
      'subagentType': 'general-purpose',
      'status': 'running',
    };
    final state = gateway.state;
    state.applyFrame({
      'fromSeq': state.seq,
      'toSeq': state.seq + 1,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {'op': 'row.appended', 'row': subagentRow},
        ],
      },
    }, onGap: () => fail('unexpected gap'));
    await tester.pumpAndSettle();

    // The Agent turn's rows are untouched (the row landed in a later
    // group); the cache must still miss because the shared table changed.
    final rebuilt = groupFor(tester, 2);
    expect(identical(rebuilt, agentGroup), isFalse,
        reason: 'the new shared table instance is part of sameInputs');
    expect(rebuilt.rows.length, agentGroup.rows.length);
    // row.appended stores a cast view of the delta payload, so compare the
    // resolved row's fields rather than the literal's identity.
    expect(rebuilt.agentSubagentByRowId![3]!['rowId'], 7);
    expect(rebuilt.agentSubagentByRowId![3]!['childSessionId'], 'sess_child_1');
    expect(arrow, findsOneWidget,
        reason: 'the rebuilt Agent tile resolves the appended subagent row');
    expect(debugTurnGroupBuilds, greaterThanOrEqualTo(1));
    // The appended row rode the tail turn, as the fixture intended.
    expect(groupFor(tester, 5).rows.last['rowId'], 7);
  });
}