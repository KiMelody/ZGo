import 'channel_client.dart';
import 'method_probe.dart';

/// The `zcode-session.initializeWorkspace` method name. Single candidate on
/// purpose (method-probing.md §3a): the desktop has served it since 3.16.3
/// (10-28 + 2026-11-17 live probes), there is no older alias to try.
const String initializeWorkspaceMethod = 'initializeWorkspace';

/// Thrown when the desktop does not serve
/// `zcode-session.initializeWorkspace` (older desktop / channel not
/// whitelisted). The state layer treats this as a capability miss and retries
/// the sessions-index subscribe once in the default `start-if-needed` shape;
/// only a second cold refusal keeps the pre-wake cold-runtime banner.
class WorkspaceWakeUnavailable implements Exception {
  /// Raw desktop message when the port translated an unknown-method reply.
  final String? message;

  const WorkspaceWakeUnavailable([this.message]);

  @override
  String toString() =>
      'WorkspaceWakeUnavailable${message == null ? '' : ': $message'}';
}

/// Tightened unknown-method verdict for [initializeWorkspaceMethod].
///
/// Deliberately NOT `MethodProbe.missingMethod`: that vocabulary includes a
/// bare `not found`, and the miss is cached for the whole session. The
/// desktop's wording is `Method not found: <name>`; the method-name check
/// pins the verdict to this method. `contains` (not `startsWith`) because
/// relay / wrapper layers may prefix the text.
bool isInitializeWorkspaceMethodMissing(Object error) =>
    error is ChannelRpcError &&
    error.message.contains('Method not found:') &&
    error.message.contains(initializeWorkspaceMethod);

/// Typed answer of `zcode-session.initializeWorkspace`:
/// `{available, workspaceKey?, reason?, reasonCode?, protocolName?,
/// protocolVersion?, transportKind?}` (live 2026-11-17, desktop 3.18.2;
/// shape identical since 3.16.3).
class WorkspaceWakeResult {
  const WorkspaceWakeResult({
    required this.available,
    this.workspaceKey,
    this.reasonCode,
    this.reason,
  });

  /// The desktop's provider/model readiness gate refused to spawn the
  /// runtime (`{available:false, reasonCode:"provider_not_ready"}`).
  static const String providerNotReadyCode = 'provider_not_ready';

  final bool available;
  final String? workspaceKey;
  final String? reasonCode;
  final String? reason;

  /// The runtime cannot start until the desktop has a usable provider/model.
  bool get providerNotReady => !available && reasonCode == providerNotReadyCode;

  /// Tolerant parse: an unusable answer degrades to "not available" (the
  /// caller keeps its pre-wake behavior); only [providerNotReady] is a new
  /// classification.
  factory WorkspaceWakeResult.fromWire(Object? wire) {
    if (wire is! Map) return const WorkspaceWakeResult(available: false);
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    return WorkspaceWakeResult(
      available: wire['available'] == true,
      workspaceKey: text(wire['workspaceKey']),
      reasonCode: text(wire['reasonCode']),
      reason: text(wire['reason']),
    );
  }
}

/// Typed access to the desktop's workspace warm-up API
/// (`zcode-session.initializeWorkspace`), the one cold-start entry that
/// carries the provider gate (research remote-wake §D; live probe 2026-11-17
/// answered in 1.9-4.1 s with a stable `{available, workspaceKey, …}` shape).
///
/// Unknown-method replies become [WorkspaceWakeUnavailable] and pin the
/// verdict for the session lifetime (a desktop never gains a method
/// mid-session); every other failure rethrows untouched so the caller can
/// keep its existing classification.
class SessionRuntimePort {
  /// Binds the channel RPC (the port owns the fixed `zcode-session` channel).
  final Future<dynamic> Function(
    String channel,
    String method,
    List<Object?> args,
  ) call;

  SessionRuntimePort(this.call);

  late final MethodProbe _probe = MethodProbe(
    (method, args) => call(Channels.zcodeSession, method, args),
  );

  bool _available = true;

  /// Session-lifetime capability verdict (for tests / diagnostics).
  bool get available => _available;

  /// Starts the workspace's agent runtime if needed. Send shape is exactly
  /// `[{workspacePath, workspaceIdentity?}]` — the desktop's warm-up schema.
  Future<WorkspaceWakeResult> initializeWorkspace(
    Map<String, dynamic> scope,
  ) async {
    if (!_available) throw const WorkspaceWakeUnavailable();
    try {
      final res = await _probe.run(
        initializeWorkspaceMethod,
        const [initializeWorkspaceMethod],
        argsOf: (_) => <Object?>[scope],
      );
      return WorkspaceWakeResult.fromWire(res);
    } on ChannelRpcError catch (e) {
      if (isInitializeWorkspaceMethodMissing(e)) {
        _available = false;
        throw WorkspaceWakeUnavailable(e.message);
      }
      rethrow;
    }
  }
}
