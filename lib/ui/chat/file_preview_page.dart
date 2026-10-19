import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../theme.dart';
import '../ui_settings.dart';
import 'file_read_result.dart';
import 'html_assembly.dart';
import 'markdown_view.dart';
import 'source_highlight.dart';

/// Source-view grading thresholds, grouped the way the read side groups its
/// step constants (timeline.dart `_readStepBytes`). At or below
/// [monolithMaxBytes] (the cap shared with syntax highlighting,
/// source_highlight.dart) the source renders as one selectable text; above it
/// the view cuts line-aligned ~[_chunkBytes] blocks and renders them lazily (a
/// whole 2 MiB `SelectableText` layout is the stall the grade exists to
/// avoid). Lengths count UTF-16 code units — the metric text layout pays for
/// (for ASCII logs/json code units == bytes).
const int _chunkBytes = 96 * 1024;

/// The read cap the truncation banner's "first N" names. The cap itself is
/// timeline.dart's `_maxTextBytes` (2 MiB), private to that library — this
/// page only knows the number it must print.
const String _readCapLabel = '2.0 MiB';

/// Splits [text] into render chunks of about [chunkBytes], cutting on line
/// boundaries: each chunk ends right after the window's last `'\n'`, so no
/// line spans two chunks and every chunk but the last ends with a newline.
///
/// A single line wider than the window (minified js/json) has no interior
/// newline to cut on and is split at the window edge instead; if that edge
/// falls between the halves of a UTF-16 surrogate pair the cut backs off
/// one code unit so both chunks stay well-formed.
///
/// `lastIndexOf` scans natively — no per-character Dart loop — and stops at
/// the window's first newline from the right, so lined text (json/log) cuts
/// in a few milliseconds per 2 MiB; only a text with no newline at all pays
/// the full backward scan of every window (tens of milliseconds, still an
/// order below the read that produced the text). The timing sentinel in
/// file_preview_page_test.dart guards that: chunking 2 MiB must stay under
/// a second.
@visibleForTesting
List<String> chunkSourceByLines(String text, {int chunkBytes = _chunkBytes}) {
  if (text.isEmpty) return const [];
  final chunks = <String>[];
  var start = 0;
  while (start < text.length) {
    var end = start + chunkBytes;
    if (end >= text.length) {
      end = text.length;
    } else {
      final newline = text.lastIndexOf('\n', end - 1);
      if (newline >= start) {
        end = newline + 1;
      } else if (end - start > 1 && _isHighSurrogate(text.codeUnitAt(end - 1))) {
        // Back at most to `start + 1`: a window never backs off to zero
        // progress (chunkBytes <= 1).
        end -= 1;
      }
    }
    chunks.add(text.substring(start, end));
    start = end;
  }
  return chunks;
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

/// Human size for the truncation banner, one decimal at each unit (the
/// design's 「共 3.0 MiB」 form). MiB is the banner's own scale — the cap
/// makes anything smaller unreachable — but the KiB branch keeps the text
/// honest if a caller ever reports a small `totalBytes`.
String _formatBytes(int bytes) {
  const mib = 1024 * 1024;
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MiB';
  return '${(bytes / 1024).toStringAsFixed(1)} KiB';
}

/// File preview page with graded render kinds (task 09-29-file-preview
/// design §4.2 dual views, generalized in task 10-18-file-preview-formats
/// design §4.1): [FilePreviewRender] picks the render surface; the source
/// view is shared by every kind (monospace, horizontal scroll, selectable,
/// syntax-highlighted when a grammar matches, size-graded — see
/// [_FilePreviewPageState._sourceView]).
///
/// * `html`: the render view assembles the file's relative css/js/img/font
///   references into one self-contained document ([HtmlAssembler]) and
///   renders it in the sandboxed WebView via `loadData` — no baseUrl, no
///   file access, no JS bridge (zero-bridge tier, [buildSandboxedWebView]).
/// * `markdown`: the render view is the chat's own [AppMarkdown] — workspace
///   image resolver, link split and fenced-code highlighting all ride in
///   (design §4.1). Over [markdownRenderMaxBytes] it is disabled and the
///   page lands on the source view with a notice: markdown cannot render
///   partially, so the cap is a hard fallback.
/// * `svg`: the render view inlines the file into a minimal centered shell
///   ([buildSvgPreviewDocument]) and surfaces it through the same
///   zero-bridge WebView — the same trust level as `html` (design §4.1).
/// * `plainText`: source view only — no render/source toggle.
///
/// Trust model (design §5.2, both tiers in one place): the html/svg render
/// views are the **zero-bridge tier** — `loadData`, no baseUrl, no file
/// access, no JS handlers ([buildSandboxedWebView]); the pdf page (S6) is
/// the deliberate **second tier** — the same posture plus exactly three
/// read-only handlers (`pdfRange`/`pdfReady`/`pdfError`). Nothing else is
/// exposed anywhere.
///
/// Reads are callback-injected so widget tests fake them; the WebView
/// surface is injectable for the same reason (widget tests cannot host
/// platform views — real rendering is device-acceptance territory).
class FilePreviewPage extends StatefulWidget {
  final String path;

  /// Which surface renders the file (design §4.1). The routing table that
  /// picks it per extension is `ChatPreview.open` (timeline.dart).
  final FilePreviewRender render;

  /// Text reads (the main file + css/js resources). The main-file result
  /// carries the failure classification the error view renders (design
  /// §2); the assembler still consumes plain text — a resource read
  /// without text degrades to a placeholder comment, never a page error.
  final Future<FileTextResult> Function(String path) readText;

  /// Binary reads as data URLs (images/fonts) — null on failure.
  final Future<String?> Function(String path) readMediaDataUrl;

  /// Workspace image resolver for the markdown render view (design §4.1):
  /// the chat's own pipeline (`ChatPreview.resolveImage`). Null leaves
  /// markdown image references on their placeholder rows.
  final Future<Uint8List?> Function(String path)? resolveImage;

  /// Link taps in the markdown render view (design §4.1): the chat's own
  /// split (`ChatPreview.openLink`). Scheme-less local paths push the next
  /// preview over this one, so a chain of previews pops back naturally on
  /// the zRoute stack — this page never navigates itself.
  final void Function(String href)? openLink;

  /// WebView surface seam: production builds the real InAppWebView;
  /// widget tests inject a placeholder (platform views unavailable there).
  /// Both document render kinds (html/svg) surface through it.
  final Widget Function(BuildContext context, String html)? webViewBuilder;

  const FilePreviewPage({
    super.key,
    required this.path,
    required this.render,
    required this.readText,
    required this.readMediaDataUrl,
    this.resolveImage,
    this.openLink,
    this.webViewBuilder,
  });

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

/// The render surfaces [FilePreviewPage] hosts (design §4.1). `plainText`
/// hides the render/source toggle (source only); the other three open on
/// their render view.
enum FilePreviewRender { html, markdown, svg, plainText }

enum _Phase { loading, assembling, done, error }

enum _View { render, source }

class _FilePreviewPageState extends State<FilePreviewPage> {
  _Phase _phase = _Phase.loading;
  _View _view = _View.render;

  /// The successful main-file read: the source view renders its `text`,
  /// and its `totalBytes`/`truncated` feed the truncation banner.
  /// Kept across a later assembler failure so the source escape still works.
  FileTextResult? _textResult;

  /// Line-aligned chunks of the main text when it exceeds
  /// [monolithMaxBytes]; null means the monolith grade (also the case
  /// before any successful read). Derived from [_textResult] and assigned
  /// together with it — one sync pass at read time (a few milliseconds per
  /// 2 MiB, see [chunkSourceByLines]) buys a rebuild-free source view.
  List<String>? _sourceChunks;

  /// Memo of the monolith's highlighted span, keyed by the text it was built
  /// from plus the brightness it was built for (the palette branches on
  /// theme). The scan and its paragraph layout are the expensive part of the
  /// monolith, and `SelectableText.rich` compares spans by identity — a fresh
  /// span per build would re-run both on every rebuild (view toggle, media
  /// query change). [highlightSpan]'s own size cap bounds this grade; a null
  /// here is a legitimate "render plain" result, not a cache miss.
  String? _spanMemoText;
  bool? _spanMemoDark;
  TextSpan? _spanMemoSpan;

  /// Classified main-read failure (design §2) — the error view's reason.
  FileReadFailure? _failure;

  /// Assembler-side error (a resource read throwing) — generic failure
  /// copy with the exception detail.
  Object? _error;

  /// The assembled self-contained document (render view).
  String? _html;
  (int, int)? _progress;

  /// Test seam: the successful main read (see [_textResult]).
  @visibleForTesting
  FileTextResult? get textResult => _textResult;

  /// Test seam: the chunked grade's line-aligned blocks (null = monolith),
  /// see [_sourceChunks].
  @visibleForTesting
  List<String>? get sourceChunks => _sourceChunks;

  /// The markdown render view's over-cap fallback (design §4.1): over
  /// [markdownRenderMaxBytes] the render segment is disabled and the page
  /// lands on the source view — markdown cannot render partially, so there
  /// is no honest partial form to show instead of the whole document.
  bool get _renderDisabled =>
      widget.render == FilePreviewRender.markdown &&
      (_textResult?.text?.length ?? 0) > markdownRenderMaxBytes;

  /// Test seam: the render-disabled fallback (see [_renderDisabled]).
  @visibleForTesting
  bool get renderDisabled => _renderDisabled;

  /// Page-lifetime memo over [widget.readText]: the assembler and the
  /// source view share one fetch of the main file and of css resources.
  /// Failures stay uncached: retry must re-fetch.
  final Map<String, FileTextResult> _textMemo = {};

  Future<FileTextResult> _readTextMemo(String path) async {
    final cached = _textMemo[path];
    if (cached != null) return cached;
    final result = await widget.readText(path);
    if (result.text != null) _textMemo[path] = result;
    return result;
  }

  /// [HtmlAssembler] keeps its `String?` resource contract: a read without
  /// text degrades to the skipped-placeholder comment.
  Future<String?> _readTextForAssembly(String path) async =>
      (await _readTextMemo(path)).text;

  Future<void> _load() async {
    setState(() {
      _phase = _Phase.loading;
      _failure = null;
      _error = null;
      _progress = null;
    });
    // Main file first: it doubles as the source view's text, and its
    // failure is the page-level error (resource failures degrade to
    // placeholder comments inside the assembly instead).
    final result = await _readTextMemo(widget.path);
    if (!mounted) return;
    if (result.text == null) {
      setState(() {
        _failure = result.failure ?? FileReadFailure.readFailed;
        _phase = _Phase.error;
      });
      return;
    }
    final text = result.text!;
    final chunks =
        text.length > monolithMaxBytes ? chunkSourceByLines(text) : null;
    setState(() {
      _textResult = result;
      _sourceChunks = chunks;
      if (widget.render == FilePreviewRender.svg) {
        // The svg document is a pure function of the file's text — built
        // once here, same pass as the source grading.
        _html = buildSvgPreviewDocument(text);
      }
      if (_renderDisabled) _view = _View.source;
      _phase = widget.render == FilePreviewRender.html
          ? _Phase.assembling
          : _Phase.done;
    });
    if (widget.render != FilePreviewRender.html) return;
    try {
      final assembler = HtmlAssembler(
        readText: _readTextForAssembly,
        readMediaDataUrl: widget.readMediaDataUrl,
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = (done, total));
        },
      );
      final assembled = await assembler.assemble(widget.path);
      if (!mounted) return;
      setState(() {
        _html = assembled.html;
        _phase = _Phase.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _phase = _Phase.error;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.render == FilePreviewRender.plainText) _view = _View.source;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.path.split(RegExp(r'[\\/]')).last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // The source-only kind has nothing to switch to; the markdown
          // kind's render segment turns off over [markdownRenderMaxBytes]
          // (design §4.1).
          if (widget.render != FilePreviewRender.plainText)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: SegmentedButton<_View>(
                segments: [
                  ButtonSegment(
                    value: _View.render,
                    label: Text(tr(context, 'chat.preview.render')),
                    enabled: !_renderDisabled,
                  ),
                  ButtonSegment(
                    value: _View.source,
                    label: Text(tr(context, 'chat.preview.source')),
                  ),
                ],
                selected: {_view},
                onSelectionChanged: (selection) {
                  HapticFeedback.selectionClick();
                  setState(() => _view = selection.first);
                },
              ),
            ),
        ],
      ),
      body: switch (_phase) {
        _Phase.loading => _center(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(height: 12),
                Text(
                  tr(context, 'chat.preview.loading'),
                  style: ZType.sub.copyWith(color: ZInk.soft(context)),
                ),
              ],
            ),
          ),
        _Phase.assembling => _center(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(height: 12),
                if (_progress != null)
                  Text(
                    trP(context, 'chat.preview.assembling',
                        ['${_progress!.$1}', '${_progress!.$2}']),
                    style: ZType.sub.copyWith(color: ZInk.soft(context)),
                  ),
              ],
            ),
          ),
        _Phase.done => _view == _View.render
            ? _renderView(context)
            : _sourceView(context),
        _Phase.error => _errorView(context),
      },
    );
  }

  Widget _center(Widget child) => Center(child: child);

  /// The render view of the current kind. html/svg both surface their
  /// in-memory document through the WebView seam; markdown renders through
  /// the chat's own [AppMarkdown]. `plainText` never reaches here (the
  /// toggle is hidden and the page lands on the source view).
  Widget _renderView(BuildContext context) {
    switch (widget.render) {
      case FilePreviewRender.markdown:
        return _markdownRender();
      case FilePreviewRender.html:
      case FilePreviewRender.svg:
        final html = _html!;
        final builder = widget.webViewBuilder;
        return builder != null
            ? builder(context, html)
            : buildSandboxedWebView(html);
      case FilePreviewRender.plainText:
        // Unreachable (the toggle is hidden and the page lands on source),
        // kept for the exhaustive switch.
        return _sourceView(context);
    }
  }

  /// The markdown render view (design §4.1): the chat's own renderer and
  /// pipeline — [AppMarkdown] with the workspace image resolver, the link
  /// split (a local link pushes the next preview over this page; the back
  /// stack unwinds the chain) and fenced-code highlighting (S4; chat call
  /// sites keep their plain default). Bounded by [markdownRenderMaxBytes]
  /// at the caller (see [_renderDisabled]) — a whole-document build with no
  /// partial mode, so the cap is a hard fallback to the source view.
  Widget _markdownRender() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(ZSpacing.card),
      child: AppMarkdown(
        _textResult?.text ?? '',
        imageResolver: widget.resolveImage,
        onLinkTap: widget.openLink,
        highlight: true,
      ),
    );
  }

  /// Source view, graded by size (design §4.2): one selectable monolith up
  /// to [monolithMaxBytes], line-aligned lazy chunks above it. Copy strips
  /// sit above either grade — the truncation banner when the read hit the
  /// cap, and the markdown render-disabled notice when the page fell back
  /// here from an over-cap render view (design §4.1).
  Widget _sourceView(BuildContext context) {
    final result = _textResult;
    final chunks = _sourceChunks;
    final body = chunks == null
        ? _monolithSource(context, result?.text ?? '')
        : _chunkedSource(context, chunks);
    final totalBytes = result?.totalBytes;
    final strips = <Widget>[
      if (result?.truncated == true && totalBytes != null)
        _strip(
            context,
            trP(context, 'chat.preview.truncated',
                [_formatBytes(totalBytes), _readCapLabel])),
      if (_renderDisabled)
        _strip(context, tr(context, 'chat.preview.renderDisabled')),
    ];
    if (strips.isEmpty) return body;
    return Column(
      children: [
        ...strips,
        Expanded(child: body),
      ],
    );
  }

  /// ≤200 KB: the established single-text form — monospace, one uniform
  /// horizontal scroll, whole-text selection. S4 highlights this grade when
  /// the extension maps to a registered grammar and the text fits
  /// [highlightMaxBytes] (design §4.3): the line then renders a rich
  /// [SelectableText] whose span carries the token colors. Everything else
  /// (unmapped/unknown/unregistered language, over the highlight cap) keeps
  /// the plain form. Still selectable — `SelectableText.rich` runs the same
  /// selection machinery as the plain constructor.
  Widget _monolithSource(BuildContext context, String text) {
    final style = _sourceTextStyle(context);
    final span = _highlightedMonolith(context, text);
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(ZSpacing.card),
        child: span == null
            ? SelectableText(text, style: style)
            : SelectableText.rich(span, style: style),
      ),
    );
  }

  /// The memoized highlight for [text] (see [_spanMemoText]).
  TextSpan? _highlightedMonolith(BuildContext context, String text) {
    final dark = ZInk.isDark(context);
    if (_spanMemoText == text && _spanMemoDark == dark) return _spanMemoSpan;
    _spanMemoText = text;
    _spanMemoDark = dark;
    return _spanMemoSpan = highlightSpan(
      context,
      text: text,
      language: highlightLanguageForPath(widget.path),
      base: _sourceTextStyle(context),
    );
  }

  /// >200 KB: chunks render lazily in a vertical [ListView]; each chunk
  /// scrolls horizontally on its own (chunk widths vary with their longest
  /// line, so one shared horizontal extent would need the widest-of-all
  /// scan this path exists to avoid).
  ///
  /// Each chunk is a plain [Text], not a [SelectableText], on purpose: only
  /// registrar-registered paragraphs take part in [SelectionArea]'s
  /// selection — `SelectableText` builds an `EditableText` that keeps its
  /// own island selection and never enrolls with the area's registrar
  /// (SDK: editable_text.dart has no SelectionRegistrar support), so a
  /// SelectableText chunk would silently break cross-chunk selection. With
  /// [Text] the area delivers one selection and one copy surface across the
  /// chunks the list has built; unbuilt chunks stay outside it — an
  /// accepted limit (design §4.2), at most a screenful away at ~96 KB per
  /// chunk. No highlight on this grade: the hljs family scans whole
  /// documents and is capped to the monolith (S4, design §4.3).
  Widget _chunkedSource(BuildContext context, List<String> chunks) {
    return SelectionArea(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: ZSpacing.card),
        itemCount: chunks.length,
        itemBuilder: (context, index) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: ZSpacing.card),
          child: Text(chunks[index], style: _sourceTextStyle(context)),
        ),
      ),
    );
  }

  /// The source-text style both grades share, so the look cannot drift
  /// across the grade boundary.
  TextStyle _sourceTextStyle(BuildContext context) => ZType.caption.copyWith(
        fontFamily: 'monospace',
        color: ZInk.solid(context),
        height: 1.5,
      );

  /// Humble full-width copy strip above the source text (design §4.2's
  /// truncation banner shape): the truncation banner and the markdown
  /// render-disabled notice share it, so the two size messages cannot drift.
  Widget _strip(BuildContext context, String text) {
    return Container(
      width: double.infinity,
      color: ZInk.tile(context),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(
        text,
        style: ZType.caption.copyWith(color: ZInk.soft(context)),
      ),
    );
  }

  Widget _errorView(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ZSpacing.emptyState),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: ZInk.ghost(context)),
            const SizedBox(height: 16),
            Text(
              _errorTitle(context),
              style: ZType.heading.copyWith(color: ZInk.solid(context)),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                '$_error',
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: ZType.caption.copyWith(color: ZInk.faint(context)),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _load,
              child: Text(tr(context, 'tasks.retry')),
            ),
            if (_textResult != null)
              TextButton(
                onPressed: () => setState(() {
                  _view = _View.source;
                  _phase = _Phase.done;
                }),
                child: Text(tr(context, 'chat.preview.useSource')),
              ),
          ],
        ),
      ),
    );
  }

  /// The cannot-preview title (design §7): a classified read failure maps
  /// to its own copy, assembler errors keep the generic one.
  String _errorTitle(BuildContext context) {
    return switch (_failure) {
      FileReadFailure.notFound => tr(context, 'chat.preview.notFound'),
      FileReadFailure.binary => tr(context, 'chat.preview.binary'),
      FileReadFailure.empty => tr(context, 'chat.preview.empty'),
      FileReadFailure.tooLarge => tr(context, 'chat.preview.tooLarge'),
      FileReadFailure.readFailed => tr(context, 'chat.preview.readFailed'),
      null => tr(context, 'chat.preview.failed'),
    };
  }
}

