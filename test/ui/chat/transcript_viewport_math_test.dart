import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/transcript_viewport_math.dart';

/// Pure arithmetic of the prepend compensation chain (task
/// 10-29-transcript-viewport, design §7). No widget tree, no controller —
/// the widget-side chain feeds these numbers.
void main() {
  AnchorSample sample({
    double top = 0,
    double dy = 0,
    double viewportTop = 0,
    double pixels = 0,
    double measurePixels = 0,
    double maxScrollExtent = 10000,
  }) =>
      (
        top: top,
        dy: dy,
        viewportTop: viewportTop,
        pixels: pixels,
        measurePixels: measurePixels,
        maxScrollExtent: maxScrollExtent,
      );

  group('readingLanding', () {
    test('keeps the anchor distance from the viewport top', () {
      // The anchor sat 120px below the viewport top and measures 400px lower
      // after the prepend: the offset moves by the measured 400.
      final s = sample(top: 520, dy: 120, viewportTop: 100, pixels: 1000);
      expect(readingLanding(s), 1300);
    });

    test('is translation-invariant (a scrollOffsetCorrection cancels)', () {
      final before = sample(top: 520, dy: 120, viewportTop: 100, pixels: 1000);
      // A scrollOffsetCorrection moves the offset up by 6500 and the content
      // window down by the same amount — the landing is unchanged.
      final corrected =
          sample(top: 520 - 6500, dy: 120, viewportTop: 100, pixels: 7500);
      expect(readingLanding(corrected), readingLanding(before));
    });
  });

  group('stickLanding', () {
    test('lands the newest box bottom on the content end', () {
      // Box bottom 300px BELOW the viewport bottom, list foot padding 8:
      // target = pixels + 300 + 8.
      final s = sample(pixels: 2000);
      expect(
        stickLanding(
          s: s,
          boxBottom: 1500,
          viewportBottom: 1200,
          listBottomPadding: 8,
        ),
        2308,
      );
    });

    test('a box ending above the viewport bottom scrolls back up', () {
      final s = sample(pixels: 2000);
      expect(
        stickLanding(
          s: s,
          boxBottom: 1000,
          viewportBottom: 1200,
          listBottomPadding: 8,
        ),
        1808,
      );
    });
  });

  group('measuredDelta', () {
    test('cancels every viewport movement since measure', () {
      // Content shift 600 (the anchor now sits 600px lower on screen); the
      // reader also dragged 150px in between.
      final s = sample(
        top: 700,
        dy: 100,
        viewportTop: 0,
        pixels: 1150,
        measurePixels: 1000,
      );
      expect(measuredDelta(s), 750,
          reason: 'screen displacement 600 + pixel displacement 150');
    });

    test('a pure prepend (no drift) is just the screen displacement', () {
      final s = sample(
        top: 300,
        dy: 100,
        viewportTop: 0,
        pixels: 1000,
        measurePixels: 1000,
      );
      expect(measuredDelta(s), 200);
    });
  });

  group('landingIsStick', () {
    test('only a pinned anchor can land pinned', () {
      expect(
        landingIsStick(
          anchorStick: false,
          positioning: true,
          s: sample(pixels: 1000, measurePixels: 0),
        ),
        isFalse,
      );
    });

    test('pinned + drift inside the 40px slack lands pinned', () {
      expect(
        landingIsStick(
          anchorStick: true,
          positioning: false,
          s: sample(pixels: 1040, measurePixels: 1000),
        ),
        isTrue,
      );
      expect(
        landingIsStick(
          anchorStick: true,
          positioning: false,
          s: sample(pixels: 960, measurePixels: 1000),
        ),
        isTrue,
      );
    });

    test('pinned + drift past the slack demotes to the reading anchor', () {
      expect(
        landingIsStick(
          anchorStick: true,
          positioning: false,
          s: sample(pixels: 1040.5, measurePixels: 1000),
        ),
        isFalse,
      );
    });

    test('a programmatic scroll owns the viewport — drift is ours', () {
      expect(
        landingIsStick(
          anchorStick: true,
          positioning: true,
          s: sample(pixels: 6000, measurePixels: 1000),
        ),
        isTrue,
      );
    });
  });

  group('clampLanding', () {
    test('clamps into the content range', () {
      expect(clampLanding(-20, 5000), 0);
      expect(clampLanding(5300, 5000), 5000);
      expect(clampLanding(1234.5, 5000), 1234.5);
    });
  });

  group('preWidenExtent', () {
    test('predicts the next page from the last measured height', () {
      expect(preWidenExtent(800, 700), 2300);
    });

    test('caps at 120000', () {
      expect(preWidenExtent(100000, 700), 120000);
      expect(preWidenExtent(60000, 700), 120000);
      expect(preWidenExtent(59000, 700), 118700);
    });
  });

  group('hopCacheNeed', () {
    test('widens by twice the estimate delta plus one viewport', () {
      expect(
        hopCacheNeed(maxScrollExtent: 4000, baseMax: 1000, viewportHeight: 800),
        6800,
      );
    });

    test('caps at 120000', () {
      expect(
        hopCacheNeed(
            maxScrollExtent: 100000, baseMax: 0, viewportHeight: 800),
        120000,
      );
    });
  });

  group('giveUpLanding', () {
    test('lands 0.85 of the last measured page height', () {
      expect(
        giveUpLanding(
          anchorStick: false,
          lastMeasuredDelta: 1000,
          userDragActive: false,
          scrollSettled: true,
          pixels: 500,
        ),
        1350,
      );
    });

    test('stays put at the very head (pixels < 1)', () {
      expect(
        giveUpLanding(
          anchorStick: false,
          lastMeasuredDelta: 1000,
          userDragActive: false,
          scrollSettled: true,
          pixels: 0,
        ),
        isNull,
      );
      expect(
        giveUpLanding(
          anchorStick: false,
          lastMeasuredDelta: 1000,
          userDragActive: false,
          scrollSettled: true,
          pixels: 0.5,
        ),
        isNull,
      );
    });

    test('never fires pinned, in motion, or without a page measurement', () {
      double? run({
        bool stick = false,
        double? delta = 1000,
        bool drag = false,
        bool settled = true,
        double pixels = 500,
      }) =>
          giveUpLanding(
            anchorStick: stick,
            lastMeasuredDelta: delta,
            userDragActive: drag,
            scrollSettled: settled,
            pixels: pixels,
          );
      expect(run(stick: true), isNull);
      expect(run(delta: null), isNull);
      expect(run(drag: true), isNull);
      expect(run(settled: false), isNull);
    });
  });

  group('visibleLandingDuration', () {
    test('no-op corrections jump (null)', () {
      expect(visibleLandingDuration(0), isNull);
      expect(visibleLandingDuration(40), isNull);
      expect(visibleLandingDuration(-40), isNull);
    });

    test('small corrections ease for 96ms', () {
      expect(visibleLandingDuration(40.5), const Duration(milliseconds: 96));
      expect(visibleLandingDuration(800), const Duration(milliseconds: 96));
    });

    test('the duration scales with the correction up to 180ms', () {
      expect(visibleLandingDuration(1600), const Duration(milliseconds: 124));
      expect(visibleLandingDuration(3200), const Duration(milliseconds: 180));
    });

    test('past 3200 it snaps (null)', () {
      expect(visibleLandingDuration(3200.5), isNull);
      expect(visibleLandingDuration(9000), isNull);
    });

    test('pinned landings always jump', () {
      expect(visibleLandingDuration(600, stick: true), isNull);
    });
  });
}
