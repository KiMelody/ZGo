import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';

/// Terminal statuses that end the work (stream-row `status` / works-entry
/// `status`); anything else reports ongoing progress.
const subagentTerminalStatuses = {
  'success',
  'error',
  'failed',
  'cancelled',
  'stopped',
  'denied',
};

/// `subagents.running[]` as the terminal-hysteresis view sees it: a replayed
/// running entry within the window of an observed terminal is dropped. This
/// is the data source of the composer pill and the management sheet's
/// running section (official `subagents.running` 口径, not backgroundWorks).
List<Map<String, dynamic>> subagentsRunningView(
  ConversationState state,
  SubagentFeed? feed,
) {
  final info = state.subagentsInfo;
  final list = info?['running'];
  final all = list is List
      ? list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
      : const <Map<String, dynamic>>[];
  return all.where((a) {
    final effective = feed?.effectiveStatus(
          '${a['childSessionId'] ?? ''}',
          '${a['status'] ?? 'running'}',
        ) ??
        'running';
    return !subagentTerminalStatuses.contains(effective);
  }).toList();
}

class _ChildEntry {
  int refs = 0;
  bool subscribing = false;
  ChatHandle? handle;
}

/// Terminal-hysteresis memory of one subagent entity (childSessionId-keyed).
class _TerminalRecord {
  String status;
  DateTime at;

  /// When the first running report against the terminal arrived — the
  /// regression stopwatch anchor (see [SubagentFeed.effectiveStatus]).
  DateTime? runningSince;

  _TerminalRecord(this.status, this.at);
}

/// Session-level pool of child-session subscriptions plus the subagent
/// terminal-state hysteresis (task internal-task A+B/E).
///
/// The parent conversation stream never carries a subagent's tool activity
/// (300-row sample: nestedChildToolRows=0) — the official web subscribes
/// the child session and groups client-side. This pool shares ONE
/// `ChatGateway.subscribe` per childSessionId across consumers (Agent tile
/// expansion, running works-bar entries, goal-panel running tiles) with
/// reference counting; refs back to zero closes the subscription.
///
/// Bridge degradations replay stale frames (success → 26s later running →
/// success, live-probed 2026-09-16). A running report within
/// [regressionHysteresis] of an observed terminal therefore keeps the
/// terminal view — the notification hub's regression guard (d63077b)
/// applied to the chat UI. The memory is fed by [observe] (parent rows +
/// backgroundWorks) and read through [effectiveStatus].
class SubagentFeed extends ChangeNotifier {
  SubagentFeed({
    required this.gateway,
    this.regressionHysteresis = const Duration(seconds: 15),
  });

  final ChatGateway gateway;

  /// How long a running report must persist before it un-finishes an
  /// already-terminal subagent.
  final Duration regressionHysteresis;

  final _children = <String, _ChildEntry>{};
  final _terminal = <String, _TerminalRecord>{};
  ConversationState? _observed;
  Timer? _expiryTimer;
  bool _disposed = false;

  // ------------------------------------------- subscription pool (A+B)

  /// Acquires a shared subscription for [childSessionId]. Refcounting is
  /// synchronous; the subscribe RPC runs in the background and its errors
  /// are swallowed — consumers degrade to parent-side data (the action tail
  /// falls back to the parent summaryText).
  void acquire(String childSessionId) {
    if (_disposed || childSessionId.isEmpty) return;
    final entry = _children.putIfAbsent(childSessionId, _ChildEntry.new);
    entry.refs++;
    if (entry.handle == null && !entry.subscribing) {
      _subscribeChild(childSessionId, entry);
    }
  }

  Future<void> _subscribeChild(
    String childSessionId,
    _ChildEntry entry,
  ) async {
    entry.subscribing = true;
    try {
      final handle = await gateway.subscribe(childSessionId);
      if (_disposed || entry.refs == 0 || _children[childSessionId] != entry) {
        // Released (or the page died) while subscribing.
        entry.subscribing = false;
        await _closeQuietly(handle);
        return;
      }
      entry
        ..subscribing = false
        ..handle = handle;
      handle.state.addListener(notifyListeners);
      notifyListeners();
    } catch (_) {
      // Subscribing a child is an enhancement (live action tail / inline
      // transcript); leave the entry without a handle and let the next
      // acquire retry.
      entry.subscribing = false;
    }
  }

