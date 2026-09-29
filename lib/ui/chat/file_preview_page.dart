import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../theme.dart';
import '../ui_settings.dart';
import 'html_assembly.dart';

/// HTML file preview with dual views (task 09-29-file-preview design §4.2,
/// user decision C): the render view assembles the file's relative css/js/
/// img/font references into one self-contained document ([HtmlAssembler])
/// and renders it in a sandboxed `InAppWebView` via `loadData` — no
/// baseUrl, no file access, no JS bridge; the source view shows the
/// original text (monospace, horizontal scroll, selectable).
///
/// Reads are callback-injected so widget tests fake them; the WebView
/// surface is injectable for the same reason (widget tests cannot host
/// platform views — real rendering is device-acceptance territory).
class FilePreviewPage extends StatefulWidget {
  final String path;

  /// Text reads (the html itself + css/js resources) — null on failure.
  final Future<String?> Function(String path) readText;

  /// Binary reads as data URLs (images/fonts) — null on failure.
  final Future<String?> Function(String path) readMediaDataUrl;

  /// WebView surface seam: production builds the real InAppWebView;
  /// widget tests inject a placeholder (platform views unavailable there).
  final Widget Function(BuildContext context, String html)? webViewBuilder;

  const FilePreviewPage({
    super.key,
    required this.path,
    required this.readText,
    required this.readMediaDataUrl,
    this.webViewBuilder,
  });

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

enum _Phase { loading, assembling, done, error }

enum _View { render, source }

class _FilePreviewPageState extends State<FilePreviewPage> {
  _Phase _phase = _Phase.loading;
  _View _view = _View.render;

  String? _html;
  String? _source;
  Object? _error;
  (int, int)? _progress;

  /// Page-lifetime memo over [widget.readText]: the assembler and the
  /// source view share one fetch of the main file and of css resources.
  final Map<String, String?> _textMemo = {};

  Future<String?> _readTextMemo(String path) async {
    if (_textMemo.containsKey(path)) return _textMemo[path];
    final text = await widget.readText(path);
    // Failures stay uncached: retry must re-fetch.
    if (text != null) _textMemo[path] = text;
    return text;
  }

  Future<void> _load() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
      _progress = null;
    });
    // Main file first: it doubles as the source view's text, and its
    // failure is the page-level error (resource failures degrade to
    // placeholder comments inside the assembly instead).
    final source = await _readTextMemo(widget.path);
    if (!mounted) return;
    if (source == null) {
      setState(() {
        _error = 'main file unreadable: ${widget.path}';
        _phase = _Phase.error;
      });
      return;
    }
    setState(() {
      _source = source;
      _phase = _Phase.assembling;
    });
    try {
      final assembler = HtmlAssembler(
        readText: _readTextMemo,
        readMediaDataUrl: widget.readMediaDataUrl,
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = (done, total));
        },
      );
      final result = await assembler.assemble(widget.path);
      if (!mounted) return;
      setState(() {
        _html = result.html;
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
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SegmentedButton<_View>(
              segments: [
                ButtonSegment(
                  value: _View.render,
                  label: Text(tr(context, 'chat.preview.render')),
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
            ? (widget.webViewBuilder ?? _defaultWebView)(context, _html!)
            : _sourceView(context),
        _Phase.error => _errorView(context),
      },
    );
  }

  Widget _center(Widget child) => Center(child: child);

  /// Production WebView: the document is fully inlined, so it loads from
  /// memory with file access off and no JS bridge — the same trust level
  /// as the official desktop opening the file in a browser (design §4.2).
  Widget _defaultWebView(BuildContext context, String html) {
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

  Widget _sourceView(BuildContext context) {
    final source = _source ?? '';
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(ZSpacing.card),
        child: SelectableText(
          source,
          style: ZType.caption.copyWith(
            fontFamily: 'monospace',
            color: ZInk.solid(context),
            height: 1.5,
          ),
        ),
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
              tr(context, 'chat.preview.failed'),
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
            if (_source != null)
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
}
