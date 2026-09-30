import 'dart:convert';

/// Pure-Dart HTML assembly for the file-preview page (design
/// 09-29-file-preview §3): pulls the relative css/js/img/font references of a
/// local HTML file — and the image/font `url()` targets inside fetched css —
/// and inlines them, so the WebView renders one self-contained document
/// without file access. Deliberately widget-free AND foundation-free (only
/// `dart:convert`): assembly logic stays unit-testable without any binding.
///
/// Parsing is regex-based on purpose (no new dependencies; malformed tags are
/// kept verbatim — fine for a preview). Depth is capped at 2 (html→css→
/// css-internal resources); deeper references are not followed. Absolute
/// references (http/https/data/protocol-relative) are kept verbatim — their
/// reachability is the sandboxed WebView's business.

/// One reference the assembler could not or would not inline.
class FailedRef {
  final String path;
  final String reason;
  const FailedRef(this.path, this.reason);

  @override
  String toString() => '$path ($reason)';
}

class AssemblyResult {
  /// The assembled document — relative references replaced by inline content
  /// or `<!-- preview: skipped <path> -->` placeholders; failures never
  /// abort the assembly.
  final String html;

  /// Paths successfully fetched and inlined.
  final List<String> inlined;

  /// Paths skipped (unreadable, disallowed extension, caps).
  final List<FailedRef> failed;

  /// True when a guard cap (count / per-file / total bytes) forced skips.
  final bool truncated;

  const AssemblyResult({
    required this.html,
    required this.inlined,
    required this.failed,
    required this.truncated,
  });
}

class HtmlAssembler {
  HtmlAssembler({
    required this.readText,
    required this.readMediaDataUrl,
    this.onProgress,
  });

  /// Text reads (css/js) — null when the file cannot be read.
  final Future<String?> Function(String path) readText;

  /// Binary reads as data URLs (images/fonts) — null on failure.
  final Future<String?> Function(String path) readMediaDataUrl;

  /// Optional progress for the preview page's N/M line: (processed,
  /// discovered) after each completed fetch attempt — discovered counts
  /// every first-attempted reference, processed those answered (inlined,
  /// skipped or failed).
  final void Function(int processed, int discovered)? onProgress;

  // Guards (design §3 记账): magnitudes aligned with the
  // attachmentPreviewMaxBytes scale; correct via live probe if ever needed.
  /// Max resources fetched per assembly.
  static const _maxFiles = 40;

  /// Max size of one fetched resource (utf8 bytes).
  static const _maxFileBytes = 2 * 1024 * 1024;

  /// Max combined size of all fetched resources (utf8 bytes).
  static const _maxTotalBytes = 8 * 1024 * 1024;

  static const _scriptExts = {'js', 'mjs'};
  static const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico'};
  static const _fontExts = {'woff', 'woff2', 'ttf', 'otf'};

  /// Whitelist (design §3): css/js/mjs + raster images + fonts. svg is NOT
  /// inlineable (kept out on purpose, see PRD non-goals).
  static const _inlineableExts = {
    'css',
    ..._scriptExts,
    ..._imageExts,
    ..._fontExts,
  };

  /// One combined pass so content inlined by an earlier rewrite is never
  /// re-scanned by a later one.
  static final _tagPattern = RegExp(
    r'<script\b[^>]*>[\s\S]*?</script>|<link\b[^>]*>|<img\b[^>]*>',
    caseSensitive: false,
  );
  static final _cssUrlPattern =
      RegExp(r'url\(\s*([^)]*?)\s*\)', caseSensitive: false);

  // Per-assemble state (reset in [assemble]; the cache doubles as the
  // visited set — a path is fetched at most once, which also kills cycles).
  final Map<String, ({String? text, String? dataUrl})> _cache = {};
  final List<String> _inlined = [];
  final List<FailedRef> _failed = [];
  int _fetched = 0;
  int _discovered = 0;
  int _totalBytes = 0;
  bool _truncated = false;

  Future<AssemblyResult> assemble(String htmlPath) async {
    _cache.clear();
    _inlined.clear();
    _failed.clear();
    _fetched = 0;
    _discovered = 0;
    _totalBytes = 0;
    _truncated = false;

    final main = await readText(htmlPath);
    if (main == null) {
      throw StateError('html_assembly: main file unreadable: $htmlPath');
    }
    final html = await _rewriteTags(main, _dirOf(htmlPath));
    return AssemblyResult(
      html: html,
      inlined: List.unmodifiable(_inlined),
      failed: List.unmodifiable(_failed),
      truncated: _truncated,
    );
  }

  // ------------------------------------------------------------ html tags

