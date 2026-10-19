import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../protocol/file_service.dart';
import '../theme.dart';
import '../ui_settings.dart';

/// The official range step (research/official-pdf-integration.md §2.2): the
/// document asks `pdfRange` for 256 KiB per call (the desktop clamps one
/// call to 1 MiB) and the transport's `rangeChunkSize` carries the same
/// value — one constant for both call sites, pinned by tests.
const int _rangeChunkBytes = 256 * 1024;

/// PDF preview page (task 10-18-file-preview-formats S6, design §5) — the
/// workspace pdf surface, built on the S0 boot spike's device-certified
/// shape (spike-notes.md §6): pdf.js 5.4.296 fully inlined into a `loadData`
/// document, the file fed through one JS bridge, pdf.js's own fake-worker
/// fallback as the accepted production path (the loadData origin makes blob
/// module workers fail on Android WebView — the fallback is the norm, no
/// branch).
///
/// Three-state read (design §3.2, the official PreviewPane decision —
/// research/official-pdf-integration.md §2.2):
/// * stat answers no size → the `readMediaPreview` data URL is inlined and
///   pdf.js gets its bytes decoded in-document;
/// * size ≤ 2 MiB → the document pulls the file eagerly in 256 KiB
///   `pdfRange` steps (the official eager loop);
/// * size > 2 MiB → a `PDFDataRangeTransport` subclass streams ranges on
///   demand — `disableAutoFetch` + `disableStream` + `rangeChunkSize=262144`
///   and no `initialData` (the official workspace-path shape; the eager
///   loop and the transport live in the document because the bytes must
///   reach pdf.js from inside: growing the loadData string by the file size
///   is not an option, and the bridge is the S0-certified data channel).
///
/// Trust model — the two sandbox tiers in one place (design §5.2): the
/// html/svg previews are the **zero-bridge tier** (`loadData`, no file
/// access, no JS handlers — the sandboxed surface in file_preview_page.dart
/// keeps its `onWebViewCreated` null); THIS page is the deliberate **second
/// tier**: the same `loadData` / no-file-access posture, loosened by
/// exactly three read-only handlers — `pdfRange` (bounded byte slices of
/// this page's one path), `pdfReady` (load handshake) and `pdfError`
/// (failure code). Nothing else is exposed; the document is fully inlined
/// and only the official pdf.js options are set.
///
/// Failures map onto the preview error lexicon (design §7): read-side
/// failures reuse the read-family copy classified by `FileReadFailure`
/// (notFound / tooLarge / readFailed — a corrupt document lands on the
/// generic read copy), the two pdf-specific keys cover password-protected
/// files (no password prompt by design §0 — the `onPassword` callback
/// reports and stops) and a missing bridge — the watchdog's 8 s
/// no-`pdfReady` verdict (design §5.2, the ohos-class degradation path;
/// `chat.preview.pdfUnsupported`).
///
/// Seams follow the FilePreviewPage convention: [stat], [readMediaDataUrl],
/// [readRange] and [loadAsset] are injectable, and [webViewBuilder] replaces
/// the platform surface (widget tests cannot host platform views) — the
/// stub receives the document and the three handler callbacks.
class PdfPreviewPage extends StatefulWidget {
  /// Absolute workspace path this page reads (the dispatch layer joins the
  /// workspace; the wire resolves relative paths against the desktop CWD).
  final String path;

  /// File metadata — the official size fork (design §3.2). A throw
  /// classifies into the read-failure copy.
  final Future<FileStat> Function(String path) stat;

  /// `readMediaPreview` as a data URL — the no-size fallback. A null read
  /// lands on the generic read failure.
  final Future<String?> Function(String path) readMediaDataUrl;

  /// `readFileRange` bytes — the data source behind the `pdfRange` handler.
  final Future<Uint8List> Function(String path, int offset, int length)
      readRange;

  /// Asset bytes seam (`rootBundle` in production; tests fake the pdf.js
  /// sources).
  final Future<Uint8List> Function(String key)? loadAsset;

