import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/state/entitlement_poller.dart';
import 'package:zgo/ui/chat/chat_page.dart';

import '../chat_page_test.dart' show FakeChatGateway, wrap;

/// Composer tool-row overflow matrix (10-10-composer-overflow-fix): every
/// portrait icon-only combination must lay out with zero RenderFlex overflow
/// at the three supported phone widths, and the label mode (≥640) must
/// ellipsize a long model chip instead of overflowing.
///
/// Keyboard dimension (10-16-narrow-screen-overflow R2/R3): with the IME
/// up (`tester.view.viewInsets` — the real view, so both the Scaffold's
/// resize and the page's `_KeyboardProbe` see it) the body shrinks to the
/// height that never tripped the `short` (<480 full-screen) landscape fold
/// and used to put the fixed stack past the body height. Each keyboard cell
/// first PROVES the keyboard branch ran (body/list height actually shrank,
/// second header row folded) and only then asserts zero overflow —
/// green-means-tested: an inset that never reached the tree would otherwise
/// pass silently.
///
/// RenderFlex overflow reports go through FlutterError, so an overflowing
/// cell fails its testWidgets on its own; the explicit `takeException`
/// guard keeps a silent pass impossible.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const longModelLabel = 'GLM-4.6-AirX-Enterprise-Edition';

  /// The keyboard inset used across the keyboard cells: beyond the probe's
  /// 100dp enter threshold, matching a mid-size OEM IME on a 800dp screen.
  const keyboardInset = 280.0;
  const viewportHeight = 800.0;

  /// Pumps one chat page at [width] logical dp with the requested tool-row
  /// state (running turn / background pill / usage ring / model label /
  /// topped-out plan quota banner).
  Future<void> pumpComposer(
    WidgetTester tester, {
    required double width,
    bool running = false,
    bool pill = false,
    bool ring = false,
    bool quotaExhausted = false,
    String? modelLabel,
  }) async {
    tester.view.physicalSize = Size(width, viewportHeight);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      if (running)
        'control': {'phase': 'running'},
      if (pill)
        'backgroundWorks': [
          {
            'workId': 'bash_1',
            'kind': 'bash',
            'title': 'Download Flutter SDK',
            'status': 'running',
            'cancellable': true,
          },
        ],
      if (ring) 'usage': {'used': 50000, 'size': 100000},
      if (modelLabel != null) 'config': {'model': modelLabel},
    };
    if (quotaExhausted) {
      // Token-class limit topped out (the only class that raises the chat
      // warning banner — TIME_LIMIT is the excluded monthly MCP quota).
      gateway.entitlementResult = EntitlementView(
        phase: EntitlementPhase.ok,
        data: {
          'quota': {
            'limits': [
              {'type': 'TOKENS_LIMIT', 'percentage': 100},
            ],
          },
        },
      );
    }
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    // Finite pumps: the pill's breathing dot animates forever, so
    // pumpAndSettle would time out on the pill cells.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Raises the IME (finite pumps — the pill's breathing dot never settles).
  Future<void> raiseKeyboard(WidgetTester tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardInset);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// The message list — the fill of the body's Expanded, so its height
  /// tracks the body: the instrument for "the keyboard branch really ran".
  Size bodyProbe(WidgetTester tester) =>
      tester.getSize(find.byType(ListView).first);

  /// Second header row marker: `chat.more` text 更多 is unique to that row
  /// in portrait (the landscape compact app bar carries a ⋮ icon instead).
  final secondHeader = find.text('更多');

  for (final width in <double>[360, 393, 412]) {
    for (final running in [false, true]) {
      for (final pill in [false, true]) {
        for (final ring in [false, true]) {
          testWidgets(
            'composer tool row fits $width dp '
            '(running=$running pill=$pill ring=$ring)',
            (tester) async {
              await pumpComposer(
                tester,
                width: width,
                running: running,
                pill: pill,
                ring: ring,
              );
              expect(tester.takeException(), isNull);
              if (running) {
                // Official swap (bundle cn = en && !nn): the empty-composer
                // fixture shows stop owning the slot, no send beside it.
                expect(find.byIcon(Icons.stop), findsOneWidget);
                expect(find.byIcon(Icons.arrow_upward), findsNothing);
              }
              if (pill) {
                expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
              }
              if (ring) {
                expect(find.byTooltip('用量统计'), findsOneWidget);
              }
            },
          );
        }
      }
    }
  }

  for (final width in <double>[360, 384]) {
    for (final running in [false, true]) {
      for (final pill in [false, true]) {
        testWidgets(
          'keyboard-up composer fits $width dp (running=$running pill=$pill)',
          (tester) async {
            await pumpComposer(
              tester,
              width: width,
              running: running,
              pill: pill,
            );
            final resting = bodyProbe(tester);
            // Portrait 800dp: `short` (<480 full-screen height) is
            // guaranteed false — the fold asserted below can only come
            // from the keyboard signal.
            expect(secondHeader, findsOneWidget);

            await raiseKeyboard(tester);

            // Green-means-tested: the keyboard branch is provably live —
            // the body shrank by most of the inset and the second header
            // row folded (R2). Only then is the overflow assertion trusted.
            final shrunk = bodyProbe(tester);
            expect(resting.height - shrunk.height, greaterThan(150));
            expect(secondHeader, findsNothing);
            // The composer rides above the IME top edge.
            expect(
              tester.getBottomRight(find.byType(TextField).first).dy,
              lessThanOrEqualTo(viewportHeight - keyboardInset + 0.5),
            );
            expect(tester.takeException(), isNull);
            if (running) {
              expect(find.byIcon(Icons.stop), findsOneWidget);
              expect(find.byIcon(Icons.arrow_upward), findsNothing);
            }
            if (pill) {
              expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
            }
          },
        );
      }
    }
  }

  testWidgets(
    'keyboard fold follows the 100/80 hysteresis: row folds past the enter '
    'threshold, survives a dip into the band, restores on collapse',
    (tester) async {
      await pumpComposer(tester, width: 360, running: true, pill: true);
      expect(secondHeader, findsOneWidget);

      // 90dp sits inside the hysteresis band (enter 100 / exit 80): not
      // yet the keyboard-occupied viewport — the row stays.
      tester.view.viewInsets = const FakeViewPadding(bottom: 90);
      await tester.pump();
      expect(secondHeader, findsOneWidget);

      // Past the enter threshold: the row folds, `short`-style.
      await raiseKeyboard(tester);
      expect(secondHeader, findsNothing);
      expect(tester.takeException(), isNull);

      // A dip into the band does not release the fold (exit threshold 80).
      tester.view.viewInsets = const FakeViewPadding(bottom: 90);
      await tester.pump();
      expect(secondHeader, findsNothing);

      // Collapse restores the row, and the composer survived the whole
      // dance (the fold swaps only the slot's inner content — spec §8.1).
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      expect(secondHeader, findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keyboard up caps the quota banner run and scrolls it (R2 structural '
    'fallback: the fixed stack scrolls instead of RenderFlex-overflowing '
    'the shrunken body)',
    (tester) async {
      await pumpComposer(
        tester,
        width: 360,
        running: true,
        quotaExhausted: true,
      );
      final banner = find.text('套餐额度已用尽');
      Finder scrollAncestor() => find.ancestor(
        of: banner,
        matching: find.byType(SingleChildScrollView),
      );
      expect(banner, findsOneWidget);
      // Resting layout: the run is the verbatim Column, no scroll wrapper.
      expect(scrollAncestor(), findsNothing);

      await raiseKeyboard(tester);
      expect(tester.takeException(), isNull);
      // Keyboard-occupied: the fallback branch actually ran — the banner
      // run sits inside the height-capped scroll view (cap 200dp), and the
      // banner stays rendered and reachable instead of overflowing.
      final scrolled = scrollAncestor();
      expect(scrolled, findsOneWidget);
      expect(tester.getSize(scrolled).height, lessThanOrEqualTo(201));
      expect(banner, findsOneWidget);
    },
  );

  testWidgets('label mode (640): long model chip ellipsizes, zero overflow', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      width: 640,
      running: true,
      pill: true,
      ring: true,
      modelLabel: longModelLabel,
    );
    expect(tester.takeException(), isNull);
    final label = find.text(longModelLabel);
    expect(label, findsOneWidget);
    final text = tester.widget<Text>(label);
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    // The cap confines the rendered label well below the chip's full
    // intrinsic width (ellipsis is active, not latent).
    expect(tester.getSize(label).width, lessThan(150));
  });

  testWidgets('label mode (1024): long model chip ellipsizes, zero overflow', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      width: 1024,
      running: true,
      pill: true,
      ring: true,
      modelLabel: longModelLabel,
    );
    expect(tester.takeException(), isNull);
    expect(find.text(longModelLabel), findsOneWidget);
  });
}
