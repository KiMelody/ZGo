/// Failure ledger + escalation policy for one device link (ADR-0009),
/// extracted verbatim from DeviceSession's dead-channel defence.
///
/// Failure tiers (the contract DeviceSession.callChannel fed until this
/// extraction):
/// - Bridge-level ([noteGateTimeout], the WorkspaceGate.waitHealthy
///   expiry): the link itself is degraded — escalate on the FIRST
///   occurrence, no per-channel counting.
/// - Channel-level ([noteChannelLevelFailure], the desktop's
///   `Channel name … timed out` answer, or the RPC timing out): counted per
///   channel; only [channelFailThreshold] consecutive failures escalate,
///   and any success on the channel ([noteChannelSuccess]) clears its
///   streak. A dead channel then degrades only the pages that use it, not
///   the link.
/// - Deterministic RPC errors (method not found, bad args) never reach the
///   ledger: the caller classifies with the protocol predicates
///   (isChannelLevelError / isChannelMissingError) and reports only
///   channel-level failures here.
///
/// All escalations — bridge-level and tri-strike alike — share ONE debounce
/// window: [onEscalate] is invoked at most once per [escalationDebounce],
/// so a permanently dead channel rebuilds at most once per window instead
/// of on every call. The stamp is taken only when [onEscalate] reports the
/// rebuild as actually scheduled, which keeps this window an exact mirror
/// of DeviceSession's authoritative one (shared with the list watchdog and
/// reloadTasks paths, which bypass this class).
class LinkSupervisor {
  LinkSupervisor({
    required this.onEscalate,
    required this.now,
    this.channelFailThreshold = 3,
    this.escalationDebounce = const Duration(seconds: 30),
    this.onLog,
  });

  /// The link rebuild action (DeviceSession's suspend+reconnect). Returns
  /// whether a rebuild was actually scheduled; a `false` return does not
  /// arm the debounce window, so the next escalation can still reach it.
  final bool Function(String reason) onEscalate;

  /// Wall clock source (tests inject a stub).
  final DateTime Function() now;

  /// Consecutive channel-level failures that escalate into a rebuild.
  final int channelFailThreshold;

  /// Minimum spacing between escalations so probe storms can't thrash.
  final Duration escalationDebounce;

  /// Optional sink for the tri-strike log line (DeviceSession's `_log`,
  /// which prefixes the device id).
  final void Function(String line)? onLog;

  /// Consecutive channel-level failures per channel name.
  final Map<String, int> _streaks = {};

  /// Wall clock of the last accepted escalation, for debouncing.
  DateTime _lastEscalationAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Any success proves the channel rides a live bridge again.
  void noteChannelSuccess(String channel) {
    _streaks.remove(channel);
  }

  /// Counts one channel-level failure of [channel]. At the threshold the
  /// streak escalates into the (debounced) link rebuild and resets — the
  /// reset happens regardless of the debounce verdict, so a permanently
  /// dead channel escalates at most once per window instead of on every
  /// call.
  void noteChannelLevelFailure(String channel, String reason) {
    final streak = (_streaks[channel] ?? 0) + 1;
    if (streak < channelFailThreshold) {
      _streaks[channel] = streak;
      return;
    }
    _streaks.remove(channel);
    onLog?.call('channel $channel failed $streak times in a row; '
        'treating the link as stalled');
    _requestEscalation(reason);
  }

  /// The bridge health gate expired: the link itself is degraded, so the
  /// first occurrence escalates — still through the shared debounce window
  /// (an escalation that just ran keeps parallel gate expiries quiet).
  /// Channel streaks are untouched: the gate says nothing about them.
  void noteGateTimeout(String reason) {
    _requestEscalation(reason);
  }

  /// Drops every channel streak (session suspend/reconnect). The debounce
  /// stamp survives: a rebuild that just ran keeps its window across the
  /// suspend.
  void reset() {
    _streaks.clear();
  }

  void _requestEscalation(String reason) {
    final at = now();
    if (at.difference(_lastEscalationAt) < escalationDebounce) return;
    if (!onEscalate(reason)) return;
    _lastEscalationAt = at;
  }
}