/// Production WebView surface for both document render kinds (html, svg):
/// the document is fully inlined, so it loads from memory with file access
/// off and **no JS bridge** — the same trust level as the desktop opening
/// the file in a browser (design §4.2, the zero-bridge tier of §5.2). The
/// zero-handler posture is structural: [InAppWebView.onWebViewCreated] stays
/// null and handlers can only be registered there (the pdf page's three
/// read-only handlers are the deliberate second tier, S6).
@visibleForTesting
Widget buildSandboxedWebView(String html) {
  return InAppWebView(
    initialData: InAppWebViewInitialData(
      data: html,
      mimeType: 'text/html',
      encoding: 'utf-8',
    ),
    initialSettings: InAppWebViewSettings(
      // Sandbox: no file access from the rendered document.
      allowFileAccessFromFileURLs: false,
      allowUniversalAccessFromFileURLs: false,
      allowFileAccess: false,
      useHybridComposition: true,
    ),
  );
}

/// The svg render view's document (design §4.1): a minimal centered shell —
/// viewport meta, zero margin, the svg contained to the viewport width —
/// with the file's own text inlined verbatim. Inlining under an HTML shell
/// (instead of handing the bytes to the WebView as an image document) is the
/// fixed shape: it needs no baseUrl, no file access and no bridge, so the
/// svg's own scripts run exactly like a script inside an html preview
/// document would — the established same-tier judgment (design §4.1).
String buildSvgPreviewDocument(String svg) {
  return '$_svgShell$svg</body></html>';
}

const String _svgShell = '<!doctype html><html><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '<style>body{margin:0;display:grid;place-items:center;min-height:100vh}'
    'svg{max-width:100%;height:auto}</style></head><body>';
