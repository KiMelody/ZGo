import 'channel_client.dart';

/// Channel-method probing shared by the automation / off-peak ports: tries
/// candidate method names until the desktop accepts one. Only "no such
/// method"-style rejections advance to the next candidate — validation and
/// permission errors rethrow immediately so the real reason surfaces. The
/// winner is remembered per operation so later calls skip the probing.
class MethodProbe {
  final Future<dynamic> Function(String method, List<Object?> args) call;
  final Map<String, String> _resolved = {};

  MethodProbe(this.call);

  /// Method the desktop last accepted for [op], if any (for tests/diag).
  String? resolved(String op) => _resolved[op];

  Future<dynamic> run(
    String op,
    List<String> candidates, {
    List<Object?> Function(String method)? argsOf,
  }) async {
    final resolved = _resolved[op];
    final order = [
      if (resolved != null) resolved,
      ...candidates.where((m) => m != resolved),
    ];
    Object? firstError;
    for (final method in order) {
      try {
        final res = await call(method, argsOf?.call(method) ?? const []);
        _resolved[op] = method;
        return res;
      } on ChannelRpcError catch (e) {
        if (!missingMethod(e.message)) rethrow;
        firstError ??= e;
      }
    }
    throw firstError ?? StateError('$op: no candidate methods left');
  }

  /// The desktop reports unknown methods in several shapes; match broadly.
  static bool missingMethod(String message) {
    final m = message.toLowerCase();
    return m.contains('no such method') ||
        m.contains('unknown method') ||
        m.contains('method not found') ||
        m.contains('not found') ||
        m.contains('unsupported') ||
        m.contains('invalid method') ||
        m.contains('cannot read propert');
  }
}

/// Deleted-task tombstone ids of one workspace (`zcode-task` channel).
/// Desktop parity: the desktop's own task list filters deleted tasks via
/// `listDeletedTaskIds` — `{workspacePath, workspaceIdentity}` in, a
/// task_id string array out (desktop bundle). The live sessions-index
/// still lists those tasks, so its rows must be filtered by this set (PRD
/// Addendum 2). The method name is probed, never hardcoded as a success
/// assumption; returns null on ANY miss (unknown method, channel gone,
/// timeout, unusable answer) — callers degrade to an empty set, the
/// pre-probe behavior. This probe must never block opening a workspace.
Future<Set<String>?> probeListDeletedTaskIds(
  Future<dynamic> Function(String method, List<Object?> args) call, {
  Map<String, dynamic> scope = const {},
}) async {
  try {
    final res = await MethodProbe(call).run(
      'listDeletedTaskIds',
      const ['listDeletedTaskIds'],
      argsOf: (method) => <Object?>[scope],
    );
    if (res is! List) return null;
    return {
      for (final id in res)
        if (id is String && id.isNotEmpty) id,
    };
  } catch (_) {
    return null;
  }
}
