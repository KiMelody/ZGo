import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/ui/chat/history_pager.dart';

/// Test rig: every injected seam records into one ordered [events] log so
/// gate/step interleavings (e.g. "the gate opens BEFORE the prepend step
/// in the same frame") are assertable; [steps] keeps the emitted payloads
/// and [frames] queues post-frame callbacks for manual pumping.
class Harness {
  final events = <String>[];
  final steps = <HistoryLoadStep>[];
  final frames = <void Function()>[];
  final responses = <Object?>[];
  final calls = <({int? beforeRowId, int limit})>[];
  bool scrollIdle = true;
  bool compensationPending = false;
  ConversationState? current;

  late final HistoryPager pager = HistoryPager(
    fetch: (sessionId, {beforeRowId, limit = 60}) async {
      calls.add((beforeRowId: beforeRowId, limit: limit));
      final answer = responses.removeAt(0);
      if (answer is Exception) throw answer;
      return answer;
    },
    currentState: () => current,
    isScrollIdle: () => scrollIdle,
    isCompensationPending: () => compensationPending,
    setCompensationPending: (value) => compensationPending = value,
    postFrame: frames.add,
    onStep: (step) {
      steps.add(step);
      events.add('step:${step.runtimeType}');
    },
    onGateChanged: () =>
        events.add('gate:${pager.loadingOlder ? 'up' : 'down'}'),
  );

  /// Drains queued post-frame callbacks (a callback may queue more).
  void runFrames() {
    while (frames.isNotEmpty) {
      frames.removeAt(0)();
    }
  }
}

