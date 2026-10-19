import 'package:flutter/material.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

import '../theme.dart';

/// Source syntax highlighting (task 10-18-file-preview-formats, design §4.3):
/// the ext→language table, the selectively registered grammar set, the
/// ZInk-converged token palette and the one entry point both preview surfaces
/// share ([highlightSpan]).
///
/// Grammars are imported one file at a time — never `all.dart` (196 grammars,
/// 2.7 MB of source): Dart tree-shaking keeps every grammar this file does not
/// import out of the build. The roster is the design's language list. Four
/// roster names have no files of their own: `jsx`/`tsx`/`html` are aliases of
/// javascript/typescript/xml (registered by their hosts), and `log` has no
/// grammar at all — txt/log map to it per the official table and fall back to
/// plain text, [highlightSpan]'s getLanguage guard being the judge. The
/// subLanguage cross-references of the roster (`dart`→markdown, `markdown`→
/// xml, `xml`→css+javascript, `javascript`/`typescript`→css+graphql+xml,
/// `shell`→bash, `yaml`→ruby) are all satisfied by the roster itself except
/// graphql — it only appears inside embedded template modes and an
/// unregistered string subLanguage degrades to plain text, so it stays out.
///
/// Highlighting is a whole-document regex scan (the hljs engine) plus a rich
/// span tree whose paragraph layout is super-linear in span count, so it is
/// bounded by [highlightMaxBytes] — deliberately below the source grade's
/// [monolithMaxBytes] (see the constant's doc for the measurements).

/// Size cap of the source view's single-selectable grade (design §4.2).
/// Lengths count UTF-16 code units — the metric text layout pays for (for
/// ASCII logs/json code units == bytes).
const int monolithMaxBytes = 200 * 1024;

/// Size cap for syntax highlighting (design §4.3), in the same UTF-16 units.
///
/// Deliberately NOT [monolithMaxBytes]: design §4.2 sanctions "调低高亮阈值"
/// as the fallback when performance misses the bar, and measurements put the
/// bar far below 200 KiB. The costs are (a) the hljs scan — roughly linear
/// (~1.2 s at a 190 KiB json on Dart JIT) — plus (b) rich-text paragraph
/// layout, which in this engine is super-linear in span count; together, a
/// warm json monolith costs ~0.2 s at 32 KiB, ~0.6 s at 64 KiB and ~7 s at
/// 190 KiB (flutter-test JIT, `SelectableText.rich`). 32 KiB keeps the graded
/// frame inside a route transition's budget even under AOT-vs-JIT uncertainty
/// (the exact device numbers are acceptance territory). Above it the source
/// renders plain, like every other fallback here. Raising it is a one-line
/// change — all three caps live in this file (design §4.2: 常量集中一处).
const int highlightMaxBytes = 32 * 1024;

/// Size cap of the markdown render view (design §0/§4.1), in the same UTF-16
/// units. Above it the page falls back to the source view and disables the
/// render segment; markdown cannot render partially ([AppMarkdown] builds the
/// whole document in one pass — flutter_markdown has no lazy/partial mode),
/// which is why the cap is a hard disable instead of the source view's grade
/// split. 256 KiB is the design's own number (§0 决策总表 / §4.1); it sits
/// with the two source caps above because all three answer one question —
/// how much whole-document layout this preview may pay for in one frame.
const int markdownRenderMaxBytes = 256 * 1024;

/// Extension → registered grammar name. Base = the official remote's
/// ext→language table (research official-pdf-integration §4.4, 32 entries
/// minus mermaid), extended with the natural extensions of the roster
/// languages the official table predates (dart/kt/swift/cs/php/…).
///
/// Deliberate aliases, official-style: toml→ini (hljs ships no toml
/// grammar), sh→bash, htm→html, yml→yaml, svg→xml, and txt/text/log→log —
/// re_highlight has no log grammar either, so those names resolve to null in
/// [highlightSpan] and render plain text.
const Map<String, String> highlightLanguageByExtension = {
  'bash': 'bash',
  'c': 'c',
  'cc': 'cpp',
  'cpp': 'cpp',
  'cs': 'csharp',
  'css': 'css',
  'dart': 'dart',
  'diff': 'diff',
  'go': 'go',
  'h': 'c',
  'hpp': 'cpp',
  'htm': 'html',
  'html': 'html',
  'ini': 'ini',
  'java': 'java',
  'js': 'javascript',
  'json': 'json',
  'jsx': 'jsx',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'log': 'log',
  'markdown': 'markdown',
  'md': 'markdown',
  'mjs': 'javascript',
  'php': 'php',
  'py': 'python',
  'rb': 'ruby',
  'rs': 'rust',
  'sh': 'bash',
  'shell': 'shell',
  'sql': 'sql',
  'svg': 'xml',
  'swift': 'swift',
  'text': 'log',
  'toml': 'ini',
  'ts': 'typescript',
  'tsx': 'tsx',
  'txt': 'log',
  'xml': 'xml',
  'yaml': 'yaml',
  'yml': 'yaml',
};

