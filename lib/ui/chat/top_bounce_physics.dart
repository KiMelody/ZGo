import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Clamping physics that lets only the TOP edge rubber-band: the content
/// tracks the finger past [minScrollExtent] (quadratic-progressive damping,
/// BouncingScrollPhysics' formula) and springs back on release, while the
/// bottom edge keeps the native clamping (and its stretch/glow indicator)
/// untouched.
///
/// Runs as `TopRubberBandPhysics → ClampingScrollPhysics →
/// RangeMaintainingScrollPhysics` — only the three overrides below differ
/// from the platform chain; [createBallisticSimulation] is deliberately NOT
/// overridden: ClampingScrollPhysics' out-of-range branch already springs
/// back to minScrollExtent. Used by the chat history pull gesture
/// (task 09-21-chat-history-pull-load; SDK-verified skeleton, see the task's
/// research/flutter-top-bounce-physics.md §1.6).
class TopRubberBandPhysics extends ClampingScrollPhysics {
  const TopRubberBandPhysics({super.parent});

  @override
  TopRubberBandPhysics applyTo(ScrollPhysics? ancestor) =>
      TopRubberBandPhysics(parent: buildParent(ancestor));

  // Short lists (few messages + the load-older row: min == max == 0) must
  // stay draggable or the pull gesture never starts.
  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => true;

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    // Bottom edge: verbatim ClampingScrollPhysics branches.
    if (position.maxScrollExtent <= position.pixels && position.pixels < value) {
      return value - position.pixels; // Overscroll (bottom): already outside.
    }
    if (position.pixels < position.maxScrollExtent &&
        position.maxScrollExtent < value) {
      return value - position.maxScrollExtent; // Hit bottom edge.
    }
    // Top edge: free — pixels may go below minScrollExtent (content follows
    // the finger); boundary returning 0 also keeps OverscrollNotification
    // silent, so no stretch/glow fires on top of the rubber-band.
    return 0.0;
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (offset == 0.0) return offset;
    final double overscrollPast =
        math.max(position.minScrollExtent - position.pixels, 0.0);
    if (overscrollPast == 0.0) {
      // In range: 1:1, same as clamping.
      return super.applyPhysicsToUserOffset(position, offset);
    }
    // BouncingScrollPhysics' quadratic-progressive damping; at the top
    // overscroll, easing back = offset < 0 (lighter than pulling out).
    final bool easing = offset < 0.0;
    final double friction = easing
        ? frictionFactor((overscrollPast - offset.abs()) / position.viewportDimension)
        : frictionFactor(overscrollPast / position.viewportDimension);
    return offset.sign * _applyFriction(overscrollPast, offset.abs(), friction);
  }

  double frictionFactor(double overscrollFraction) =>
      math.pow(1 - overscrollFraction, 2) * 0.52;

  static double _applyFriction(double extentOutside, double absDelta, double gamma) {
    var total = 0.0;
    if (extentOutside > 0) {
      final double deltaToLimit = extentOutside / gamma;
      if (absDelta < deltaToLimit) {
        return absDelta * gamma;
      }
      total += extentOutside;
      absDelta -= deltaToLimit;
    }
    return total + absDelta;
  }
}
