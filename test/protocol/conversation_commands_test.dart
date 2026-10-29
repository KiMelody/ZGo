import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/remote_client.dart' show BridgeSession;

import '../helpers/chat_role_fakes.dart';

/// Subtype + degraded-forwarding lock for [ConversationCommands]
/// (task 10-29-conversation-commands-grouping): the interface is the UI's
/// static view of the transport, so the implementation and the shared
/// recording fake must satisfy it, and [degraded] must mirror the bridge
/// session's notifier (the loading placeholder listens to it).
void main() {
  test('transport and its recording fake are ConversationCommands', () {
    expect(
      ConversationTransport(
        session: _FakeBridgeSession(),
        scope: const {'workspacePath': '/repo'},
      ),
      isA<ConversationCommands>(),
    );
    expect(
      RecordingConversationTransport((method, args) => const {}, () => false),
      isA<ConversationCommands>(),
    );
  });

  test('degraded getter forwards the bridge session notifier', () {
    final session = _FakeBridgeSession();
    final ConversationCommands commands = ConversationTransport(
      session: session,
      scope: const {'workspacePath': '/repo'},
    );

    expect(commands.degraded, same(session.degraded));
    expect(commands.degraded.value, isNull);

    session.markDegraded('rpc-transport-fault');
    expect(commands.degraded.value, 'rpc-transport-fault');

    session.degraded.value = null;
    expect(commands.degraded.value, isNull);
  });
}

/// Bridge stand-in: the transport's constructor only listens to
/// [recovered] and [degraded] is the surface under test; anything else
/// fails loud via noSuchMethod.
class _FakeBridgeSession implements BridgeSession {
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);

  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);

  @override
  DateTime? lastDegradedAt;

  @override
  ChannelClient get channels => throw UnimplementedError('no channels');

  @override
  void markDegraded(String reason) {
    lastDegradedAt = DateTime.now();
    degraded.value = reason;
  }

  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
