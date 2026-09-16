import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/channel_client.dart';
import 'package:zlinker/protocol/connection_params.dart';
import 'package:zlinker/ui/model_providers_page.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

import 'helpers/fake_device_session.dart';

/// Channel-level load failures (the 2026-09 model-provider outage) must
/// render the dedicated "desktop channel unavailable" state with a retry,
/// distinct from the raw load-failure copy and from the empty list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => MaterialApp(
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: child,
      );

  RemoteConnectionParams paramsOf() => RemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
      )!;

  testWidgets('channel-level load failure shows unavailable state + retry',
      (WidgetTester tester) async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      channelHandler: (channel, method, args) async =>
          throw ChannelRpcError(
              "Channel name '$channel' timed out after 1000ms", null),
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('桌面端通道不可用'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // Not the raw load-failure copy — the outage must not read as "no
    // providers configured".
    expect(find.textContaining('加载失败'), findsNothing);

    // Retry re-issues the channel call and stays in the error state.
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(session.channelCalls, hasLength(2));
    expect(find.text('桌面端通道不可用'), findsOneWidget);
  });

  testWidgets('RPC-timeout load failure also shows unavailable state',
      (WidgetTester tester) async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      channelHandler: (channel, method, args) async =>
          throw TimeoutException('model-provider.getAll timed out'),
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('桌面端通道不可用'), findsOneWidget);
  });

  testWidgets('non-channel load failure keeps the raw error copy',
      (WidgetTester tester) async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      channelHandler: (channel, method, args) async => throw StateError('boom'),
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('桌面端通道不可用'), findsNothing);
  });

  testWidgets('empty provider list is distinct from the error states',
      (WidgetTester tester) async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      channelHandler: (channel, method, args) async => [],
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('桌面端通道不可用'), findsNothing);
    expect(find.textContaining('加载失败'), findsNothing);
    expect(find.byType(RefreshIndicator), findsOneWidget);
  });
}
