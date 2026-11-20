import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/ui/chat/transcript_viewport.dart';
import 'package:zgo/ui/chat/timeline.dart';

/// Controller-level tests for [TranscriptViewport] (task
/// 10-29-transcript-viewport): the 23 history-pager decisions migrated to the
/// viewport's seams (`coverage-map.md` maps them one by one) plus the
/// compensation chain driven through a fake measurement port and a landing
/// sink. No widget tree: frames, gateway answers and measurements are plain
/// closures the tests drive.
class _FakeMeasure implements TranscriptMeasurePort {
  ({double top, double height})? viewport = (top: 0, height: 500);
  List<GroupMeasurement> groups = const [];
  Map<Key, ({double top, double height})> rowBoxes = const {};
  ScrollSample scroll =
      (pixels: 0, maxScrollExtent: 10000, viewportDimension: 500);

  @override
  ({double top, double height})? viewportBox() => viewport;

  @override
  List<GroupMeasurement> builtGroups() => groups;

  @override
  ({double top, double height})? rowBox(Key rowKey) => rowBoxes[rowKey];

  @override
  ScrollSample position() => scroll;

  @override
  List<List<Map<String, dynamic>>> groupRows(
          List<Map<String, dynamic>> rows) =>
      groupChatRows(rows);
}

/// Test rig: every injected seam records into one ordered [events] log so
/// gate/toast interleavings are assertable; [frames] queues post-frame
/// callbacks for manual pumping and [landings] records the compensation's
/// dispatch (duration null = jump).
class _Harness {
  final events = <String>[];
  final toasts = <HistoryToastStep>[];
  final frames = <void Function()>[];
  final responses = <Object?>[];
  final calls = <({int? beforeRowId, int limit})>[];
  final landings = <({double target, Duration? duration})>[];
  final measure = _FakeMeasure();
  ConversationState? current;
  String? sessionId = 's1';
  bool stickToBottom = false;
  int captures = 0;

  /// Runs inside the capture seam (the async GPU read-back window) — lets a
  /// test simulate a drag that starts mid-capture.
  void Function()? duringCapture;

  late final TranscriptViewport viewport = TranscriptViewport(
    fetch: (sessionId, {beforeRowId, limit = 60}) async {
      calls.add((beforeRowId: beforeRowId, limit: limit));
      final answer = responses.removeAt(0);
      if (answer is Exception) throw answer;
      return answer;
    },
    currentState: () => current,
    currentSessionId: () => sessionId,
    isStickToBottom: () => stickToBottom,
    listBottomPadding: 8,
    onToast: (step) {
      toasts.add(step);
      events.add('toast:${step.runtimeType}');
    },
    postFrame: frames.add,
    measure: measure,
    capture: () async {
      captures++;
      duringCapture?.call();
      return null;
    },
    landing: (target, {duration}) =>
        landings.add((target: target, duration: duration)),
  );

  _Harness() {
    viewport.addListener(() {
      events.add('gate:${viewport.loadingOlder ? 'up' : 'down'}');
    });
  }

  /// Runs the next queued post-frame callback WITHOUT draining the
  /// microtasks it schedules — for "the gate opens before the prepend runs"
  /// style ordering asserts.
  void runFrameSync() {
    expect(frames, isNotEmpty, reason: 'no frame queued');
    frames.removeAt(0)();
  }

  Future<void> flushMicrotasks() => Future<void>.delayed(Duration.zero);

  /// Runs exactly one post-frame callback plus the microtasks it schedules
  /// (the async capture / fetch continuations).
  Future<void> pumpOne() async {
    runFrameSync();
    await flushMicrotasks();
  }

  /// Drains queued post-frame callbacks, flushing microtasks between frames
  /// (a callback may queue more).
  Future<void> runFrames() async {
    var guard = 0;
    while (frames.isNotEmpty) {
      if (guard++ > 200) fail('frame queue never drains');
      await pumpOne();
    }
  }

  void dispose() => viewport.dispose();
}

