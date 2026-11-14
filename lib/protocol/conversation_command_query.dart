// Query-side wire types for `zcode-agent.queryConversationCommandsV4`
// (task 11-13-command-reconcile, live-probed on 3.18.2).
//
// Wire contract (research/query-shape.md + 11-11 archive):
// - input (strict): `{...scope, commands: [{sessionId, commandId}] 1-64}`;
//   single-leg addressing is enough for session commands (the null leg only
//   ever addresses global/clock commands and answers "unknown" for every
//   session command). `clock: true` is not used by this task.
// - output (strict): `{results: [{key: {sessionId, commandId}, result, turn?}],
//   clock?}`, where `result` is either the exact string `"unknown"` or a
//   decision object `{commandId, status, reasonCode?, message?,
//   revisionAtDecision, ...command-specific fields}`.
//
// Parsing discipline: match by `key.sessionId + key.commandId` (array order
// is not a contract), keep the decision object as a raw map (the live 3.18.2
// shape carried an extra `memoryEnabled` field — whitelisting would drop
// command-specific fields), and treat missing/malformed results and
// `fault.command.queryUnavailable` as QUERY-side failures, never as command
// outcomes.
library;

/// One single-leg query address.
class CommandAddress {
  const CommandAddress({this.sessionId, required this.commandId});

  final String? sessionId;
  final String commandId;

  Map<String, dynamic> toWire() => {
    'sessionId': sessionId,
    'commandId': commandId,
  };

  @override
  bool operator ==(Object other) =>
      other is CommandAddress &&
      other.sessionId == sessionId &&
      other.commandId == commandId;

  @override
  int get hashCode => Object.hash(sessionId, commandId);

  @override
  String toString() => 'CommandAddress(${sessionId ?? 'null'}, $commandId)';
}

/// Decision status enum of the inbox record (wire values are the same six
/// strings). An unrecognized wire status is a query-side failure, not a
/// seventh state.
enum CommandDecisionStatus { accepted, duplicate, noop, stale, rejected, failed }

/// One decoded decision object. [raw] is the complete wire map, including
/// command-specific extra fields; typed getters are conveniences only.
class CommandDecision {
  const CommandDecision({
    required this.status,
    required this.wireStatus,
    required this.raw,
    this.commandId,
    this.reasonCode,
    this.message,
    this.revisionAtDecision,
  });

  final CommandDecisionStatus status;
  final String wireStatus;

  /// The complete decision object as received. Never a whitelist.
  final Map<String, dynamic> raw;

  /// The decision object's own commandId when present (key fallback is
  /// applied by the parser).
  final String? commandId;
  final String? reasonCode;
  final String? message;
  final int? revisionAtDecision;

  /// Arrived and applied (or intentionally unchanged): the command reached
  /// the inbox and no resend is owed.
  bool get isDelivered =>
      status == CommandDecisionStatus.accepted ||
      status == CommandDecisionStatus.duplicate ||
      status == CommandDecisionStatus.noop;

  /// The failed status here is the QUERY side failing, not the command:
  /// the official renderer filters this reasonCode out of command outcomes.
  bool get isQueryUnavailable =>
      status == CommandDecisionStatus.failed &&
      reasonCode == queryUnavailableReasonCode;

  static const String queryUnavailableReasonCode =
      'fault.command.queryUnavailable';
}

/// Per-address parse result. Exactly one of [unknown], [decision], or a
/// query-side failure is meaningful at a time.
class CommandQueryEntry {
  const CommandQueryEntry({
    required this.address,
    this.decision,
    this.turn,
    this.unknown = false,
    this.missing = false,
    this.malformed = false,
  });

  final CommandAddress address;
  final CommandDecision? decision;

  /// Optional sibling used by the official TTFT clock calibration; carried
  /// through untouched.
  final Object? turn;

  /// The exact wire sentinel `"unknown"` (not found / trimmed / possibly an
  /// arrived-but-undecided inFlight record).
  final bool unknown;

  /// Requested but absent from `results` (partial response).
  final bool missing;

  /// Present but structurally unusable (bad key/status/result type).
  final bool malformed;

  /// No command outcome can be read from this entry — retry the query later
  /// or leave the item to the TTL sweep. Never a terminal command verdict.
  bool get querySideFailure =>
      missing || malformed || (decision?.isQueryUnavailable ?? false);

  bool get resolved => unknown || (decision != null && !querySideFailure);
}

/// One `queryConversationCommandsV4` response (or a merged multi-batch
/// response) matched back to the requested addresses.
class CommandQueryOutcome {
  CommandQueryOutcome._({
    required this.entries,
    required this.clock,
    required this.malformed,
  });

  final Map<CommandAddress, CommandQueryEntry> entries;

  /// Top-level `clock?` passthrough (only present for `clock:true` calls).
  final Object? clock;

  /// True when any part of the response shape was unusable.
  final bool malformed;

  static CommandQueryOutcome empty() =>
      CommandQueryOutcome._(entries: const {}, clock: null, malformed: false);

  CommandQueryEntry? entryFor({String? sessionId, required String commandId}) =>
      entries[CommandAddress(sessionId: sessionId, commandId: commandId)];

  Iterable<CommandQueryEntry> get values => entries.values;

  bool get partial => entries.values.any((entry) => entry.querySideFailure);