  /// WebView surface seam: production builds [buildPdfWebView]; widget tests
  /// inject a placeholder that captures the document and the handlers.
  final Widget Function(
    BuildContext context,
    String html,
    Map<String, JavaScriptHandlerCallback> handlers,
  )? webViewBuilder;

  const PdfPreviewPage({
    super.key,
    required this.path,
    required this.stat,
    required this.readMediaDataUrl,
    required this.readRange,
    this.loadAsset,
    this.webViewBuilder,
  });

  @override
  State<PdfPreviewPage> createState() => _PdfPreviewPageState();
}

/// How the document gets its bytes (design §3.2, the official three-state
/// decision). `full`/`range` split at 2 MiB; `dataUrl` is the no-size
/// fallback.
enum PdfLoadMode { dataUrl, full, range }

enum _Phase { loading, content, error }

/// The error view's reason: the first three values mirror the read-family
/// copy classified by `FileReadFailure`, `password`/`unsupported` are the
/// two pdf-specific keys (design §7).
enum _PdfFailure { notFound, tooLarge, readFailed, password, unsupported }

class _PdfPreviewPageState extends State<PdfPreviewPage> {
  /// Watchdog budget (design §5.2): document handed over → no `pdfReady`
  /// inside this window means the bridge never came up (the ohos-class
  /// degradation path, softened into an honest "unsupported" state).
  static const _watchdogBudget = Duration(seconds: 8);

  /// The official three-state threshold (research §2.2): at or below it the
  /// document pulls the file eagerly, above it the range transport streams.
  static const _fullMaxBytes = 2 * 1024 * 1024;

