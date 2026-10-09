import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/remote_client.dart' show BridgeSession;

/// editUserQuery `workspaceMode` wire shape (D1, F1): the 3.14 enum is
/// `["preserve","rewind"]` and the desktop treats it as
/// `workspaceMode ?? "preserve"` — so **preserve ships as NO field** (the
/// legacy payload old desktops already accept) and only 'rewind' goes on
/// the wire. CAS framing (baseRevision/baseLogEpoch) is unchanged.
void main() {
  test('rewind=true sends workspaceMode:"rewind"', () async {
    final t = _RecordingTransport();
    await t.editUserQuery(
      's1',
      {'rowId': 7},
      '改后的消息',
      workspaceMode: 'rewind',
    );

    expect(t.commands.single.$1, 'editUserQuery');
    expect(t.commands.single.$2, {
      'target': {'rowId': 7},
      'newText': '改后的消息',
      'workspaceMode': 'rewind',
    });
  });

  test('preserve is the wire default: the field stays OFF the payload',
      () async {
    final t = _RecordingTransport();
    await t.editUserQuery(
      's1',
      {'rowId': 7},
      '保留对话的编辑',
      workspaceMode: 'preserve',
    );

    expect(t.commands.single.$2, {
      'target': {'rowId': 7},
      'newText': '保留对话的编辑',
    });
  });

  test('no mode argument (legacy callers) sends the legacy payload',
      () async {
    final t = _RecordingTransport();
    await t.editUserQuery('s1', {'rowId': 7}, '旧调用点');

    expect(t.commands.single.$2, {
      'target': {'rowId': 7},
      'newText': '旧调用点',
    });
  });
}

class _RecordingTransport extends ConversationTransport {
  _RecordingTransport()
    : super(session: _FakeBridgeSession(), scope: const {});

  final List<(String, Map<String, dynamic>)> commands = [];

  @override
  Future<dynamic> sendCommand(
    String? sessionId,
    String type,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    commands.add((type, payload));
    return const {'status': 'accepted'};
  }
}

/// Minimal bridge stand-in (constructor listener + health gate only).
class _FakeBridgeSession implements BridgeSession {
  @override
  final ChannelClient channels = ChannelClient(sendBody: (_) {});

  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);

  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);

  @override
  DateTime? lastDegradedAt;

  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
