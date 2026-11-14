// In-memory ledger for V4 command reconciliation (task 11-13-command-
// reconcile, step 3; R7 hoists its lifetime above one transport).
//
// The ledger shadows every V4 envelope command the transport sends. A
// command that times out inside a degraded-bridge window is SUSPENDED
// instead of blindly re-sent; the reconciler queries the desktop's inbox
// (`queryConversationCommandsV4`) and resolves the item by its recorded
// decision. Everything here is pure protocol logic: no Flutter import, and
// the transport supplies the query/resend callbacks (step 4 wiring).
//
// R7 lifetime: the ledger instance survives a whole-link rebuild. The
// transport that owns it detaches it on teardown, the next transport adopts
// it (rebinding the query/resend callbacks), and the still-open outcome
// stream keeps the suspended chain observable. A resend runs through a
// preflight (session live + its workspace active) supplied by the host; a
// preflight failure backs off like a query-side failure instead of ending
// the command, and `proto.sessionNotFound` on a resend is a recoverable
// classification with one extra preflight+resend cycle inside the TTL.
//
// Semantics fixed by research/query-shape.md (live 3.18.2):
// - `"unknown"` is not "not delivered" (a stale-rejected command is never
//   query-visible, and stale decisions do not enter the queryable set), so
//   the unknown path does a second confirmation before re-sending.
// - Accepted does not necessarily advance the revision; the ledger never
//   assumes it does (it only seeds `revisionAtDecision` for stale re-entry).
// - Decision objects are command-specific passthrough maps (e.g.
//   `memoryEnabled`); the ledger stores the raw value in its outcomes.
import 'dart:async';

import 'channel_client.dart';
import 'conversation_command_query.dart';

/// Typed suspension signal thrown to callers when a command timed out in a
/// degraded-bridge window and was handed to the ledger. Extends
/// [TimeoutException] so existing generic timeout catches still see it; the
/// transport's link-failure accounting and `sendTextOrQueue` are expected to
/// check this type FIRST (step 4 wiring).
class CommandSuspendedException extends TimeoutException {
  CommandSuspendedException({required this.commandId, this.sessionId})
    : super('command suspended pending reconciliation: $commandId');

  final String commandId;
  final String? sessionId;
}

/// A resend's context preflight could not be satisfied (R7): the entry's
/// session is not live on the active bridge, or its workspace could not be
/// opened within the bounded wait. Not a command verdict — the ledger backs
/// off like a query-side failure and leaves the TTL as the bound.
class CommandPreflightException implements Exception {
  const CommandPreflightException(this.message);

  final String message;

  @override
  String toString() => 'CommandPreflightException: $message';
}

/// The desktop's pre-execution refusal for a session that is not loaded on
/// the current bridge (CommandInbox.decide). Recoverable when the client
/// first restores the session's workspace + subscription (R7).
const String commandSessionNotFoundReasonCode = 'proto.sessionNotFound';

enum CommandLedgerState { inflight, suspended }

/// How a ledger item ended. `superseded`/`abandoned` are silent internal
/// transitions (no UI outcome); the rest are terminal command facts.
enum CommandLedgerSettlement {
  delivered,
  rejected,
  failed,
  timedOut,
  superseded,
  abandoned,
}

/// Terminal outcome emitted for a suspended command (or its resend chain).
/// switchModelConfig is recorded but never emitted — the §12 snapshot/revert
/// chain owns that command's user-visible terminal state.
class CommandLedgerOutcome {
  const CommandLedgerOutcome({
    required this.commandId,
    required this.rootCommandId,
    required this.sessionId,
    required this.kind,
    required this.settlement,
    this.decision,
  });

  /// The item that actually settled (the original or its resend).
  final String commandId;

  /// The suspension chain's origin — UI chips bind this id.
  final String rootCommandId;
  final String? sessionId;
  final String kind;
  final CommandLedgerSettlement settlement;

  /// The raw decision object when the outcome came from a query.
  final CommandDecision? decision;
}

