import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/ui/chat/subagent_detail_page.dart';

/// Gateway whose subscribe() never resolves — the live-observed stall where
/// the desktop bridge dies mid-handshake and the subscription call hangs.
class _StalledGateway implements ChatGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #subscribe) {
      return Completer<ChatHandle>().future;
    }
    throw UnimplementedError('${invocation.memberName}');
  }
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