/// One shared engine, lazily built: the registration below is the only
/// mention of the imported grammars, so tree-shaking keeps the other ~170
/// language files out of the binary.
final Highlight _highlight = _buildHighlight();

Highlight _buildHighlight() {
  final highlight = Highlight();
  highlight.registerLanguages({
    'json': langJson,
    'dart': langDart,
    'javascript': langJavascript, // aliases: js, jsx, mjs, cjs
    'typescript': langTypescript, // aliases: ts, tsx, mts, cts
    'python': langPython,
    'java': langJava,
    'kotlin': langKotlin,
    'swift': langSwift,
    'go': langGo,
    'rust': langRust,
    'c': langC,
    'cpp': langCpp,
    'csharp': langCsharp,
    'php': langPhp,
    'ruby': langRuby,
    'bash': langBash, // alias: sh
    'shell': langShell,
    'sql': langSql,
    'ini': langIni,
    'yaml': langYaml,
    'xml': langXml, // aliases: html, xhtml, svg, …
    'css': langCss,
    'markdown': langMarkdown,
    'diff': langDiff,
  });
  return highlight;
}

/// The grammar [path] resolves to: its last-dot extension, lowercased and fed
/// through [highlightLanguageByExtension] (`.tar.gz` reads its `gz` tail, a
/// dotfile like `.gitignore` has no extension). Null means "no mapping" —
/// the caller renders plain text; a mapped-but-unregistered name (`log`)
/// also falls through [highlightSpan]'s guard.
String? highlightLanguageForPath(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return highlightLanguageByExtension[name.substring(dot + 1).toLowerCase()];
}

/// hljs token scope → style, resolved through the ZInk token family so both
/// app themes keep contrast (design §4.3: base an hljs theme, converge the
/// values onto tokens).
///
/// Scope keys are the dot forms the engine actually emits (`title.function`,
/// `variable.language` — verified against the registered roster). The
/// packaged theme files key off hljs CSS class names instead (`title.function_`
/// with a trailing underscore), which the [TextSpanRenderer] exact lookup
/// never matches — and upstream issue #1's black brackets/commas live in
/// those same files. Building the palette from tokens sidesteps both: every
/// unmapped scope falls back to the caller's base style, so punctuation
/// always paints in the source ink.
///
/// Token choices: keywords red, titles/functions violet (the task-dot pair —
/// [ZInk.usageChart]'s light value is tuned for chart fills and too pale for
/// code text), strings/names green, numbers/attributes/operators blue,
/// built-ins orange, comments gray.
@visibleForTesting
Map<String, TextStyle> sourceHighlightTheme(BuildContext context) {
  final red = TextStyle(color: ZInk.dangerTone(context));
  final violet = TextStyle(
      color:
          ZInk.isDark(context) ? ZColors.violet400 : ZColors.violet600);
  final green = TextStyle(color: ZInk.successTone(context));
  final blue = TextStyle(color: ZInk.usageBlue(context));
  final orange = TextStyle(color: ZInk.usageOrange(context));
  final gray = TextStyle(color: ZInk.muted(context));
  final ink = TextStyle(color: ZInk.solid(context));
  return {
    'keyword': red,
    'doctag': red,
    'template-tag': red,
    'template-variable': red,
    'type': red,
    'variable.language': red,
    'deletion': red,
    'title': violet,
    'title.class': violet,
    'title.function': violet,
    'title.function.invoke': violet,
    'function': violet,
    'function.dispatch': violet,
    'string': green,
    'regexp': green,
    'meta-string': green,
    'name': green,
    'tag': green,
    'quote': green,
    'selector-tag': green,
    'selector-pseudo': green,
    'addition': green,
    'link': green,
    'number': blue,
    'literal': blue,
    'meta': blue,
    'meta.prompt': blue,
    'attr': blue,
    'attribute': blue,
    'operator': blue,
    'variable': blue,
    'variable.constant': blue,
    'property': blue,
    'selector-attr': blue,
    'selector-class': blue,
    'selector-id': blue,
    'section': blue,
    'built_in': orange,
    'symbol': orange,
    'bullet': orange,
    'comment': gray,
    'code': gray,
    'formula': gray,
    'subst': ink,
    'emphasis': ink.copyWith(fontStyle: FontStyle.italic),
    'strong': ink.copyWith(fontWeight: FontWeight.w600),
  };
}