/// One re-entry request. The transport binds [CommandLedgerResend] to
/// `sendCommand` with the added `attempt/rootCommandId/reconcile` seam:
/// - `reconcile: true`  — query-driven resend (fresh commandId, base revision
///   re-read; `seedRevision` is applied to `_ackedRevisions` first when the
///   query reported stale);
/// - `reconcile: false` — gate-close handoff (no query, no new ledger entry,
///   no recursive suspension; sendCommand refetches the CAS revision itself).
class CommandResendRequest {
  const CommandResendRequest({
    required this.commandId,
    required this.rootCommandId,
    required this.sessionId,
    required this.kind,
    required this.payload,
    required this.channelExtra,
    required this.attempt,
    required this.reconcile,
    this.seedRevision,
    this.sentAt,
    this.notFoundRetries = 0,
  });

  /// The suspended command being re-entered.
  final String commandId;
  final String rootCommandId;
  final String? sessionId;
  final String kind;
  final Map<String, dynamic> payload;
  final Map<String, dynamic>? channelExtra;

  /// Attempt number of the NEW send (original attempt + 1).
  final int attempt;
  final bool reconcile;

  /// Query-reported `revisionAtDecision` for the stale bucket.
  final int? seedRevision;

  /// The chain's origin send time — resends keep the ORIGINAL 2min TTL
  /// deadline instead of restarting it on every re-entry.
  final DateTime? sentAt;

  /// How many recoverable `proto.sessionNotFound` cycles already ran in
  /// this chain (carried so a resend entry cannot restart the budget).
  final int notFoundRetries;
}

/// One tracked command. [state] and the confirmation flags are the ledger's
/// own bookkeeping; the wire-facing fields are immutable.
class CommandLedgerEntry {
  CommandLedgerEntry({
    required this.commandId,
    required this.sessionId,
    required this.kind,
    required this.semanticPayload,
    required this.channelExtra,
    required this.sentAt,
    required this.attempt,
    this.rootCommandId,
    this.notFoundRetries = 0,
  });

  final String commandId;
  final String? sessionId;
  final String kind;
  final Map<String, dynamic> semanticPayload;
  final Map<String, dynamic>? channelExtra;
  final DateTime sentAt;
  final int attempt;
  final String? rootCommandId;

  CommandLedgerState state = CommandLedgerState.inflight;

  /// Recoverable `proto.sessionNotFound` cycles already spent by this
  /// chain (R7). The budget is per chain, not per resend entry.
  int notFoundRetries;

  /// Backoff rounds already scheduled for a failed preflight/sessionNotFound
  /// retry (R7). Caps at the query-side retry schedule length.
  int retrySchedules = 0;
  bool retryScheduled = false;

  /// The first `"unknown"` answer scheduled the ~5s second confirmation.
  bool confirmScheduled = false;

  /// The second confirmation completed; the next unknown means re-send.
  bool confirmed = false;

  /// A resend is on the wire; concurrent rounds must not pick this item.
  bool resending = false;

  String get rootId => rootCommandId ?? commandId;
  bool get isSuspended => state == CommandLedgerState.suspended;
}

typedef CommandLedgerQuery =
    Future<CommandQueryOutcome> Function(List<CommandAddress> commands);
typedef CommandLedgerResend =
    Future<void> Function(CommandResendRequest request);

/// `Method not found:` AND the query method name (method-probing.md §3a).
/// Deliberately stricter than MethodProbe.missingMethod: the consequence is
/// a transport-lifetime ledger shutdown, so a bare `not found` must not hit.
bool isQueryMethodMissingError(Object error) =>
    error is ChannelRpcError &&
    error.message.contains('Method not found:') &&
    error.message.contains('queryConversationCommandsV4');

/// Deterministic capability refusals: retrying (or leaving items suspended)
/// is pointless, so two consecutive hits close the ledger and hand the
/// existing suspended items back to the legacy blind-resend path.
bool isQueryCapabilityRefusalError(Object error) {
  if (error is! ChannelRpcError) return false;
  final text = '${error.message} ${error.data}';
  return text.contains('fault.command.queryConnectionUntrusted') ||
      text.contains('fault.command.queryForeignWorkspace');
}

