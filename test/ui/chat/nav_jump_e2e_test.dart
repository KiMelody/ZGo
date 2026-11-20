// E2E acceptance for the turn-navigator jump chain (task 11-19 step 8,
// design D7 / PRD R1-R3). The message list is a fixed-height lazy list, so a
// jump whose final offset is derived from 0/maxScrollExtent probes parks in
// unpainted layout space; this file clicks real navigator cells through the
// production wiring and asserts the MEASURED landing.
//
// Cell targeting goes through the semantics labels, never strip indices: the
// strip is an itemExtent:10 ListView (210 cells = 2100dp, taller than the
// visible strip) that `_syncStrip` auto-scrolls as the highlight moves, so
// ListView indices drift under the test. The label is the user-facing
// "跳转到第 N 条问题" copy built by TurnNavigator._cell/_panelCell.
//
// Root causes covered:
// - R1/R2 uniform 210-query session (total ~177k px, above the 120k jump
//   cache ceiling): top / middle / bottom targets must land the query group
//   on the viewport top (±8px) and never on an estimate pole.
// - R2 give-up branch: unreachable under the uniform fixture (the widened
//   window always covers the target), so a small debugJumpMaxCacheExtent
//   ceiling plus a height-skewed session forces the proportional probe to
//   miss the target; the chain must fall back to the pre-jump offset.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/turn_navigator.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  darkTheme: buildDarkTheme(),
  builder: (context, inner) =>
      UiSettingsProvider(settings: UiSettings(), child: inner!),
  home: child,
);

/// One plain-text paragraph line; repeated 11x it lays out at 749px in the
/// 390-wide test viewport (measured). A single paragraph per answer keeps
/// the widened-cache layout pass cheap — no markdown structure to parse, no
/// images, no tool cards.
const String _answerLine =
    'Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu. ';

String _uniformAnswer() => _answerLine * 11;

/// 210 turns of user question + ~749px plain answer → ~845px per turn,
/// ~177k px total (above the 120k production jump cache ceiling). Row ids
/// double as the query directory (i*10+1) so `turn-<rowId>` keys are stable.
List<Map<String, dynamic>> uniformSession({int queries = 210}) => [
  for (var i = 0; i < queries; i++) ...[
    {
      'rowId': i * 10 + 1,
      'kind': 'userInput',
      'text': '问题 $i',
      'origin': 'realUser',
    },
    {
      'rowId': i * 10 + 2,
      'kind': 'assistantText',
      'text': _uniformAnswer(),
    },
  ],
];

/// Height-skewed session for the give-up branch: the first 12 answers are
/// ~2828px plain paragraphs, the remaining 18 are ~476px line lists, so a
/// proportional probe built on a small cache window cannot be trusted —
/// exactly the degenerate distribution the fallback exists for.
List<Map<String, dynamic>> skewedSession({int queries = 30}) => [
  for (var i = 0; i < queries; i++) ...[
    {
      'rowId': i * 10 + 1,
      'kind': 'userInput',
      'text': '问题 $i',
      'origin': 'realUser',
    },
    {
      'rowId': i * 10 + 2,
      'kind': 'assistantText',
      'text': i < 12
          ? _answerLine * 44
          : List.generate(20, (l) => 'line $l of the answer').join('\n'),
    },
  ],
];

/// Pumps the chat page at the 390x844 test viewport, feeds [rows], and
/// settles the list onto the newest end (the jump chain's origin).
Future<ScrollController> pumpChat(
  WidgetTester tester,
  FakeChatGateway gateway,
  List<Map<String, dynamic>> rows,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    wrap(
      ChatPage(
        host: gateway,
        sessionId: 's1',
        title: 't',
        // Pin the terminal-footer confirm window beyond the test: the footer
        // popping in per group grows the content mid-test and would shift
        // groups AFTER a measured landing.
        turnFooterConfirmWindow: const Duration(days: 1),
      ),
    ),
  );
  gateway.feedSnapshot(rows);
  await tester.pumpAndSettle();
  // The message list is the FIRST ListView in the Stack (the navigator
  // strip's own scrollable is a later sibling).
  final controller =
      tester.widget<ListView>(find.byType(ListView).first).controller!;
  // Constructive precondition (same effect as a user scrolling to the
  // bottom): opening a 420-group window lands on the FIRST frame's extent
  // estimate and no later state frame follows, so the session rests short of
  // the newest end. Settle onto the real bottom so the jump origin — and the
  // full >120k distance to the top targets — is deterministic.
  controller.jumpTo(controller.position.maxScrollExtent);
  await tester.pumpAndSettle();
  return controller;
}

TurnNavigator strip(WidgetTester tester) =>
    tester.widget<TurnNavigator>(find.byType(TurnNavigator));

/// Floats the enlarged panel out (long-press on the right-edge band), then
/// scrolls the panel so [index]'s cell sits centered/visible. Long-press
/// instead of dragging the thin strip: the panel scrolls 32dp slots and the
/// controller jump is deterministic (no drag overshoot loop).
Future<void> openOverlayAt(WidgetTester tester, int index) async {
  final rect = tester.getRect(find.byType(TurnNavigator));
  final gesture = await tester.startGesture(
    Offset(rect.right - TurnNavigator.hitWidth / 2, rect.center.dy),
  );
  await tester.pump(const Duration(milliseconds: 300));
  await gesture.up();
  await tester.pumpAndSettle();
  final panel = find.descendant(
    of: find.byType(TurnNavigator),
    matching: find.byWidgetPredicate(
      (w) => w is ListView && w.itemExtent == TurnNavigator.expandedSlotHeight,
    ),
  );
  expect(
    panel,
    findsOneWidget,
    reason: 'the long-press on the strip band must float the enlarged panel',
  );
  final controller = tester.widget<ListView>(panel).controller!;
  final desired =
      (TurnNavigator.expandedSlotHeight * (index + 0.5) -
              controller.position.viewportDimension / 2)
          .clamp(0.0, controller.position.maxScrollExtent);
  controller.jumpTo(desired);
  await tester.pumpAndSettle();
}

