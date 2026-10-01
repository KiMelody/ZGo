import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';

/// Matrix for [parseRowsRangeResponse] (task 10-01-history-pager-extract,
/// commit point A): the rowsRange response fallback chain
/// (`rows.window ?? rows.rows` → List direct → `items ?? window` →
/// `res is List` → unrecognizable = null) × (hasMore / atLogEpoch missing,
/// matching, drifting) × the sort switch. Each row freezes one branch of
/// the three former private copies (chat `_loadOlderSettled` / subagent
/// sheet `_loadEarlier` / subagent detail `_loadOlder`); the per-caller
/// drop/apply/toast policy stays at the call sites and is NOT part of the
/// parse.
void main() {
  ConversationState stateWithEpoch(String? epoch) {
    final state = ConversationState()..logEpoch = epoch;
    return state;
  }

  Map<String, dynamic> row(int id) => {'rowId': id, 'kind': 'assistantText'};

  group('fallback chain shapes', () {
    test('rows.window wins over rows.rows when both present', () {
      final page = parseRowsRangeResponse(
        {
          'rows': {
            'window': [row(12)],
            'rows': [row(99)],
          },
        },
        state: stateWithEpoch('e1'),
      );
      expect(page.rows!.map((r) => r['rowId']), [12]);
    });

    test('rows.rows is the in-map fallback when window is absent', () {
      final page = parseRowsRangeResponse(
        {
          'rows': {
            'rows': [row(7), row(3)],
          },
        },
        state: stateWithEpoch('e1'),
      );
      expect(page.rows!.map((r) => r['rowId']), [3, 7]); // sorted
    });

    test('rows as a bare List is used directly', () {
      final page = parseRowsRangeResponse(
        {
          'rows': [row(5)],
        },
        state: stateWithEpoch('e1'),
      );
      expect(page.rows!.map((r) => r['rowId']), [5]);
    });

    test('top-level items is the fallback when rows is unusable', () {
      final page = parseRowsRangeResponse(
        {
          'rows': 'garbage',
          'items': [row(8)],
        },
        state: stateWithEpoch('e1'),
      );
      expect(page.rows!.map((r) => r['rowId']), [8]);
    });

    test('top-level window is the last Map fallback', () {
      final page = parseRowsRangeResponse(
        {
          'window': [row(9)],
        },
        state: stateWithEpoch('e1'),
      );
      expect(page.rows!.map((r) => r['rowId']), [9]);
    });

    test('a bare List response is used directly (no envelope)', () {
      final page = parseRowsRangeResponse(
        [row(4), row(2)],
        state: stateWithEpoch('e1'),
      );
      expect(page.rows!.map((r) => r['rowId']), [2, 4]); // sorted
      expect(page.hasMore, isNull);
      expect(page.epochMatches, isTrue, reason: 'no envelope → no drift');
    });

    test('unrecognizable shapes answer null rows, not an empty list', () {
      for (final res in [
        null,
        'garbage',
        <String, dynamic>{},
        <String, dynamic>{'rows': 42},
      ]) {
        final page = parseRowsRangeResponse(res, state: stateWithEpoch('e1'));
        expect(page.rows, isNull, reason: 'res = $res');
      }
    });

    test('an empty bare List response stays an empty list (res is List)', () {
      final page = parseRowsRangeResponse(
        <dynamic>[],
        state: stateWithEpoch('e1'),
      );
      expect(page.rows, isEmpty);
      expect(page.rows, isNotNull);
    });

    test('an empty recognizable window stays an empty list', () {
      final page = parseRowsRangeResponse(
        {
          'rows': <dynamic>[],
        },
        state: stateWithEpoch('e1'),
      );
      expect(page.rows, isEmpty);
      expect(page.rows, isNotNull);
    });

    test('non-Map elements are dropped by the cast', () {
      final page = parseRowsRangeResponse(
        {
          'rows': [row(1), 'junk', 3],
        },
        state: stateWithEpoch('e1'),
      );
      expect(page.rows!.length, 1);
      expect(page.rows!.single['rowId'], 1);
    });

    test('rows are cast to Map<String, dynamic>', () {
      final page = parseRowsRangeResponse(
        {
          'rows': [
            <dynamic, dynamic>{'rowId': 1, 'kind': 'assistantText'},
          ],
        },
        state: stateWithEpoch('e1'),
      );
      expect(page.rows!.single, isA<Map<String, dynamic>>());
    });
  });

  group('epoch + hasMore envelope', () {
    test('missing atLogEpoch folds into a match (lenient, web store)', () {
      final page = parseRowsRangeResponse(
        <String, dynamic>{'rows': [row(1)]},
        state: stateWithEpoch('e1'),
      );
      expect(page.atLogEpoch, isNull);
      expect(page.epochMatches, isTrue);
    });

    test('matching epoch answers epochMatches true', () {
      final page = parseRowsRangeResponse(
        {
          'atLogEpoch': 'e1',
          'rows': [row(1)],
        },
        state: stateWithEpoch('e1'),
      );
      expect(page.epochMatches, isTrue);
    });

    test('drifting epoch answers epochMatches false — caller decides', () {
      final page = parseRowsRangeResponse(
        {
          'atLogEpoch': 'e2',
          'rows': [row(1)],
          'hasMore': true,
        },
        state: stateWithEpoch('e1'),
      );
      expect(page.epochMatches, isFalse);
      // The page itself is NOT dropped here — chat applies it with a
      // toast (round 23), sheet/detail drop it. Parse only reports.
      expect(page.rows, isNotEmpty);
      expect(page.hasMore, isTrue);
    });

    test('epochMatches compares against the PASSED state', () {
      final res = {
        'atLogEpoch': 'e2',
        'rows': [row(1)],
      };
      expect(
        parseRowsRangeResponse(res, state: stateWithEpoch('e2')).epochMatches,
        isTrue,
      );
      expect(
        parseRowsRangeResponse(res, state: stateWithEpoch('e9')).epochMatches,
        isFalse,
      );
    });

    test('hasMore passes through; absent answers null', () {
      final present = parseRowsRangeResponse(
        {
          'rows': [row(1)],
          'hasMore': true,
        },
        state: stateWithEpoch('e1'),
      );
      expect(present.hasMore, isTrue);
      final absent = parseRowsRangeResponse(
        {
          'rows': [row(1)],
        },
        state: stateWithEpoch('e1'),
      );
      expect(absent.hasMore, isNull);
    });
  });

  group('sort switch', () {
    test('default sorts by rowId ascending (chat/detail)', () {
      final page = parseRowsRangeResponse(
        {
          'rows': [row(30), row(10), row(20)],
        },
        state: stateWithEpoch('e1'),
      );
      expect(page.rows!.map((r) => r['rowId']).toList(), [10, 20, 30]);
    });

    test('sortOldestFirst: false preserves response order (sheet)', () {
      final page = parseRowsRangeResponse(
        {
          'rows': [row(30), row(10), row(20)],
        },
        state: stateWithEpoch('e1'),
        sortOldestFirst: false,
      );
      expect(page.rows!.map((r) => r['rowId']).toList(), [30, 10, 20]);
    });

    test('missing rowId sorts as 0 without throwing', () {
      final page = parseRowsRangeResponse(
        {
          'rows': [
            {'kind': 'assistantText'}, // no rowId
            row(5),
          ],
        },
        state: stateWithEpoch('e1'),
      );
      expect(page.rows!.first['rowId'], isNull);
      expect(page.rows!.last['rowId'], 5);
    });
  });
}