  _Phase _phase = _Phase.loading;
  String? _html;
  _PdfFailure? _failure;
  String? _errorDetail;
  int _bootToken = 0;
  Timer? _watchdog;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    super.dispose();
  }

  Future<Uint8List> _loadAsset(String key) async {
    final data = await rootBundle.load(key);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<void> _load() async {
    _watchdog?.cancel();
    final token = ++_bootToken;
    setState(() {
      _phase = _Phase.loading;
      _html = null;
      _failure = null;
      _errorDetail = null;
      _ready = false;
    });
    try {
      final stat = await widget.stat(widget.path);
      String? dataUrl;
      final PdfLoadMode mode;
      if (stat.size == null) {
        mode = PdfLoadMode.dataUrl;
        dataUrl = await widget.readMediaDataUrl(widget.path);
        if (dataUrl == null) {
          _fail(_PdfFailure.readFailed, 'readMediaPreview returned no data');
          return;
        }
      } else if (stat.size! <= _fullMaxBytes) {
        mode = PdfLoadMode.full;
      } else {
        mode = PdfLoadMode.range;
      }
      final load = widget.loadAsset ?? _loadAsset;
      final workerSource = utf8.decode(await load(_workerAsset));
      final libSource = utf8.decode(await load(_libAsset));
      if (!mounted || token != _bootToken) return;
      final html = buildPdfPreviewDocument(
        workerSource: workerSource,
        pdfLibSource: libSource,
        mode: mode,
        path: widget.path,
        totalBytes: stat.size,
        dataUrl: dataUrl,
        loadingCopy: tr(context, 'chat.preview.loading'),
      );
      setState(() {
        _html = html;
        _phase = _Phase.content;
      });
      _watchdog = Timer(_watchdogBudget, () {
        if (!mounted || token != _bootToken || _ready) return;
        _fail(_PdfFailure.unsupported, null);
      });
    } catch (e) {
      if (!mounted || token != _bootToken) return;
      _fail(_classifyError(e), '$e');
    }
  }

  void _fail(_PdfFailure failure, String? detail) {
    if (!mounted) return;
    _watchdog?.cancel();
    setState(() {
      _failure = failure;
      _errorDetail = detail;
      _phase = _Phase.error;
    });
  }

  /// Official `f6` classifier (research §2 error table): a missing file
  /// surfaces as ENOENT / "no such file or directory" in the error text.
  /// Kept local like the read layer's own copy in `ChatPreview`.
  static final _missingFileRe = RegExp(
    r'\bENOENT\b|no such file or directory',
    caseSensitive: false,
  );

  /// The desktop's over-limit reads answer the "…file is too large for
  /// inline preview" family (see FileServicePort.readMedia).
  static final _tooLargeRe = RegExp(r'too large', caseSensitive: false);

  static _PdfFailure _classifyError(Object error) {
    final message = '$error';
    if (_missingFileRe.hasMatch(message)) return _PdfFailure.notFound;
    if (_tooLargeRe.hasMatch(message)) return _PdfFailure.tooLarge;
    return _PdfFailure.readFailed;
  }

  /// `pdfRange(path, offset, length)` → base64 bytes of THIS page's path.
  ///
  /// The JS-supplied path argument is deliberately ignored: the handler is
  /// the only way out of the sandbox, and pinning it to [widget.path] keeps
  /// it a single-file read channel (design §5.2 — the bridge is read-only
  /// and its arguments are controlled). A gateway failure throws, which the
  /// platform turns into a rejected JS promise — the document's
  /// `onRequestError` path (design §5.2), so the load fails instead of
  /// silently reading zeros.
  Future<dynamic> _onPdfRange(List<dynamic> args) async {
    final offset = _asInt(args.length > 1 ? args[1] : null) ?? 0;
    final length = _asInt(args.length > 2 ? args[2] : null) ?? 0;
    final bytes = await widget.readRange(
      widget.path,
      offset < 0 ? 0 : offset,
      length < 0 ? 0 : length,
    );
    return base64Encode(bytes);
  }

  /// Load handshake from the document: the bridge worked and the first page
  /// rendered — the watchdog stands down.
  dynamic _onPdfReady(List<dynamic> args) {
    _watchdog?.cancel();
    _ready = true;
    return null;
  }

  /// Failure code channel (load/parse/password/range/render). Before the
  /// handshake the page flips to its error view; after it, errors are
  /// ignored — the load phase is the terminal one (design §5.2), and a
  /// post-render hiccup must not tear down a working view.
  dynamic _onPdfError(List<dynamic> args) {
    final code = args.isNotEmpty ? '${args.first}' : 'unknown';
    _watchdog?.cancel();
    if (!mounted || _ready) return null;
    final failure = _classifyCode(code);
    setState(() {
      _failure = failure;
      // The detail line is diagnostic; the password code is the literal
      // word "password" and carries none.
      _errorDetail = failure == _PdfFailure.password ? null : code;
      _phase = _Phase.error;
    });
    return null;
  }

  static _PdfFailure _classifyCode(String code) {
    if (code == 'password') return _PdfFailure.password;
    return _classifyError(code);
  }

  static int? _asInt(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  Map<String, JavaScriptHandlerCallback> get _handlers => {
        'pdfRange': _onPdfRange,
        'pdfReady': _onPdfReady,
        'pdfError': _onPdfError,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.path.split(RegExp(r'[\\/]')).last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
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
        _Phase.content => _surface(context),
        _Phase.error => _errorView(context),
      },
    );
  }

  Widget _center(Widget child) => Center(child: child);

  Widget _surface(BuildContext context) {
    final html = _html!;
    final builder = widget.webViewBuilder;
    if (builder != null) return builder(context, html, _handlers);
    return buildPdfWebView(
      key: ValueKey('pdf-preview-$_bootToken'),
      html: html,
      handlers: _handlers,
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
              textAlign: TextAlign.center,
              style: ZType.heading.copyWith(color: ZInk.solid(context)),
            ),
            if (_errorDetail != null) ...[
              const SizedBox(height: 8),
              Text(
                _errorDetail!,
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
          ],
        ),
      ),
    );
  }

  /// The error view's copy (design §7): the read-family values reuse the
  /// classification's lexicon, the pdf-specific ones cover the password
  /// state and the missing-bridge verdict.
  String _errorTitle(BuildContext context) {
    return switch (_failure) {
      _PdfFailure.notFound => tr(context, 'chat.preview.notFound'),
      _PdfFailure.tooLarge => tr(context, 'chat.preview.tooLarge'),
      _PdfFailure.readFailed => tr(context, 'chat.preview.readFailed'),
      _PdfFailure.password => tr(context, 'chat.preview.pdfPassword'),
      _PdfFailure.unsupported => tr(context, 'chat.preview.pdfUnsupported'),
      null => tr(context, 'chat.preview.failed'),
    };
  }
}