class CommandLedger {
  CommandLedger({
    required CommandLedgerQuery query,
    required CommandLedgerResend resend,
    DateTime Function()? now,
    Duration ttl = const Duration(minutes: 2),
    Duration secondConfirmDelay = const Duration(seconds: 5),
    List<Duration> queryRetryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
    ],
    int maxAttempts = 1,
    int maxNotFoundRetries = 1,
    void Function(String line)? onLog,
  }) : assert(maxAttempts >= 0),
       assert(maxNotFoundRetries >= 0),
       _query = query,
       _resendCallback = resend,
       _now = now ?? DateTime.now,
       _ttl = ttl,
       _secondConfirmDelay = secondConfirmDelay,
       _queryRetryDelays = List<Duration>.unmodifiable(queryRetryDelays),
       _maxAttempts = maxAttempts,
       _maxNotFoundRetries = maxNotFoundRetries,
       _onLog = onLog;

  CommandLedgerQuery _query;
  CommandLedgerResend _resendCallback;
  final DateTime Function() _now;
  final Duration _ttl;
  final Duration _secondConfirmDelay;
  final List<Duration> _queryRetryDelays;
  final int _maxAttempts;
  final int _maxNotFoundRetries;
  void Function(String line)? _onLog;

  /// Rebind the host seams after a transport handoff (R7): the ledger keeps
  /// its entries/timers/outcome stream, while queries and resends now ride
  /// the adopted transport (and its host preflight).
  void rebind({
    required CommandLedgerQuery query,
    required CommandLedgerResend resend,
    void Function(String line)? onLog,
  }) {
    _query = query;
    _resendCallback = resend;
    _onLog = onLog;
  }

  /// Idempotent replay pairs keep the existing same-commandId retry
  /// mechanism (protocol-guidelines.md) and never enter the ledger.
  static const Set<String> _idempotentKinds = {
    'createSession',
    'createSelectionSideSession',
  };

  final Map<String, CommandLedgerEntry> _entries = {};
  final Map<String, Timer> _ttlTimers = {};
  final Map<String, Timer> _confirmTimers = {};
  final Map<String, Timer> _retryTimers = {};
  final StreamController<CommandLedgerOutcome> _outcomes =
      StreamController<CommandLedgerOutcome>.broadcast();

  Timer? _queryRetryTimer;
  int _queryRetryAttempt = 0;
  int _capabilityRefusals = 0;
  bool _disabled = false;
  bool _disposed = false;
  bool _reconciling = false;
  Future<void>? _reconcileFuture;
  Future<void>? _handoffFuture;

  /// Terminal outcomes for suspended items (delivered/rejected/failed/
  /// timedOut). Normal acks and superseded items stay silent.
  Stream<CommandLedgerOutcome> get outcomes => _outcomes.stream;

  List<CommandLedgerEntry> get entries =>
      List<CommandLedgerEntry>.unmodifiable(_entries.values);

  CommandLedgerEntry? entry(String commandId) => _entries[commandId];

  bool get ledgerDisabled => _disabled;

  /// New suspensions must not be created once the gate closed; the transport
  /// falls back to its legacy blind-resend path instead.
  bool get canSuspend => !_disabled && !_disposed;

  /// Whether a timed-out command may be suspended. A resend entry
  /// (`attempt >= maxAttempts`) must go straight to its terminal failure —
  /// the transport uses this before [suspend] so the chain cannot loop.
  bool shouldSuspend(String commandId) {
    final entry = _entries[commandId];
    if (entry == null || !canSuspend) return false;
    return entry.attempt < _maxAttempts;
  }

  /// Records a freshly sent V4 envelope command.
  ///
  /// Returns false for the idempotent replay pairs (not tracked). Recording
  /// a resend (a [rootCommandId] is present) immediately supersedes the root
  /// item without emitting an outcome — the resend's own send/ack path owns
  /// the chain from then on, and the root must never be TTL-failed while
  /// the resend is in flight.
  bool record({
    required String commandId,
    required String? sessionId,
    required String kind,
    required Map<String, dynamic> semanticPayload,
    Map<String, dynamic>? channelExtra,
    int attempt = 0,
    String? rootCommandId,
    String? supersedeCommandId,
    DateTime? sentAt,
    int notFoundRetries = 0,
  }) {
    if (_disposed) return false;
    if (_idempotentKinds.contains(kind)) return false;
    if (rootCommandId != null) _drop(rootCommandId);
    // A chained resend (the current item is itself a resend) is superseded
    // atomically with the new record; the root drop alone would leave it
    // suspended and TTL-fail later (R7 retry cycle).
    if (supersedeCommandId != null) _drop(supersedeCommandId);
    // A duplicate id (never expected: fresh uuids) must not leave the old
    // entry's TTL/confirmation timers armed against the new record.
    _drop(commandId);
    _entries[commandId] = CommandLedgerEntry(
      commandId: commandId,
      sessionId: sessionId,
      kind: kind,
      semanticPayload: Map<String, dynamic>.from(semanticPayload),
      channelExtra: channelExtra == null
          ? null
          : Map<String, dynamic>.from(channelExtra),
      sentAt: sentAt ?? _now(),
      attempt: attempt,
      rootCommandId: rootCommandId,
      notFoundRetries: notFoundRetries,
    );
    return true;
  }

  /// Settles a tracked command from its normal ack (not from a query).
  ///
  /// Non-rooted items settle silently — the caller already holds the ack.
  /// A rooted resend emits a terminal outcome so the suspension chain can
  /// upgrade its chip (except switchModelConfig, which §12 owns).
  bool settleFromAck(String commandId, Object? ack) {
    final entry = _entries[commandId];
    if (entry == null) return false;
    final status = ack is Map ? ack['status'] : null;
    final settlement = switch (status) {
      'rejected' => CommandLedgerSettlement.rejected,
      'failed' || 'stale' => CommandLedgerSettlement.failed,
      _ => CommandLedgerSettlement.delivered,
    };
    _settle(
      entry,
      settlement: settlement,
      emit: entry.rootCommandId != null || entry.isSuspended,
    );
    return true;
  }

  /// A resend answered `rejected + proto.sessionNotFound` (R7): the desktop
  /// refused before execution because the session was not live on the
  /// current bridge. Recoverable — keep the chain suspended and schedule one
  /// preflight+resend cycle; only a second hit (or an expired TTL) is
  /// terminal. Returns true when the item was kept.
  bool recoverableSessionNotFound(String commandId, Object? ack) {
    final entry = _entries[commandId];
    if (entry == null) return false;
    return _recoverFromSessionNotFound(
      entry,
      decision: _sessionNotFoundDecision(ack),
    );
  }

  bool _recoverFromSessionNotFound(
    CommandLedgerEntry entry, {
    required CommandDecision decision,
  }) {
    if (entry.notFoundRetries >= _maxNotFoundRetries ||
        _expired(entry, _now())) {
      _settle(
        entry,
        settlement: CommandLedgerSettlement.rejected,
        decision: decision,
        emit: true,
      );
      return false;
    }
    entry.notFoundRetries++;
    entry.state = CommandLedgerState.suspended;
    entry.resending = false;
    entry.confirmScheduled = false;
    entry.confirmed = false;
    _armTtl(entry);
    _log(
      '[ledger] ${entry.commandId} not found on the bridge; '
      'preflight+resend retry',
    );
    _scheduleEntryRetry(
      entry,
      () => unawaited(
        _resend(
          entry,
          seedRevision: null,
          exhaustedSettlement: CommandLedgerSettlement.rejected,
          allowAtBound: true,
        ),
      ),
    );
    return true;
  }

  CommandDecision _sessionNotFoundDecision(Object? ack) {
    final raw = ack is Map
        ? ack.map((key, value) => MapEntry('$key', value))
        : <String, dynamic>{};
    final reason = raw['reasonCode'];
    final message = raw['message'];
    final revision = raw['revisionAtDecision'];
    final commandId = raw['commandId'];
    return CommandDecision(
      status: CommandDecisionStatus.rejected,
      wireStatus: 'rejected',
      raw: raw,
      commandId: commandId is String ? commandId : null,
      reasonCode: reason is String ? reason : commandSessionNotFoundReasonCode,
      message: message is String ? message : null,
      revisionAtDecision: revision is num ? revision.toInt() : null,
    );
  }

  /// Bounded backoff for a failed preflight / recoverable-not-found retry
  /// (R7). Reuses the query-side schedule (5s/15s by default); the TTL timer
  /// stays armed, so a chain that never recovers ends with the existing
  /// timeout semantics instead of a command verdict.
  void _scheduleEntryRetry(
    CommandLedgerEntry entry,
    void Function() action, {
    bool allowDisabled = false,
  }) {
    if (_disposed) return;
    if (_disabled && !allowDisabled) return;
    if (entry.retryScheduled) return;
    if (entry.retrySchedules >= _queryRetryDelays.length) return;
    final delay = _queryRetryDelays[entry.retrySchedules++];
    entry.retryScheduled = true;
    _retryTimers[entry.commandId]?.cancel();
    _retryTimers[entry.commandId] = Timer(delay, () {
      _retryTimers.remove(entry.commandId);
      entry.retryScheduled = false;
      if (_disposed) return;
      if (!identical(_entries[entry.commandId], entry) ||
          !entry.isSuspended) {
        return;
      }
      if (_expired(entry, _now())) {
        _settleTimedOut(entry);
        return;
      }
      if (entry.resending) {
        // A query-triggered resend or the gate-close handoff is already on
        // the wire for this entry. Firing this retry now would put the same
        // payload on the wire twice; that in-flight round either settles/
        // supersedes the entry or schedules its own follow-up retry.
        return;
      }
      action();
    });
  }

  /// Clears an item on a NON-suspension failure path (handshake failure,
  /// waitHealthy timeout, non-degraded timeout, deterministic RPC error)
  /// before the transport rethrows. Emits nothing; TTL only scans suspended
  /// items, so this is the only cleanup for those paths.
  bool discard(String commandId) {
    final entry = _entries[commandId];
    if (entry == null) return false;
    _settle(
      entry,
      settlement: CommandLedgerSettlement.abandoned,
      emit: false,
    );
    return true;
  }

  /// Suspends a timed-out command and immediately starts the first
  /// reconciliation round (fire-and-forget: the caller gets the sentinel
  /// first, the query never blocks the suspension notice). [handshake] is
  /// awaited inside the transport's query callback.
  CommandSuspendedException suspend(String commandId) {
    final entry = _entries[commandId];
    if (entry == null) {
      throw StateError('commandLedger: command not tracked: $commandId');
    }
    if (_disabled) {
      throw StateError('commandLedger: ledger disabled');
    }
    if (entry.state != CommandLedgerState.suspended) {
      entry.state = CommandLedgerState.suspended;
      _armTtl(entry);
      unawaited(reconcile());
    }
    return CommandSuspendedException(
      commandId: commandId,
      sessionId: entry.sessionId,
    );
  }

  /// Runs one reconciliation round over every suspended, queryable item.
  ///
  /// This is the first-round trigger (from [suspend]), the bridge-recovered
  /// compensation trigger and the query-failure backoff trigger — all three
  /// share this entry point, so the transport's `handshake()`-first rule is
  /// enforced in one place. Rounds never overlap.
  Future<void> reconcile() {
    if (_disposed || _disabled) return Future<void>.value();
    if (_reconciling) return _reconcileFuture ?? Future<void>.value();
    final future = _reconcile();
    _reconcileFuture = future;
    return future;
  }

  Future<void> _reconcile() async {
    _reconciling = true;
    try {
      final now = _now();
      final queryable = <CommandLedgerEntry>[];
      for (final entry in List<CommandLedgerEntry>.of(_entries.values)) {
        if (!entry.isSuspended || entry.resending) continue;
        if (_expired(entry, now)) {
          _settleTimedOut(entry);
          continue;
        }
        // Null-session entries cannot be addressed by the single-leg query
        // (the null leg only covers global/clock commands); the TTL sweep is
        // their existing-timeout path.
        if (entry.sessionId == null) continue;
        queryable.add(entry);
      }
      if (queryable.isEmpty) return;

      CommandQueryOutcome outcome;
      try {
        outcome = await _query([
          for (final entry in queryable)
            CommandAddress(
              sessionId: entry.sessionId,
              commandId: entry.commandId,
            ),
        ]);
        noteQuerySuccess();
      } catch (error) {
        final disabled = noteQueryFailure(error);
        if (disabled) return;
        _scheduleQueryRetry();
        return;
      }

      var needRetry = false;
      for (final entry in queryable) {
        if (!_entries.containsKey(entry.commandId) || entry.resending) {
          continue;
        }
        final result = outcome.entryFor(
          sessionId: entry.sessionId,
          commandId: entry.commandId,
        );
        if (result == null || result.querySideFailure) {
          needRetry = true;
          continue;
        }
        await _applyQueryEntry(entry, result);
      }
      if (!needRetry) _queryRetryAttempt = 0;
      if (needRetry) _scheduleQueryRetry();
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _applyQueryEntry(
    CommandLedgerEntry entry,
    CommandQueryEntry result,
  ) async {
    if (result.unknown) {
      await _handleUnknown(entry);
      return;
    }
    final decision = result.decision;
    if (decision == null || decision.isQueryUnavailable) return;
    if (decision.isDelivered) {
      _settle(
        entry,
        settlement: CommandLedgerSettlement.delivered,
        decision: decision,
        emit: true,
      );
      return;
    }
    if (decision.status == CommandDecisionStatus.stale) {
      await _resend(
        entry,
        seedRevision: decision.revisionAtDecision,
        decision: decision,
        exhaustedSettlement: CommandLedgerSettlement.failed,
      );
      return;
    }
    // R7: a pre-execution sessionNotFound refusal is recoverable — the
    // command never reached execution, so a preflight+resend after restoring
    // the session's workspace/subscription can still deliver it.
    if (decision.status == CommandDecisionStatus.rejected &&
        decision.reasonCode == commandSessionNotFoundReasonCode) {
      _recoverFromSessionNotFound(entry, decision: decision);
      return;
    }
    _settle(
      entry,
      settlement: decision.status == CommandDecisionStatus.rejected
          ? CommandLedgerSettlement.rejected
          : CommandLedgerSettlement.failed,
      decision: decision,
      emit: true,
    );
  }

  Future<void> _handleUnknown(CommandLedgerEntry entry) async {
    if (_expired(entry, _now())) {
      _settleTimedOut(entry);
      return;
    }
    if (!entry.confirmed) {
      if (entry.confirmScheduled) return;
      entry.confirmScheduled = true;
      _confirmTimers[entry.commandId]?.cancel();
      _confirmTimers[entry.commandId] = Timer(_secondConfirmDelay, () {
        _confirmTimers.remove(entry.commandId);
        final current = _entries[entry.commandId];
        if (current == null || !current.isSuspended) return;
        current.confirmScheduled = false;
        current.confirmed = true;
        unawaited(reconcile());
      });
      return;
    }
    await _resend(
      entry,
      seedRevision: null,
      exhaustedSettlement: CommandLedgerSettlement.timedOut,
    );
  }

  /// Re-enters the command through the transport's `sendCommand` callback.
  ///
  /// The original item is NOT settled here: the new send records itself with
  /// [CommandLedgerEntry.rootCommandId] and [record] supersedes the original
  /// at that instant ("重发条目入账即 supersede"). If the call fails before
  /// recording, the original stays suspended and the TTL remains its bound.
  Future<void> _resend(
    CommandLedgerEntry entry, {
    required int? seedRevision,
    required CommandLedgerSettlement exhaustedSettlement,
    CommandDecision? decision,
    bool allowAtBound = false,
  }) async {
    final atBound = entry.attempt >= _maxAttempts;
    if ((atBound && !allowAtBound) || entry.sessionId == null) {
      _settle(
        entry,
        settlement: exhaustedSettlement,
        decision: decision,
        emit: true,
      );
      return;
    }
    entry.resending = true;
    final request = CommandResendRequest(
      commandId: entry.commandId,
      rootCommandId: entry.rootId,
      sessionId: entry.sessionId,
      kind: entry.kind,
      payload: Map<String, dynamic>.from(entry.semanticPayload),
      channelExtra: entry.channelExtra == null
          ? null
          : Map<String, dynamic>.from(entry.channelExtra!),
      attempt: entry.attempt + 1,
      reconcile: true,
      seedRevision: seedRevision,
      sentAt: entry.sentAt,
      notFoundRetries: entry.notFoundRetries,
    );
    _log(
      '[ledger] resend ${entry.commandId} -> attempt ${request.attempt} '
      '(${entry.kind})',
    );
    try {
      await _resendCallback(request);
    } on CommandPreflightException catch (error) {
      // R7: the host could not restore the session context. Not a command
      // verdict — keep the suspension, back off, and let the TTL bound it.
      _log('[ledger] resend preflight failed: $error');
      if (identical(_entries[entry.commandId], entry) && entry.isSuspended) {
        _scheduleEntryRetry(
          entry,
          () => unawaited(
            _resend(
              entry,
              seedRevision: seedRevision,
              exhaustedSettlement: exhaustedSettlement,
              decision: decision,
              allowAtBound: allowAtBound,
            ),
          ),
        );
      }
    } catch (error) {
      // The resend's own failure path belongs to the transport (it either
      // records a new item or throws to the original caller); the ledger
      // keeps the original suspension so TTL still bounds it.
      _log('[ledger] resend failed: $error');
    } finally {
      if (identical(_entries[entry.commandId], entry)) {
        entry.resending = false;
      }
    }
  }

  // The callback field is [_resendCallback] so [_resend] can stay the
  // orchestration method.

  /// Gate-close handoff: every currently suspended item is re-entered once
  /// with `reconcile:false` (no query, no new ledger item, no recursive
  /// suspension), two workers at most. R7: the host preflight runs inside
  /// the same resend callback; a preflight failure keeps the item suspended
  /// (TTL bound) and backs off instead of silently dropping the message.
  /// The cached future resets on completion so a later trigger can retry
  /// whatever a failed preflight left behind.
  Future<void> handOffSuspended() {
    final existing = _handoffFuture;
    if (existing != null) return existing;
    final future = _handOffSuspended();
    _handoffFuture = future;
    return future.whenComplete(() {
      if (identical(_handoffFuture, future)) _handoffFuture = null;
    });
  }

  Future<void> _handOffSuspended() async {
    _queryRetryTimer?.cancel();
    _queryRetryTimer = null;
    final pending = [
      for (final entry in _entries.values)
        if (entry.isSuspended && !entry.resending) entry,
    ];
    if (pending.isEmpty) return;
    var next = 0;
    Future<void> worker() async {
      while (next < pending.length) {
        final entry = pending[next++];
        if (!identical(_entries[entry.commandId], entry) ||
            !entry.isSuspended) {
          continue;
        }
        await _handOffOne(entry);
      }
    }

    await Future.wait([worker(), worker()]);
  }

  Future<void> _handOffOne(CommandLedgerEntry entry) async {
    if (!identical(_entries[entry.commandId], entry) ||
        !entry.isSuspended) {
      return;
    }
    final request = CommandResendRequest(
      commandId: entry.commandId,
      rootCommandId: entry.rootId,
      sessionId: entry.sessionId,
      kind: entry.kind,
      payload: Map<String, dynamic>.from(entry.semanticPayload),
      channelExtra: entry.channelExtra == null
          ? null
          : Map<String, dynamic>.from(entry.channelExtra!),
      attempt: entry.attempt,
      reconcile: false,
      sentAt: entry.sentAt,
      notFoundRetries: entry.notFoundRetries,
    );
    try {
      await _resendCallback(request);
      _settle(
        entry,
        settlement: CommandLedgerSettlement.superseded,
        emit: false,
      );
    } on CommandPreflightException catch (error) {
      _log('[ledger] handoff preflight failed: $error');
      if (identical(_entries[entry.commandId], entry) && entry.isSuspended) {
        _scheduleEntryRetry(
          entry,
          () => unawaited(_handOffOne(entry)),
          allowDisabled: true,
        );
      }
    } catch (error) {
      _log('[ledger] handoff resend failed: $error');
      _settle(
        entry,
        settlement: CommandLedgerSettlement.superseded,
        emit: false,
      );
    }
  }

  /// Reaction to a query-side exception from the transport. Returns true
  /// when the gate closed (caller must not schedule a backoff retry).
  bool noteQueryFailure(Object error) {
    if (_disabled) return true;
    if (isQueryMethodMissingError(error)) {
      _disable();
      return true;
    }
    if (isQueryCapabilityRefusalError(error)) {
      _capabilityRefusals++;
      if (_capabilityRefusals >= 2) {
        _disable();
        return true;
      }
      return false;
    }
    return false;
  }

  /// Any successful query resets the consecutive capability-refusal count.
  void noteQuerySuccess() {
    _capabilityRefusals = 0;
  }

  void _disable() {
    if (_disabled) return;
    _disabled = true;
    _log('[ledger] disabled — handing suspended items to the fallback path');
    unawaited(handOffSuspended());
  }

  void _scheduleQueryRetry() {
    if (_disabled || _disposed) return;
    if (_queryRetryAttempt >= _queryRetryDelays.length) return;
    final delay = _queryRetryDelays[_queryRetryAttempt++];
    _queryRetryTimer?.cancel();
    _queryRetryTimer = Timer(delay, () {
      _queryRetryTimer = null;
      if (_disabled || _disposed) return;
      unawaited(reconcile());
    });
  }

  bool _expired(CommandLedgerEntry entry, DateTime now) =>
      now.difference(entry.sentAt) >= _ttl;

  void _armTtl(CommandLedgerEntry entry) {
    _ttlTimers[entry.commandId]?.cancel();
    final remaining = _ttl - _now().difference(entry.sentAt);
    _ttlTimers[entry.commandId] = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        _ttlTimers.remove(entry.commandId);
        final current = _entries[entry.commandId];
        if (current == null || !current.isSuspended) return;
        _settleTimedOut(current);
      },
    );
  }

  void _settleTimedOut(CommandLedgerEntry entry) {
    _settle(
      entry,
      settlement: CommandLedgerSettlement.timedOut,
      emit: true,
    );
  }

  void _settle(
    CommandLedgerEntry entry, {
    required CommandLedgerSettlement settlement,
    required bool emit,
    CommandDecision? decision,
  }) {
    final removed = _entries.remove(entry.commandId);
    if (removed == null) return;
    _cancelTimers(entry.commandId);
    if (!emit || _disposed || entry.kind == 'switchModelConfig') return;
    _outcomes.add(
      CommandLedgerOutcome(
        commandId: entry.commandId,
        rootCommandId: entry.rootId,
        sessionId: entry.sessionId,
        kind: entry.kind,
        settlement: settlement,
        decision: decision,
      ),
    );
  }

  void _drop(String commandId) {
    final entry = _entries.remove(commandId);
    if (entry == null) return;
    _cancelTimers(commandId);
  }

  void _cancelTimers(String commandId) {
    _ttlTimers.remove(commandId)?.cancel();
    _confirmTimers.remove(commandId)?.cancel();
    _retryTimers.remove(commandId)?.cancel();
  }

  void _log(String line) => _onLog?.call(line);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _queryRetryTimer?.cancel();
    _queryRetryTimer = null;
    for (final timer in [
      ..._ttlTimers.values,
      ..._confirmTimers.values,
      ..._retryTimers.values,
    ]) {
      timer.cancel();
    }
    _ttlTimers.clear();
    _confirmTimers.clear();
    _retryTimers.clear();
    _entries.clear();
    await _outcomes.close();
  }
}