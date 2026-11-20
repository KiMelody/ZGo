import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation_state.dart';
import 'package:zgo/ui/chat/diff_view.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

/// Task 11-19 step 3: the collapsed tool card must not pay for its body.
/// `ExpansionTile` builds its children even while offstage (the SDK wraps the
/// body in `Offstage`, which only skips painting), so the tile gates the
/// children list on its own `_expanded` and memoizes the extraction work.

Widget wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  builder: (context, child) =>
      UiSettingsProvider(settings: UiSettings()..locale = 'zh-CN', child: child!),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Widget chatRow(Map<String, dynamic> row) {
  final recording = RecordingCalls();
  return ChatRow(
    row: row,
    conversation: FakeConversation(recording),
    sessionId: 's1',
    onAction: (_, __) async {},
    state: ConversationState()..rows = [row],
    preview: ChatPreview(FakeWorkspaceContext(recording)),
  );
}

Map<String, dynamic> editRow() => {
  'rowId': 1,
  'kind': 'toolCall',
  'toolName': 'Edit',
  'status': 'success',
  'input': {
    'file_path': 'C:/w/a.dart',
    'old_string': 'one\ntwo',
    'new_string': 'one\nthree',
  },
};

/// No extractable diff → the expansion renders the raw JSON body through
/// `_kv`, carrying the sentinel that proves the body was built.
Map<String, dynamic> bashRow() => {
  'rowId': 2,
  'kind': 'toolCall',
  'toolName': 'Bash',
  'status': 'success',
  'inputText': '{"command":"echo hi"}',
  'output': {'text': 'kv-body-sentinel'},
};

void main() {
  testWidgets('a collapsed tool card builds no diff body; expanding does',
      (tester) async {
    await tester.pumpWidget(wrap(chatRow(editRow())));
    await tester.pumpAndSettle();

    // Collapsed: the summary renders, the body never enters the tree. This
    // is the assertion the old implementation failed — the offstage body
    // built the DiffView on every rebuild.
    expect(find.textContaining('已写入'), findsOneWidget);
    expect(find.byType(DiffView), findsNothing);

    await tester.tap(find.byType(ExpansionTile).first);
    await tester.pumpAndSettle();

    // Expanded: the same content as before the change.
    expect(find.byType(DiffView), findsOneWidget);
    expect(find.textContaining('one'), findsWidgets);
  });

  testWidgets('a collapsed tool card builds no kv body; expanding does',
      (tester) async {
    await tester.pumpWidget(wrap(chatRow(bashRow())));
    await tester.pumpAndSettle();

    expect(find.textContaining('kv-body-sentinel'), findsNothing,
        reason: 'the pretty-printed JSON body is not built while collapsed');

    await tester.tap(find.byType(ExpansionTile).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('kv-body-sentinel'), findsWidgets);

    // Collapse by tapping the header line (the ExpansionTile box now spans
    // the open body, so its center would land inside the content).
    await tester.tap(find.textContaining('终端 · echo hi'));
    await tester.pumpAndSettle();
    expect(find.textContaining('kv-body-sentinel'), findsNothing,
        reason: 'collapsing drops the body again (no stale mount)');
  });

  test('extractDiff memoizes by row identity (no re-extraction on rebuilds)',
      () {
    debugDiffExtractions = 0;
    final row = editRow();
    final first = extractDiff(row);
    final second = extractDiff(row);
    expect(identical(first, second), isTrue,
        reason: 'the same row instance must reuse the cached DiffData');
    expect(debugDiffExtractions, 1,
        reason: 'one extraction for two lookups');

    // A fresh map with identical content is a new identity: rows are
    // replaced wholesale on an upsert, and that is when the cache misses.
    final copy = Map<String, dynamic>.from(row);
    extractDiff(copy);
    expect(debugDiffExtractions, 2);

    // "No diff" is memoized too (the sentinel keeps it from re-extracting).
    debugDiffExtractions = 0;
    final plain = {'rowId': 9, 'kind': 'toolCall'};
    expect(extractDiff(plain), isNull);
    expect(extractDiff(plain), isNull);
    expect(debugDiffExtractions, 1);
  });

  testWidgets('rebuilding an unchanged tool row does not re-extract the diff',
      (tester) async {
    // Warm-up build outside the measured window (theme/localizations frames).
    await tester.pumpWidget(wrap(chatRow(editRow())));
    await tester.pumpAndSettle();

    debugDiffExtractions = 0;
    final row = editRow();
    await tester.pumpWidget(wrap(chatRow(row)));
    await tester.pumpAndSettle();
    final afterFirstBuild = debugDiffExtractions;
    expect(afterFirstBuild, 1,
        reason: 'the tile and toolRowSemantics share one extraction');

    // New widget instances, same row map: a rebuild must hit the memo.
    await tester.pumpWidget(wrap(chatRow(row)));
    await tester.pumpAndSettle();
    expect(debugDiffExtractions, afterFirstBuild);
  });
}