/// Conversation V4 protocol over the `zcode-agent` channel.
///
/// Flow:
/// 1. `helloConversationV4()` + `initializeConversationV4(clientHello)`
/// 2. `subscribeConversationV4(scope + sessionId)` -> ack.subscriptionId
/// 3. frames pushed via dynamic event `onDynamicConversationFrame(scope)`:
///    wire frames `{wireVersion:3, kind:'complete'|'fragment', topic,
///    subscriptionId, frame | fragment*}`; complete frames carry
///    `{topic, subscriptionId, fromSeq, toSeq, sentAt, payload}` where payload
///    is `{kind:'snapshot', snapshot}` or `{kind:'deltas', deltas}`.
/// 4. commands via `sendConversationCommandV4(scope + envelope)` with
///    envelope `{commandId, clientId, sessionId, type, payload, issuedAt}`.
///
/// Barrel façade: the implementation is split across
/// `conversation_transport.dart` (wire commands, handshake, attachment
/// chunking + the native send-text/queue and rowsRange-parsing blocks),
/// `conversation_subscription.dart` (shared subscription base + the two
/// subscriptions), `conversation_state.dart` (state containers + model
/// family) and `replayable_queue.dart` (native offline queue). Each part
/// carries a bundle-anchor header — see docs/adr/0013 for the diff
/// procedure. Callers import this file, not the parts.
library;

export 'conversation_state.dart';
export 'conversation_subscription.dart';
export 'conversation_transport.dart';
export 'replayable_queue.dart';