const _workerAsset = 'assets/pdfjs/pdf.worker.min.mjs';
const _libAsset = 'assets/pdfjs/pdf.min.mjs';

/// ASCII JS string literal for safe embedding in a `<script>` block:
/// jsonEncode produces a valid JS literal, and `</` is escaped so the
/// payload can never close the surrounding script tag (the worker source is
/// 1 MB of minified js — an unescaped `</script>` inside a string would end
/// the document early).
String _jsLiteral(String source) =>
    jsonEncode(source).replaceAll('</', r'<\/');

/// Production WebView surface for the pdf document (design §5.2, the second
/// sandbox tier): `loadData` from memory, file access off, and exactly the
/// three read-only handlers registered in `onWebViewCreated` — the only
/// place the plugin accepts handler registration, so handing [handlers]
/// through is the deliberate loosening made structural.
@visibleForTesting
Widget buildPdfWebView({
  Key? key,
  required String html,
  required Map<String, JavaScriptHandlerCallback> handlers,
}) {
  return InAppWebView(
    key: key,
    initialData: InAppWebViewInitialData(
      data: html,
      mimeType: 'text/html',
      encoding: 'utf-8',
    ),
    initialSettings: InAppWebViewSettings(
      // Second-tier sandbox: still no file access, no baseUrl; the
      // loosening is limited to the handlers registered below.
      allowFileAccess: false,
      allowFileAccessFromFileURLs: false,
      allowUniversalAccessFromFileURLs: false,
      useHybridComposition: true,
    ),
    onWebViewCreated: (controller) {
      for (final entry in handlers.entries) {
        controller.addJavaScriptHandler(
          handlerName: entry.key,
          callback: entry.value,
        );
      }
    },
  );
}

