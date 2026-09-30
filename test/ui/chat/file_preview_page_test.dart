import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/file_preview_page.dart';
import 'package:zgo/ui/theme.dart';

Widget wrap(Widget child) => MaterialApp(theme: buildDarkTheme(), home: child);

/// The page under test with a stub WebView surface (platform views are not
/// hostable in widget tests — the real InAppWebView is device-acceptance
/// territory; the seam exists for exactly this).
FilePreviewPage page({
  required Future<String?> Function(String path) readText,
  Future<String?> Function(String path)? readMediaDataUrl,
  Widget Function(BuildContext, String html)? webViewBuilder,
}) {
  return FilePreviewPage(
    path: 'C:/w/index.html',
    readText: readText,
    readMediaDataUrl: readMediaDataUrl ?? (_) async => null,
    webViewBuilder:
        webViewBuilder ?? (context, html) => Text('WEBVIEW:$html'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loading → done: assembles css into the rendered document',
      (tester) async {
    await tester.pumpWidget(wrap(page(
      readText: (path) => path.endsWith('index.html')
          ? asyncValue(
              '<html><head><link rel="stylesheet" href="a.css"></head>'
              '<body>hi</body></html>')
          : asyncValue('body{}'),
    )));
    await tester.pumpAndSettle();

    // The <link> was replaced by an inline <style> carrying the css.
    expect(find.textContaining('<style>'), findsOneWidget);
    final webview =
        tester.widget<Text>(find.textContaining('WEBVIEW:')).data!;
    expect(webview, isNot(contains('<link')));
    expect(webview, contains('body{}'));
    expect(find.text('index.html'), findsOneWidget); // app bar title
  });

  testWidgets('assembling phase shows the N/M progress line', (tester) async {
    final css = Completer<String?>();
    await tester.pumpWidget(wrap(page(
      readText: (path) => path.endsWith('index.html')
          ? asyncValue(
              '<html><head><link rel="stylesheet" href="a.css"></head></html>')
          : css.future,
    )));
    await tester.pump(); // loading frame
    await tester.pump(); // assembling frame (main read done, css pending)
    expect(find.textContaining('拼装资源中'), findsOneWidget);

    css.complete('body{}');
    await tester.pumpAndSettle();
    expect(find.textContaining('拼装资源中'), findsNothing);
    expect(find.textContaining('WEBVIEW:'), findsOneWidget);
  });

  testWidgets('main-file failure → error view, retry recovers',
      (tester) async {
    var fail = true;
    await tester.pumpWidget(wrap(page(
      readText: (path) => fail
          ? asyncValue(null)
          : asyncValue('<html><body>ok</body></html>'),
    )));
    await tester.pumpAndSettle();
    expect(find.text('预览加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // Main file unreadable → no source to fall back to.
    expect(find.text('改用源码视图'), findsNothing);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('WEBVIEW:'), findsOneWidget);
    expect(find.text('预览加载失败'), findsNothing);
  });

  testWidgets('source view shows the original text and back-switch works',
      (tester) async {
    const source = '<html>\n  <body>very long line '
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</body>\n'
        '</html>';
    await tester.pumpWidget(wrap(page(
      readText: (_) => asyncValue(source),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('源码'));
    await tester.pumpAndSettle();
    expect(find.textContaining('<body>'), findsOneWidget);
    expect(find.textContaining('WEBVIEW:'), findsNothing);

    await tester.tap(find.text('渲染'));
    await tester.pumpAndSettle();
    expect(find.textContaining('WEBVIEW:'), findsOneWidget);
  });

  testWidgets('error with readable source offers the switch-to-source escape',
      (tester) async {
    // Main file readable, then the assembler crashes on a resource read
    // (readText throwing) — the source is already memoized, so the error
    // view must offer the source escape.
    await tester.pumpWidget(wrap(page(
      readText: (path) {
        if (path.endsWith('index.html')) {
          return asyncValue(
              '<html><head><link rel="stylesheet" href="a.css"></head></html>');
        }
        throw StateError('boom');
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('预览加载失败'), findsOneWidget);
    expect(find.text('改用源码视图'), findsOneWidget);

    await tester.tap(find.text('改用源码视图'));
    await tester.pumpAndSettle();
    expect(find.textContaining('<html>'), findsOneWidget);
  });
}

/// Microtask-resolved future value (keeps the async state machine honest).
Future<String?> asyncValue(String? value) async => value;
