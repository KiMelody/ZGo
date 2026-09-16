// Guard: user-visible copy must come from the tr() tables in
// lib/ui/ui_settings.dart. A CJK character inside a string literal outside that
// table means a Chinese-only string leaks into the en UI (the table falls back
// zh -> key, so the leak is silent).
//
// The whitelist below is (file, literal) exact and mirrors the "intentional
// design" list in the i18n task PRD. Every entry carries its reason; do not
// "fix" a whitelisted literal, and do not add an entry without one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A literal the scanner must let through. [substring] marks the multi-line
/// injected-script entries, which cannot be registered verbatim.
class Exemption {
  const Exemption({
    required this.file,
    required this.literal,
    required this.reason,
    this.substring = false,
  });

  final String file;
  final String literal;
  final String reason;
  final bool substring;

  bool matches(String path, String text) =>
      file == path &&
      (substring ? text.contains(literal) : text == literal);
}

/// A hardcoded literal the scan rejected.
typedef CjkHit = ({String file, String literal});

/// Strings that must stay hardcoded. Scoped to desktop-parity matching and to
/// copy already locale-branched by hand.
const List<Exemption> exemptions = [
  Exemption(
    file: 'lib/ui/chat/chat_page.dart',
    literal: '未提供回答',
    reason: 'askQuestion: matches desktop model output text (zh branch)',
  ),
  Exemption(
    file: 'lib/ui/chat/chat_page.dart',
    literal: 'No answer',
    reason: 'askQuestion: matches desktop model output text (en branch)',
  ),
  Exemption(
    file: 'lib/ui/chat/chat_page.dart',
    literal: 'auto-continued',
    reason: 'askQuestion: desktop model output marker',
  ),
  Exemption(
    file: 'lib/ui/chat/chat_page.dart',
    literal: '自动继续',
    reason: 'askQuestion: desktop model output marker (zh branch)',
  ),
  Exemption(
    file: 'lib/ui/chat/chat_page.dart',
    literal: r'^[，,·:：/、\s]+',
    reason: 'strips leading punctuation from desktop-provided subagent '
        'summaries — pattern only, never rendered',
  ),
  Exemption(
    file: 'lib/ui/chat/chat_page.dart',
    literal: r'${_trimZero(n / 10000)}万',
    reason: '_fmtCompactTokens already branches by locale (zh 万 / en k-M)',
  ),
  Exemption(
    file: 'lib/protocol/off_peak.dart',
    literal: '订阅',
    reason: 'normalize(): classifies raw desktop error messages, not UI copy',
  ),
  Exemption(
    file: 'lib/protocol/off_peak.dart',
    literal: '额度',
    reason: 'normalize(): classifies raw desktop error messages, not UI copy',
  ),
  Exemption(
    file: 'lib/protocol/off_peak.dart',
    literal: '不可用',
    reason: 'normalize(): classifies raw desktop error messages, not UI copy',
  ),
  Exemption(
    file: 'lib/ui/remote_page.dart',
    literal: '(function () {',
    reason: 'injected deep-link JS: matches the desktop web DOM text '
        '(takeover buttons), never rendered by the app',
    substring: true,
  ),
];

/// Han ideographs plus CJK punctuation and compatibility forms.
final RegExp _cjk = RegExp(
  r'[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff'
  r'\ufe30-\ufe4f\uff00-\uffef]',
);

/// Never scanned: this file *is* the table.
const String _tablePath = 'lib/ui/ui_settings.dart';

/// Dart files under [root], excluding the i18n table.
List<String> dartSources(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .map((f) => f.path.replaceAll(r'\', '/'))
    .where((p) => p.endsWith('.dart') && p != _tablePath)
    .toList()
  ..sort();

/// Collects CJK-containing string literals outside the whitelist, so the
/// failure message can list each one.
List<CjkHit> scanForCjkLiterals(String root) {
  final hits = <CjkHit>[];
  for (final path in dartSources(root)) {
    for (final literal in stringLiterals(File(path).readAsStringSync())) {
      if (!_cjk.hasMatch(literal.text)) continue;
      if (_isExempt(path, literal.text)) continue;
      hits.add((file: path, literal: literal.text));
    }
  }
  return hits;
}

bool _isExempt(String file, String literal) =>
    exemptions.any((e) => e.matches(file, literal));

void main() {
  test('lib/ has no hardcoded CJK string literals (use the tr tables)', () {
    final hits = scanForCjkLiterals('lib');
    final report = hits.map((h) => '${h.file}  ${h.literal}').join('\n');
    expect(
      hits,
      isEmpty,
      reason: 'Move these into lib/ui/ui_settings.dart (zh + en) and read them '
          'through tr()/trP()/trLocale():\n$report',
    );
  });

  test('every whitelisted literal still exists in its file', () {
    for (final entry in exemptions) {
      final file = File(entry.file);
      expect(file.existsSync(), isTrue, reason: '${entry.file} is gone');
      final literals = stringLiterals(file.readAsStringSync());
      expect(
        literals.any((l) => entry.matches(entry.file, l.text)),
        isTrue,
        reason: 'stale whitelist entry: "${entry.literal}" is no longer a '
            'string literal in ${entry.file} — drop the entry',
      );
    }
  });

  test('whitelisted literals are not reused as copy elsewhere', () {
    final exempted = exemptions.map((e) => e.literal).toSet();
    final reused = <String>[];
    for (final path in dartSources('lib')) {
      for (final literal in stringLiterals(File(path).readAsStringSync())) {
        if (exempted.contains(literal.text) &&
            !_isExempt(path, literal.text)) {
          reused.add('$path  ${literal.text}');
        }
      }
    }
    expect(
      reused,
      isEmpty,
      reason: 'These literals are whitelisted for one parity match only, so '
          'here they are plain hardcoded copy:\n${reused.join('\n')}',
    );
  });
}

/// A string literal extracted from source, with its 1-based line number.
typedef Literal = ({int line, String text});

/// Extracts string literals (single, double, triple, raw, interpolated) while
/// skipping `//` and `/* */` comments.
List<Literal> stringLiterals(String source) {
  final out = <Literal>[];
  var i = 0;
  while (i < source.length) {
    final c = source[i];
    if (c == '/' && i + 1 < source.length && source[i + 1] == '/') {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '*') {
      i += 2;
      while (i + 1 < source.length &&
          !(source[i] == '*' && source[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    final raw = c == 'r' &&
        i + 1 < source.length &&
        (source[i + 1] == "'" || source[i + 1] == '"');
    if (c != "'" && c != '"' && !raw) {
      i++;
      continue;
    }
    final quoteAt = raw ? i + 1 : i;
    final quote = source[quoteAt];
    final triple = source.startsWith('$quote$quote$quote', quoteAt);
    final open = triple ? '$quote$quote$quote' : quote;
    final buf = StringBuffer();
    var j = quoteAt + open.length;
    while (j < source.length) {
      if (!raw && source[j] == r'\') {
        buf.write(source[j]);
        j++;
        if (j < source.length) {
          buf.write(source[j]);
          j++;
        }
        continue;
      }
      if (source.startsWith(open, j)) break;
      // Unterminated single-line literal: bail out instead of swallowing code.
      if (!triple && source[j] == '\n') break;
      buf.write(source[j]);
      j++;
    }
    final line = '\n'.allMatches(source.substring(0, i)).length + 1;
    out.add((line: line, text: buf.toString()));
    i = j + open.length;
  }
  return out;
}
