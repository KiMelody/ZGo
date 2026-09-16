import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/conversation.dart';

void main() {
  ConversationState stateWithWindow({
    required List<Map<String, dynamic>> window,
    int? totalCount,
    Object? firstRowId = _sentinel,
  }) {
    final state = ConversationState();
    final rowsObj = <String, dynamic>{
      'window': window,
      if (totalCount != null) 'totalCount': totalCount,
      // firstRowId intentionally absent unless the test passes it — the
      // live snapshot is NOT guaranteed to carry it (web pages on
      // window[0].rowId instead).
      if (!identical(firstRowId, _sentinel)) 'firstRowId': firstRowId,
    };
    state.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessionId': 's1',
          'logEpoch': 'e1',
          'revision': 1,
          'rows': rowsObj,
        },
      },
    }, onGap: () {});
    return state;
  }

  Map<String, dynamic> row(int id) => {'rowId': id, 'kind': 'assistantText'};

  test('missing snapshot firstRowId falls back to window head (web cursor)',
      () {
    final state = stateWithWindow(
      window: [row(10), row(11)],
      totalCount: 50,
    );
    expect(state.firstRowId, 10, reason: 'web pages on window[0].rowId');
    expect(state.canLoadOlder, isTrue);
  });

  test('explicit snapshot firstRowId still wins', () {
    final state = stateWithWindow(
      window: [row(10), row(11)],
      totalCount: 50,
      firstRowId: 9,
    );
    expect(state.firstRowId, 9);
  });

  test('rangeEnvelopeMatches guards on logEpoch', () {
    final state = stateWithWindow(window: [row(10)], totalCount: 5);
    expect(state.rangeEnvelopeMatches('e1'), isTrue);
    expect(state.rangeEnvelopeMatches('e2'), isFalse);
    expect(state.rangeEnvelopeMatches(null), isTrue);
  });

  test('hasMore from the response drives canLoadOlder (web paging)', () {
    final state = stateWithWindow(
      window: [row(10), row(11)],
      totalCount: 2,
    );
    // totals equal → heuristic says no more
    expect(state.canLoadOlder, isFalse);
    // but the server said there is more — hasMore wins
    state.hasMore = true;
    expect(state.canLoadOlder, isTrue);
    // server said done — no more even if totals drift
    state.hasMore = false;
    expect(state.canLoadOlder, isFalse);
  });

  test('prependOlderRows merges, dedupes and moves the cursor', () {
    final state = stateWithWindow(
      window: [row(10), row(11)],
      totalCount: 50,
    );
    state.prependOlderRows([row(8), row(9), row(10)]);
    expect(state.rows.map((r) => r['rowId']), [8, 9, 10, 11]);
    expect(state.firstRowId, 8);
  });

  test('prependOlderRows keeps the cursor on the smallest prepended row even '
      'when the response firstRowId is a placeholder', () {
    // Live-probed trap: snapshot/response firstRowId can be 1 while the real
    // rows sit far higher — trusting it made the second「加载更早」page a
    // no-op.
    final state = stateWithWindow(
      window: [row(100), row(101)],
      totalCount: 60,
      firstRowId: 1, // placeholder
    );
    expect(state.oldestRowId, 100, reason: 'cursor = oldest held row');

    // Page 1 returns rows 40..99 with a placeholder envelope firstRowId.
    state.prependOlderRows([for (var id = 40; id <= 99; id++) row(id)]);
    expect(state.rows.first['rowId'], 40);
    expect(state.firstRowId, 40, reason: 'not rewound to the placeholder 1');
    expect(state.oldestRowId, 40);

    // Page 2 must page back from the REAL cursor and land strictly older.
    state.prependOlderRows([for (var id = 1; id <= 39; id++) row(id)]);
    expect(state.rows.first['rowId'], 1);
    expect(state.firstRowId, 1);
    // Two pages of strictly-older rows reassemble the full ascending history.
    expect(
      state.rows.map((r) => r['rowId']),
      [for (var id = 1; id <= 101; id++) id],
    );
    expect(state.oldestRowId, 1);
  });

  test('prependOlderRows with no fresh rows leaves the cursor alone', () {
    final state = stateWithWindow(
      window: [row(40), row(100)],
      totalCount: 60,
    );
    state.prependOlderRows([row(40), row(100)]);
    expect(state.firstRowId, 40,
        reason: 'an all-duplicate page must not rewrite the cursor');
  });
}

class _Absent { const _Absent(); }
const _sentinel = _Absent();
