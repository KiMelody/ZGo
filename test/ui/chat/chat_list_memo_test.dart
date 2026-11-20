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
}