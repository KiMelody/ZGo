// Unit tests for the chat history pull gesture's scroll physics
// (task 09-21-chat-history-pull-load), adapted from the task research's
// SDK-verification suite (research/top_bounce_verify_test.dart, 4 cases).
//
// Note: FixedScrollMetrics on Flutter 3.47.4 requires `devicePixelRatio`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/top_bounce_physics.dart';

void main() {
  test('applyBoundaryConditions: top free, bottom clamped', () {
    const physics = TopRubberBandPhysics();
    final metrics = FixedScrollMetrics(
      minScrollExtent: 0.0,
      maxScrollExtent: 500.0,
      pixels: 0.0,
      viewportDimension: 300.0,
      devicePixelRatio: 3.0,
      axisDirection: AxisDirection.down,
    );
    // Top: allow underscroll (returns 0 → pixels tracks the finger).
    expect(physics.applyBoundaryConditions(metrics, -80.0), 0.0);
    // Bottom: clamp exactly like ClampingScrollPhysics.
    expect(physics.applyBoundaryConditions(metrics, 600.0), 100.0);
    // In-range movement: no boundary correction.
    expect(physics.applyBoundaryConditions(metrics, 100.0), 0.0);
  });

  test('applyPhysicsToUserOffset: 1:1 in range, damped out of range', () {
    const physics = TopRubberBandPhysics();
    FixedScrollMetrics metrics(double pixels) => FixedScrollMetrics(
          minScrollExtent: 0.0,
          maxScrollExtent: 500.0,
          pixels: pixels,
          viewportDimension: 300.0,
          devicePixelRatio: 3.0,
          axisDirection: AxisDirection.down,
        );
    // In range (not overscrolled yet): clamping identity, no damping.
    expect(physics.applyPhysicsToUserOffset(metrics(0.0), -100.0), -100.0);
    // Overscrolled (pixels = -80), pulling further out: still moves out
    // (negative) but damped below the raw delta.
    final damped = physics.applyPhysicsToUserOffset(metrics(-80.0), -100.0);
    expect(damped, lessThan(0.0));
    expect(damped.abs(), lessThan(100.0));
  });

  testWidgets('top rubber band: tracks finger, springs back, threshold window',
      (WidgetTester tester) async {
    double? pixelsAtFirstNonDragUpdate;
    double? pixelsAtScrollEnd;
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollUpdateNotification &&
                n.dragDetails == null &&
                pixelsAtFirstNonDragUpdate == null) {
              // First ballistic-frame update after release (RefreshIndicator
              // pattern): pixels is still the release position.
              pixelsAtFirstNonDragUpdate = n.metrics.pixels;
            }
            if (n is ScrollEndNotification) {
              pixelsAtScrollEnd = n.metrics.pixels;
            }
            return false;
          },
          child: ListView.builder(
            controller: controller,
            physics: const TopRubberBandPhysics(),
            itemCount: 50,
            itemBuilder: (_, i) => SizedBox(height: 40, child: Text('item $i')),
          ),
        ),
      ),
    );

    // Pull down at the top → pixels goes negative (content follows finger).
    final gesture = await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    expect(controller.offset, lessThan(-64.0),
        reason: 'content must track the finger past -64');

    // Release → inherited Clamping ballistic springs back to 0.
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.offset, 0.0, reason: 'must spring back to minScrollExtent');

    // Release-detection window: the first non-drag update still reported the
    // overscrolled pixels (threshold decidable), while ScrollEndNotification
    // only fires AFTER the bounce (too late).
    expect(pixelsAtFirstNonDragUpdate, isNotNull);
    expect(pixelsAtFirstNonDragUpdate!, lessThanOrEqualTo(-64.0));
    expect(pixelsAtScrollEnd, isNotNull);
    expect(pixelsAtScrollEnd, 0.0);
  });

  testWidgets('physics flip (custom -> null) recreates position but keeps pixels',
      (WidgetTester tester) async {
    bool canLoadOlder = true;
    final controller = ScrollController();
    addTearDown(controller.dispose);

    Widget build() => Directionality(
          textDirection: TextDirection.ltr,
          child: ListView.builder(
            controller: controller,
            physics: canLoadOlder ? const TopRubberBandPhysics() : null,
            itemCount: 50,
            itemBuilder: (_, i) => SizedBox(height: 40, child: Text('item $i')),
          ),
        );
    await tester.pumpWidget(build());

    await tester.drag(find.byType(ListView), const Offset(0, -200), warnIfMissed: false);
    await tester.pumpAndSettle();
    final offsetBefore = controller.offset;
    expect(offsetBefore, greaterThan(0.0));

    // Flip the flag and rebuild (same runtimeType chain change as
    // `physics: canLoadOlder ? X : null` in a page setState).
    canLoadOlder = false;
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    expect(controller.hasClients, isTrue);
    expect(controller.offset, offsetBefore,
        reason: 'absorb() must preserve pixels across the flip');
  });

  testWidgets('default clamping (physics: null) still clamps the top',
      (WidgetTester tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ListView.builder(
          controller: controller,
          itemCount: 50,
          itemBuilder: (_, i) => SizedBox(height: 40, child: Text('item $i')),
        ),
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    expect(controller.offset, 0.0, reason: 'platform default clamps at top');
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
