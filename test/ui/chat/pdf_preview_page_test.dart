import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/ui/chat/pdf_preview_page.dart';
import 'package:zgo/ui/theme.dart';

Widget wrap(Widget child) => MaterialApp(theme: buildDarkTheme(), home: child);

const _workerMarker = '/* WORKER_SRC_MARKER */';
const _libMarker = '/* LIB_SRC_MARKER */';

/// Captures what the page hands to the WebView surface seam: the assembled
/// document and the three handler callbacks (platform views cannot host in
/// widget tests; the real InAppWebView is device-acceptance territory).
class _Surface {
  String? html;
  Map<String, JavaScriptHandlerCallback>? handlers;
}

/// The page under test with stub reads / fake assets and a capturing
/// surface stub — the FilePreviewPage test convention.
({Widget widget, _Surface surface}) harness({
  String path = 'C:/w/doc.pdf',
  Future<FileStat> Function(String)? stat,
  Future<String?> Function(String)? readMediaDataUrl,
  Future<Uint8List> Function(String, int, int)? readRange,
  Future<Uint8List> Function(String)? loadAsset,
}) {
  final surface = _Surface();
  return (
    widget: PdfPreviewPage(
      path: path,
      stat: stat ?? (_) async => const FileStat(type: 'file', size: 1024),
      readMediaDataUrl: readMediaDataUrl ?? (_) async => null,
      readRange: readRange ?? (_, __, ___) async => Uint8List(0),
      loadAsset: loadAsset ??
          ((key) async => Uint8List.fromList(utf8.encode(
              key.endsWith('pdf.worker.min.mjs') ? _workerMarker : _libMarker))),
      webViewBuilder: (context, html, handlers) {
        surface.html = html;
        surface.handlers = handlers;
        return Text('WEBVIEW:$html');
      },
    ),
    surface: surface,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loading holds until the read mode is decided', (tester) async {
    final stat = Completer<FileStat>();
    final h = harness(stat: (_) => stat.future);
    await tester.pumpWidget(wrap(h.widget));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在加载…'), findsOneWidget);
    expect(find.textContaining('WEBVIEW:'), findsNothing);

    stat.complete(const FileStat(type: 'file', size: 1024));
    await tester.pumpAndSettle();
    expect(find.textContaining('WEBVIEW:'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('range mode (>2 MiB): the official transport shape',
      (tester) async {
    final mediaCalls = <String>[];
    final h = harness(
      stat: (_) async => const FileStat(type: 'file', size: 3 * 1024 * 1024),
      readMediaDataUrl: (p) async {
        mediaCalls.add(p);
        return 'data:application/pdf;base64,QUJD';
      },
    );
    await tester.pumpWidget(wrap(h.widget));
    await tester.pumpAndSettle();

    final html = h.surface.html!;
    expect(html, contains('window.__PDF_MODE = "range"'));
    expect(html, contains('window.__PDF_TOTAL = 3145728'));
    expect(html, contains('window.__PDF_PATH = "C:/w/doc.pdf"'));
    expect(html, contains('window.__PDF_DATA_URL = null'));
    // The official workspace-path transport (research §2.1): a
    // PDFDataRangeTransport subclass, length only, NO initialData.
    expect(html,
        contains('class RangeTransport extends pdfjs.PDFDataRangeTransport'));
    expect(html, contains('super(length, null)'));
    expect(html, contains('disableAutoFetch: true'));
    expect(html, contains('disableStream: true'));
    expect(html, contains('rangeChunkSize: 262144'));
    expect(mediaCalls, isEmpty,
        reason: 'a known size never falls back to the media read');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('full mode (<=2 MiB): the official eager 256 KiB loop',
      (tester) async {
    final rangeCalls = <Object?>[];
    final h = harness(
      stat: (_) async => const FileStat(type: 'file', size: 1024 * 1024),
      readRange: (p, o, l) async {
        rangeCalls.add((p, o, l));
        return Uint8List(0);
      },
    );
    await tester.pumpWidget(wrap(h.widget));
    await tester.pumpAndSettle();

    final html = h.surface.html!;
    expect(html, contains('window.__PDF_MODE = "full"'));
    expect(html, contains('window.__PDF_TOTAL = 1048576'));
    // The eager loop's step (the official 256 KiB) and its termination:
    // an empty payload ends the read — the wire's certified signal.
    expect(html, contains("callBridge('pdfRange', path, offset, 262144)"));
    expect(html, contains('if (chunk.length === 0) break;'));
    expect(rangeCalls, isEmpty,
        reason: 'the eager read runs inside the document (the loadData '
            'string must not grow by the file size), not at page build');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no size: the readMedia data URL feeds the document',
      (tester) async {
    final mediaCalls = <String>[];
    final h = harness(
      stat: (_) async => const FileStat(type: 'file'),
      readMediaDataUrl: (p) async {
        mediaCalls.add(p);
        return 'data:application/pdf;base64,QUJD';
      },
    );
    await tester.pumpWidget(wrap(h.widget));
    await tester.pumpAndSettle();

    final html = h.surface.html!;
    expect(html, contains('window.__PDF_MODE = "dataUrl"'));
    expect(html,
        contains('window.__PDF_DATA_URL = "data:application/pdf;base64,QUJD"'));
    expect(mediaCalls, ['C:/w/doc.pdf']);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a null readMedia fallback lands on the read failure',
      (tester) async {
    final h = harness(stat: (_) async => const FileStat(type: 'file'));
    await tester.pumpWidget(wrap(h.widget));
    await tester.pumpAndSettle();

    expect(find.text('读取失败'), findsOneWidget);
    expect(find.textContaining('WEBVIEW:'), findsNothing);
  });

  testWidgets('document: inlined sources + the S0-certified pdf.js forms',
      (tester) async {
    final h = harness(
      stat: (_) async => const FileStat(type: 'file', size: 3 * 1024 * 1024),
    );
    await tester.pumpWidget(wrap(h.widget));
    await tester.pumpAndSettle();

    final html = h.surface.html!;
    // Worker + library sources travel inside the document; both start from
    // same-document Blob URLs (the opaque-origin worker failure is pdf.js's
    // own fallback path — no branch in the document).
    expect(html, contains(_workerMarker));
    expect(html, contains(_libMarker));
    expect(html, contains('URL.createObjectURL'));
    expect(html, contains('new Blob'));
    // Document-side halves of the three bridge handlers.
    expect(html, contains("callBridge('pdfRange'"));
    expect(html, contains("callBridge('pdfReady'"));
    expect(html, contains("callBridge('pdfError'"));
    // Password rides the loading task, never the options (S0 device
    // certificate: an options password function breaks the fake-worker
    // structuredClone path).
    expect(html, contains('loadingTask.onPassword ='));
    expect(html, isNot(contains('password:')));
    // The viewer's official shape: single canvas + pager + 0.25 zoom steps
    // clamped to 0.25-4.0.
    expect(html, contains('Math.max(0.25, scale + delta)'));
    expect(html, contains('Math.min(4,'));
    // The status line carries the lexicon copy until the first page renders.
    expect(html, contains('正在加载…'));
    // App-bar title: the file's base name.
    expect(find.text('doc.pdf'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  group('bridge handlers (the second sandbox tier)', () {
    testWidgets('the surface receives exactly the three read-only handlers',
        (tester) async {
      final h = harness();
      await tester.pumpWidget(wrap(h.widget));
      await tester.pumpAndSettle();

      expect(h.surface.handlers!.keys.toSet(),
          {'pdfRange', 'pdfReady', 'pdfError'});

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pdfRange forwards (offset, length) and returns base64 bytes',
        (tester) async {
      final calls = <(String, int, int)>[];
      final bytes = Uint8List.fromList([0, 1, 2, 253, 254, 255]);
      final h = harness(readRange: (path, offset, length) async {
        calls.add((path, offset, length));
        return bytes;
      });
      await tester.pumpWidget(wrap(h.widget));
      await tester.pumpAndSettle();

      final Future<dynamic> pending = h.surface
          .handlers!['pdfRange']!(['C:/elsewhere.pdf', 262144, 262144])
          as Future<dynamic>;
      expect(await pending, base64Encode(bytes));
      // The step the document asked for is forwarded verbatim; the
      // JS-supplied path is ignored — the handler serves this page's one
      // path only (the read-only single-file channel, design §5.2).
      expect(calls, [('C:/w/doc.pdf', 262144, 262144)]);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pdfRange clamps junk arguments to zero', (tester) async {
      final calls = <(String, int, int)>[];
      final h = harness(readRange: (path, offset, length) async {
        calls.add((path, offset, length));
        return Uint8List(0);
      });
      await tester.pumpWidget(wrap(h.widget));
      await tester.pumpAndSettle();

      final handler = h.surface.handlers!['pdfRange']!;
      await (handler(['C:/w/doc.pdf', -5, -1]) as Future<dynamic>);
      await (handler(['C:/w/doc.pdf', 'junk', const <int>[]])
          as Future<dynamic>);
      expect(calls, [
        ('C:/w/doc.pdf', 0, 0),
        ('C:/w/doc.pdf', 0, 0),
      ]);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failing readRange rejects the bridge call', (tester) async {
      final h = harness(
        readRange: (_, __, ___) async =>
            throw Exception('ENOENT: no such file or directory'),
      );
      await tester.pumpWidget(wrap(h.widget));
      await tester.pumpAndSettle();

      final Future<dynamic> pending =
          h.surface.handlers!['pdfRange']!(['C:/w/doc.pdf', 0, 262144])
              as Future<dynamic>;
      // The rejection text reaches the document, which echoes it into
      // pdfError — the load fails instead of reading as end-of-file.
      await expectLater(
          pending, throwsA(predicate((Object? e) => '$e'.contains('ENOENT'))));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pdfError maps the codes onto their copies', (tester) async {
      final h = harness(
        stat: (_) async => const FileStat(type: 'file', size: 3 * 1024 * 1024),
      );
      await tester.pumpWidget(wrap(h.widget));
      await tester.pumpAndSettle();
      expect(find.textContaining('WEBVIEW:'), findsOneWidget);

      final handler = h.surface.handlers!['pdfError']!;
      handler(['password']);
      await tester.pump();
      expect(find.text('受密码保护的 PDF，暂不支持'), findsOneWidget);
      expect(find.text('password'), findsNothing,
          reason: 'the raw code is not user copy');
      expect(find.textContaining('WEBVIEW:'), findsNothing);

      handler(['range: ENOENT: no such file or directory, open \'C:/w/x.pdf\'']);
      await tester.pump();
      expect(find.text('文件不存在或已被移动'), findsOneWidget);

      handler(['load: Invalid PDF structure']);
      await tester.pump();
      expect(find.text('读取失败'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('post-ready errors do not tear down the view', (tester) async {
      final h = harness();
      await tester.pumpWidget(wrap(h.widget));
      await tester.pumpAndSettle();

      h.surface.handlers!['pdfReady']!([]);
      h.surface.handlers!['pdfError']!(['render: boom']);
      await tester.pump();

      expect(find.textContaining('WEBVIEW:'), findsOneWidget);
      expect(find.text('读取失败'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('lifecycle', () {
    testWidgets('stat failure: ENOENT lands on notFound, retry recovers',
        (tester) async {
      var fail = true;
      final h = harness(stat: (_) async {
        if (fail) {
          throw Exception(
              "ENOENT: no such file or directory, open 'C:/w/gone.pdf'");
        }
        return const FileStat(type: 'file', size: 1024);
      });
      await tester.pumpWidget(wrap(h.widget));
      await tester.pumpAndSettle();

      expect(find.text('文件不存在或已被移动'), findsOneWidget);
      expect(find.textContaining('ENOENT'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.textContaining('WEBVIEW:'), findsOneWidget);
      expect(find.text('文件不存在或已被移动'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('watchdog: no pdfReady inside 8 s flips to unsupported',
        (tester) async {
      final h = harness();
      await tester.pumpWidget(wrap(h.widget));
      await tester.pumpAndSettle();
      expect(find.textContaining('WEBVIEW:'), findsOneWidget);
      expect(find.text('此设备暂不支持 PDF 预览'), findsNothing);

      await tester.pump(const Duration(seconds: 9));
      expect(find.text('此设备暂不支持 PDF 预览'), findsOneWidget);
      expect(find.textContaining('WEBVIEW:'), findsNothing);
    });

    testWidgets('pdfReady stands the watchdog down', (tester) async {
      final h = harness();
      await tester.pumpWidget(wrap(h.widget));
      await tester.pumpAndSettle();

      h.surface.handlers!['pdfReady']!([]);
      await tester.pump(const Duration(seconds: 9));

      expect(find.textContaining('WEBVIEW:'), findsOneWidget);
      expect(find.text('此设备暂不支持 PDF 预览'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });

  test('the pdf WebView stays in the second-tier sandbox', () {
    // The InAppWebView factory asserts a registered platform implementation;
    // this fake satisfies that one call and nothing else is reached (the
    // widget is inspected, never built — platform views cannot host here).
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
    final surface = buildPdfWebView(
      html: '<p/>',
      handlers: {'pdfRange': (args) => null},
    ) as InAppWebView;
    final params = surface.platform.params;
    expect(params.onWebViewCreated, isNotNull,
        reason: 'the three read-only handlers are registered there — the '
            'deliberate second tier (the zero-bridge tier keeps it null)');
    expect(params.initialSettings?.allowFileAccess, isFalse);
    expect(params.initialSettings?.allowFileAccessFromFileURLs, isFalse);
    expect(params.initialSettings?.allowUniversalAccessFromFileURLs, isFalse);
    expect(params.initialData?.data, '<p/>');
    expect(params.initialData?.mimeType, 'text/html');
    expect(params.initialData?.baseUrl, isNull,
        reason: 'the document loads from memory, no origin games');
  });
}

/// Minimal platform registration so the production [InAppWebView] widget can
/// be constructed (not built) in this test file — same fake as
/// file_preview_page_test.dart.
class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
          PlatformInAppWebViewWidgetCreationParams params) =>
      _FakeInAppWebViewWidget(params);
}

class _FakeInAppWebViewWidget extends PlatformInAppWebViewWidget {
  _FakeInAppWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();

  @override
  void dispose() {}
}
