import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/ui/chat/file_preview_page.dart';
import 'package:zgo/ui/chat/file_read_result.dart';
import 'package:zgo/ui/chat/markdown_view.dart';
import 'package:zgo/ui/chat/source_highlight.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/theme.dart';

import '../../helpers/recording_chat_gateway.dart';

Widget wrap(Widget child) => MaterialApp(theme: buildDarkTheme(), home: child);

/// Every TextSpan in the tree, root first.
Iterable<TextSpan> highlightSpans(TextSpan root) sync* {
  yield root;
  for (final child in root.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) yield* highlightSpans(child);
  }
}

/// Microtask-resolved successful read (keeps the async state machine
/// honest).
Future<FileTextResult> asyncValue(
  String text, {
  int? totalBytes,
  bool truncated = false,
}) async =>
    FileTextResult(text: text, totalBytes: totalBytes, truncated: truncated);

/// Microtask-resolved classified read failure.
Future<FileTextResult> asyncFailure(FileReadFailure failure) async =>
    FileTextResult(failure: failure);

/// Line-aligned source fixture: [count] lines of [lineBytes] bytes each (the
/// trailing newline ends the line), so the text is exactly
/// `lineBytes * count` bytes and every 96 KiB window holds newline cuts.
String linesFixture(int lineBytes, int count) =>
    List.filled(count, '${'a' * (lineBytes - 1)}\n').join();