  Future<String> _rewriteTags(String html, String dir) async {
    final out = StringBuffer();
    var last = 0;
    for (final m in _tagPattern.allMatches(html)) {
      out.write(html.substring(last, m.start));
      final tag = m.group(0)!;
      final lower = tag.toLowerCase();
      if (lower.startsWith('<script')) {
        out.write(await _inlineScript(tag, dir));
      } else if (lower.startsWith('<link')) {
        out.write(await _inlineLink(tag, dir));
      } else {
        out.write(await _inlineImg(tag, dir));
      }
      last = m.end;
    }
    out.write(html.substring(last));
    return out.toString();
  }

  Future<String> _inlineLink(String tag, String dir) async {
    final rel = (_attrValue(tag, 'rel') ?? '').toLowerCase();
    final href = _attrValue(tag, 'href');
    if (!rel.contains('stylesheet') || href == null || href.isEmpty) {
      return tag; // not a stylesheet link — untouched
    }
    final path = _resolvePath(href, dir);
    if (path == null) return tag; // absolute — kept verbatim
    final got = await _fetch(path);
    final css = got?.text;
    if (css == null) return _skipped(path);
    final inlined = await _inlineCssUrls(css, _dirOf(path));
    return '<style>\n$inlined\n</style>';
  }

  Future<String> _inlineScript(String match, String dir) async {
    final openEnd = match.indexOf('>');
    final openTag = openEnd < 0 ? match : match.substring(0, openEnd + 1);
    final src = _attrValue(openTag, 'src');
    if (src == null || src.isEmpty) return match; // inline script — untouched
    final path = _resolvePath(src, dir);
    if (path == null) return match;
    final got = await _fetch(path);
    final text = got?.text;
    if (text == null) return _skipped(path);
    // Carry the type attribute over (type="module" must survive inlining).
    final type = _attrValue(openTag, 'type');
    return '<script${type == null ? '' : ' type="$type"'}>\n$text\n</script>';
  }

  Future<String> _inlineImg(String tag, String dir) async {
    final srcset = _attrValue(tag, 'srcset');
    var pick = srcset == null ? null : _largestOfSrcset(srcset);
    pick ??= _attrValue(tag, 'src');
    if (pick == null || pick.isEmpty) return tag;
    final path = _resolvePath(pick, dir);
    if (path == null) return tag;
    final got = await _fetch(path);
    final dataUrl = got?.dataUrl;
    if (dataUrl == null) return _skipped(path);
    var t = _dropAttr(tag, 'srcset');
    if (_attrRe('src').hasMatch(t)) {
      t = _replaceAttrValue(t, 'src', dataUrl);
    } else {
      t = t.replaceFirst(RegExp(r'/?>$'), ' src="$dataUrl">');
    }
    return t;
  }

  // ------------------------------------------------------------- css url()

  /// Inlines image/font `url()` targets inside a fetched css — the depth-2
  /// hop and the last one followed. Other targets (css/js/unknown) and
  /// failures keep the original `url()` verbatim: a css declaration has no
  /// valid inline replacement, and the sandboxed WebView simply skips it.
  Future<String> _inlineCssUrls(String css, String cssDir) async {
    final out = StringBuffer();
    var last = 0;
    for (final m in _cssUrlPattern.allMatches(css)) {
      out.write(css.substring(last, m.start));
      out.write(await _replaceCssUrl(m, cssDir));
      last = m.end;
    }
    out.write(css.substring(last));
    return out.toString();
  }

  Future<String> _replaceCssUrl(Match m, String cssDir) async {
    final raw = (m.group(1) ?? '').trim();
    final unquoted = raw.length >= 2 &&
            ((raw.startsWith('"') && raw.endsWith('"')) ||
                (raw.startsWith("'") && raw.endsWith("'")))
        ? raw.substring(1, raw.length - 1)
        : raw;
    final path = _resolvePath(unquoted, cssDir);
    if (path == null) return m.group(0)!;
    final ext = _extOf(path);
    if (!_imageExts.contains(ext) && !_fontExts.contains(ext)) {
      return m.group(0)!; // never re-parse css here — the depth cap
    }
    final got = await _fetch(path);
    final dataUrl = got?.dataUrl;
    if (dataUrl == null) return m.group(0)!;
    return 'url($dataUrl)';
  }

  // ----------------------------------------------------------- guarded io