/// Builds the self-contained pdf document (design §5.1): worker and library
/// sources inlined as JS string literals, same-document Blob module URLs
/// (the opaque-origin sandbox fails the worker start — pdf.js falls back to
/// its fake worker, the S0-certified production path), and the viewer
/// orchestration — single page + bottom pager + zoom ±0.25 (0.25–4.0) — the
/// official PdfViewer component's logic (research §3).
///
/// [mode] picks the data channel (see [PdfLoadMode]); [totalBytes] is the
/// known size for the full/range modes, [dataUrl] the `readMediaPreview`
/// data URL for the no-size fallback, and [loadingCopy] the locale string
/// the status line shows until the first page renders.
String buildPdfPreviewDocument({
  required String workerSource,
  required String pdfLibSource,
  required PdfLoadMode mode,
  required String path,
  int? totalBytes,
  String? dataUrl,
  required String loadingCopy,
}) {
  assert(mode == PdfLoadMode.dataUrl ? dataUrl != null : totalBytes != null);
  return '''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>pdf</title>
<style>
html,body{margin:0;height:100%;background:#161616;color:#ccc;font:13px/1.4 system-ui,sans-serif;overflow:hidden}
#stage{position:absolute;inset:0 0 64px 0;overflow:auto;display:flex;justify-content:center;padding:8px 0;-webkit-overflow-scrolling:touch}
#view{background:#fff;box-shadow:0 2px 14px rgba(0,0,0,.5);align-self:flex-start}
#bar{position:fixed;left:0;right:0;bottom:0;height:64px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;background:#1d1d1d;border-top:1px solid #333}
#pager{display:flex;align-items:center;gap:8px}
button{min-width:44px;min-height:44px;font-size:16px;background:#2a2a2a;color:#eee;border:1px solid #3a3a3a;border-radius:8px}
button:disabled{opacity:.35}
input{width:56px;height:36px;text-align:center;background:#111;color:#eee;border:1px solid #3a3a3a;border-radius:8px;font-size:14px}
#line{font:11px ui-monospace,monospace;color:#8a8a8a}
</style>
</head>
<body>
<div id="stage"><canvas id="view"></canvas></div>
<div id="bar">
<div id="pager">
<button id="prev">&lt;</button>
<input id="pageInput" inputmode="numeric" value="1">
<span id="pageTotal">/ ?</span>
<button id="next">&gt;</button>
<button id="zoomOut">&minus;</button>
<span id="zoomPct">100%</span>
<button id="zoomIn">+</button>
</div>
<div id="line">$loadingCopy</div>
</div>
<script>
window.__PDF_WORKER_SRC = ${_jsLiteral(workerSource)};
window.__PDF_LIB_SRC = ${_jsLiteral(pdfLibSource)};
window.__PDF_MODE = ${_jsLiteral(mode.name)};
window.__PDF_PATH = ${_jsLiteral(path)};
window.__PDF_TOTAL = ${totalBytes ?? 0};
window.__PDF_DATA_URL = ${dataUrl == null ? 'null' : _jsLiteral(dataUrl)};
</script>
<script type="module">
const line = document.getElementById('line');
const canvas = document.getElementById('view');
function b64Bytes(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}
// flutter_inappwebview runs its bridge at document start, but callHandler()
// is only usable after the platform dispatches its ready event; wait for it
// (or for the already-set _platformReady flag, so a late listener cannot
// miss the once-only event).
function bridgeReady() {
  if (window.flutter_inappwebview && window.flutter_inappwebview._platformReady) {
    return Promise.resolve();
  }
  return new Promise(function (resolve) {
    window.addEventListener('flutterInAppWebViewPlatformReady',
      function () { resolve(); }, { once: true });
  });
}
async function callBridge(name) {
  await bridgeReady();
  const args = Array.prototype.slice.call(arguments, 1);
  return window.flutter_inappwebview.callHandler.apply(
    window.flutter_inappwebview, [name].concat(args));
}
// Every failure funnels through the one code channel; the Dart side
// classifies the code into its error copy.
function reportError(code) {
  callBridge('pdfError', String(code)).catch(function () {});
}
window.addEventListener('error', function (e) { reportError('window: ' + (e && e.message)); });
window.addEventListener('unhandledrejection', function (e) {
  const reason = e && e.reason;
  reportError('promise: ' + ((reason && reason.message) || reason));
});

let pdfjs = null;
let doc = null;
let pageNo = 1;
let scale = 1.0;
let busy = false;

// Single-page viewer (the official PdfViewer shape, research §3): one
// canvas, an explicit pager, zoom in 0.25 steps clamped to 0.25-4.0, the
// page input clamped to 1..numPages, and keyboard arrows (an attached
// keyboard is harmless extra reach).
async function renderPage(n) {
  if (!doc || busy) return;
  busy = true;
  try {
    const page = await doc.getPage(n);
    const dpr = window.devicePixelRatio || 1;
    const viewport = page.getViewport({ scale: scale * dpr });
    canvas.width = Math.floor(viewport.width);
    canvas.height = Math.floor(viewport.height);
    canvas.style.width = Math.floor(viewport.width / dpr) + 'px';
    canvas.style.height = Math.floor(viewport.height / dpr) + 'px';
    await page.render({ canvasContext: canvas.getContext('2d'), viewport: viewport }).promise;
    pageNo = n;
    document.getElementById('pageInput').value = String(n);
    document.getElementById('pageTotal').textContent = '/ ' + doc.numPages;
    document.getElementById('zoomPct').textContent = Math.round(scale * 100) + '%';
    document.getElementById('prev').disabled = n <= 1;
    document.getElementById('next').disabled = n >= doc.numPages;
  } finally {
    busy = false;
  }
}
function go(delta) {
  if (!doc) return;
  renderPage(Math.min(doc.numPages, Math.max(1, pageNo + delta)))
    .catch(function (err) { reportError('render: ' + ((err && err.message) || err)); });
}
function zoom(delta) {
  scale = Math.min(4, Math.max(0.25, scale + delta));
  if (doc) {
    renderPage(pageNo)
      .catch(function (err) { reportError('render: ' + ((err && err.message) || err)); });
  }
}
document.getElementById('prev').addEventListener('click', function () { go(-1); });
document.getElementById('next').addEventListener('click', function () { go(1); });
document.getElementById('zoomIn').addEventListener('click', function () { zoom(0.25); });
document.getElementById('zoomOut').addEventListener('click', function () { zoom(-0.25); });
document.getElementById('pageInput').addEventListener('change', function (e) {
  if (!doc) return;
  let n = parseInt(e.target.value, 10);
  if (!isFinite(n)) n = pageNo;
  renderPage(Math.min(doc.numPages, Math.max(1, n)))
    .catch(function (err) { reportError('render: ' + ((err && err.message) || err)); });
});
document.getElementById('pageInput').addEventListener('keydown', function (e) {
  if (e.key === 'Enter') e.target.blur();
});
document.addEventListener('keydown', function (e) {
  if (e.target && e.target.tagName === 'INPUT') return;
  if (e.key === 'ArrowLeft') go(-1);
  if (e.key === 'ArrowRight') go(1);
});

// The eager whole-file read (size <= 2 MiB, the official eager leg of the
// three-state fork): 256 KiB steps (the official client's own step; the
// desktop clamps one call to 1 MiB), and the empty payload ends the read —
// the wire's certified termination signal (research §6). The bytes must
// reach pdf.js from inside the document: growing the loadData string by the
// file size is not an option (the S0 document is already ~1.5 MB), so the
// bridge is the data channel and the loop lives here.
async function readAll(path, totalBytes) {
  const parts = [];
  let offset = 0;
  while (offset < totalBytes) {
    const chunk = b64Bytes(await callBridge('pdfRange', path, offset, $_rangeChunkBytes));
    if (chunk.length === 0) break;
    parts.push(chunk);
    offset += chunk.length;
  }
  const all = new Uint8Array(offset);
  let at = 0;
  for (const part of parts) {
    all.set(part, at);
    at += part.length;
  }
  return all;
}

async function boot() {
  // Same-document Blob URLs: the loadData origin makes blob module workers
  // fail on Android WebView (device-certified, spike-notes §6), and pdf.js
  // falls back to its main-thread fake worker by itself — no branch here.
  const workerUrl = URL.createObjectURL(
    new Blob([window.__PDF_WORKER_SRC], { type: 'text/javascript' }));
  const libUrl = URL.createObjectURL(
    new Blob([window.__PDF_LIB_SRC], { type: 'text/javascript' }));
  pdfjs = await import(libUrl);
  pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;

  let options;
  if (window.__PDF_MODE === 'dataUrl') {
    // No size: the readMedia data URL, decoded in-document (no fetch
    // machinery).
    const url = window.__PDF_DATA_URL;
    options = { data: b64Bytes(url.slice(url.indexOf(',') + 1)) };
  } else if (window.__PDF_MODE === 'range') {
    // The official workspace-path transport (research §2.1): length only,
    // NO initialData; the options below are the official range set.
    class RangeTransport extends pdfjs.PDFDataRangeTransport {
      constructor(length, path) {
        super(length, null);
        this.path = path;
      }
      requestDataRange(begin, end) {
        callBridge('pdfRange', this.path, begin, end - begin)
          .then(function (b64) {
            this.onDataRange(begin, b64Bytes(b64));
          }.bind(this))
          .catch(function (err) {
            reportError('range: ' + ((err && err.message) || err));
          });
      }
      abort() {}
    }
    options = {
      range: new RangeTransport(window.__PDF_TOTAL, window.__PDF_PATH),
      disableAutoFetch: true,
      disableStream: true,
      rangeChunkSize: $_rangeChunkBytes
    };
  } else {
    options = { data: await readAll(window.__PDF_PATH, window.__PDF_TOTAL) };
  }

  // Password goes through the loading task, NOT through getDocument
  // options: a password function in the options breaks pdf.js's fake-worker
  // path (LoopbackPort structuredClones the request and functions cannot be
  // cloned — S0-certified, spike-notes §6). No input prompt by design §0:
  // report the state and stop.
  const loadingTask = pdfjs.getDocument(options);
  loadingTask.onPassword = function () { reportError('password'); };
  doc = await loadingTask.promise;
  await renderPage(1);
  line.hidden = true;
  callBridge('pdfReady').catch(function () {});
}

boot().catch(function (err) {
  reportError('load: ' + ((err && err.message) || err));
});
</script>
</body>
</html>
''';
}
