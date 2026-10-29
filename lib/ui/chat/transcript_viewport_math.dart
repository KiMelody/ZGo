import 'dart:math' as math;

/// Pure landing arithmetic of [TranscriptViewport]'s prepend compensation
/// (task 10-29-transcript-viewport). Inputs are scalars sampled from the
/// measurement port; nothing here touches a widget tree, a ScrollController
/// or a RenderBox — the widget-side chain in `transcript_viewport.dart` only
/// feeds the numbers and dispatches the result through its landing sink.
///
/// The formulas are byte-for-byte the chat page's pre-extraction chain
/// (rounds 12-24): keep them together with their comments there.

/// One measured anchor sample: the landing box's global [top], the anchor
/// offset recorded at measure time ([dy] — group dy or row dy), the viewport
/// origin, the current offset ([pixels]) and the offset at measure time
/// ([measurePixels]).
typedef AnchorSample = ({
  double top,
  double dy,
  double viewportTop,
  double pixels,
  double measurePixels,
  double maxScrollExtent,
});

/// Reading landing: keep the anchor's distance from the viewport top
/// (`pixels + (top - viewportTop - dy)`). Translation-invariant — a
/// SliverList scrollOffsetCorrection moves `top` and `pixels` by the same
/// amount and cancels (round 18).
double readingLanding(AnchorSample s) =>
    s.pixels + (s.top - s.viewportTop - s.dy);

/// Pinned landing: put the newest group's bottom exactly on the true content
/// end (the list's bottom padding above the viewport bottom) — derived from
/// measured boxes, so it can neither fall short the way
/// `animateTo(max-estimate)` does nor overshoot into the unpainted region the
/// way the old Δmax jumpTo did (2026-09-21 device acceptance).
double stickLanding({
  required AnchorSample s,
  required double boxBottom,
  required double viewportBottom,
  required double listBottomPadding,
}) =>
    s.pixels + (boxBottom - viewportBottom) + listBottomPadding;

/// TRUE content shift of one prepend: the anchor's screen displacement plus
/// the total pixel displacement since measure — every viewport movement
/// cancels out, leaving the pure content height (round 21). Feeds the NEXT
/// prepend's cache-extent pre-widen and the give-up fallback, never a pixel
/// jump.
double measuredDelta(AnchorSample s) =>
    (s.top - s.viewportTop - s.dy) + (s.pixels - s.measurePixels);

/// Pinned-verdict demotion guard (round 8 / round 15): the anchor was
/// captured pinned, but the landing is only allowed to target the newest end
/// while the viewport did not drift from the measure-time offset — unless a
/// PROGRAMMATIC scroll (our own animation) owns it, whose motion is ours, not
/// the reader's. Judged by the offset drift, not by the page's sticky flag:
/// the prepend itself grows max and flips that flag without any user
/// movement.
bool landingIsStick({
  required bool anchorStick,
  required bool positioning,
  required AnchorSample s,
  double slack = 40,
}) =>
    anchorStick &&
    (positioning || (s.pixels - s.measurePixels).abs() <= slack);

/// Clamp to the content range: `jumpTo` bypasses `applyBoundaryConditions`,
/// and an un-clamped stale-baseline target once parked the viewport past the
/// true end (blank view + fake stick).
double clampLanding(double target, double maxScrollExtent) =>
    target.clamp(0.0, maxScrollExtent).toDouble();

/// One-frame layout-cache pre-widen before the prepend applies (round 21):
/// the anchor sits ~one page below the offset after the prepend, beyond the
/// ~250px default cache. Predicted from the last page's measured height, ×2
/// headroom for its variance, capped at 120000.
double preWidenExtent(
  double lastMeasuredDelta,
  double viewportHeight, {
  double cap = 120000,
}) =>
    math.min(lastMeasuredDelta * 2 + viewportHeight, cap);

/// One-frame layout-cache widen when the anchor was not built at hop 0: the
/// extent-estimate delta ×2 headroom (inflation is one-sided — an
/// under-estimate leaves the anchor short), capped at 120000.
double hopCacheNeed({
  required double maxScrollExtent,
  required double baseMax,
  required double viewportHeight,
  double cap = 120000,
}) =>
    math.min((maxScrollExtent - baseMax) * 2 + viewportHeight, cap);

/// Give-up fallback after the widened cache still cannot find the anchor:
/// land by the last page's MEASURED height at a conservative 0.85-fold (an
/// under-shot lands ~300px off where a full-height guess missed by 1287,
/// round 20) instead of compounding an uncompensated prepend into the NEXT
/// landing. Only for reading landings whose viewport is at rest and not at
/// the very head (`pixels >= 1`): at the head the reader is looking at the
/// FRESH page, and an estimated jump there leaps somewhere they never chose
/// (round 21). Returns null when the chain must stay put.
double? giveUpLanding({
  required bool anchorStick,
  required double? lastMeasuredDelta,
  required bool userDragActive,
  required bool scrollSettled,
  required double pixels,
  double factor = 0.85,
}) {
  if (anchorStick ||
      lastMeasuredDelta == null ||
      userDragActive ||
      !scrollSettled ||
      pixels < 1.0) {
    return null;
  }
  return pixels + lastMeasuredDelta * factor;
}

/// VISIBLE landing easing (round 12): small reading corrections ANIMATE
/// instead of teleporting; a same-frame teleport reads as "content nudges
/// DOWN a little". The duration scales with the distance so a ~3k correction
/// doesn't glide at 5× the speed of a 400px one; past the ceiling it snaps
/// (half a screen of gliding is worse than one cut). Pinned landings and
/// no-op corrections stay instant.
Duration? visibleLandingDuration(double correction, {bool stick = false}) {
  if (stick || correction <= 40 || correction > 3200) return null;
  final ms = (96.0 + (correction - 800).clamp(0.0, 2400.0) * 84 / 2400)
      .clamp(96.0, 180.0)
      .toDouble();
  return Duration(milliseconds: ms.round());
}
