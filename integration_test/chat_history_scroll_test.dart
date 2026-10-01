// History scroll/paging acceptance on a real rendering pipeline (emulator).
//
// The pager's decisions are covered by unit/widget tests under a synthetic
// clock with uniform row heights; what those cannot exercise is real-frame
// layout + ballistic timing under high row-height variance — exactly where
// the SliverList extent estimate drifts by whole pages (device lesson
// 2026-09-22: maxScrollExtent after a big prepend is an estimate, jumpTo is
// not boundary-clamped). This test pumps the REAL ChatPage on a real device
// surface through every load trigger — open auto-load, in-window drag
// prefetch, fling coast, top pull-release — across seven pages with
// deliberately wild height variance, asserting after each page:
//
//   1. exactly one rowsRange call per trigger (no duplicate-fire loops),
//   2. the reading anchor survives the prepend (visible-set overlap),
//   3. the offset stays inside [0, maxScrollExtent] (no overshoot blank),
//   4. a final pixel screenshot rides reportData for host-side eyeballing.
//
//   ZGO_SHOT_DIR=build/shots flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/chat_history_scroll_test.dart -d <device>
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../test/helpers/recording_chat_gateway.dart';

final _shotKey = GlobalKey();

Widget _wrap(Widget child) => RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: child,
      ),
    );

/// Variance-page rows: every 5th row ~24 lines, every 5th+3 ~8 lines, the
/// rest single-line — height spread far beyond what the mean-height extent
/// estimate can approximate on a phone-width viewport.
List<Map<String, dynamic>> varianceRows(int from, int to) => [
      for (var i = from; i <= to; i++)
        if (i % 5 == 0)
          {
            'rowId': i,
            'kind': 'userInput',
            'text': List.generate(24, (l) => '历史消息 $i 行 $l').join('\n'),
          }
        else if (i % 5 == 3)
          {
            'rowId': i,
            'kind': 'userInput',
            'text': List.generate(8, (l) => '历史消息 $i 行 $l').join('\n'),
          }
        else
          {'rowId': i, 'kind': 'userInput', 'text': '历史消息 $i'},
    ];

/// Tall-head page: the OLDEST row is a ~70-line message, the rest uniform
/// single-liners — the extent-estimate killer (laid-out mean wildly
/// mispredicts the un-laid tail, the exact 09-22 device failure shape).
List<Map<String, dynamic>> tallHeadRows(int from, int to) => [
      {
        'rowId': from,
        'kind': 'userInput',
        'text': List.generate(70, (l) => '历史消息 $from 行 $l').join('\n'),
      },
      for (var i = from + 1; i <= to; i++)
        {'rowId': i, 'kind': 'userInput', 'text': '历史消息 $i'},
    ];

Map<String, dynamic> page(
  List<Map<String, dynamic>> rows, {
  required bool hasMore,
}) =>
    {
      'atLogEpoch': 'e1',
      'hasMore': hasMore,
      'rows': {'window': rows},
    };

/// Message texts currently built inside the list viewport — the "what the
/// reader sees" set. User bubbles render as SelectableText; the row text
/// may flow into Text children, so collect both and match by prefix.
Set<String> visibleMessages(WidgetTester tester) => {
      for (final w in tester.widgetList<SelectableText>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(SelectableText),
        ),
      ))
        w.data,
      for (final w in tester.widgetList<Text>(
        find.descendant(of: find.byType(ListView), matching: find.byType(Text)),
      ))
        w.data,
    }.whereType<String>().where((t) => t.startsWith('历史消息')).toSet();

