import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/ui/chat/subagent_detail_page.dart';
import 'package:zgo/ui/chat/subagent_feed.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/fake_device_session.dart';

/// Prepend anchor compensation on the detail page (design D2 miniature):
/// reading readers must not see the viewport jump when an older page lands.
/// Rows are mixed-height on purpose (short bubbles vs long markdown answers)
/// — spec §9: uniform row heights cannot catch the extent-estimate skew this
/// compensation exists for.
class _AnchorGateway extends FakeDeviceSession {
  _AnchorGateway({
    required this.rows,
    this.totalCount,
    this.rangeResult,
  }) : super(deviceId: 'd1', params: _params);

  static final _params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
  )!;

  final List<Map<String, dynamic>> rows;
  final int? totalCount;

  /// Mutate mid-test to program the NEXT page (button tap path).
  Map<String, dynamic>? rangeResult;

  final List<(String, int?, int)> ranges = [];
  ConversationState? lastState;

  @override
  ConversationTransport get conversationCommands => _AnchorCommands(this);

  @override
  Future<ChatHandle> subscribe(String sessionId) async {
    final state = ConversationState();
    lastState = state;
    state.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessionId': sessionId,
          'logEpoch': 'e1',
          'revision': 1,
          'rows': {
            'window': rows,
            'totalCount': totalCount ?? rows.length,
            if (rows.isNotEmpty)
              'firstRowId': (rows.first['rowId'] as num?)?.toInt(),
          },
        },
      },
    }, onGap: () => fail('unexpected gap'));
    return ChatHandle(
      state: state,
      close: () async {},
    );
  }
}

class _AnchorCommands implements ConversationTransport {
  _AnchorCommands(this._gateway);

  final _AnchorGateway _gateway;

  @override
  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) async {
    _gateway.ranges.add((sessionId, beforeRowId, limit));
    return _gateway.rangeResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Map<String, dynamic>>.value(const {'status': 'accepted'});
}

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

