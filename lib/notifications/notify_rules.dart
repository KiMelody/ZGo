import '../protocol/automation.dart';
import '../protocol/off_peak.dart';

/// Pure derivations of notification events from before/after snapshots.
/// Dependency-free so they unit-test without any platform channel.

const runningPhases = {'running', 'prewarming'};
const terminalTaskPhases = {
  'completedSuccess',
  'completedInterrupted',
  'error',
};

/// A task reached a terminal phase since the last tick.
class TaskCompletionEvent {
  final String sessionId;
  final String title;
  final String phase; // completedSuccess | completedInterrupted | error

  const TaskCompletionEvent({
    required this.sessionId,
    required this.title,
    required this.phase,
  });

  bool get failed => phase == 'error';
}

/// [previousPhases] doubles as the de-dupe: a running→terminal transition
/// fires exactly once, and re-running a task fires again on its next
/// completion (notify-state derived from the same signals).
///
/// [catchUpEdges] turns on the two resume-recovery edges, both restricted to
/// rows the relay overview anchors (`relayAnchored` — the overview is the
/// whole-table authority; sidecar/live-index snapshots re-arrive on every
/// reconnect and their terminal rows are history, not fresh completions —
/// the 2026-11-08 acceptance burst of 37 notices was exactly that):
/// - runtime newcomer: a task the baseline has never seen at all (created
///   AND finished while the app was in the background) notifies instead of
///   being read as history;
/// - idle start: the baseline saw the task `idle` (created, the turn not
///   yet running) and the next sight is terminal — the running leg happened
///   entirely off-screen.
/// It must stay OFF for the first diff of a device's baseline: that whole
/// table IS history (the 09-16 replay rule), so only a diff past the first
/// may treat a terminal row as fresh.
///
/// Rows with a parentSessionId are auxiliary child sessions (subagents,
/// compact/goal helpers) that ride the same index — they are not
/// user-facing tasks and never notify.
List<TaskCompletionEvent> taskCompletionEvents({
  required Map<String, String> previousPhases,
  required List<
      ({
        String sessionId,
        String title,
        String phase,
        String? parentSessionId,
        bool relayAnchored,
      })
    > sessions,
  bool catchUpEdges = false,
}) {
  final events = <TaskCompletionEvent>[];
  final tasks =
      sessions.where((s) => s.parentSessionId == null).toList();
  final nowPhases = {for (final s in tasks) s.sessionId: s.phase};
  final byId = {for (final s in tasks) s.sessionId: s};
  previousPhases.forEach((sessionId, wasPhase) {
    final now = nowPhases[sessionId];
    // Correction edge: an error notice already fired (sometimes spuriously
    // — a bridge crash-loop transient, or a trailing model-only helper turn
    // failing after the main turn completed), and the true completedSuccess
    // then lands WITHOUT a running gap. The running→terminal edge below
    // can't see it (error is terminal, not running), so without this edge
    // the baseline stays error and the REAL completion is never notified.
    if (wasPhase == 'error' && now == 'completedSuccess') {
      final entry = byId[sessionId]!;
      events.add(TaskCompletionEvent(
        sessionId: sessionId,
        title: entry.title.isEmpty ? sessionId : entry.title,
        phase: now!,
      ));
      return;
    }
    // Idle start (see the doc block): the baseline caught the task before
    // its turn was running, so the running leg played out unseen.
    if (wasPhase == 'idle' &&
        catchUpEdges &&
        byId[sessionId]?.relayAnchored == true &&
        now != null &&
        terminalTaskPhases.contains(now)) {
      final entry = byId[sessionId]!;
      events.add(TaskCompletionEvent(
        sessionId: sessionId,
        title: entry.title.isEmpty ? sessionId : entry.title,
        phase: now,
      ));
      return;
    }
    if (!runningPhases.contains(wasPhase)) return;
    if (now == null || !terminalTaskPhases.contains(now)) return;
    final entry = byId[sessionId]!;
    events.add(TaskCompletionEvent(
      sessionId: sessionId,
      title: entry.title.isEmpty ? sessionId : entry.title,
      phase: now,
    ));
  });
  if (catchUpEdges) {
    // Runtime newcomer: the baseline has no row for it, yet its first
    // appearance is already terminal — it was created and finished while the
    // app was not watching (a background gap, then the resume pull).
    // Relay-anchored only: a sidecar snapshot's terminal session is an old
    // conversation re-entering the view, never a fresh task completion.
    for (final s in tasks) {
      if (previousPhases.containsKey(s.sessionId)) continue;
      if (!s.relayAnchored) continue;
      if (!terminalTaskPhases.contains(s.phase)) continue;
      events.add(TaskCompletionEvent(
        sessionId: s.sessionId,
        title: s.title.isEmpty ? s.sessionId : s.title,
        phase: s.phase,
      ));
    }
  }
  return events;
}

/// An off-peak task reached completed/failed since the last tick.
class OffPeakEvent {
  final OffPeakTask task;
  final bool failed;

  const OffPeakEvent(this.task, {required this.failed});
}

List<OffPeakEvent> offPeakEvents({
  required Map<String, String> previousStatuses,
  required List<OffPeakTask> tasks,
}) {
  final events = <OffPeakEvent>[];
  for (final t in tasks) {
    if (!t.terminal) continue;
    final was = previousStatuses[t.id];
    // Only notify on the transition, not on every poll of an old entry.
    if (was == t.status) continue;
    if (was == null) {
      // First sight of a terminal task is HISTORY (app cold start, or the
      // per-device status cache was rebuilt after a reconnect): baseline
      // silently, like the task-phase snapshot. Without this, every
      // reconnect replayed completion notifications for all finished
      // off-peak tasks.
      continue;
    }
    if (t.completed) events.add(OffPeakEvent(t, failed: false));
    if (t.failed) events.add(OffPeakEvent(t, failed: true));
  }
  return events;
}

/// An automation fired since the last tick (lastRunAt bumped).
class AutomationRunEvent {
  final AutomationItem item;
  final bool failed;

  const AutomationRunEvent(this.item, {required this.failed});
}

List<AutomationRunEvent> automationRunEvents({
  required Map<String, int> previousLastRunAt,
  required List<AutomationItem> items,
}) {
  final events = <AutomationRunEvent>[];
  for (final item in items) {
    final lastRunAt = item.lastRunAt;
    if (lastRunAt == null) continue;
    final was = previousLastRunAt[item.id];
    if (was != null && lastRunAt <= was) continue;
    if (was == null && lastRunAt < DateTime.now().millisecondsSinceEpoch -
        const Duration(minutes: 10).inMilliseconds) {
      // First sight of an old run: silent (avoid replaying history).
      continue;
    }
    final failed = item.lastResult == 'error' ||
        (item.lastResult?.toLowerCase().contains('fail') ?? false);
    events.add(AutomationRunEvent(item, failed: failed));
  }
  return events;
}