ScrollController historyController(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!;

int rowsRangeCalls(RecordingChatGateway gateway) =>
    gateway.calls.where((c) => c.$1 == 'rowsRange').length;

double prefetchThreshold(ScrollController controller) =>
    math.max(64.0, controller.position.viewportDimension * 2);

/// Park INSIDE the prefetch window (a programmatic jump does not count as
/// user-driven — by design), then drag through stepped moves and HOLD
/// before lifting — a single huge moveBy hands the velocity tracker one
/// giant sample and the release flings to the top, pinning the anchor at
/// the page head (observed on emulator). The armed set is captured at the
/// HOLD (finger down, page parked by the DRAG HOLD note in
/// HistoryPager.settle) — the reading position the anchor must keep: the
/// drag itself is legitimate reading motion, so a set captured at the
/// parked pre-drag position would assert against rows the reader already
/// scrolled away from.
Future<Set<String>> dragPrefetch(
  WidgetTester tester,
  ScrollController controller, {
  double extra = 600,
}) async {
  final threshold = prefetchThreshold(controller);
  controller.jumpTo(threshold + extra);
  await tester.pumpAndSettle();
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(ListView)),
  );
  await tester.pump();
  final total = extra + threshold / 2;
  final steps = 8;
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(0, total / steps));
    await tester.pump(const Duration(milliseconds: 24));
  }
  await tester.pump(const Duration(milliseconds: 120)); // hold: zero release velocity
  final armed = visibleMessages(tester);
  await gesture.up();
  await tester.pumpAndSettle();
  return armed;
}

/// Fling from just above the window: the applied drag stays outside, the
/// ballistic coast crosses in and prefetches (快速上翻 AC). The coast moves
/// the reading position before the fetch lands, so the anchor assertion is
/// call-count + in-range + non-empty — NOT overlap with a pre-fling set.
Future<void> flingPrefetch(
  WidgetTester tester,
  ScrollController controller, {
  double extra = 400,
}) async {
  final threshold = prefetchThreshold(controller);
  controller.jumpTo(threshold + extra);
  await tester.pumpAndSettle();
  await tester.fling(
    find.byType(ListView),
    const Offset(0, 300),
    2000,
    warnIfMissed: false,
  );
  await tester.pumpAndSettle();
}

/// Park at the top, then pull past the 64px threshold and release: the
/// release frame fires the load. Returns the armed set captured AT the
/// overscrolled hold (the top rows under the reader's finger) — the
/// pull-landing must keep them on screen (round-23: reading continues UP
/// INTO the fresh page from there).
Future<Set<String>> pullLoad(
  WidgetTester tester,
  ScrollController controller,
) async {
  controller.jumpTo(0);
  await tester.pumpAndSettle();
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(ListView)),
  );
  await tester.pump();
  await gesture.moveBy(const Offset(0, 300));
  await tester.pump();
  expect(controller.offset, lessThan(-64.0),
      reason: 'content follows the finger past the pull threshold');
  final armed = visibleMessages(tester);
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pumpAndSettle();
  return armed;
}

