import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/off_peak.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/recording_chat_gateway.dart';

class FakeChatGateway extends RecordingChatGateway {}

/// Minimal off-peak host answering [tasks] for the port's `list` probe.
class FakeOffPeakHost implements OffPeakHost {
  FakeOffPeakHost({this.tasks = const []});
  final List<Map<String, dynamic>> tasks;

  @override
  DeviceStatus status = DeviceStatus.connected;

  @override
  Map<String, dynamic> offPeakScope = const {'workspacePath': '/repo'};

  @override
  late final OffPeakPort offPeak =
      OffPeakPort((method, args) async => tasks, newWire: false);
}

Widget wrap(Widget child) => MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bound run with a live position renders the queue card',
      (tester) async {
    final gateway = FakeChatGateway();
    final host = FakeOffPeakHost(tasks: [
      {
        'offPeakTaskId': 't1',
        'title': '构建报告',
        'status': 'queued',
        'queuePosition': 3,
        'sessionId': 's1',
      },
    ]);
    var opened = 0;
    await tester.pumpWidget(wrap(ChatPage(
      gateway: gateway,
      sessionId: 's1',
      title: 't',
      offPeakHost: host,
      onOpenOffPeak: () => opened++,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('构建报告'), findsOneWidget);
    expect(find.text('排队第 3 位 · 将在本会话中运行'), findsOneWidget);
    expect(find.byIcon(Icons.dark_mode_outlined), findsOneWidget);
    expect(find.text('去到闲时任务'), findsOneWidget);

    await tester.tap(find.text('去到闲时任务'));
    expect(opened, 1);
  });

  testWidgets('bound run without a position renders nothing', (tester) async {
    final gateway = FakeChatGateway();
    final host = FakeOffPeakHost(tasks: [
      {
        'offPeakTaskId': 't1',
        'title': '构建报告',
        'status': 'queued',
        'sessionId': 's1',
      },
    ]);
    await tester.pumpWidget(wrap(ChatPage(
      gateway: gateway,
      sessionId: 's1',
      title: 't',
      offPeakHost: host,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('将在本会话中运行'), findsNothing);
    expect(find.text('去到闲时任务'), findsNothing);
  });

  testWidgets('unbound session renders nothing', (tester) async {
    final gateway = FakeChatGateway();
    final host = FakeOffPeakHost(tasks: [
      {
        'offPeakTaskId': 't1',
        'title': '别的会话',
        'status': 'queued',
        'queuePosition': 5,
        'sessionId': 'other',
      },
    ]);
    await tester.pumpWidget(wrap(ChatPage(
      gateway: gateway,
      sessionId: 's1',
      title: 't',
      offPeakHost: host,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('将在本会话中运行'), findsNothing);
  });

  testWidgets('no off-peak host hides the card entirely', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('将在本会话中运行'), findsNothing);
  });
}