/// The highlighted [TextSpan] for [text] in [language], or null when the
/// caller must render plain text instead: no language mapped or registered,
/// empty text, text over [highlightMaxBytes], or the engine failing on this
/// content (safe mode; a preview degrades, it never bricks).
///
/// [base] is the plain-text style the caller would use — the renderer's
/// fallback for every unmapped scope and the root span's style, so the
/// highlighted text keeps the caller's font, size and color exactly.
TextSpan? highlightSpan(
  BuildContext context, {
  required String text,
  required String? language,
  required TextStyle base,
}) {
  if (language == null || text.isEmpty || text.length > highlightMaxBytes) {
    return null;
  }
  if (_highlight.getLanguage(language) == null) return null;
  try {
    final renderer = _FlatSpanRenderer(base, sourceHighlightTheme(context));
    _highlight.highlight(code: text, language: language).render(renderer);
    return renderer.span;
  } catch (_) {
    // Error escape hatch: user text drives a 1:1 hljs port (whole-document
    // regex). Whatever it throws on a hostile file, the preview shows plain
    // text instead of taking the page down.
    return null;
  }
}

/// Linear [HighlightRenderer] producing one flat leaf span per same-style
/// text run, in document order.
///
/// The packaged `TextSpanRenderer` cannot be used here: its `addSpan` copies
/// the node's whole children list on every text run (`[...children, span]`),
/// which is quadratic in the number of token nodes — measured on a 190 KiB
/// json: scan 1.2 s, its render 56 s, this flat assembly 11 ms (Dart JIT).
/// Styling is resolved exactly as the packaged renderer does — a run takes
/// its immediate node's scope style, unmapped scopes fall back to [base] —
/// so the paint is identical, only the object graph is flat.
///
/// Adjacent runs with an equal style (the engine emits token fragments, many
/// of them base-style punctuation/whitespace) merge into one leaf: export
/// text is laid out per span, and a 190 KiB json otherwise produced ~83k
/// spans whose paragraph layout alone stalled the frame for seconds.
class _FlatSpanRenderer implements HighlightRenderer {
  final TextStyle _base;
  final Map<String, TextStyle> _theme;

  /// Open node scopes, innermost last.
  final List<String?> _scopes = [];
  final List<TextSpan> _leaves = [];

  /// The run being accumulated (flushed on the next style change).
  StringBuffer? _runText;
  TextStyle? _runStyle;

  _FlatSpanRenderer(this._base, this._theme);

  @override
  void addText(String text) {
    final scope = _scopes.isEmpty ? null : _scopes.last;
    final style = (scope == null ? null : _theme[scope]) ?? _base;
    if (_runText != null && _runStyle == style) {
      _runText!.write(text);
      return;
    }
    _flushRun();
    _runStyle = style;
    _runText = StringBuffer(text);
  }

  @override
  void openNode(DataNode node) => _scopes.add(node.scope);

  @override
  void closeNode(DataNode node) => _scopes.removeLast();

  void _flushRun() {
    final buffer = _runText;
    if (buffer == null) return;
    _leaves.add(TextSpan(text: buffer.toString(), style: _runStyle));
    _runText = null;
    _runStyle = null;
  }

  TextSpan? get span {
    _flushRun();
    return _leaves.isEmpty ? null : TextSpan(style: _base, children: _leaves);
  }
}