/// Clicks query [index]'s navigator cell by its semantics label, floating
/// the overlay first when the cell is outside the thin strip's built window.
Future<void> tapQueryCell(WidgetTester tester, int index) async {
  final label = '跳转到第 ${index + 1} 条问题';
  var cell = find.bySemanticsLabel(label);
  if (cell.evaluate().isEmpty) {
    await openOverlayAt(tester, index);
    cell = find.bySemanticsLabel(label);
    expect(
      cell,
      findsOneWidget,
      reason: 'the enlarged panel must expose "$label" after scrolling to it',
    );
  }
  await tester.tap(cell);
  await tester.pumpAndSettle();
}

/// Asserts the query [index]'s turn group sits on the viewport top (±8px),
/// overlaps the viewport, and the settled offset is neither estimate pole.
void expectLandedOnTop(
  WidgetTester tester,
  ScrollController controller,
  int index,
) {
  final rowId = index * 10 + 1;
  final viewport = find.byType(ListView).first;
  final viewportTop = tester.getTopLeft(viewport).dy;
  final viewportHeight = tester.getSize(viewport).height;
  final position = controller.position;
  final max = position.maxScrollExtent;
  final pixels = position.pixels;
  final group = find.byKey(ValueKey('turn-$rowId'), skipOffstage: false);
  debugPrint(
    '[e2e] query=$index pixels=${pixels.toStringAsFixed(1)} '
    'max=${max.toStringAsFixed(1)} (settled: '
    '${pixels <= max ? 'pixels <= max' : 'PIXELS > MAX'})',
  );
  expect(
    group,
    findsOneWidget,
    reason: 'query $index group must be built after the jump',
  );
  final groupTop = tester.getTopLeft(group).dy;
  final groupSize = tester.getSize(group);
  debugPrint(
    '[e2e] query=$index groupTop=${groupTop.toStringAsFixed(2)} '
    'viewportTop=${viewportTop.toStringAsFixed(2)} '
    'delta=${(groupTop - viewportTop).toStringAsFixed(2)}',
  );
  expect(
    (groupTop - viewportTop).abs(),
    lessThanOrEqualTo(8),
    reason:
        'query $index must land on the viewport top (±8px), never at an '
        'estimate pole',
  );
  expect(
    groupTop,
    lessThan(viewportTop + viewportHeight),
    reason: 'the landed group must overlap the viewport',
  );
  expect(
    groupTop + groupSize.height,
    greaterThan(viewportTop),
    reason: 'the landed group must overlap the viewport',
  );
  expect(pixels, greaterThan(0), reason: 'a mid-session target is not 0');
  expect(
    pixels,
    lessThan(max),
    reason: 'a mid-session target never parks at maxScrollExtent',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'uniform long session: top/middle/bottom query cells land on the '
    'viewport top (±8px), never on an estimate pole',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final gateway = FakeChatGateway();
        final controller = await pumpChat(tester, gateway, uniformSession());

        // The precondition settled onto the newest end: all 210 cells, the
        // last one active.
        expect(strip(tester).rowIds.length, 210);
        expect(strip(tester).activeIndex, 209);
        debugPrint(
          '[e2e] opened pixels=${controller.position.pixels} '
          'max=${controller.position.maxScrollExtent}',
        );

        // Top (4, 12), middle (70, 140) and bottom (190, 200) of the loaded
        // window. The last turn (209) is deliberately absent: its remaining
        // content cannot fill a viewport, so the clamp is expected behavior
        // (PRD non-goal), not a landing bug.
        for (final index in const [4, 12, 70, 140, 190, 200]) {
          await tapQueryCell(tester, index);
          expectLandedOnTop(tester, controller, index);
          // The highlight follows the reader's position to the same group.
          expect(strip(tester).activeIndex, index);
        }
      } finally {
        // WidgetTester verifies semantic handles were disposed BEFORE
        // addTearDown runs; dispose in the body.
        semantics.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'give-up returns to the pre-jump offset when the small cache ceiling '
    'cannot cover a height-skewed target',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final previousCeiling = debugJumpMaxCacheExtent;
      debugJumpMaxCacheExtent = 2000;
      try {
        final gateway = FakeChatGateway();
        final controller = await pumpChat(
          tester,
          gateway,
          skewedSession(),
        );
        expect(strip(tester).rowIds.length, 30);
        expect(strip(tester).activeIndex, 29);
        final origin = controller.position.pixels;
        debugPrint(
          '[e2e] give-up origin=$origin max=${controller.position.maxScrollExtent}',
        );
        expect(origin, greaterThan(0), reason: 'starts pinned to the newest end');

        // Query 5 sits in the tall first half; with a 2k cache window the
        // probe cannot bring it into layout, so the chain must give up.
        await tapQueryCell(tester, 5);

        expect(controller.position.pixels, origin);
        debugPrint(
          '[e2e] give-up settled pixels=${controller.position.pixels} '
          'max=${controller.position.maxScrollExtent}',
        );
      } finally {
        debugJumpMaxCacheExtent = previousCeiling;
        // WidgetTester verifies semantic handles were disposed BEFORE
        // addTearDown runs; dispose in the body.
        semantics.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}