/// Pure-Dart unit tests for [HistoryPager] (task 10-01-history-pager-extract,
/// commit point B): the fetch/park/generation decisions extracted from the
/// chat page's `_loadOlder` / `_loadOlderSettled` / `_flushPendingOlder`.
/// The measurement chain (anchor / veil / prepend landing) stays widget-side
/// and is exercised by `test/ui/chat_page_test.dart` — nothing here needs a
/// binding: frames and gateway answers are plain closures the tests drive.
void main() {
  Map<String, dynamic> row(int id) => {'rowId': id, 'kind': 'assistantText'};

  ConversationState stateWithRows(
    List<int> rowIds, {
    String? epoch,
    int? firstRowId,
  }) =>
      ConversationState()
        ..rows = [for (final id in rowIds) row(id)]
        ..firstRowId = firstRowId
        ..logEpoch = epoch;

  /// A conversationRowsRangeV4 answer with the envelope the chat page
  /// consumes (rows + hasMore + atLogEpoch).
  Map<String, dynamic> olderPage(
    int from,
    int to, {
    bool? hasMore,
    String? atLogEpoch,
  }) =>
      {
        'rows': [for (int id = from; id <= to; id++) row(id)],
        if (hasMore != null) 'hasMore': hasMore,
        if (atLogEpoch != null) 'atLogEpoch': atLogEpoch,
      };

  group('entry gate (mutual exclusion)', () {
    test('beginLoad rejects without a state or session, gate untouched', () {
      final h = Harness()..current = null;
      expect(h.pager.beginLoad(null), isNull);
      expect(h.pager.beginLoad('s1'), isNull, reason: 'no state to page on');
      h.current = stateWithRows([10, 11]);
      expect(h.pager.beginLoad(null), isNull);
      expect(h.events, isEmpty, reason: 'a rejected entry never flips');
    });

    test('beginLoad rejects while a load is already in flight', () {
      final h = Harness()..current = stateWithRows([10, 11]);
      final first = h.pager.beginLoad('s1');
      expect(first, isNotNull);
      expect(h.events, ['gate:up']);
      expect(h.pager.loadingOlder, isTrue);
      expect(h.pager.beginLoad('s1'), isNull, reason: 're-entry blocked');
      expect(h.events, ['gate:up'], reason: 'no second flip');
    });

    test('beginLoad rejects while the re-entry gate is closed', () {
      final h = Harness()
        ..current = stateWithRows([10, 11])
        ..compensationPending = true;
      expect(h.pager.beginLoad('s1'), isNull);
      expect(h.events, isEmpty);
    });

    test('beginLoad hands the state captured at entry to settle', () {
      final h = Harness()..current = stateWithRows([10, 11]);
      final request = h.pager.beginLoad('s1');
      expect(request, isNotNull);
      expect(request!.sessionId, 's1');
      expect(identical(request.state, h.current), isTrue);
    });
  });

  group('cursor', () {
    test(
        'requests page back from the oldest held rowId, never the '
        'placeholder snapshot firstRowId', () async {
      final h = Harness()
        ..current = stateWithRows([100, 105, 111], firstRowId: 1)
        ..responses.add(olderPage(40, 99, hasMore: false));
      final request = h.pager.beginLoad('s1')!;
      await h.pager.settle(request);
      expect(h.calls, hasLength(1));
      expect(h.calls.single.beforeRowId, 100,
          reason: 'cursor = state.oldestRowId (live-probed placeholder trap)');
      expect(h.calls.single.limit, 60);
    });
  });

  group('settle decisions', () {
    test(
        'a fetched page proceeds: re-entry gate closes now, loading gate '
        'releases, prepend step arrives next frame', () async {
      final h = Harness()
        ..current = stateWithRows([100, 111], epoch: 'e1')
        ..responses.add(olderPage(40, 99, hasMore: true, atLogEpoch: 'e1'));
      final request = h.pager.beginLoad('s1')!;
      await h.pager.settle(request);
      expect(h.compensationPending, isTrue,
          reason: 'the re-entry gate closes in the same microtask, not at '
              'the prepend frame');
      expect(h.pager.loadingOlder, isFalse,
          reason: 'the finally releases the loading gate — the re-entry gate '
              'owns the window until the prepend');
      expect(h.events, ['gate:up', 'gate:down']);
      expect(h.frames, hasLength(1));
      h.runFrames();
      expect(h.events, [
        'gate:up',
        'gate:down',
        'step:HistoryProceed',
      ]);
    });

    test('the proceed step carries the page for the measurement chain',
        () async {
      final h = Harness()
        ..current = stateWithRows([100, 111], epoch: 'e1')
        ..responses.add(olderPage(40, 99, hasMore: true, atLogEpoch: 'e1'));
      await h.pager.settle(h.pager.beginLoad('s1')!);
      h.runFrames();
      final proceed = h.steps.whereType<HistoryProceed>().single;
      expect(proceed.hasMore, isTrue);
      expect(
        proceed.older.map((r) => r['rowId']),
        everyElement(inInclusiveRange(40, 99)),
      );
      expect(identical(proceed.state, h.current), isTrue);
    });

    test(
        'an epoch drift emits stale AND still proceeds (round 23: rows are '
        'immutable log entries)', () async {
      final h = Harness()
        ..current = stateWithRows([100, 111], epoch: 'e1')
        ..responses.add(olderPage(40, 99, hasMore: false, atLogEpoch: 'e2'));
      await h.pager.settle(h.pager.beginLoad('s1')!);
      h.runFrames();
      expect(
        h.events,
        containsAllInOrder(
            <String>['step:HistoryStale', 'step:HistoryProceed']),
      );
    });

    test(
        'identity guard: a page fetched on a since-replaced state is '
        'dropped silently, gate released, nothing scheduled', () async {
      final h = Harness()..current = stateWithRows([100, 111], epoch: 'e1');
      final request = h.pager.beginLoad('s1')!;
      // The resubscribe swaps the state out from under the in-flight fetch.
      h.responses.add(olderPage(40, 99, hasMore: true));
      final swapped = stateWithRows([50], epoch: 'e2');
      final first = h.current;
      h.current = swapped;
      await h.pager.settle(request);
      expect(h.events, ['gate:up', 'gate:down'],
          reason: 'no step of any kind — the page belongs to a state nobody '
              'shows');
      expect(h.frames, isEmpty);
      expect(identical(first, request.state), isTrue);
      expect(identical(swapped, h.current), isTrue);
    });

    test('an empty page writes hasMore (?? false) and reports noOlder',
        () async {
      final h = Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(<String, dynamic>{
          'rows': <dynamic>[],
          'hasMore': true,
        });
      await h.pager.settle(h.pager.beginLoad('s1')!);
      expect(h.events, ['gate:up', 'step:HistoryNoOlder', 'gate:down']);
      expect(h.current!.hasMore, isTrue,
          reason: 'hasMore is written even on the empty page');
      expect(h.frames, isEmpty);
    });

    test('a null-rows response follows the same noOlder path', () async {
      final h = Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add('garbage');
      await h.pager.settle(h.pager.beginLoad('s1')!);
      expect(h.events, contains('step:HistoryNoOlder'));
      expect(h.current!.hasMore, isFalse, reason: 'page.hasMore ?? false');
    });

    test('noOlder is suppressed when the state holds no rows at all', () async {
      final h = Harness()
        ..current = stateWithRows([])
        ..responses.add(<String, dynamic>{'rows': <dynamic>[]});
      await h.pager.settle(h.pager.beginLoad('s1')!);
      expect(h.events, ['gate:up', 'gate:down'],
          reason: 'no toast-worthy step on an empty session');
      expect(h.current!.hasMore, isNull, reason: 'hasMore untouched');
    });

    test('a fetch failure reports failed and releases the gate', () async {
      final h = Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(Exception('rpc down'));
      await h.pager.settle(h.pager.beginLoad('s1')!);
      expect(h.events, ['gate:up', 'step:HistoryFailed', 'gate:down']);
      expect(h.compensationPending, isFalse);
      expect(h.frames, isEmpty);
    });
  });

  group('DRAG HOLD parking and flush', () {
    test(
        'a page fetched mid-drag parks, keeps the loading gate up, closes '
        'no re-entry gate', () async {
      final h = Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 99, hasMore: true))
        ..scrollIdle = false;
      await h.pager.settle(h.pager.beginLoad('s1')!);
      expect(h.events, ['gate:up', 'step:HistoryHold'],
          reason: 'the hold is parked, the gate stays up — no duplicate '
              'fetch may fire');
      expect(h.pager.loadingOlder, isTrue);
      expect(h.compensationPending, isFalse);
      expect(h.frames, isEmpty);
    });

    test(
        'flushHeld releases the loading gate BEFORE the prepend step, in '
        'the same frame (round 14 ordering)', () async {
      final h = Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 99, hasMore: true))
        ..scrollIdle = false;
      await h.pager.settle(h.pager.beginLoad('s1')!);
      h.scrollIdle = true;
      h.frames.clear();
      h.events.clear();
      h.pager.flushHeld();
      expect(h.frames, hasLength(1));
      h.runFrames();
      expect(h.events, ['gate:down', 'step:HistoryProceed'],
          reason: 'the gate opens in the prepend frame, immediately before '
              'the prepend runs');
    });

    test(
        'flushHeld drops a held page whose state was replaced and releases '
        'the gate', () {
      final heldState = stateWithRows([100, 111]);
      final h = Harness()
        ..current = heldState
        ..scrollIdle = false;
      h.pager.parkPrependIfBusy(heldState, [row(40)], true);
      expect(h.pager.loadingOlder, isTrue);
      h.current = stateWithRows([50]); // resubscribe
      h.events.clear();
      h.pager.flushHeld();
      expect(h.events, ['gate:down'],
          reason: 'silent drop — no prepend, no step');
      expect(h.frames, isEmpty);
    });

    test('flushHeld waits a frame per pending compensation chain', () {
      final heldState = stateWithRows([100, 111]);
      final h = Harness()
        ..current = heldState
        ..compensationPending = true
        ..scrollIdle = false;
      h.pager.parkPrependIfBusy(heldState, [row(40)], true);
      h.events.clear();
      h.pager.flushHeld();
      expect(h.events, isEmpty, reason: 'still waiting');
      expect(h.frames, hasLength(1), reason: 're-checks next frame');
      h.compensationPending = false;
      h.runFrames();
      expect(h.events, ['gate:down', 'step:HistoryProceed']);
    });

    test('flushHeld without a parked page is a no-op', () {
      final h = Harness()..current = stateWithRows([100, 111]);
      h.pager.flushHeld();
      expect(h.events, isEmpty);
      expect(h.frames, isEmpty);
    });
  });

  group('prepend frame calls (measurement side)', () {
    test(
        'parkPrependIfBusy parks and re-raises the gate when the viewport '
        'moves', () {
      final state = stateWithRows([100, 111]);
      final h = Harness()
        ..current = state
        ..scrollIdle = false;
      expect(h.pager.loadingOlder, isFalse);
      expect(h.pager.parkPrependIfBusy(state, [row(40)], true), isTrue);
      expect(h.events, ['gate:up', 'step:HistoryHold'],
          reason: 'the prepend-frame recheck parks exactly like the arrival '
              'hold and raises the gate the finally had lowered');
      expect(h.pager.loadingOlder, isTrue);
    });

    test('parkPrependIfBusy is a no-op at a settled viewport', () {
      final state = stateWithRows([100, 111]);
      final h = Harness()..current = state;
      expect(h.pager.parkPrependIfBusy(state, [row(40)], true), isFalse);
      expect(h.events, isEmpty);
      expect(h.pager.loadingOlder, isFalse);
    });

    test(
        'commitPrepend bumps the generation, writes hasMore and returns '
        'the inserted count', () {
      final state = stateWithRows([100, 111]);
      final h = Harness()..current = state;
      expect(h.pager.anchorGeneration, 0,
          reason: 'settle/proceed alone never touches the generation — only '
              'the prepend commit does');
      final outcome = h.pager.commitPrepend(state, [row(40), row(50)], true);
      expect(outcome.generation, 1);
      expect(outcome.inserted, 2);
      expect(state.hasMore, isTrue);
      expect(state.rows.map((r) => r['rowId']), [40, 50, 100, 111]);
    });

    test(
        'a duplicate page answers inserted=0, still bumps the generation '
        'and writes hasMore, and reports duplicateDropped', () {
      final state = stateWithRows([100, 111]);
      final h = Harness()..current = state;
      h.pager.commitPrepend(state, [row(40)], true);
      h.events.clear();
      final outcome = h.pager.commitPrepend(state, [row(40)], false);
      expect(outcome.inserted, 0,
          reason: 'a re-fire that raced the prepend window dedupes to zero');
      expect(outcome.generation, 2,
          reason: 'the generation bumps before the duplicate verdict — the '
              'chain it would have served is stale either way');
      expect(state.hasMore, isFalse,
          reason: 'the hasMore write-back precedes the duplicate check');
      expect(state.rows.map((r) => r['rowId']), [40, 100, 111],
          reason: 'no content shift — anchoring a no-op prepend is forbidden');
      expect(h.events, ['step:HistoryDuplicateDropped']);
    });

    test('a superseded chain detects staleness against the pager counter', () {
      final state = stateWithRows([100, 111]);
      final h = Harness()..current = state;
      final first = h.pager.commitPrepend(state, [row(40)], true);
      final second = h.pager.commitPrepend(state, [row(30)], true);
      expect(first.generation, 1);
      expect(second.generation, 2);
      expect(first.generation != h.pager.anchorGeneration, isTrue,
          reason: 'chain one is stale: only the newest page may still land');
    });
  });
}
