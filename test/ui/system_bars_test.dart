import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/system_bars.dart';

/// Records the seam calls so the platform × orientation matrix (AC1) can be
/// asserted as exact call sequences.
class _RecordingChrome implements SystemChromeApi {
  final List<String> calls = <String>[];

  static String _names(List<SystemUiOverlay> overlays) =>
      overlays.map((o) => o.name).join(', ');

  @override
  Future<void> setMode(SystemUiMode mode, {List<SystemUiOverlay>? overlays}) {
    calls.add(overlays == null
        ? 'setMode(${mode.name})'
        : 'setMode(${mode.name}, overlays: [${_names(overlays)}])');
    return Future.value();
  }

  @override
  Future<void> setOverlays(List<SystemUiOverlay> overlays) {
    calls.add('setOverlays([${_names(overlays)}])');
    return Future.value();
  }
}

void _usePlatform(TargetPlatform platform) {
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('android landscape goes immersive sticky, bars hidden at once', () {
    _usePlatform(TargetPlatform.android);
    final chrome = _RecordingChrome();
    applySystemBarsFor(Orientation.landscape, chrome: chrome);
    expect(chrome.calls, ['setMode(immersiveSticky, overlays: [])']);
  });

  test('android portrait restores edge-to-edge', () {
    _usePlatform(TargetPlatform.android);
    final chrome = _RecordingChrome();
    applySystemBarsFor(Orientation.portrait, chrome: chrome);
    expect(chrome.calls, ['setMode(edgeToEdge)']);
  });

  test('iOS landscape hides the status bar via the overlays channel', () {
    _usePlatform(TargetPlatform.iOS);
    final chrome = _RecordingChrome();
    applySystemBarsFor(Orientation.landscape, chrome: chrome);
    expect(chrome.calls, ['setOverlays([])']);
  });

  test('iOS portrait restores the top overlay', () {
    _usePlatform(TargetPlatform.iOS);
    final chrome = _RecordingChrome();
    applySystemBarsFor(Orientation.portrait, chrome: chrome);
    expect(chrome.calls, ['setOverlays([top])']);
  });

  test('other platforms pass the mode straight through', () {
    _usePlatform(TargetPlatform.windows);
    final chrome = _RecordingChrome();
    applySystemBarsFor(Orientation.landscape, chrome: chrome);
    expect(chrome.calls, ['setMode(edgeToEdge)']);
  });

  test('re-applying the same orientation is idempotent (R4 re-assert)', () {
    _usePlatform(TargetPlatform.android);
    final chrome = _RecordingChrome();
    applySystemBarsFor(Orientation.landscape, chrome: chrome);
    applySystemBarsFor(Orientation.landscape, chrome: chrome);
    expect(chrome.calls, [
      'setMode(immersiveSticky, overlays: [])',
      'setMode(immersiveSticky, overlays: [])',
    ]);
  });

  // AC2: the context-free hook the root observer (main.dart) calls. The
  // full ZGoApp tree is too heavy to pump for this — the extracted
  // "read orientation → apply" unit is asserted directly instead.
  // The platform override is reset inside the body (try/finally):
  // testWidgets checks foundation debug variables before addTearDown runs.
  testWidgets(
    'applySystemBarsForView reads the view orientation without a context',
    (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      tester.view.physicalSize = const Size(800, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final chrome = _RecordingChrome();
      applySystemBarsForView(chrome: chrome);
      expect(chrome.calls, ['setMode(immersiveSticky, overlays: [])']);

      // Rotation lands as a plain orientation flip → matching re-apply.
      tester.view.physicalSize = const Size(400, 800);
      applySystemBarsForView(chrome: chrome);
      expect(chrome.calls.last, 'setMode(edgeToEdge)');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
