import 'package:flutter/foundation.dart';

/// Connection states shared by both relay generations (V1 proof relay on
/// `/ws`, V2 account-JWT relay on `/api/v1/remote/ws2`).
enum RelayState {
  idle,
  connecting,
  authenticating,
  waiting,
  paired,
  reconnecting,
  error,
  kicked,
  closed,
}

class RelayFailure {
  final String reason;
  final String? message;
  const RelayFailure(this.reason, [this.message]);

  @override
  String toString() => message == null ? reason : '$reason: $message';
}

/// V1 close-code mapping (kept for both relays: the V2 server uses the
/// same close-code family in practice, and an unknown code maps to null).
String? relayCloseReason(int code) {
  switch (code) {
    case 4004:
      return 'session-not-found';
    case 4009:
      return 'session-conflict';
    case 4010:
      return 'desktop-disconnected';
    case 4011:
      return 'session-expired';
    case 4012:
      return 'workspace-closed';
    case 4013:
      return 'invalid-mobile-connection';
    default:
      return null;
  }
}

/// The relay socket surface [RemoteClient] consumes. Deliberately minimal:
/// the payload layer above it (bootstrap / bridge / rpc-frame) is identical
/// on V1 and V2, so both transports only own the auth + heartbeat wiring.
///
/// Failure semantics both implementations share:
/// - a transient drop after pairing reconnects with the V1 backoff
///   (`1000 * (1 << attempt)` clamped 1-15s) and passes through
///   [RelayState.reconnecting];
/// - `kicked` is terminal — no reconnect; the state layer suppresses retry;
/// - outbound payloads sent while unpaired are queued (bounded) and flushed
///   on `paired`.
abstract class RelayTransport {
  /// Decoded `data` payloads (`{type:"data", payload}` unwrapped).
  Stream<Map<String, dynamic>> get payloads;

  ValueListenable<RelayState> get stateListenable;
  RelayState get state;

  /// Non-fatal/terminal failures (`kicked`, `auth-required`, the close-code
  /// family). The state layer maps the reason into its failure banner.
  Stream<RelayFailure> get failures;

  Future<void> start();

  void sendPayload(Map<String, dynamic> payload);

  /// Fire-and-forget mobile-diagnostic payload (never queued, never awaited,
  /// never surfaces an error). Dropped while the link is not authenticated.
  void sendMobileDiagnostic(String event, [Map<String, dynamic>? fields]);

  Future<void> dispose();
}
