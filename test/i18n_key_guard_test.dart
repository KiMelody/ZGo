// Guard: every i18n key referenced through tr()/trP()/trByKey()/
// trByKeyP()/trLocale() in lib/ must exist in BOTH tables of
// lib/i18n/lexicon.dart. A missing key is silent: trLocale falls back to
// the key itself, so the raw key text ("auto.custom.every") ships to users.
// Catches the rename-leftover class that the CJK scan (i18n_cjk_scan_test)
// cannot see. Keys built with interpolation ('chat.mode.$m') are skipped —
// their families stay a manual check, same as before.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _tablePath = 'lib/i18n/lexicon.dart';

/// Dart files under lib/, excluding the i18n table itself.
List<String> _dartSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .map((f) => f.path.replaceAll('\\', '/'))
    .where((p) => p.endsWith('.dart') && p != _tablePath)
    .toList();

/// Keys of one table (`_zh` / `_en`) in lexicon.dart.
Set<String> _tableKeys(String source, String tableName) {
  final start = source.indexOf('const $tableName = {');
  expect(start, isPositive, reason: '$tableName not found in $_tablePath');
  final end = source.indexOf('\n};', start);
  final keys = <String>{};
  for (final line in source.substring(start, end).split('\n')) {
    final m = RegExp(r"^\s*'([a-zA-Z0-9_.\-]+)':").firstMatch(line);
    if (m != null) keys.add(m.group(1)!);
  }
  return keys;
}

/// The first string literal of every tr*() call site, i.e. the key argument
/// (the context/locale argument ahead of it is always a variable, never a
/// literal). Returns file -> offending key -> line numbers.
Map<String, Map<String, List<int>>> _referencedKeys() {
  final callPattern =
      RegExp(r"""\btr(?:P|ByKey|ByKeyP|Locale)?\s*\(\s*['"]([^'"\n]+)['"]""");
  final out = <String, Map<String, List<int>>>{};
  for (final path in _dartSources()) {
    final source = File(path).readAsStringSync();
    for (final m in callPattern.allMatches(source)) {
      final key = m.group(1)!;
      // Dynamic families ('chat.mode.$m') and non-key literals (URLs,
      // probe strings passed through trLocale lookups) stay manual checks.
      if (key.contains(r'$') || !key.contains('.')) continue;
      final line = '\n'.allMatches(source.substring(0, m.start)).length + 1;
      out.putIfAbsent(path, () => {}).putIfAbsent(key, () => []).add(line);
    }
  }
  return out;
}

void main() {
  test('the _zh and _en tables carry the same key set', () {
    final source = File(_tablePath).readAsStringSync();
    final zh = _tableKeys(source, '_zh');
    final en = _tableKeys(source, '_en');
    expect(en.difference(zh), isEmpty,
        reason: 'Keys only in _en (zh falls back to the raw key):\n'
            '${en.difference(zh).toSet().join('\n')}');
    expect(zh.difference(en), isEmpty,
        reason: 'Keys only in _zh (en falls back to zh copy):\n'
            '${zh.difference(en).toSet().join('\n')}');
  });

  test('every literal tr() key in lib/ exists in both tables', () {
    final source = File(_tablePath).readAsStringSync();
    final zh = _tableKeys(source, '_zh');
    final en = _tableKeys(source, '_en');
    final missing = <String>[];
    _referencedKeys().forEach((path, keys) {
      keys.forEach((key, lines) {
        if (!zh.contains(key) || !en.contains(key)) {
          missing.add('$path:${lines.join(',')}  $key');
        }
      });
    });
    expect(missing, isEmpty,
        reason: 'tr() falls back to the raw key text for these — add them to '
            'both tables in $_tablePath:\n${missing.join('\n')}');
  });
}