  /// Parses [raw] against the addresses this call requested. Never throws on
  /// malformed wire data: unreadable pieces become [missing]/[malformed]
  /// entries instead.
  static CommandQueryOutcome parse(
    Object? raw,
    List<CommandAddress> requested,
  ) {
    final entries = <CommandAddress, CommandQueryEntry>{
      for (final address in requested)
        address: CommandQueryEntry(address: address, missing: true),
    };
    var malformed = false;
    final map = _asStringMap(raw);
    if (map == null) {
      return CommandQueryOutcome._(
        entries: entries,
        clock: null,
        malformed: true,
      );
    }
    final clock = map['clock'];
    final results = map['results'];
    if (results is! List) {
      return CommandQueryOutcome._(
        entries: entries,
        clock: clock,
        malformed: true,
      );
    }
    for (final item in results) {
      final entryMap = _asStringMap(item);
      if (entryMap == null) {
        malformed = true;
        continue;
      }
      final key = _asStringMap(entryMap['key']);
      if (key == null) {
        malformed = true;
        continue;
      }
      final commandId = key['commandId'];
      if (commandId is! String || commandId.isEmpty) {
        malformed = true;
        continue;
      }
      final rawSessionId = key['sessionId'];
      if (rawSessionId != null && rawSessionId is! String) {
        malformed = true;
        continue;
      }
      final address = CommandAddress(
        sessionId: rawSessionId as String?,
        commandId: commandId,
      );
      if (!entries.containsKey(address)) {
        // A result for an address this call did not request: ignore it —
        // matching is by key, never by array position.
        continue;
      }
      final result = entryMap['result'];
      if (result == 'unknown') {
        entries[address] = CommandQueryEntry(
          address: address,
          unknown: true,
          turn: entryMap['turn'],
        );
        continue;
      }
      final decisionMap = _asStringMap(result);
      if (decisionMap == null) {
        malformed = true;
        entries[address] = CommandQueryEntry(
          address: address,
          malformed: true,
        );
        continue;
      }
      final wireStatus = decisionMap['status'];
      final wireStatusString = wireStatus is String ? wireStatus : '';
      final status = _statusOf(wireStatusString);
      if (status == null) {
        malformed = true;
        entries[address] = CommandQueryEntry(
          address: address,
          malformed: true,
        );
        continue;
      }
      final decisionCommandId = decisionMap['commandId'];
      final reasonCode = decisionMap['reasonCode'];
      final message = decisionMap['message'];
      final revision = decisionMap['revisionAtDecision'];
      entries[address] = CommandQueryEntry(
        address: address,
        decision: CommandDecision(
          status: status,
          wireStatus: wireStatusString,
          raw: decisionMap,
          commandId: decisionCommandId is String ? decisionCommandId : null,
          reasonCode: reasonCode is String ? reasonCode : null,
          message: message is String ? message : null,
          revisionAtDecision: revision is num ? revision.toInt() : null,
        ),
        turn: entryMap['turn'],
      );
    }
    return CommandQueryOutcome._(
      entries: entries,
      clock: clock,
      malformed: malformed,
    );
  }

  /// Merges per-batch outcomes into one requested-address-keyed result.
  /// Later batches win for a duplicate address (never expected: one batch
  /// carries each address once).
  static CommandQueryOutcome merge(Iterable<CommandQueryOutcome> outcomes) {
    final entries = <CommandAddress, CommandQueryEntry>{};
    Object? clock;
    var malformed = false;
    for (final outcome in outcomes) {
      entries.addAll(outcome.entries);
      clock ??= outcome.clock;
      malformed = malformed || outcome.malformed;
    }
    return CommandQueryOutcome._(
      entries: entries,
      clock: clock,
      malformed: malformed,
    );
  }

  static CommandDecisionStatus? _statusOf(Object? value) => switch (value) {
    'accepted' => CommandDecisionStatus.accepted,
    'duplicate' => CommandDecisionStatus.duplicate,
    'noop' => CommandDecisionStatus.noop,
    'stale' => CommandDecisionStatus.stale,
    'rejected' => CommandDecisionStatus.rejected,
    'failed' => CommandDecisionStatus.failed,
    _ => null,
  };

  static Map<String, dynamic>? _asStringMap(Object? value) {
    if (value is! Map) return null;
    final out = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) return null;
      out[key] = entry.value;
    }
    return out;
  }
}

/// Schema cap: `commands` 1-64 per call.
const int commandQueryBatchSize = 64;

/// Chunks addresses into schema-legal batches; the input order is preserved.
List<List<CommandAddress>> commandQueryBatches(
  List<CommandAddress> commands,
) {
  if (commands.isEmpty) return const [];
  final batches = <List<CommandAddress>>[];
  for (var start = 0; start < commands.length; start += commandQueryBatchSize) {
    final end = start + commandQueryBatchSize;
    batches.add(
      commands.sublist(
        start,
        end > commands.length ? commands.length : end,
      ),
    );
  }
  return batches;
}

/// Builds the exact scoped-port argument of one batch. Single-leg only:
/// `{...scope, commands:[{sessionId, commandId}]}`.
Map<String, dynamic> commandQueryPayload(
  Map<String, dynamic> scope,
  List<CommandAddress> batch,
) => {
  ...scope,
  'commands': [for (final address in batch) address.toWire()],
};