/// A context the synthetic notifications carry — identity routing is skipped
/// without an attached controller, so nothing ever reads it.
class _FakeContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Map<String, dynamic> row(int id, {String kind = 'assistantText'}) =>
      {'rowId': id, 'kind': kind};

  ConversationState stateWithRows(
    List<int> rowIds, {
    String? epoch,
    int? firstRowId,
  }) =>
      ConversationState()
        ..rows = [for (final id in rowIds) row(id)]
        ..firstRowId = firstRowId
        ..logEpoch = epoch;

  /// A conversationRowsRangeV4 answer with the envelope the viewport
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

  GroupMeasurement measuredGroup(int rowId,
          {double top = 0, double height = 100}) => (
        key: ValueKey('turn-$rowId'),
        rows: [row(rowId)],
        top: top,
        height: height,
      );

  ScrollMetrics metrics({double pixels = 0}) => FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 10000,
        pixels: pixels,
        viewportDimension: 500,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      );

  /// A user drag starts (identity routing is skipped without an attached
  /// controller — these tests drive the notification route directly).
  void dragStart(_Harness h) => h.viewport.onScrollNotification(
        ScrollStartNotification(
          metrics: metrics(),
          context: _FakeContext(),
          dragDetails: DragStartDetails(),
        ),
      );

  /// A PROGRAMMATIC scroll (jumpTo / animateTo) starts: `dragDetails == null`
  /// is the wire verdict the viewport reads as `_positioning`.
  void programmaticStart(_Harness h) => h.viewport.onScrollNotification(
        ScrollStartNotification(metrics: metrics(), context: _FakeContext()),
      );

  void dragEnd(_Harness h) => h.viewport.onScrollNotification(
        ScrollEndNotification(metrics: metrics(), context: _FakeContext()),
      );

  group('entry gate (mutual exclusion)', () {
    test('loadOlder rejects without a state or session, gate untouched',
        () async {
      final h = _Harness()..current = null;
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      expect(h.events, isEmpty);
      expect(h.frames, isEmpty);

      h.current = stateWithRows([10, 11]);
      h.sessionId = null;
      await h.viewport.loadOlder();
      expect(h.events, isEmpty, reason: 'no session to page on');
      expect(h.frames, isEmpty);
    });

    test('loadOlder rejects while a load is already in flight', () async {
      final h = _Harness()..current = stateWithRows([10, 11]);
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      expect(h.events, ['gate:up']);
      expect(h.viewport.loadingOlder, isTrue);
      await h.viewport.loadOlder();
      expect(h.events, ['gate:up'], reason: 'no second flip');
      expect(h.frames, hasLength(1), reason: 'no second fetch scheduled');
    });

    test('loadOlder rejects while the re-entry gate is closed', () async {
      final h = _Harness()
        ..current = stateWithRows([10, 11])
        ..responses.add(olderPage(1, 9, hasMore: true));
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.pumpOne(); // settle: the re-entry gate closes, prepend queued
      expect(h.viewport.compensationInFlight, isTrue);
      expect(h.viewport.loadingOlder, isFalse);

      await h.viewport.loadOlder();
      expect(h.calls, hasLength(1), reason: 're-entry blocked');
      expect(h.frames, hasLength(1), reason: 'only the prepend frame');
    });

    test('loadOlder hands the state captured at entry to the fetch', () async {
      final h = _Harness()..current = stateWithRows([10, 11]);
      addTearDown(h.dispose);
      final captured = h.current;
      h.responses.add(olderPage(1, 9, hasMore: true));
      await h.viewport.loadOlder();
      expect(identical(captured, h.current), isTrue);
      await h.runFrames();
      expect(h.current!.rows.map((r) => r['rowId']).first, 1);
    });
  });

  group('cursor', () {
    test(
        'requests page back from the oldest held rowId, never the '
        'placeholder snapshot firstRowId', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 105, 111], firstRowId: 1)
        ..responses.add(olderPage(40, 99, hasMore: false));
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.runFrames();
      expect(h.calls, hasLength(1));
      expect(h.calls.single.beforeRowId, 100,
          reason: 'cursor = state.oldestRowId (live-probed placeholder trap)');
      expect(h.calls.single.limit, 60);
    });
  });

  group('settle decisions', () {
    test(
        'a fetched page proceeds: re-entry gate closes now, loading gate '
        'releases, the prepend applies next frame', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111], epoch: 'e1')
        ..responses.add(olderPage(40, 99, hasMore: true, atLogEpoch: 'e1'));
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.pumpOne(); // the settle body only
      expect(h.viewport.compensationInFlight, isTrue,
          reason: 'the re-entry gate closes in the same microtask, not at '
              'the prepend frame');
      expect(h.viewport.loadingOlder, isFalse,
          reason: 'the finally releases the loading gate — the re-entry gate '
              'owns the window until the prepend');
      expect(h.events, ['gate:up', 'gate:down']);
      expect(h.frames, hasLength(1));
      expect(h.current!.rows.map((r) => r['rowId']), [100, 111],
          reason: 'the page lands on the queued frame, not in settle');
      await h.runFrames();
      expect(h.current!.rows.map((r) => r['rowId']),
          [for (var i = 40; i <= 99; i++) i, 100, 111]);
      expect(h.viewport.compensationInFlight, isFalse,
          reason: 'no measurable anchor releases the gate');
    });

    test('the applied page carries rows and the hasMore write-back',
        () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111], epoch: 'e1')
        ..responses.add(olderPage(40, 99, hasMore: true, atLogEpoch: 'e1'));
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.runFrames();
      expect(h.current!.rows.first['rowId'], 40);
      expect(h.current!.rows.length, 62);
      expect(h.current!.hasMore, isTrue);
    });

    test(
        'an epoch drift toasts stale AND still proceeds (round 23: rows are '
        'immutable log entries)', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111], epoch: 'e1')
        ..responses.add(olderPage(40, 99, hasMore: false, atLogEpoch: 'e2'));
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.runFrames();
      expect(h.events,
          containsAllInOrder(<String>['toast:HistoryStale', 'gate:down']));
      expect(h.current!.rows.first['rowId'], 40, reason: 'applied anyway');
    });

    test(
        'identity guard: a page fetched on a since-replaced state is '
        'dropped silently, gate released, nothing scheduled', () async {
      final h = _Harness()..current = stateWithRows([100, 111], epoch: 'e1');
      addTearDown(h.dispose);
      final first = h.current;
      await h.viewport.loadOlder();
      // The resubscribe swaps the state out under the in-flight fetch.
      h.current = stateWithRows([50], epoch: 'e2');
      h.responses.add(olderPage(40, 99, hasMore: true));
      await h.runFrames();
      expect(h.events, ['gate:up', 'gate:down'],
          reason: 'no toast of any kind — the page belongs to a state nobody '
              'shows');
      expect(h.current!.rows.map((r) => r['rowId']), [50]);
      expect(identical(first, h.current), isFalse);
    });

    test('an empty page writes hasMore (?? false) and reports noOlder',
        () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(<String, dynamic>{
          'rows': <dynamic>[],
          'hasMore': true,
        });
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.runFrames();
      expect(h.events, ['gate:up', 'toast:HistoryNoOlder', 'gate:down']);
      expect(h.current!.hasMore, isTrue,
          reason: 'hasMore is written even on the empty page');
    });

    test('a null-rows response follows the same noOlder path', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add('garbage');
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.runFrames();
      expect(h.events, contains('toast:HistoryNoOlder'));
      expect(h.current!.hasMore, isFalse, reason: 'page.hasMore ?? false');
    });

    test('noOlder is suppressed when the state holds no rows at all',
        () async {
      final h = _Harness()
        ..current = stateWithRows([])
        ..responses.add(<String, dynamic>{'rows': <dynamic>[]});
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.runFrames();
      expect(h.events, ['gate:up', 'gate:down'],
          reason: 'no toast-worthy step on an empty session');
      expect(h.current!.hasMore, isNull, reason: 'hasMore untouched');
    });

    test('a fetch failure reports failed and releases the gate', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(Exception('rpc down'));
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.runFrames();
      expect(h.events, ['gate:up', 'toast:HistoryFailed', 'gate:down']);
      expect(h.viewport.compensationInFlight, isFalse);
      expect(h.frames, isEmpty);
    });
  });

  group('programmatic positioning (A7: the host pin samples its own glide)', () {
    test('a programmatic scroll start/end brackets isPositioning', () {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(h.viewport.isPositioning, isFalse);
      programmaticStart(h);
      expect(h.viewport.isPositioning, isTrue,
          reason: 'the host must be able to tell its own glide from the '
              'reader\'s motion');
      dragEnd(h);
      expect(h.viewport.isPositioning, isFalse);
    });

    test('a user drag takes the viewport back from a programmatic glide', () {
      final h = _Harness();
      addTearDown(h.dispose);
      programmaticStart(h);
      expect(h.viewport.isPositioning, isTrue);

      dragStart(h); // the reader grabs mid-glide
      expect(h.viewport.isPositioning, isFalse,
          reason: 'a drag start clears the programmatic verdict, so the pin '
              'flips on the reader\'s own updates again (round 8)');
      expect(h.viewport.canJumpToQuery, isFalse);
    });
  });

  group('DRAG HOLD parking and flush', () {
    test(
        'a page fetched mid-drag parks, keeps the loading gate up, closes '
        'no re-entry gate', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 99, hasMore: true));
      addTearDown(h.dispose);
      dragStart(h);
      await h.viewport.loadOlder();
      await h.runFrames();
      expect(h.events, ['gate:up'],
          reason: 'the hold is parked, the gate stays up — no duplicate '
              'fetch may fire');
      expect(h.viewport.loadingOlder, isTrue);
      expect(h.viewport.compensationInFlight, isFalse);
      expect(h.current!.rows.map((r) => r['rowId']), [100, 111]);
    });

    test(
        'flushHeld releases the loading gate BEFORE the prepend runs, in '
        'the same frame (round 14 ordering)', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 99, hasMore: true));
      addTearDown(h.dispose);
      dragStart(h);
      await h.viewport.loadOlder();
      await h.runFrames();
      h.events.clear();

      dragEnd(h); // ScrollEnd -> flushHeld queues the prepend frame
      expect(h.frames, hasLength(1));
      h.runFrameSync();
      expect(h.events, ['gate:down'],
          reason: 'the gate opens in the prepend frame, immediately before '
              'the prepend runs');
      expect(h.current!.rows.map((r) => r['rowId']), [100, 111],
          reason: 'the async capture runs after the gate flip');
      await h.flushMicrotasks();
      await h.runFrames();
      expect(h.current!.rows.first['rowId'], 40);
    });

    test(
        'flushHeld drops a held page whose state was replaced and releases '
        'the gate', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 99, hasMore: true));
      addTearDown(h.dispose);
      dragStart(h);
      await h.viewport.loadOlder();
      await h.runFrames();
      h.current = stateWithRows([50]); // resubscribe
      h.events.clear();

      dragEnd(h);
      await h.flushMicrotasks();
      expect(h.events, ['gate:down'],
          reason: 'silent drop — no prepend, no toast');
      expect(h.frames, isEmpty);
      expect(h.current!.rows.map((r) => r['rowId']), [50]);
    });

    test('flushHeld defers while a compensation chain is in flight',
        () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 99, hasMore: true));
      addTearDown(h.dispose);
      h.measure.groups = [measuredGroup(100, top: 100)];
      await h.viewport.loadOlder();
      await h.pumpOne(); // settle: re-entry gate closed, prepend queued

      dragStart(h); // a drag starts in the gap: the prepend parks
      await h.pumpOne();
      expect(h.viewport.loadingOlder, isTrue);
      expect(h.viewport.compensationInFlight, isTrue);
      h.events.clear();

      h.viewport.flushHeld();
      expect(h.frames, hasLength(1), reason: 're-checks next frame');
      expect(h.events, isEmpty, reason: 'still waiting');
      expect(h.current!.rows.map((r) => r['rowId']), [100, 111],
          reason: 'nothing applied while the gate is closed');
    });

    test('flushHeld without a parked page is a no-op', () {
      final h = _Harness()..current = stateWithRows([100, 111]);
      addTearDown(h.dispose);
      h.viewport.flushHeld();
      expect(h.events, isEmpty);
      expect(h.frames, isEmpty);
    });
  });

  group('prepend frame calls (measurement side)', () {
    test(
        'the prepend frame parks and re-raises the gate when the viewport '
        'moves', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 99, hasMore: true));
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.pumpOne(); // settle: the finally lowers the gate
      expect(h.viewport.loadingOlder, isFalse);
      expect(h.viewport.compensationInFlight, isTrue);

      dragStart(h);
      await h.pumpOne(); // the prepend frame re-checks and parks
      expect(h.viewport.loadingOlder, isTrue,
          reason: 'the gate the finally lowered is raised back');
      expect(h.current!.rows.map((r) => r['rowId']), [100, 111]);
      expect(h.frames, isEmpty);
    });

    test(
        'the prepend frame re-checks the hold AFTER the async capture '
        '(round 16)', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 99, hasMore: true));
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.pumpOne(); // settle: the finally lowers the gate
      expect(h.viewport.loadingOlder, isFalse);

      // The finger goes down while the GPU read-back is in flight.
      h.duringCapture = () => dragStart(h);
      await h.pumpOne(); // prepend frame: capture, then the recheck parks
      expect(h.captures, 1);
      expect(h.viewport.loadingOlder, isTrue,
          reason: 'parked after the capture, gate re-armed');
      expect(h.current!.rows.map((r) => r['rowId']), [100, 111]);
      expect(h.frames, isEmpty);
    });

    test(
        'the prepend frame is a no-op at a settled viewport (the page '
        'applies)', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 99, hasMore: true));
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.runFrames();
      expect(h.current!.rows.first['rowId'], 40);
      expect(h.viewport.loadingOlder, isFalse);
      expect(h.viewport.compensationInFlight, isFalse);
    });

    test(
        'the prepend commit bumps the generation, writes hasMore and '
        'prepends the page', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 50, hasMore: true));
      addTearDown(h.dispose);
      expect(h.viewport.anchorGeneration, 0,
          reason: 'settle/proceed alone never touches the generation — only '
              'the prepend commit does');
      await h.viewport.loadOlder();
      await h.runFrames();
      expect(h.viewport.anchorGeneration, 1);
      expect(h.current!.hasMore, isTrue);
      expect(h.current!.rows.map((r) => r['rowId']),
          [40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 100, 111]);
    });

    test(
        'a duplicate page answers zero inserts, still bumps the generation, '
        'writes hasMore, and drops without anchoring', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 50, hasMore: true));
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.runFrames();
      final afterFirst = h.current!.rows.length;

      // A re-fire that raced the prepend window returns the SAME page.
      h.responses.add(olderPage(40, 50, hasMore: false));
      await h.viewport.loadOlder();
      await h.runFrames();
      expect(h.viewport.anchorGeneration, 2,
          reason: 'the generation bumps before the duplicate verdict — the '
              'chain it would have served is stale either way');
      expect(h.current!.hasMore, isFalse,
          reason: 'the hasMore write-back precedes the duplicate check');
      expect(h.current!.rows.length, afterFirst,
          reason: 'no content shift — anchoring a no-op prepend is forbidden');
      expect(h.viewport.compensationInFlight, isFalse,
          reason: 'the duplicate branch releases the re-entry gate');
      expect(h.viewport.veil.value.phase, TranscriptVeilPhase.none);
      expect(h.landings, isEmpty);
    });

    test('a superseded chain detects staleness against the counter', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 50, hasMore: true))
        ..responses.add(olderPage(20, 39, hasMore: true));
      addTearDown(h.dispose);
      await h.viewport.loadOlder();
      await h.runFrames();
      final firstGeneration = h.viewport.anchorGeneration;
      await h.viewport.loadOlder();
      await h.runFrames();
      expect(firstGeneration, 1);
      expect(h.viewport.anchorGeneration, 2);
      expect(firstGeneration != h.viewport.anchorGeneration, isTrue,
          reason: 'chain one is stale: only the newest page may still land');
    });
  });

  group('compensation (controller-level landing)', () {
    test('a reading prepend lands by the measured anchor delta', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 99, hasMore: true));
      addTearDown(h.dispose);
      // Pre-prepend layout: the anchor group sits 100px below the viewport
      // top, the offset is 500.
      h.measure.groups = [measuredGroup(100, top: 100)];
      h.measure.scroll =
          (pixels: 500, maxScrollExtent: 10000, viewportDimension: 500);
      await h.viewport.loadOlder();
      await h.pumpOne(); // settle
      await h.pumpOne(); // prepend frame: measure + commit + queue landing

      // Post-prepend layout: the prepend pushed the same group to 600.
      h.measure.groups = [measuredGroup(100, top: 600)];
      h.measure.scroll =
          (pixels: 500, maxScrollExtent: 10600, viewportDimension: 500);
      await h.pumpOne(); // landing frame

      expect(h.landings, hasLength(1));
      expect(h.landings.single.target, 1000,
          reason: 'pixels + (top - viewportTop - dy) = 500 + 600 - 100');
      expect(h.landings.single.duration, const Duration(milliseconds: 96),
          reason: 'a 500px correction eases instead of teleporting');
      expect(h.viewport.compensationInFlight, isFalse);
      expect(h.viewport.anchorCacheExtent, isNull);
    });

    test('a pinned prepend lands the newest group on the true content end',
        () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 99, hasMore: true))
        ..stickToBottom = true;
      addTearDown(h.dispose);
      // Two groups: the reading anchor is 'turn-100', the pinned landing
      // target is the newest 'turn-111'.
      h.current!.rows = [row(100, kind: 'userInput'), row(111)];
      h.measure.groups = [measuredGroup(100, top: 100)];
      h.measure.scroll =
          (pixels: 500, maxScrollExtent: 10000, viewportDimension: 500);
      await h.viewport.loadOlder();
      await h.pumpOne();
      await h.pumpOne();

      // After the prepend the newest group's box bottom sits 100px below
      // the viewport bottom (0 + 500).
      h.measure.groups = [
        measuredGroup(40, top: 0),
        measuredGroup(111, top: 520, height: 80),
      ];
      h.measure.scroll =
          (pixels: 500, maxScrollExtent: 10600, viewportDimension: 500);
      await h.pumpOne();

      expect(h.landings, hasLength(1));
      expect(h.landings.single.target, 608,
          reason: 'pixels + (boxBottom - viewportBottom) + paddingBottom '
              '= 500 + (600 - 500) + 8');
      expect(h.landings.single.duration, isNull,
          reason: 'pinned landings snap');
    });

    test(
        'an anchor that is not built at hop 0 widens the cache for one '
        'frame, then lands measured', () async {
      final h = _Harness()
        ..current = stateWithRows([100, 111])
        ..responses.add(olderPage(40, 99, hasMore: true));
      addTearDown(h.dispose);
      h.measure.groups = [measuredGroup(100, top: 100)];
      h.measure.scroll =
          (pixels: 500, maxScrollExtent: 10000, viewportDimension: 500);
      await h.viewport.loadOlder();
      await h.pumpOne();
      await h.pumpOne();

      // Only an unrelated group is laid out: the anchor is beyond the cache.
      h.measure.groups = [measuredGroup(999, top: 0)];
      h.measure.scroll =
          (pixels: 500, maxScrollExtent: 10600, viewportDimension: 500);
      await h.pumpOne(); // hop 0: widen the cache
      expect(h.landings, isEmpty);
      expect(h.viewport.anchorCacheExtent, 1700,
          reason: '(max - baseMax) * 2 + viewportHeight = 600 * 2 + 500');

      h.measure.groups = [measuredGroup(100, top: 600)];
      await h.pumpOne(); // hop 1: measured landing
      expect(h.landings, hasLength(1));
      expect(h.landings.single.target, 1000);
      expect(h.viewport.anchorCacheExtent, isNull);
    });

    test(
      'a drag at hop 0 drops the widened cache, and the release landing is '
      'unchanged (prepend → drag → release → prepend)',
      () async {
        final h = _Harness()..current = stateWithRows([100, 111]);
        addTearDown(h.dispose);
        h.measure.groups = [measuredGroup(100, top: 100)];
        h.measure.scroll =
            (pixels: 500, maxScrollExtent: 10000, viewportDimension: 500);

        // First prepend + landing arms the pre-widen (measured delta 500).
        h.responses.add(olderPage(40, 99, hasMore: true));
        await h.viewport.loadOlder();
        await h.pumpOne(); // settle: prepend frame queued
        await h.pumpOne(); // prepend frame: commit + queue the landing
        h.measure.groups = [measuredGroup(100, top: 600)];
        h.measure.scroll =
            (pixels: 500, maxScrollExtent: 10600, viewportDimension: 500);
        await h.pumpOne(); // landing hop 0
        expect(h.landings.single.target, 1000);
        expect(h.viewport.compensationInFlight, isFalse);

        // Second prepend: the cache is widened from the measured delta.
        h.responses.add(olderPage(20, 39, hasMore: true));
        await h.viewport.loadOlder();
        await h.pumpOne(); // settle
        await h.pumpOne(); // prepend frame
        expect(h.viewport.anchorCacheExtent, 1500,
            reason: 'preWiden = measuredDelta 500 × 2 + viewport 500');

        // A drag arrives before the chain measures. The hop-0 wait branch
        // drops the wide window (the whole point of task 11-19 step 2) and
        // keeps the chain parked on the finger.
        dragStart(h);
        await h.pumpOne();
        expect(h.viewport.anchorCacheExtent, isNull,
            reason: 'a drag must not keep laying out the widened window');
        expect(h.viewport.compensationInFlight, isTrue,
            reason: 'the chain waits for the release, it does not land');

        // Release: the chain re-measures and lands exactly as before —
        // pixels 500 + (top 1200 − viewportTop 0 − dy 600).
        dragEnd(h);
        h.measure.groups = [
          measuredGroup(40, top: 0),
          measuredGroup(100, top: 1200),
        ];
        h.measure.scroll =
            (pixels: 500, maxScrollExtent: 11200, viewportDimension: 500);
        await h.pumpOne();
        expect(h.landings, hasLength(2));
        expect(h.landings.last.target, 1100,
            reason: 'measured landing unchanged by the cleared cache');
        expect(h.viewport.anchorCacheExtent, isNull);
        expect(h.viewport.compensationInFlight, isFalse);

        // A THIRD prepend after the drag parks nothing stale: the cache is
        // re-widened on demand from the freshly measured delta (600).
        h.responses.add(olderPage(10, 19, hasMore: true));
        await h.viewport.loadOlder();
        await h.pumpOne(); // settle
        await h.pumpOne(); // prepend frame
        expect(h.viewport.anchorCacheExtent, 1700,
            reason: 'measuredDelta 600 × 2 + viewport 500');
      },
    );

    test('a drag mid-hop keeps the widened cache so the landing is not '
        'downgraded to the give-up estimate', () async {
      final h = _Harness()..current = stateWithRows([100, 111]);
      addTearDown(h.dispose);
      h.measure.groups = [measuredGroup(100, top: 100)];
      h.measure.scroll =
          (pixels: 500, maxScrollExtent: 10000, viewportDimension: 500);

      h.responses.add(olderPage(40, 99, hasMore: true));
      await h.viewport.loadOlder();
      await h.pumpOne(); // settle
      await h.pumpOne(); // prepend frame (no pre-widen yet: no measured delta)

      // Hop 0 finds no anchor and widens the window for hop 1.
      h.measure.groups = [measuredGroup(999, top: 0)];
      h.measure.scroll =
          (pixels: 500, maxScrollExtent: 10600, viewportDimension: 500);
      await h.pumpOne();
      expect(h.viewport.anchorCacheExtent, 1700);

      // The drag arrives while hop 1 is pending: the wide window is what
      // keeps the anchor laid out, so the wait branch keeps it.
      dragStart(h);
      await h.pumpOne();
      expect(h.viewport.anchorCacheExtent, 1700,
          reason: 'mid-hop must not clear the window the hunt depends on');
      expect(h.viewport.compensationInFlight, isTrue);

      // Release: hop 1 measures and lands; only the terminal exit clears.
      dragEnd(h);
      h.measure.groups = [measuredGroup(100, top: 600)];
      await h.pumpOne();
      expect(h.landings.single.target, 1000);
      expect(h.viewport.anchorCacheExtent, isNull);
    });
  });
}
