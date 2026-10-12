import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Seam over the [SystemChrome] statics so the system-bar policy below can
/// be unit tested with a recording fake (task 10-12 AC1).
abstract class SystemChromeApi {
  Future<void> setMode(SystemUiMode mode, {List<SystemUiOverlay>? overlays});

  Future<void> setOverlays(List<SystemUiOverlay> overlays);
}

class _SystemChromeApi implements SystemChromeApi {
  const _SystemChromeApi();

  @override
  Future<void> setMode(SystemUiMode mode, {List<SystemUiOverlay>? overlays}) {
    return SystemChrome.setEnabledSystemUIMode(mode, overlays: overlays);
  }

  @override
  Future<void> setOverlays(List<SystemUiOverlay> overlays) {
    // The bare SystemChrome.setEnabledSystemUIOverlays static was folded
    // into setEnabledSystemUIMode in newer SDKs; manual + overlays sends
    // the same 'SystemChrome.setEnabledSystemUIOverlays' message.
    return SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: overlays,
    );
  }
}

const SystemChromeApi _defaultApi = _SystemChromeApi();

/// Landscape hides the status bar + navigation/gesture bar entirely
/// (immersive sticky: the transient edge swipe does not fire window-inset
/// changes, so the SafeAreas never re-flow — design §1); portrait restores
/// the platform defaults (Android edge-to-edge == the targetSdk 35 default,
/// iOS top overlay). Other platforms pass the portrait mode straight
/// through — the services layer silently no-ops where the concept does not
/// exist. Idempotent: applying the same orientation twice sends the same
/// calls, nothing else (R4 re-assert semantics).
void applySystemBarsFor(Orientation orientation, {SystemChromeApi? chrome}) {
  final SystemChromeApi api = chrome ?? _defaultApi;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      if (orientation == Orientation.landscape) {
        // overlays: [] is the design §3 call shape (immediate hide on
        // older engines; current engines hide at once for immersiveSticky,
        // so the argument is a no-op here — only manual consumes it).
        api.setMode(SystemUiMode.immersiveSticky, overlays: const []);
      } else {
        api.setMode(SystemUiMode.edgeToEdge);
      }
    case TargetPlatform.iOS:
      // The engine ignores setEnabledSystemUIMode on iOS, so this branch
      // rides the overlays channel instead (PRD R1/R6; no plist change).
      api.setOverlays(
        orientation == Orientation.landscape
            ? const <SystemUiOverlay>[]
            : const <SystemUiOverlay>[SystemUiOverlay.top],
      );
    default:
      api.setMode(SystemUiMode.edgeToEdge);
  }
}

/// [applySystemBarsFor] fed from the first platform view's orientation —
/// no [BuildContext], so it is callable from State.initState and the root
/// WidgetsBindingObserver callbacks (main.dart trigger points, PRD R4).
void applySystemBarsForView({SystemChromeApi? chrome}) {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  applySystemBarsFor(
    MediaQueryData.fromView(view).orientation,
    chrome: chrome,
  );
}
