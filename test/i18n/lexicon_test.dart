import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/i18n/lexicon.dart';

void main() {
  group('table parity', () {
    test('zh and en share the exact same key set', () {
      final zh = zhTable.keys.toSet();
      final en = enTable.keys.toSet();
      expect(
        en.difference(zh),
        isEmpty,
        reason: 'keys missing from the zh table',
      );
      expect(
        zh.difference(en),
        isEmpty,
        reason: 'keys missing from the en table',
      );
      expect(zhTable.length, enTable.length);
    });

    test('no table value is empty', () {
      for (final entry in {...zhTable, ...enTable}.entries) {
        expect(
          entry.value.trim(),
          isNotEmpty,
          reason: '${entry.key} has an empty value',
        );
      }
    });
  });
}