  /// Fetches [path] once (the cache is the visited set), enforcing the
  /// whitelist and byte caps. Returns null when skipped — the reason is
  /// recorded in [_failed].
  Future<({String? text, String? dataUrl})?> _fetch(String path) async {
    final cached = _cache[path];
    if (cached != null) return cached;
    _discovered++;
    // Progress fires at discovery too: a slow pending fetch still shows its
    // slot in the page's N/M line.
    _progressed();

    final ext = _extOf(path);
    if (!_inlineableExts.contains(ext)) {
      _failed.add(FailedRef(path, 'extension not allowed'));
      _progressed();
      return null;
    }
    if (_fetched >= _maxFiles) {
      _failed.add(FailedRef(path, 'file-count cap reached'));
      _truncated = true;
      _progressed();
      return null;
    }

    if (ext == 'css' || _scriptExts.contains(ext)) {
      final text = await readText(path);
      if (text == null) {
        _failed.add(FailedRef(path, 'read failed'));
        _progressed();
        return null;
      }
      if (!_withinCaps(path, utf8.encode(text).length)) {
        _progressed();
        return null;
      }
      _fetched++;
      _inlined.add(path);
      final got = (text: text, dataUrl: null);
      _progressed();
      return _cache[path] = got;
    }

    final dataUrl = await readMediaDataUrl(path);
    if (dataUrl == null) {
      _failed.add(FailedRef(path, 'read failed'));
      _progressed();
      return null;
    }
    if (!_withinCaps(path, utf8.encode(dataUrl).length)) {
      _progressed();
      return null;
    }
    _fetched++;
    _inlined.add(path);
    final got = (text: null, dataUrl: dataUrl);
    _progressed();
    return _cache[path] = got;
  }

  void _progressed() => onProgress?.call(_fetched + _failed.length, _discovered);

  bool _withinCaps(String path, int bytes) {
    if (bytes > _maxFileBytes) {
      _failed.add(FailedRef(path, 'file exceeds the $_maxFileBytes-byte cap'));
      _truncated = true;
      return false;
    }
    if (_totalBytes + bytes > _maxTotalBytes) {
      _failed.add(FailedRef(path, 'total $_maxTotalBytes-byte cap reached'));
      _truncated = true;
      return false;
    }
    _totalBytes += bytes;
    return true;
  }

  // -------------------------------------------------------------- helpers

  static String _skipped(String path) => '<!-- preview: skipped $path -->';

  /// Largest candidate of a srcset ("a.png 1x, b.png 2x") — the preview
  /// inlines the best available resolution only. Descriptors are "2x" /
  /// "640w": the trailing unit letter is stripped before parsing.
  static String? _largestOfSrcset(String srcset) {
    String? best;
    var bestScore = -1.0;
    for (final candidate in srcset.split(',')) {
      final parts = candidate.trim().split(RegExp(r'\s+'));
      if (parts.isEmpty || parts.first.isEmpty) continue;
      var score = 1.0;
      if (parts.length > 1) {
        final digits = RegExp(r'^[0-9.]+').firstMatch(parts[1]);
        score = digits == null ? 1.0 : (double.tryParse(digits.group(0)!) ?? 1.0);
      }
      if (score > bestScore) {
        best = parts.first;
        bestScore = score;
      }
    }
    return best;
  }

  /// Resolves [ref] against the directory of the referencing file
  /// (posix-style, backslashes normalized). Returns null for references that
  /// must be kept verbatim: remote (http/https/data/protocol-relative),
  /// same-document fragments, and empty leftovers after query stripping.
  /// `..` may escape upward — content comes from the user's own desktop,
  /// same trust level as the desktop opening a browser.
  static String? _resolvePath(String ref, String baseDir) {
    var p = ref.trim().replaceAll('\\', '/');
    final hash = p.indexOf('#');
    if (hash >= 0) {
      if (hash == 0) return null; // url(#frag) — same-document reference
      p = p.substring(0, hash);
    }
    final query = p.indexOf('?');
    if (query >= 0) p = p.substring(0, query);
    if (p.isEmpty) return null;

    final lower = p.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('data:') ||
        p.startsWith('//')) {
      return null;
    }

    final rootAbsolute = p.startsWith('/');
    final stack = <String>[];
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (stack.isNotEmpty && stack.last != '..' && !stack.last.endsWith(':')) {
          stack.removeLast();
        } else if (!rootAbsolute) {
          stack.add('..');
        }
        continue;
      }
      stack.add(seg);
    }
    final body = stack.join('/');
    if (body.isEmpty) return null;
    if (rootAbsolute) return '/$body';
    // Drive-absolute (C:/…) or upward-escaping results don't join the dir.
    if (body.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(body)) {
      return body;
    }
    return baseDir.isEmpty ? body : '$baseDir/$body';
  }

  static String _dirOf(String path) {
    final p = path.replaceAll('\\', '/');
    final i = p.lastIndexOf('/');
    return i < 0 ? '' : p.substring(0, i);
  }

  static String _extOf(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i + 1).toLowerCase();
  }

  // `(?<![\w-])` keeps `data-src` etc. from matching as `src`.
  static RegExp _attrRe(String name) => RegExp(
      "(?<![\\w-])$name\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s'>]+))",
      caseSensitive: false);

  static String? _attrValue(String tag, String name) {
    final m = _attrRe(name).firstMatch(tag);
    if (m == null) return null;
    return m.group(2) ?? m.group(3) ?? m.group(4);
  }

  static String _dropAttr(String tag, String name) =>
      tag.replaceFirst(_attrRe(name), '');

  static String _replaceAttrValue(String tag, String name, String value) =>
      tag.replaceFirst(_attrRe(name), '$name="$value"');
}