/// Push a PNG through reportData['screenshots'] (the custom driver unpacks
/// them into ZGO_SHOT_DIR). Android image-surface mode only — call after
/// convertFlutterSurfaceToImage, which disables pumpAndSettle (end of test).
Future<void> _reportShot(String name) async {
  final boundary =
      _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final report = IntegrationTestWidgetsFlutterBinding.instance.reportData ??=
      <String, dynamic>{};
  final shots =
      (report['screenshots'] as List<dynamic>? ?? <dynamic>[]).toList();
  shots.add({'screenshotName': name, 'bytes': data!.buffer.asUint8List()});
  report['screenshots'] = shots;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('history: seven high-variance pages load through every '
      'trigger without losing the reading anchor', (tester) async {
    final gateway = RecordingChatGateway();
    // Seeded window: rows 400..445 (variance heights), older pages queued —
    // entry 0 goes to the open auto-load. Snapshot is fed BEFORE mounting
    // (the open auto-load reads canLoadOlder inside the subscribe
    // continuation, which runs before a post-mount feed would land).
    gateway.rowsRangeResults.addAll([
      page(tallHeadRows(340, 399), hasMore: true), // p1: open auto-load
      page(varianceRows(280, 339), hasMore: true), // p2: drag prefetch
      page(tallHeadRows(220, 279), hasMore: true), // p3: fling coast
      page(varianceRows(160, 219), hasMore: true), // p4: pull release
      page(tallHeadRows(100, 159), hasMore: true), // p5: drag prefetch
      page(varianceRows(40, 99), hasMore: true), // p6: fling coast
      page(tallHeadRows(1, 39), hasMore: false), // p7: pull release
    ]);
    gateway.feedSnapshot(varianceRows(400, 445), firstRowId: 1, totalCount: 446);

    await tester.pumpWidget(
      _wrap(ChatPage(gateway: gateway, sessionId: 's1', title: '历史验收')),
    );
    await tester.pumpAndSettle();

    final controller = historyController(tester);
    // Compact per-cycle trace (offset/extent + visible count): the full
    // anchor mechanics ride the page's own [anchor] debugPrint family.
    // ignore: avoid_print
    void diag(String label) {
      final visible = visibleMessages(tester).toList()..sort();
      // ignore: avoid_print
      print('[$label] offset=${controller.offset.toStringAsFixed(1)} '
          'max=${controller.position.maxScrollExtent.toStringAsFixed(1)} '
          'viewport=${controller.position.viewportDimension.toStringAsFixed(1)} '
          'visible=${visible.length} '
          'first=${visible.isEmpty ? '-' : visible.first} '
          'last=${visible.isEmpty ? '-' : visible.last}');
    }

    // Post-cycle sanity, shared by every load below.
    void expectAnchored(
      Set<String> visibleBefore,
      int calls,
      String cycle, {
      bool overlap = true,
    }) {
      diag(cycle);
      expect(rowsRangeCalls(gateway), calls,
          reason: '$cycle: exactly one rowsRange per trigger');
      if (overlap) {
        expect(visibleMessages(tester).intersection(visibleBefore), isNotEmpty,
            reason: '$cycle: the reading anchor survived the prepend');
      }
      expect(controller.offset, greaterThan(0.0),
          reason: '$cycle: not teleported to the page top');
      expect(controller.offset,
          lessThanOrEqualTo(controller.position.maxScrollExtent + 1.0),
          reason: '$cycle: no estimate overshoot past the content');
      expect(controller.position.maxScrollExtent, greaterThan(0.0));
    }

    // p1: the open auto-load consumed page 1 while the view settled.
    expect(rowsRangeCalls(gateway), 1, reason: 'open auto-load fired once');
    diag('p1 open');
    expect(visibleMessages(tester), isNotEmpty);

    // p2: in-window drag prefetch — the armed set must survive the prepend.
    final p2armed = await dragPrefetch(tester, controller);
    expectAnchored(p2armed, 2, 'p2 drag');

    // p3: fling coast prefetch — the coast legitimately moves the reading
    // position; assert fetch-count + bounds + content, not overlap.
    await flingPrefetch(tester, controller);
    expectAnchored(const <String>{}, 3, 'p3 fling', overlap: false);
    expect(visibleMessages(tester), isNotEmpty, reason: 'p3: not blank');

    // p4: top pull-release load — round-23: reading continues UP INTO the
    // fresh page from the armed top rows.
    final p4armed = await pullLoad(tester, controller);
    expectAnchored(p4armed, 4, 'p4 pull');

    // p5: drag prefetch again, deep in accumulated history by now.
    final p5armed = await dragPrefetch(tester, controller);
    expectAnchored(p5armed, 5, 'p5 drag');

    // p6: fling coast.
    await flingPrefetch(tester, controller);
    expectAnchored(const <String>{}, 6, 'p6 fling', overlap: false);
    expect(visibleMessages(tester), isNotEmpty, reason: 'p6: not blank');

    // p7: final pull — hasMore flips false, history ends at rowId 1.
    final p7armed = await pullLoad(tester, controller);
    expectAnchored(p7armed, 7, 'p7 pull');

    // Exhausted: canLoadOlder flipped false → the top rubber band is gone
    // (physics reverts to native clamping by design —「no elasticity once
    // all history is loaded」). Drag down and release: no fetch, no crash,
    // the offset stays clamped at the history head.
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    final exhaust = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await tester.pump();
    await exhaust.moveBy(const Offset(0, 300));
    await tester.pump();
    await exhaust.up();
    await tester.pumpAndSettle();
    diag('exhausted pull');
    expect(rowsRangeCalls(gateway), 7, reason: 'no fetch after exhaustion');
    expect(controller.offset, 0.0, reason: 'settled back at the history head');
    expect(visibleMessages(tester), isNotEmpty);

    // Pixel evidence for host-side eyeballing (image-surface mode keeps
    // scheduling frames — capture last, after all pumpAndSettle assertions).
    await binding.convertFlutterSurfaceToImage();
    await tester.pump(const Duration(milliseconds: 300));
    await _reportShot('history-final-7pages');
  });
}
