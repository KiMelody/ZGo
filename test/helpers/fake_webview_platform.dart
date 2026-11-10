import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Registers a minimal `flutter_inappwebview` platform so the production
/// [InAppWebView] widget can be constructed (not built) in widget tests.
///
/// The real platform view cannot host in a test binding; this fake satisfies
/// only the factory's platform assert, so pages that *push* a WebView can be
/// asserted on (same seam as `test/ui/chat/file_preview_page_test.dart`).
void installFakeWebViewPlatform() {
  InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
}

class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
          PlatformInAppWebViewWidgetCreationParams params) =>
      _FakeInAppWebViewWidget(params);
}

class _FakeInAppWebViewWidget extends PlatformInAppWebViewWidget {
  _FakeInAppWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();

  @override
  void dispose() {}
}