  /// Releases one reference; the last one closes the subscription.
  void release(String childSessionId) {
    if (_disposed) return;
    final entry = _children[childSessionId];
    if (entry == null || entry.refs == 0) return;
    entry.refs--;
    if (entry.refs > 0) return;
    _children.remove(childSessionId);
    final handle = entry.handle;
    handle?.state.removeListener(notifyListeners);
    entry.handle = null;
    unawaited(_closeQuietly(handle));
  }

  /// Live child conversation state, null without an active subscription.
  ConversationState? childState(String childSessionId) =>
      _children[childSessionId]?.handle?.state;

  // --------------------------------------------- terminal hysteresis (E)

  /// Starts deriving hysteresis memory from the parent conversation
  /// (`kind=='subagent'` rows + `backgroundWorks`). A later call re-points
  /// the observation (a subscribe retry swaps the state object).
  void observe(ConversationState state) {
    _observed?.removeListener(_onParentChanged);
    _observed = state;
    state.addListener(_onParentChanged);
    _onParentChanged();
  }

  void _onParentChanged() {
    final state = _observed;
    if (_disposed || state == null) return;
    for (final row in state.rows) {
      if (row['kind'] != 'subagent') continue;
      _observeStatus('${row['childSessionId'] ?? ''}',
          '${row['status'] ?? ''}');
    }
    for (final work in state.backgroundWorks) {
      if (work['kind'] != 'subagent') continue;
      _observeStatus('${work['childSessionId'] ?? ''}',
          '${work['status'] ?? ''}');
    }
    _armExpiry();
  }

  void _observeStatus(String childSessionId, String status) {
    if (childSessionId.isEmpty) return;
    final now = DateTime.now();
    final record = _terminal[childSessionId];
    if (subagentTerminalStatuses.contains(status)) {
      // Terminal reports are always believed and refresh the anchor; any
      // pending regression stopwatch is over.
      if (record == null) {
        _terminal[childSessionId] = _TerminalRecord(status, now);
      } else {
        record
          ..status = status
          ..at = now
          ..runningSince = null;
      }
      return;
    }
    if (record == null) return;
    // A running report against a known terminal only un-finishes it once
    // it has persisted [regressionHysteresis] (a real re-run lasts far
    // longer; a bridge-recovery replay reverts long before).
    final since = record.runningSince ??= now;
    if (now.difference(since) >= regressionHysteresis) {
      _terminal.remove(childSessionId);
    }
  }

  /// The status a consumer should render: a running report within the
  /// hysteresis window of an observed terminal keeps the terminal status.
  String effectiveStatus(String childSessionId, String reportedStatus) {
    final record = _terminal[childSessionId];
    if (record == null || subagentTerminalStatuses.contains(reportedStatus)) {
      return reportedStatus;
    }
    final since = record.runningSince;
    if (since == null ||
        DateTime.now().difference(since) < regressionHysteresis) {
      return record.status;
    }
    return reportedStatus;
  }

  /// Repaints a persisted-running entry the window held back even when no
  /// further parent frame arrives to rebuild the consumers.
  void _armExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (_disposed) return;
    DateTime? next;
    for (final record in _terminal.values) {
      final since = record.runningSince;
      if (since == null) continue;
      final at = since.add(regressionHysteresis);
      if (next == null || at.isBefore(next)) next = at;
    }
    if (next == null) return;
    _expiryTimer = Timer(next.difference(DateTime.now()), () {
      _expiryTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _expiryTimer?.cancel();
    _observed?.removeListener(_onParentChanged);
    for (final entry in _children.values) {
      final handle = entry.handle;
      entry.handle = null;
      handle?.state.removeListener(notifyListeners);
      unawaited(_closeQuietly(handle));
    }
    _children.clear();
    _terminal.clear();
    super.dispose();
  }
}

Future<void> _closeQuietly(ChatHandle? handle) async {
  try {
    await handle?.close();
  } catch (_) {
    // Closing is best-effort; the transport tears down with the session.
  }
}