/// Mixed-height turns: a short user bubble + an alternating short/long
/// markdown answer. Heights land roughly in the 40/300/120 mix.
List<Map<String, dynamic>> turns(int from, int to) => [
      for (var i = from; i <= to; i++) ...[
        {'rowId': i * 2 - 1, 'kind': 'userInput', 'text': '任务 $i'},
        {
          'rowId': i * 2,
          'kind': 'assistantText',
          'text': i.isOdd ? '回答 $i' : ('回答 $i 的长输出 ' * 60),
        },
      ],
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pumps the page through its open auto-fill (pinned → no veil, the
  /// follow pass owns that landing) and settles the reader at the very top;
  /// jumpTo carries no dragDetails, so no prefetch noise fires. Shared by
  /// the frozen-frame/veil tests (10-15 revision).
  Future<void> pumpReaderAtTop(
    WidgetTester tester,
    _AnchorGateway gateway,
  ) async {
    addTearDown(() => gateway.dispose());
    final feed = SubagentFeed(gateway: gateway);
    await tester.pumpWidget(
      wrap(
        SubagentDetailPage(
          gateway: gateway,
          feed: feed,
          childSessionId: 'sess_child_1',
          title: '实现加固',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    tester.widget<ListView>(find.byType(ListView)).controller!.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// The veil Opacity wrapping the list (nearest ancestor of the ListView).
  Finder listVeil() => find
      .ancestor(of: find.byType(ListView), matching: find.byType(Opacity))
      .first;

  /// Walks the frames until the veiled build shows (the frozen capture's
  /// read-back spans a pump or two in the test binding) and returns there —
  /// mid-flight, before the measured landing lifts it.
  Future<void> pumpUntilVeiled(WidgetTester tester) async {
    var pumps = 0;
    while (tester.widget<Opacity>(listVeil()).opacity == 1.0 && pumps < 10) {
      pumps++;
      await tester.pump();
    }
    expect(tester.widget<Opacity>(listVeil()).opacity, 0.0,
        reason: 'the prepend frame must paint behind the veil');
  }

  double anchorDy(WidgetTester tester) => tester
      .renderObject<RenderBox>(find.text('任务 -19'))
      .localToGlobal(Offset.zero)
      .dy;

  testWidgets('prepending a mixed-height page keeps the reading anchor '
      'visually pinned (dy drift < 1px)', (tester) async {
    // 8 turns in the window; the open auto-fill prepends 20 older turns and
    // keeps the gate open (hasMore) so the button path stays reachable.
    final gateway = _AnchorGateway(
      rows: turns(1, 8),
      totalCount: 100,
      rangeResult: {
        'hasMore': true,
        'atLogEpoch': 'e1',
        'rows': {
          'window': turns(-19, 0),
          'firstRowId': -39,
        },
      },
    );
    addTearDown(() => gateway.dispose());
    final feed = SubagentFeed(gateway: gateway);
    await tester.pumpWidget(
      wrap(
        SubagentDetailPage(
          gateway: gateway,
          feed: feed,
          childSessionId: 'sess_child_1',
          title: '实现加固',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(gateway.ranges.length, 1); // open auto-fill only

    // Reading position: the very top. jumpTo carries no dragDetails → no
    // prefetch noise. The row at the viewport top ('任务 -19', leading the
    // first stable group) is the reading target the compensation must pin.
    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    controller.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final before = tester
        .renderObject<RenderBox>(find.text('任务 -19'))
        .localToGlobal(Offset.zero)
        .dy;

    // Load the second page through the button (no gesture active, so the
    // page lands directly — no drag-hold parking).
    gateway.rangeResult = {
      'hasMore': false,
      'atLogEpoch': 'e1',
      'rows': {
        'window': turns(-39, -20),
        'firstRowId': -79,
      },
    };
    await tester.tap(find.text('加载更早消息'));
    await tester.pumpAndSettle();

    // The anchor row sits where it did before the prepend: the compensation
    // landed on a measured RenderBox delta, not an extent estimate.
    final after = tester
        .renderObject<RenderBox>(find.text('任务 -19'))
        .localToGlobal(Offset.zero)
        .dy;
    expect((after - before).abs(), lessThan(1.0));
    // The widened cache did not leak past the landing.
    expect(
      tester.widget<ListView>(find.byType(ListView)).scrollCacheExtent,
      isNull,
    );
  });

  testWidgets('a pinned prepend is not compensated — the follow pass lands '
      'the reader back at the bottom', (tester) async {
    final gateway = _AnchorGateway(
      rows: turns(1, 6),
      totalCount: 100,
      rangeResult: {
        'hasMore': false,
        'atLogEpoch': 'e1',
        'rows': {
          'window': turns(-19, 0),
          'firstRowId': -39,
        },
      },
    );
    addTearDown(() => gateway.dispose());
    final feed = SubagentFeed(gateway: gateway);
    await tester.pumpWidget(
      wrap(
        SubagentDetailPage(
          gateway: gateway,
          feed: feed,
          childSessionId: 'sess_child_1',
          title: '实现加固',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // Open auto-fill prepended 20 turns while pinned: no anchor compensation,
    // the follow pass grew the view back to the newest row.
    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(
      controller.position.pixels,
      moreOrLessEquals(controller.position.maxScrollExtent),
    );
    expect(find.text('任务 6'), findsOneWidget);
  });

  testWidgets('a reading prepend veils the list and stands the frozen '
      'frame on top (round-24 twin)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = _AnchorGateway(
      rows: turns(1, 8),
      totalCount: 100,
      rangeResult: {
        'hasMore': true,
        'atLogEpoch': 'e1',
        'rows': {
          'window': turns(-19, 0),
          'firstRowId': -39,
        },
      },
    );
    await pumpReaderAtTop(tester, gateway);
    gateway.rangeResult = {
      'hasMore': false,
      'atLogEpoch': 'e1',
      'rows': {
        'window': turns(-39, -20),
        'firstRowId': -79,
      },
    };

    await tester.tap(find.text('加载更早消息'));
    await pumpUntilVeiled(tester);

    // The frozen capture (not a bare veil — the bare veil is the device
    // black-flash) covers the whole viewport from the Stack's top slot.
    final rawFinder = find.byType(RawImage);
    expect(rawFinder, findsOneWidget);
    final frame = tester.widget<RawImage>(rawFinder).image;
    expect(frame, isNotNull);
    final stack = tester.widget<Stack>(
      find.ancestor(of: rawFinder, matching: find.byType(Stack)).first,
    );
    final topmost = stack.children.last as Positioned;
    expect(topmost.left, 0.0);
    expect(topmost.top, 0.0);
    expect(topmost.right, 0.0);
    expect(topmost.bottom, 0.0);
  });

  testWidgets('the measured landing lifts the veil and disposes the frozen '
      'frame', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = _AnchorGateway(
      rows: turns(1, 8),
      totalCount: 100,
      rangeResult: {
        'hasMore': true,
        'atLogEpoch': 'e1',
        'rows': {
          'window': turns(-19, 0),
          'firstRowId': -39,
        },
      },
    );
    await pumpReaderAtTop(tester, gateway);
    final before = anchorDy(tester);
    gateway.rangeResult = {
      'hasMore': false,
      'atLogEpoch': 'e1',
      'rows': {
        'window': turns(-39, -20),
        'firstRowId': -79,
      },
    };

    await tester.tap(find.text('加载更早消息'));
    await pumpUntilVeiled(tester);
    final frame = tester.widget<RawImage>(find.byType(RawImage)).image!;

    // Landing post-frame: the veil lifts, the RawImage unmounts and the
    // frame's GPU memory goes back (a leaked frame would hold a texture).
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(listVeil()).opacity, 1.0,
        reason: 'the measured landing must lift the veil');
    expect(find.byType(RawImage), findsNothing);
    expect(frame.debugDisposed, isTrue,
        reason: 'the lifted frozen frame must be disposed');
    // The landing stayed measured: the reading anchor did not move.
    expect((anchorDy(tester) - before).abs(), lessThan(1.0));
  });

  testWidgets('a user drag lifts the frozen frame immediately', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = _AnchorGateway(
      rows: turns(1, 8),
      totalCount: 100,
      rangeResult: {
        'hasMore': true,
        'atLogEpoch': 'e1',
        'rows': {
          'window': turns(-19, 0),
          'firstRowId': -39,
        },
      },
    );
    await pumpReaderAtTop(tester, gateway);
    gateway.rangeResult = {
      'hasMore': false,
      'atLogEpoch': 'e1',
      'rows': {
        'window': turns(-39, -20),
        'firstRowId': -79,
      },
    };

    await tester.tap(find.text('加载更早消息'));
    // Finger down BEFORE the veil arms: pointer streams keep their down-time
    // hit path, so an in-flight gesture still reaches the scrollable through
    // the veiled frames (exactly how a real reader's moving finger does).
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await pumpUntilVeiled(tester);

    // The freeze must never feel sticky: the first drag movement reveals
    // the real list, whatever the compensation chain is still doing.
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(tester.widget<Opacity>(listVeil()).opacity, 1.0,
        reason: 'a user drag lifts the freeze immediately');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsNothing);
  });

  testWidgets('a failed capture downgrades to the visible landing — the '
      'list never goes blank', (tester) async {
    final gateway = _AnchorGateway(
      rows: turns(1, 8),
      totalCount: 100,
      rangeResult: {
        'hasMore': true,
        'atLogEpoch': 'e1',
        'rows': {
          'window': turns(-19, 0),
          'firstRowId': -39,
        },
      },
    );
    await pumpReaderAtTop(tester, gateway);
    final before = anchorDy(tester);
    gateway.rangeResult = {
      'hasMore': false,
      'atLogEpoch': 'e1',
      'rows': {
        'window': turns(-39, -20),
        'firstRowId': -79,
      },
    };
    // The race the guard exists for: a repaint scheduled but not yet painted
    // when the page lands (the loading-spinner frame on a slow device). The
    // capture skips, the chain downgrades — visible landing, no blank veil.
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find
          .ancestor(
            of: find.byType(ListView),
            matching: find.byType(RepaintBoundary),
          )
          .first,
    );
    boundary.markNeedsPaint();
    expect(boundary.debugNeedsPaint, isTrue);

    await tester.tap(find.text('加载更早消息'));
    await tester.pump();
    expect(find.byType(RawImage), findsNothing);
    expect(tester.widget<Opacity>(listVeil()).opacity, 1.0);
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsNothing);
    // The visible landing still measured its anchor: no jump either way.
    final after = anchorDy(tester);
    expect((after - before).abs(), lessThan(1.0));
    expect(
      tester.widget<ListView>(find.byType(ListView)).scrollCacheExtent,
      isNull,
    );
  });
}
