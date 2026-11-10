import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/state/device_store.dart';
import 'package:zgo/ui/remote_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

/// Records every pop so the AppBar action can be asserted without any
/// session/hub (V1 口径 A: the button only pops).
class _RecordingObserver extends NavigatorObserver {
  final popped = <Route<dynamic>>[];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route);
  }
}

Widget wrap(Widget child, {NavigatorObserver? observer}) => MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      navigatorObservers: [if (observer != null) observer],
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

Future<Device> setupDevice() async {
  SharedPreferences.setMockInitialValues({});
  final store = DeviceStore();
  await store.load();
  return store.addUrl(
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=songsong&app_version=3.8.1');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The real platform view cannot host in widget tests; this fake only
    // satisfies the factory's platform assert (same seam as
    // test/ui/chat/file_preview_page_test.dart).
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
  });

  testWidgets('the AppBar back action pops the page (V1 口径 A)',
      (WidgetTester tester) async {
    final device = await setupDevice();
    final observer = _RecordingObserver();

    await tester.pumpWidget(wrap(
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(zRoute(
                (_) => RemotePage(device: device),
              )),
              child: const Text('open remote'),
            ),
          ),
        ),
      ),
      observer: observer,
    ));

    await tester.tap(find.text('open remote'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RemotePage), findsOneWidget);
    expect(observer.popped, isEmpty);

    // The pushed route's AppBar auto-adds a leading back arrow too, so the new
    // action is located by its tooltip rather than the shared icon.
    final action = find.byTooltip('返回原生界面');
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(observer.popped, hasLength(1),
        reason: 'the action must pop the remote page');
    expect(find.byType(RemotePage), findsNothing);
    expect(find.text('open remote'), findsOneWidget);
  });

  testWidgets('the action carries the localized tooltip',
      (WidgetTester tester) async {
    final device = await setupDevice();
    await tester.pumpWidget(wrap(RemotePage(device: device)));
    await tester.pump();

    // zh-CN default: the copy comes from the lexicon table, never a literal.
    expect(find.byTooltip('返回原生界面'), findsOneWidget);
  });

  testWidgets('RemotePage still exposes only device/target* params',
      (WidgetTester tester) async {
    final device = await setupDevice();
    await tester.pumpWidget(wrap(RemotePage(
      device: device,
      targetSessionId: 's-1',
      targetTitle: 'title',
    )));
    await tester.pump();

    final page = tester.widget<RemotePage>(find.byType(RemotePage));
    expect(page.device.id, device.id);
    expect(page.targetSessionId, 's-1');
    expect(page.targetTitle, 'title');
  });
}

/// Minimal platform registration so the production [InAppWebView] widget can
/// be constructed (not built) in this test file.
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