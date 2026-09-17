import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/state/device_session.dart' show ChatHandle;
import 'package:zlinker/ui/chat/subagent_detail_page.dart';

import '../helpers/recording_chat_gateway.dart';

/// Gateway whose subscribe() never resolves — the live-observed stall where
/// the desktop bridge dies mid-handshake and the subscription call hangs.
/// Everything else rides the shared loose-default recording gateway.
class _StalledGateway extends RecordingChatGateway {
  @override
  Future<ChatHandle> subscribe(String sessionId) =>
      Completer<ChatHandle>().future;
}

void main() {
  testWidgets('subscribe stall surfaces timeout error with retry button',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SubagentDetailPage(
          gateway: _StalledGateway(),
          childSessionId: 'sess_subagent_stalled',
          title: 'T',
        ),
      ),
    );
    await tester.pump();
    // Before the timeout: spinner, no error.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('数据加载超时'), findsNothing);

    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();

    // After 15s: the timeout error bar replaces the silent spinner.
    expect(find.textContaining('数据加载超时'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
