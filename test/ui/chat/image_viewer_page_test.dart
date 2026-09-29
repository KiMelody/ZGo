import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/chat/image_viewer_page.dart';
import 'package:zlinker/ui/theme.dart';

/// 1x1 PNG (valid decode target for Image.memory in tests).
final Uint8List kPng =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlE'
        'QVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

Widget wrap(Widget child) => MaterialApp(theme: buildDarkTheme(), home: child);

/// Home that pushes the viewer with [zRoute]-equivalent navigation so the
/// close action has a route to pop.
class _Launcher extends StatelessWidget {
  const _Launcher({required this.bytes, this.fileName});

  final Uint8List bytes;
  final String? fileName;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<dynamic>(
                builder: (_) =>
                    ImageViewerPage(bytes: bytes, fileName: fileName),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      );
}

Future<void> pumpViewer(WidgetTester tester,
    {String? fileName, Size? size}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
      wrap(_Launcher(bytes: kPng, fileName: fileName)));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the image inside an InteractiveViewer with chrome',
      (tester) async {
    await pumpViewer(tester, fileName: 'assets/chart.png');
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('assets/chart.png'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('close button pops back to the caller', (tester) async {
    await pumpViewer(tester, fileName: 'a.png');
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('tapping the image area toggles the chrome', (tester) async {
    await pumpViewer(tester, fileName: 'a.png');
    final opacity = tester.widget<AnimatedOpacity>(
      find.descendant(
          of: find.byType(ImageViewerPage), matching: find.byType(AnimatedOpacity)),
    );
    expect(opacity.opacity, 1);

    await tester.tap(find.byType(InteractiveViewer));
    await tester.pump();
    final hidden = tester.widget<AnimatedOpacity>(
      find.descendant(
          of: find.byType(ImageViewerPage), matching: find.byType(AnimatedOpacity)),
    );
    expect(hidden.opacity, 0);
  });

  testWidgets('chrome-less viewer (no file name) renders the close row only',
      (tester) async {
    await pumpViewer(tester);
    expect(find.text(''), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('landscape short viewport does not overflow', (tester) async {
    await pumpViewer(tester,
        fileName: 'wide.png', size: const Size(851, 390));
    expect(tester.takeException(), isNull);
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });
}
