import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/ui/chat/subagent_detail_page.dart';
import 'package:zgo/ui/chat/subagent_feed.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/fake_device_session.dart';

/// Widget-level contract of [TranscriptVeil] / [TranscriptViewport] (task
/// 10-29-transcript-viewport, design §6 + §9): the frozen-frame veil over a
/// real list — capture, arm, lift, dispose, drag-lift, failed-capture
/// downgrade, the unified pinned landing, and the key prefixes the
/// measurement port walks by.
///
/// Hosted on the subagent detail page: it is the second consumer, and the
/// 10-15 "twin" miniature it used to carry is now the same module (this file
/// replaces `subagent_detail_anchor_test.dart`).
class _VeilGateway extends FakeDeviceSession {
  _VeilGateway({
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
  ConversationTransport get conversationCommands => _VeilCommands(this);

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

class _VeilCommands implements ConversationTransport {
  _VeilCommands(this._gateway);

  final _VeilGateway _gateway;

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
/// markdown answer. Heights land roughly in the 40/300/120 mix — uniform
/// rows cannot catch the extent-estimate skew the compensation exists for.
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

  Future<SubagentFeed> pumpDetail(
    WidgetTester tester,
    _VeilGateway gateway,
  ) async {
    addTearDown(() => gateway.dispose());
    final feed = SubagentFeed(conversation: gateway);
    await tester.pumpWidget(
      wrap(
        SubagentDetailPage(
          host: gateway,
          feed: feed,
          childSessionId: 'sess_child_1',
          title: '实现加固',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    return feed;
  }

  /// The veil Opacity wrapping the list (nearest ancestor of the ListView) —
  /// the same assertion shape the chat page test relies on (design §6).
  Finder listVeil() => find
      .ancestor(of: find.byType(ListView), matching: find.byType(Opacity))
      .first;

  /// Walks the frames until the veiled build shows (the frozen capture's
  /// read-back spans a pump or two in the test binding) and returns there —
  /// mid-flight, before the measured landing lifts it.
  Future<void> pumpUntilVeiled(WidgetTester tester) async {
    var pumps = 0;
    while (tester.widget<Opacity>(listVeil()).opacity == 1.0 && pumps < 20) {
      pumps++;
      await tester.pump();
    }
    expect(tester.widget<Opacity>(listVeil()).opacity, 0.0,
        reason: 'the prepend frame must paint behind the veil');
  }

  /// Pumps the page through its open auto-fill and settles the reader at the
  /// very top; jumpTo carries no dragDetails, so no prefetch noise fires.
  Future<void> pumpReaderAtTop(
    WidgetTester tester,
    _VeilGateway gateway,
  ) async {
    await pumpDetail(tester, gateway);
    tester.widget<ListView>(find.byType(ListView)).controller!.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  double anchorDy(WidgetTester tester) => tester
      .renderObject<RenderBox>(find.text('任务 -19'))
      .localToGlobal(Offset.zero)
      .dy;

  testWidgets('a reading prepend veils the list and stands the frozen '
      'frame on top', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = _VeilGateway(
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
    // The veil is the ListView's nearest Opacity ancestor and only its
    // opacity flips (design §6).
    expect(
      tester.widget<Opacity>(listVeil()).opacity,
      0.0,
    );
  });

  testWidgets('the measured landing lifts the veil and disposes the frozen '
      'frame', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = _VeilGateway(
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

  testWidgets('a pinned prepend freezes TOO and lands on the measured '
      'newest end (the declared semantics upgrade)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // The open auto-fill lands while the reader is pinned at the bottom:
    // the old detail miniature skipped the freeze and played a visible
    // return-to-bottom; the shared viewport captures + veils and lands the
    // newest group on the true content end.
    final gateway = _VeilGateway(
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
    final feed = SubagentFeed(conversation: gateway);
    await tester.pumpWidget(
      wrap(
        SubagentDetailPage(
          host: gateway,
          feed: feed,
          childSessionId: 'sess_child_1',
          title: '实现加固',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await pumpUntilVeiled(tester);
    expect(find.byType(RawImage), findsOneWidget,
        reason: 'pinned prepends freeze like reading ones');
    await tester.pumpAndSettle();

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(
      controller.position.pixels,
      moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 0.5),
      reason: 'the endKey landing puts the newest group on the content end',
    );
    expect(find.text('任务 6'), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
  });

  testWidgets('a user drag lifts the frozen frame immediately', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = _VeilGateway(
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
    final gateway = _VeilGateway(
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

  testWidgets('the measurement keys follow the documented turn-/row- '
      'prefixes', (tester) async {
    // The viewport's element port walks by these prefixes and by the
    // ChatTurnGroup/ChatRow types (design §11). A rename on either side must
    // fail THIS test instead of silently orphaning every anchor.
    final gateway = _VeilGateway(rows: turns(1, 2), totalCount: 2);
    await pumpDetail(tester, gateway);

    final group = tester.widget<ChatTurnGroup>(find.byType(ChatTurnGroup).first);
    final firstRowId = group.rows.first['rowId'];
    expect(group.key, ValueKey('turn-$firstRowId'),
        reason: 'group key = ValueKey(turn-<first rowId>)');
    expect(find.byKey(ValueKey('row-$firstRowId')), findsOneWidget,
        reason: 'row key = ValueKey(row-<rowId>)');
    // The rowId fallback's contract: the group widget exposes the rows the
    // compensation matches against.
    expect(group.rows.first['rowId'], firstRowId);
  });
}
