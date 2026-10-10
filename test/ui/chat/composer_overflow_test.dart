import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/chat_page.dart';

import '../chat_page_test.dart' show FakeChatGateway, wrap;

/// Composer tool-row overflow matrix (10-10-composer-overflow-fix): every
/// portrait icon-only combination must lay out with zero RenderFlex overflow
/// at the three supported phone widths, and the label mode (≥640) must
/// ellipsize a long model chip instead of overflowing.
///
/// RenderFlex overflow reports go through FlutterError, so an overflowing
/// cell fails its testWidgets on its own; the explicit `takeException`
/// guard keeps a silent pass impossible.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const longModelLabel = 'GLM-4.6-AirX-Enterprise-Edition';

  /// Pumps one chat page at [width] logical dp with the requested tool-row
  /// state (running turn / background pill / usage ring / model label).
  Future<void> pumpComposer(
    WidgetTester tester, {
    required double width,
    bool running = false,
    bool pill = false,
    bool ring = false,
    String? modelLabel,
  }) async {
    tester.view.physicalSize = Size(width, 800);
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
