import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/subagent_feed.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/recording_chat_gateway.dart';

/// `_TurnHeader` running-duration ticker (design D1): the running turn
/// recomputes its elapsed locally on a 1s clock (official web parity), a
/// terminal turn keeps the wire `activeMs`. Determinism: the tests inject
/// the State's clock seam and drive the ticker with `tester.pump` — real
/// wall-clock deltas are ~0ms in fast tests and would flake by construction.
void main() {
  const baseMs = 1700000000000;

  Widget wrap(Widget child) => MaterialApp(
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: Scaffold(body: child),
      );

  /// The library-private header's state, reached through the only public
  /// surface that builds it — the shared ChatTurnGroup renderer.
  dynamic headerState(WidgetTester tester) => tester.state<State>(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_TurnHeader',
        ),
      );

  Future<void> pumpTurn(
    WidgetTester tester,
    List<Map<String, dynamic>> rows,
    RecordingChatGateway gateway,
    SubagentFeed feed,
  ) async {
    await tester.pumpWidget(
      wrap(
        ChatTurnGroup(
          key: const ValueKey('turn-1'),
          rows: rows,
          gateway: gateway,
          sessionId: 's1',
          onAction: (label, action) async => action(),
          state: gateway.state,
          feed: feed,
          preview: ChatPreview(gateway),
          confirmWindow: const Duration(milliseconds: 150),
          workspaceLabel: null,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('running + startedAt ticks locally with the injected clock',
      (tester) async {
    final gateway = RecordingChatGateway();
    addTearDown(gateway.dispose);
    final feed = SubagentFeed(gateway: gateway);
    addTearDown(feed.dispose);
    await pumpTurn(tester, [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'running',
        'startedAt': baseMs - 65000,
      },
    ], gateway, feed);

    var nowMs = baseMs;
    final header = headerState(tester);
    header.clock = () => DateTime.fromMillisecondsSinceEpoch(nowMs);
    // Next ticker tick rebuilds with the injected clock: 65s elapsed.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('已工作 1 分 5 秒'), findsOneWidget);

    // Quiet stretch (no wire frames): the local ticker keeps counting.
    nowMs += 1000;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('已工作 1 分 6 秒'), findsOneWidget);
  });

  testWidgets('running takes max(wire activeMs, now − startedAt) — the '
      'monotonic rule against clock skew', (tester) async {
    final gateway = RecordingChatGateway();
    addTearDown(gateway.dispose);
    final feed = SubagentFeed(gateway: gateway);
    addTearDown(feed.dispose);
    await pumpTurn(tester, [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'running',
        // Wire says 30s, the local clock says 90s — the live readout wins.
        'activeMs': 30000,
        'startedAt': baseMs - 90000,
      },
    ], gateway, feed);

    var nowMs = baseMs;
    final header = headerState(tester);
    header.clock = () => DateTime.fromMillisecondsSinceEpoch(nowMs);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('已工作 1 分 30 秒'), findsOneWidget);

    // A wire value AHEAD of the local clock (device/desktop skew) must not
    // make the readout jump backwards — the max keeps the wire value.
    nowMs = baseMs - 120000;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('已工作 30 秒'), findsOneWidget);
  });

  testWidgets('terminal keeps the wire activeMs and never ticks', (
    tester,
  ) async {
    final gateway = RecordingChatGateway();
    addTearDown(gateway.dispose);
    final feed = SubagentFeed(gateway: gateway);
    addTearDown(feed.dispose);
    await pumpTurn(tester, [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'activeMs': 65000,
      },
    ], gateway, feed);

    var nowMs = baseMs;
    final header = headerState(tester);
    header.clock = () => DateTime.fromMillisecondsSinceEpoch(nowMs);
    nowMs += 5000;
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('已工作 1 分 5 秒'), findsOneWidget);
    expect(header.tickerArmed, isFalse,
        reason: 'terminal rows arm no ticker');
  });

  testWidgets('endedAt − startedAt is the terminal fallback chain (official '
      'RX order), missing fields fall back inert', (tester) async {
    final gateway = RecordingChatGateway();
    addTearDown(gateway.dispose);
    final feed = SubagentFeed(gateway: gateway);
    addTearDown(feed.dispose);
    await pumpTurn(tester, [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'startedAt': baseMs - 20000,
        'endedAt': baseMs - 5000,
      },
    ], gateway, feed);

    var nowMs = baseMs;
    final header = headerState(tester);
    header.clock = () => DateTime.fromMillisecondsSinceEpoch(nowMs);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('已工作 15 秒'), findsOneWidget);

    // Defensive fallback (live-wire trust is high but not absolute): a
    // running header without startedAt shows the wire value only — the
    // pre-ticker behavior, never a crash.
    await pumpTurn(tester, [
      {'rowId': 3, 'kind': 'userInput', 'text': 'hi again'},
      {'rowId': 4, 'kind': 'turnHeader', 'state': 'running'},
    ], gateway, feed);
    expect(find.textContaining('已工作'), findsNothing);
    expect(headerState(tester).tickerArmed, isFalse);
  });

  testWidgets('terminal upsert disarms the running ticker via '
      'didUpdateWidget; unmounting disarms via dispose', (tester) async {
    final gateway = RecordingChatGateway();
    addTearDown(gateway.dispose);
    final feed = SubagentFeed(gateway: gateway);
    addTearDown(feed.dispose);
    await pumpTurn(tester, [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'running',
        'startedAt': baseMs - 10000,
      },
    ], gateway, feed);

    var nowMs = baseMs;
    final header = headerState(tester);
    header.clock = () => DateTime.fromMillisecondsSinceEpoch(nowMs);
    await tester.pump(const Duration(seconds: 1));
    expect(header.tickerArmed, isTrue);

    // The terminal upsert (same rowId) re-renders the header — the state
    // survives, the ticker must not.
    await pumpTurn(tester, [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'activeMs': 65000,
      },
    ], gateway, feed);
    expect(header.tickerArmed, isFalse);
    nowMs += 5000;
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('已工作 1 分 5 秒'), findsOneWidget);
  });

  testWidgets('the armed ticker is canceled on unmount (ListView recycle '
      'path) — the test framework fails on a pending timer', (tester) async {
    final gateway = RecordingChatGateway();
    addTearDown(gateway.dispose);
    final feed = SubagentFeed(gateway: gateway);
    addTearDown(feed.dispose);
    await pumpTurn(tester, [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'running',
        'startedAt': baseMs - 10000,
      },
    ], gateway, feed);
    expect(headerState(tester).tickerArmed, isTrue);

    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    await tester.pump();
    // Reaching here without flutter_test's pending-timer complaint is the
    // dispose-path assertion.
  });
}