/// The page under test with a stub WebView surface (platform views are not
/// hostable in widget tests — the real InAppWebView is device-acceptance
/// territory; the seam exists for exactly this).
FilePreviewPage page({
  Key? key,
  String path = 'C:/w/index.html',
  FilePreviewRender render = FilePreviewRender.html,
  required Future<FileTextResult> Function(String path) readText,
  Future<String?> Function(String path)? readMediaDataUrl,
  Future<Uint8List?> Function(String path)? resolveImage,
  void Function(String href)? openLink,
  Widget Function(BuildContext, String html)? webViewBuilder,
}) {
  return FilePreviewPage(
    key: key,
    path: path,
    render: render,
    readText: readText,
    readMediaDataUrl: readMediaDataUrl ?? (_) async => null,
    resolveImage: resolveImage,
    openLink: openLink,
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
    final css = Completer<FileTextResult>();
    await tester.pumpWidget(wrap(page(
      readText: (path) => path.endsWith('index.html')
          ? asyncValue(
              '<html><head><link rel="stylesheet" href="a.css"></head></html>')
          : css.future,
    )));
    await tester.pump(); // loading frame
    await tester.pump(); // assembling frame (main read done, css pending)
    expect(find.textContaining('拼装资源中'), findsOneWidget);

    css.complete(FileTextResult(text: 'body{}'));
    await tester.pumpAndSettle();
    expect(find.textContaining('拼装资源中'), findsNothing);
    expect(find.textContaining('WEBVIEW:'), findsOneWidget);
  });

  testWidgets('main-file failure → classified error view, retry recovers',
      (tester) async {
    var fail = true;
    await tester.pumpWidget(wrap(page(
      readText: (path) => fail
          ? asyncFailure(FileReadFailure.readFailed)
          : asyncValue('<html><body>ok</body></html>'),
    )));
    await tester.pumpAndSettle();
    expect(find.text('读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // Main file unreadable → no source to fall back to.
    expect(find.text('改用源码视图'), findsNothing);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('WEBVIEW:'), findsOneWidget);
    expect(find.text('读取失败'), findsNothing);
  });

  testWidgets('classified read failures render their own copy',
      (tester) async {
    const cases = {
      FileReadFailure.notFound: '文件不存在或已被移动',
      FileReadFailure.binary: '二进制文件，无文本预览',
      FileReadFailure.empty: '空文件',
      FileReadFailure.tooLarge: '文件超过预览大小上限',
      FileReadFailure.readFailed: '读取失败',
    };
    for (final entry in cases.entries) {
      // A fresh key per case: the same widget type in the same slot would
      // keep the previous State (and its result) alive.
      await tester.pumpWidget(wrap(page(
        key: ValueKey(entry.key),
        readText: (_) => asyncFailure(entry.key),
      )));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget, reason: '${entry.key}');
      expect(find.text('预览加载失败'), findsNothing, reason: '${entry.key}');
      expect(find.text('重试'), findsOneWidget, reason: '${entry.key}');
      expect(find.text('改用源码视图'), findsNothing, reason: '${entry.key}');
    }
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

  testWidgets('plainText kind: no toggle, no assembly, source renders',
      (tester) async {
    final reads = <String>[];
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/notes.md',
      render: FilePreviewRender.plainText,
      readText: (path) {
        reads.add(path);
        return asyncValue('# notes\n<link rel="stylesheet" href="a.css">');
      },
    )));
    await tester.pumpAndSettle();

    expect(reads, ['C:/w/notes.md'],
        reason: 'plainText mode never runs the assembler');
    expect(find.text('渲染'), findsNothing);
    expect(find.text('源码'), findsNothing);
    expect(find.textContaining('# notes'), findsOneWidget);
  });

  testWidgets('truncation metadata lands in the page state for S3',
      (tester) async {
    await tester.pumpWidget(wrap(page(
      readText: (_) => asyncValue('x',
          totalBytes: 3 * 1024 * 1024, truncated: true),
    )));
    await tester.pumpAndSettle();

    final state = tester.state<State>(find.byType(FilePreviewPage));
    expect((state as dynamic).textResult?.truncated, isTrue);
    expect((state as dynamic).textResult?.totalBytes, 3 * 1024 * 1024);
  });

  testWidgets('a failed resource read degrades to the placeholder comment',
      (tester) async {
    await tester.pumpWidget(wrap(page(
      readText: (path) => path.endsWith('index.html')
          ? asyncValue(
              '<html><head><link rel="stylesheet" href="a.css"></head></html>')
          : asyncFailure(FileReadFailure.notFound),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('WEBVIEW:'), findsOneWidget);
    expect(find.textContaining('preview: skipped'), findsOneWidget);
    expect(find.text('预览加载失败'), findsNothing);
    expect(find.text('文件不存在或已被移动'), findsNothing);
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

  // ---------------------------------------------------------------------
  // Source-view grading + truncation banner (S3, design §4.2).
  // ---------------------------------------------------------------------

  testWidgets('source at or below 200 KiB stays one selectable monolith',
      (tester) async {
    final text = linesFixture(64, 199 * 1024 ~/ 64); // 199 KiB
    await tester.pumpWidget(wrap(page(
      render: FilePreviewRender.plainText,
      readText: (_) => asyncValue(text),
    )));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    expect(find.byType(SelectionArea), findsNothing);
    final state = tester.state<State>(find.byType(FilePreviewPage)) as dynamic;
    expect(state.sourceChunks, isNull);
  });

  testWidgets('over 200 KiB grades into line-aligned lazy chunks',
      (tester) async {
    // 201 KiB in 64-byte lines: three 96 KiB windows.
    final text = linesFixture(64, 201 * 1024 ~/ 64);
    await tester.pumpWidget(wrap(page(
      render: FilePreviewRender.plainText,
      readText: (_) => asyncValue(text),
    )));
    await tester.pumpAndSettle();

    final state = tester.state<State>(find.byType(FilePreviewPage)) as dynamic;
    final chunks = state.sourceChunks as List<String>;
    expect(chunks.length, 3, reason: '201 KiB over 96 KiB windows');
    for (var i = 0; i < chunks.length - 1; i++) {
      expect(chunks[i].endsWith('\n'), isTrue,
          reason: 'chunk $i must end on a line boundary');
    }
    expect(chunks.join(), text);

    // The list is the grade's shape; the area wraps it for selection.
    expect(find.byType(ListView), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(ListView),
        matching: find.byType(SelectionArea),
      ),
      findsOneWidget,
    );
    // Chunks are plain registered text inside the area, never the island
    // selection of SelectableText.
    expect(find.byType(SelectableText), findsNothing);
    // Lazy: the first chunk is built, the last (a screenfuls-tall chunk
    // away) is not.
    expect(find.text(chunks.first), findsOneWidget);
    expect(find.text(chunks.last), findsNothing);
    expect(find.textContaining('已截断'), findsNothing);
  });

  testWidgets('a capped read renders the truncation banner above the source',
      (tester) async {
    await tester.pumpWidget(wrap(page(
      render: FilePreviewRender.plainText,
      readText: (_) => asyncValue('hello\n',
          totalBytes: 3 * 1024 * 1024, truncated: true),
    )));
    await tester.pumpAndSettle();

    expect(find.text('已截断，共 3.0 MiB，显示前 2.0 MiB'), findsOneWidget);
    // The banner must not steal the source's selectability.
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('no banner unless the read is truncated with a known size',
      (tester) async {
    Future<void> pumpCase(int? totalBytes, bool truncated, Key key) async {
      // A fresh key per case: the same key would keep the previous State
      // (and its read) alive.
      await tester.pumpWidget(wrap(page(
        key: key,
        render: FilePreviewRender.plainText,
        readText: (_) => asyncValue('hello\n',
            totalBytes: totalBytes, truncated: truncated),
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('已截断'), findsNothing, reason: '$key');
    }

    await pumpCase(3 * 1024 * 1024, false, const ValueKey('not-truncated'));
    await pumpCase(null, true, const ValueKey('no-total'));
  });

  testWidgets(
      'a 1.9 MiB source builds its first graded frame within the sentinel',
      (tester) async {
    final text = linesFixture(1024, 1900); // ≈1.9 MiB
    final watch = Stopwatch()..start();
    await tester.pumpWidget(wrap(page(
      render: FilePreviewRender.plainText,
      readText: (_) => asyncValue(text),
    )));
    await tester.pump(); // read resolves in a microtask → graded frame
    await tester.pump();
    watch.stop();

    // Slow-CI-tolerant regression sentinel only (design §4.2): the graded
    // path opens interactively; a regression to whole-text layout stalls
    // for seconds and trips this.
    expect(watch.elapsedMilliseconds, lessThan(3000),
        reason: 'first graded frame took ${watch.elapsedMilliseconds} ms');
    expect(find.byType(ListView), findsOneWidget);
    final state = tester.state<State>(find.byType(FilePreviewPage)) as dynamic;
    expect(state.sourceChunks, isNotNull);
  });

  // ---------------------------------------------------------------------
  // Monolith syntax highlighting (S4, design §4.3 / source_highlight.dart).
  // ---------------------------------------------------------------------

  testWidgets('a mapped extension highlights the monolith source, keeping '
      'selection', (tester) async {
    const source = 'void main() {\n  final x = 1; // note\n}\n';
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/main.dart',
      render: FilePreviewRender.plainText,
      readText: (_) => asyncValue(source),
    )));
    await tester.pumpAndSettle();

    // Still one SelectableText — the rich constructor, same selection
    // machinery as before.
    final body = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(body.data, isNull);
    final span = body.textSpan;
    expect(span, isNotNull);
    expect(span!.toPlainText(), source);
    final colors = highlightSpans(span)
        .map((s) => s.style?.color)
        .whereType<Color>()
        .toSet();
    expect(colors.length, greaterThan(1),
        reason: 'token colors must sit on top of the base ink');
  });

  testWidgets('an unmapped extension keeps the plain monolith',
      (tester) async {
    const source = 'payload: {casual: text}\n';
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/data.unknownext',
      render: FilePreviewRender.plainText,
      readText: (_) => asyncValue(source),
    )));
    await tester.pumpAndSettle();

    final body = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(body.data, source);
    expect(body.textSpan, isNull);
  });

  testWidgets('a mapped-but-unregistered extension (.txt → log) stays plain',
      (tester) async {
    const source = 'just log lines\n';
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/notes.txt',
      render: FilePreviewRender.plainText,
      readText: (_) => asyncValue(source),
    )));
    await tester.pumpAndSettle();

    final body = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(body.data, source);
    expect(body.textSpan, isNull);
  });

  testWidgets('the chunked grade above the cap never highlights',
      (tester) async {
    final text = linesFixture(64, 201 * 1024 ~/ 64); // 201 KiB, json path
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/data.json',
      render: FilePreviewRender.plainText,
      readText: (_) => asyncValue(text),
    )));
    await tester.pumpAndSettle();

    // Chunks are plain Text inside the SelectionArea — no rich span at all
    // (the whole-document hljs scan is capped to the monolith).
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('over the highlight cap the monolith stays plain and '
      'selectable', (tester) async {
    // 33 KiB > highlightMaxBytes (32 KiB) but still the ≤200 KiB monolith
    // grade: plain SelectableText, no ListView, no rich span.
    final text = linesFixture(64, 33 * 1024 ~/ 64);
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/data.json',
      render: FilePreviewRender.plainText,
      readText: (_) => asyncValue(text),
    )));
    await tester.pumpAndSettle();

    final body = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(body.data, text);
    expect(body.textSpan, isNull);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('a 190 KiB json monolith opens within the sentinel',
      (tester) async {
    // Above the highlight cap, so the graded frame is the S3 monolith form —
    // still timed because the frame now takes the highlight guard path.
    const line = '{"key": "value", "n": 1234567890, "ok": true},\n';
    final buffer = StringBuffer();
    while (buffer.length < 190 * 1024) {
      buffer.write(line);
    }
    final text = buffer.toString();
    final watch = Stopwatch()..start();
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/data.json',
      render: FilePreviewRender.plainText,
      readText: (_) => asyncValue(text),
    )));
    await tester.pump(); // read resolves in a microtask → graded frame
    await tester.pump();
    watch.stop();

    expect(watch.elapsedMilliseconds, lessThan(3000),
        reason: 'first graded frame took ${watch.elapsedMilliseconds} ms');
    final body = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(body.textSpan, isNull);
  });

  // ---------------------------------------------------------------------
  // Render kinds md / svg (S5, design §4.1).
  // ---------------------------------------------------------------------

  testWidgets('the markdown kind lands on the render view, wired to the '
      'chat pipeline and S4 highlighting', (tester) async {
    Future<Uint8List?> resolver(String path) async => null;
    final links = <String>[];
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/notes.md',
      render: FilePreviewRender.markdown,
      readText: (_) => asyncValue('# title\n\n[doc](other.md)\n'),
      resolveImage: resolver,
      openLink: links.add,
    )));
    await tester.pumpAndSettle();

    final md = tester.widget<AppMarkdown>(find.byType(AppMarkdown));
    expect(md.data, '# title\n\n[doc](other.md)\n');
    expect(md.selectable, isTrue);
    expect(md.highlight, isTrue,
        reason: 'the S4 fence highlighting rides the render view');
    expect(md.imageResolver, same(resolver),
        reason: 'the chat image pipeline is reused, not re-implemented');
    expect(md.onLinkTap, isNotNull);
    // Render-first landing with the dual-view toggle (plainText's opposite).
    expect(find.text('渲染'), findsOneWidget);
    expect(find.text('源码'), findsOneWidget);

    // A link tap forwards the raw href — navigation stays with the
    // injected openLink (the chat's split), never with this page.
    await tester.tap(find.text('doc'));
    await tester.pumpAndSettle();
    expect(links, ['other.md']);
  });

  testWidgets('md image references resolve through the injected workspace '
      'resolver', (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/notes.md',
      render: FilePreviewRender.markdown,
      readText: (_) => asyncValue('![shot](shots/a.png)\n'),
      resolveImage: (path) async {
        asked.add(path);
        return null;
      },
    )));
    await tester.pumpAndSettle();

    expect(asked, ['shots/a.png']);
    // Null resolution renders the placeholder row, not a page error.
    expect(find.textContaining('图片加载失败'), findsOneWidget);
  });

  testWidgets('the md source view highlights through the markdown grammar '
      '(S4 table)', (tester) async {
    const source = '# heading\n\nsome **bold** text\n';
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/notes.md',
      render: FilePreviewRender.markdown,
      readText: (_) => asyncValue(source),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('源码'));
    await tester.pumpAndSettle();

    final body = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(body.data, isNull);
    expect(body.textSpan, isNotNull,
        reason: 'md maps to the registered markdown grammar (S4)');
    expect(body.textSpan!.toPlainText(), source);
  });

  testWidgets('md over 256 KiB falls back to the source view: render '
      'disabled, notice shown, render segment off', (tester) async {
    final text = 'a' * (markdownRenderMaxBytes + 1);
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/big.md',
      render: FilePreviewRender.markdown,
      readText: (_) => asyncValue(text),
    )));
    await tester.pumpAndSettle();

    expect(find.byType(AppMarkdown), findsNothing);
    expect(find.text('文件过大，渲染视图已禁用（源码视图可用）'), findsOneWidget);
    final state = tester.state<State>(find.byType(FilePreviewPage)) as dynamic;
    expect(state.renderDisabled, isTrue);
    // 256 KiB is also over the source monolith cap (200 KiB) → chunks.
    expect(state.sourceChunks, isNotNull);
    expect(find.byType(ListView), findsOneWidget);

    // The render segment is disabled: tapping it cannot surface the render
    // view.
    await tester.tap(find.text('渲染'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(AppMarkdown), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('md exactly at the 256 KiB cap still opens the render view '
      '(the guard is >)', (tester) async {
    // Line-shaped prose (a real markdown document's shape): flutter_markdown
    // lays it out in well under a second. NOT a single unbroken token — a
    // 32 KiB+ word is the pathological paragraph-layout case (measured at
    // the S5 implementation: 26 s at 32 KiB in the flutter-test JIT), which
    // no widget test should ever try to render.
    final buffer = StringBuffer();
    const line = 'The quick brown fox jumps over the lazy dog 0123456789.\n';
    while (buffer.length < markdownRenderMaxBytes) {
      buffer.write(line);
    }
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/big.md',
      render: FilePreviewRender.markdown,
      readText: (_) =>
          asyncValue(buffer.toString().substring(0, markdownRenderMaxBytes)),
    )));
    await tester.pumpAndSettle();

    expect(find.byType(AppMarkdown), findsOneWidget);
    final state = tester.state<State>(find.byType(FilePreviewPage)) as dynamic;
    expect(state.renderDisabled, isFalse);
    expect(find.textContaining('渲染视图已禁用'), findsNothing);
  });

  testWidgets('the svg kind renders through the sandboxed WebView from the '
      'shell document', (tester) async {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
        '<rect width="10" height="10"/></svg>';
    await tester.pumpWidget(wrap(page(
      path: 'C:/w/logo.svg',
      render: FilePreviewRender.svg,
      readText: (_) => asyncValue(svg),
    )));
    await tester.pumpAndSettle();

    final doc = tester.widget<Text>(find.textContaining('WEBVIEW:')).data!;
    expect(doc, contains('<!doctype html>'));
    expect(doc, contains('place-items:center'));
    expect(doc, contains(svg), reason: 'the original svg text inlines verbatim');
    expect(doc, endsWith('</body></html>'));
    expect(find.text('渲染'), findsOneWidget);

    // The svg source view highlights through the xml grammar (S4: svg→xml).
    await tester.tap(find.text('源码'));
    await tester.pumpAndSettle();
    final body = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(body.textSpan, isNotNull);
    expect(body.textSpan!.toPlainText(), svg);
  });

  testWidgets('a local link in the md render view pushes the next preview; '
      'the back stack unwinds the chain', (tester) async {
    // Full production chain: ChatPreview.open → render kind → AppMarkdown
    // link → ChatPreview.openLink → the next preview over this one.
    final gateway = RecordingChatGateway();
    const md = '# notes\n\n[next](other.md)\n';
    gateway.fileReadTextResult = TextChunk(
      text: md,
      bytesRead: md.length,
      totalBytes: md.length,
      hasMore: false,
    );
    final preview = ChatPreview(gateway);
    await tester.pumpWidget(wrap(Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => preview.open(context, 'notes.md'),
            child: const Text('open preview'),
          ),
        ),
      ),
    )));

    await tester.tap(find.text('open preview'));
    await tester.pumpAndSettle();
    expect(find.text('notes.md'), findsOneWidget); // page A app-bar title
    expect(find.byType(AppMarkdown), findsOneWidget);

    await tester.tap(find.text('next'));
    await tester.pumpAndSettle();

    // Page B (the linked md) sits on top of page A.
    expect(find.text('other.md'), findsOneWidget);
    expect(find.text('notes.md'), findsNothing);
    final pageB = tester.widget<FilePreviewPage>(find.byType(FilePreviewPage));
    expect(pageB.render, FilePreviewRender.markdown);
    expect(pageB.path, '/repo/app/other.md',
        reason: 'the link path joins the workspace (desktop CWD semantics)');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('notes.md'), findsOneWidget);
    expect(find.text('other.md'), findsNothing);
    expect(find.byType(AppMarkdown), findsOneWidget);
  });

  test('buildSvgPreviewDocument wraps the file text in the minimal shell', () {
    final doc = buildSvgPreviewDocument('<svg/>');
    expect(doc, startsWith('<!doctype html>'));
    expect(doc, contains('<meta charset="utf-8">'));
    expect(doc, contains('content="width=device-width, initial-scale=1"'));
    expect(doc, contains('svg{max-width:100%;height:auto}'));
    expect(doc, endsWith('<svg/></body></html>'));
    // A pure string shell: no scripts, no bridge hooks (zero-bridge tier).
    expect(doc, isNot(contains('<script')));
    expect(doc, isNot(contains('flutter_inappwebview')));
  });

  test('the sandboxed WebView carries no JS bridge and keeps file access '
      'off (zero-bridge tier, design §5.2)', () {
    // The InAppWebView factory asserts a registered platform implementation;
    // this fake satisfies that one call and nothing else is reached (the
    // widget is inspected, never built — platform views cannot host here).
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
    final surface = buildSandboxedWebView('<svg/>') as InAppWebView;
    final params = surface.platform.params;
    expect(params.onWebViewCreated, isNull,
        reason: 'handlers can only be registered in onWebViewCreated — the '
            'zero-bridge posture is structural');
    expect(params.initialSettings?.allowFileAccess, isFalse);
    expect(params.initialSettings?.allowFileAccessFromFileURLs, isFalse);
    expect(params.initialSettings?.allowUniversalAccessFromFileURLs, isFalse);
    expect(params.initialData?.data, '<svg/>');
    expect(params.initialData?.mimeType, 'text/html');
  });

  group('chunkSourceByLines', () {
    test('cuts only after newlines even with long lines', () {
      // 8 KiB lines: every 96 KiB window holds ~11 of them, so every cut has
      // a newline to land on.
      final text = linesFixture(8 * 1024, 130); // ~1.02 MiB
      final chunks = chunkSourceByLines(text);
      expect(chunks.length, greaterThan(10));
      expect(chunks.join(), text);
      for (var i = 0; i < chunks.length - 1; i++) {
        expect(chunks[i].endsWith('\n'), isTrue,
            reason: 'chunk $i must end on a line boundary');
        expect(chunks[i].length, lessThanOrEqualTo(96 * 1024));
      }
    });

    test('an over-wide single line splits at the window, never inside a '
        'surrogate pair', () {
      // No newline anywhere → the fallback cut applies; the leading ASCII
      // unit shifts the window edge onto an emoji's high surrogate, where a
      // naive cut would halve a pair.
      final text = 'x${'😀' * 60000}';
      final chunks = chunkSourceByLines(text);
      expect(chunks.length, 2);
      expect(chunks[0].length, 96 * 1024 - 1);
      expect(chunks[0].endsWith('😀'), isTrue);
      expect(chunks.join(), text);
    });

    test('chunking 2 MiB stays far below the interactive budget', () {
      final text = linesFixture(1024, 2048); // 2 MiB
      final watch = Stopwatch()..start();
      final chunks = chunkSourceByLines(text);
      watch.stop();

      expect(chunks.join(), text);
      // Regression sentinel: the native backward scan lands in the low
      // milliseconds; near a second means a per-character walk crept in.
      expect(watch.elapsedMilliseconds, lessThan(1000),
          reason: 'chunking 2 MiB took ${watch.elapsedMilliseconds} ms');
    });
  });
}

/// Minimal platform registration so the production [InAppWebView] widget can
/// be constructed (not built) in this test file. The real platform view
/// cannot host in widget tests; the fake only satisfies the factory's
/// platform assert and the [PlatformInAppWebViewWidget] contract, so the
/// widget-level assertions in the zero-bridge test can read the creation
/// params.
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
