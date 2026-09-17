import 'dart:async';

import 'package:flutter/foundation.dart';

import '../notifications/notification_service.dart';
import '../notifications/notify_rules.dart';
import '../notifications/phase_snapshot_store.dart';
import '../protocol/conversation.dart';
import '../ui/ui_settings.dart';
import 'device_session.dart';

/// One task row of the merged notification view, matching the row shape
/// [taskCompletionEvents] consumes.
typedef _TaskRow = ({
  String sessionId,
  String title,
  String phase,
  String? parentSessionId,
});

/// Bridges device sessions to local notifications:
/// - task events ride two phase sources: the relay task overview (EVERY
///   workspace) and the live sessions-index of the subscribed one
///   (precise phases) — no extra RPC,
/// - off-peak results poll every 60s,
/// - automation runs poll every 120s,
/// all gated by the notification switches in settings. Errors are always
/// silent — notifications are an enhancement, never a failure surface.
///
/// Task phases are also baselined on disk, so a task that was running when
/// the process was killed still reports its completion on the next launch.
class NotificationHub {
  final NotificationService service;
  final UiSettings ui;

  /// Resolves a device label for notification bodies.
  final String Function(String deviceId) deviceLabelOf;

  /// Survives the process for the task-phase baseline (see
  /// [_restorePhases] / [_snapshotPhases]).
  final PhaseSnapshotStore phaseSnapshots;

  NotificationHub({
    required this.service,
    required this.ui,
    required this.deviceLabelOf,
    this.taskConfirmWindow = const Duration(seconds: 3),
    this.regressionHysteresis = const Duration(seconds: 15),
    this.phaseSnapshots = const PhaseSnapshotStore(),
  });

  static const offPeakPollInterval = Duration(seconds: 60);
  static const automationPollInterval = Duration(seconds: 120);

  /// A completion notice waits this long and re-checks the live phase
  /// before firing (see [_scheduleTaskNotice]).
  final Duration taskConfirmWindow;

  /// A task the baseline already saw finish only reverts to running once the
  /// running report has persisted this long (see [_effectivePhases]).
  final Duration regressionHysteresis;

  final _tracked = <String, NotifiableSession>{};
  final _taskPhases = <String, Map<String, String>>{};

  /// When a terminal task was first re-reported as running, keyed
  /// `'$deviceId:$sessionId'` — the regression guard's stopwatch
  /// (see [_effectivePhases]).
  final _runningSince = <String, DateTime>{};
  final _offPeakStatuses = <String, Map<String, String>>{};
  final _autoLastRunAt = <String, Map<String, int>>{};
  final _pendingTasks = <String, Timer>{};
  Timer? _offPeakTimer;
  Timer? _autoTimer;
  bool _disposed = false;

  String _tr(String key) => trLocale(ui.locale, key);

  bool get _master => ui.notificationsEnabled && service.isReady;

  /// Reconciles tracked sessions with the live hub sessions (main wires
  /// this to hub changes).
  void syncWith(Iterable<NotifiableSession> sessions) {
    if (_disposed) return;
    final seen = <String>{};
    for (final session in sessions) {
      seen.add(session.deviceId);
      if (!_tracked.containsKey(session.deviceId)) {
        _tracked[session.deviceId] = session;
        session.addListener(() => _onSessionChanged(session));
        // Baseline the task phases so pre-existing running tasks don't
        // fire completion notifications on the first tick.
        _snapshotPhases(
          session,
          _effectivePhases(session.deviceId, _mergedTasks(session)),
        );
        // The live list is not up yet, so a shutdown baseline may still be
        // the only record of a task that was running when we died.
        unawaited(_restorePhases(session));
      }
    }
    for (final id in _tracked.keys.toList()) {
      if (!seen.contains(id)) {
        _tracked.remove(id);
        _taskPhases.remove(id);
        // A pending completion notice is unverifiable once the link is
        // gone — drop it rather than fire off a stale snapshot.
        final stale = _pendingTasks.keys
            .where((k) => k.startsWith('$id:'))
            .toList();
        for (final k in stale) {
          _pendingTasks.remove(k)?.cancel();
        }
        // Same for the regression stopwatches of the departed device: its
        // tasks are no longer observed, and a reconnect re-times from
        // scratch anyway.
        _runningSince.removeWhere((k, _) => k.startsWith('$id:'));
        // Off-peak statuses and automation lastRunAt are DEVICE facts:
        // keep them across reconnects so a WebView handover or relay flap
        // doesn't replay completion notifications for old tasks. The disk
        // phase snapshot is kept for the same reason (and is bounded by the
        // 12h ttl + the startup sweep instead of by device deletion).
      }
    }
  }

  void start() {
    _offPeakTimer?.cancel();
    _autoTimer?.cancel();
    _offPeakTimer =
        Timer.periodic(offPeakPollInterval, (_) => pollOffPeakNow());
    _autoTimer =
        Timer.periodic(automationPollInterval, (_) => pollAutomationsNow());
    // Drop snapshots no process will ever restore (uninstalled devices, or
    // anything past the ttl).
    unawaited(phaseSnapshots.sweep());
  }

  /// Adopts the baseline a previous process left for this device. The prefs
  /// read is async, so the live index may win the race: an already baselined
  /// device keeps its in-memory phases and the snapshot is discarded (the
  /// window is milliseconds against a connection taking seconds, and the
  /// cost is one missed notice).
  Future<void> _restorePhases(NotifiableSession session) async {
    final deviceId = session.deviceId;
    final restored = await phaseSnapshots.restore(deviceId);
    if (restored == null || _disposed) return;
    if (!_tracked.containsKey(deviceId)) return;
    if (_taskPhases.containsKey(deviceId)) return;
    debugPrint('[notify] restored ${restored.length} phases for $deviceId');
    _taskPhases[deviceId] = restored;
  }

  /// Every task of the device as diffable rows: the relay overview covers
  /// ALL workspaces, the live sessions-index of the subscribed one overrides
  /// it per task id (it carries the precise phase, e.g.
  /// `completedInterrupted`, which the overview folds into `completed`).
  /// Keying by task id keeps a task reported by both sources a single row,
  /// so the shared baseline de-dupes the pair.
  Map<String, _TaskRow> _mergedTasks(NotifiableSession session) {
    final byId = <String, _TaskRow>{};
    for (final task in session.relayTasks) {
      final entry = SessionEntry.fromRelayTask(task);
      if (entry.sessionId.isEmpty) continue;
      byId[entry.sessionId] = _rowOf(entry);
    }
    final sessions = session.sessions;
    if (sessions != null) {
      for (final entry in sessions.list) {
        byId[entry.sessionId] = _rowOf(entry);
      }
    }
    return byId;
  }

  static _TaskRow _rowOf(SessionEntry entry) => (
    sessionId: entry.sessionId,
    title: entry.title,
    phase: entry.phase,
    parentSessionId: entry.parentSessionId,
  );

  /// Neither source has reported yet: the workspace subscription is not up
  /// and no relay overview has arrived. The baseline must stay untouched
  /// then — an in-memory entry is what blocks [_restorePhases] from adopting
  /// the previous process's snapshot.
  static bool _silent(NotifiableSession session) =>
      session.sessions == null && session.relayTasks.isEmpty;

  void _snapshotPhases(NotifiableSession session, Map<String, String> phases) {
    if (_silent(session)) return;
    final deviceId = session.deviceId;
    // Chat frames update the index at high frequency; only an actual phase
    // change is worth writing to disk. An unchanged map also means the disk
    // copy already says exactly this.
    if (mapEquals(_taskPhases[deviceId], phases)) return;
    _taskPhases[deviceId] = phases;
    unawaited(phaseSnapshots.save(deviceId, phases));
  }

  /// The phase view the diff AND the disk baseline consume: the raw rows,
  /// except that a task the baseline already saw finish is not un-finished by
  /// a running report that is merely a blip.
  ///
  /// The desktop bridge degrades and recovers every 45-90s, and its recovery
  /// frame can report `running` for tasks that are in fact done. Taken at face
  /// value that pulled the baseline back, so the next fresh frame read as a
  /// second running→terminal edge and re-notified — the duplicate completion
  /// notices of the 2026-09-16 device report (the confirm window in
  /// [_scheduleTaskNotice] only guards the opposite side, a terminal blip
  /// right after an edge). A running report must therefore hold for
  /// [regressionHysteresis] before the baseline believes it; a real re-run
  /// lasts far longer than that window, so its completion still notifies.
  Map<String, String> _effectivePhases(
    String deviceId,
    Map<String, _TaskRow> rows,
  ) {
    final prev = _taskPhases[deviceId];
    final now = DateTime.now();
    final phases = <String, String>{};
    for (final row in rows.values) {
      final key = '$deviceId:${row.sessionId}';
      final was = prev?[row.sessionId];
      if (runningPhases.contains(row.phase) &&
          was != null &&
          terminalTaskPhases.contains(was)) {
        final since = _runningSince[key] ??= now;
        if (now.difference(since) < regressionHysteresis) {
          phases[row.sessionId] = was; // hold the terminal baseline
          continue;
        }
      }
      // Not a regression at all: whatever stopwatch ran here is over.
      _runningSince.remove(key);
      phases[row.sessionId] = row.phase;
    }
    // A task that vanished while under observation stops holding one too:
    // its row is gone from the live view (and from the baseline with it), so
    // a stopwatch left behind could never fire again — it would only pile up.
    final live = {for (final row in rows.values) '$deviceId:${row.sessionId}'};
    _runningSince.removeWhere(
        (k, _) => k.startsWith('$deviceId:') && !live.contains(k));
    return phases;
  }

  void _onSessionChanged(NotifiableSession session) {
    if (_disposed || _silent(session)) return;
    final prev = _taskPhases.putIfAbsent(session.deviceId, () => {});
    final rows = _mergedTasks(session);
    final phases = _effectivePhases(session.deviceId, rows);
    final events = taskCompletionEvents(
      previousPhases: prev,
      sessions: [
        for (final row in rows.values)
          (
            sessionId: row.sessionId,
            title: row.title,
            phase: phases[row.sessionId] ?? row.phase,
            parentSessionId: row.parentSessionId,
          ),
      ],
    );
    // Track phases even while silenced so re-enabling doesn't replay
    // history. Diff and disk copy both read the effective view, so a bridge
    // blip neither doubles a notice nor lands on disk.
    _snapshotPhases(session, phases);
    if (!_master || !ui.notifyTasksEnabled) return;
    for (final e in events) {
      _scheduleTaskNotice(session, e);
    }
  }

  /// Delays a completion notice by [taskConfirmWindow] and re-checks the
  /// live phase before showing. Sending a message briefly flips the
  /// session running→terminal→running again (model-only helper turns
  /// like title generation), which used to fire a bogus "已完成" the
  /// moment a turn STARTED. A blip reverts inside the window and is
  /// dropped; a real terminal phase (including a fast error) persists
  /// and notifies — only delayed.
  void _scheduleTaskNotice(
    NotifiableSession session,
    TaskCompletionEvent e,
  ) {
    final key = '${session.deviceId}:${e.sessionId}';
    debugPrint(
        '[notify] task edge $key → ${e.phase} "${e.title}", confirming');
    _pendingTasks.remove(key)?.cancel();
    _pendingTasks[key] = Timer(taskConfirmWindow, () {
      _pendingTasks.remove(key);
      if (_disposed) return;
      // The merged view, not just the subscribed index: a task of another
      // workspace only exists in the relay overview and would look gone here.
      final still = _mergedTasks(session)[e.sessionId]?.phase;
      if (still != e.phase) {
        debugPrint('[notify] task edge $key dropped, phase now $still');
        return;
      }
      if (!_master || !ui.notifyTasksEnabled) return;
      final title = switch (e.phase) {
        'error' => _tr('notify.task.failed'),
        'completedInterrupted' => _tr('notify.task.interrupted'),
        _ => _tr('notify.task.done'),
      };
      unawaited(service.show(
        NotifyChannel.tasks,
        NotificationService.stableId('${session.deviceId}:${e.sessionId}'),
        title,
        e.title,
        {
          'type': 'task',
          'deviceId': session.deviceId,
          'sessionId': e.sessionId,
          'title': e.title,
        },
      ));
    });
  }

  /// Polls off-peak tasks of every connected session (public so tests and
  /// manual refreshes can drive it).
  Future<void> pollOffPeakNow() async {
    if (_disposed || !_master || !ui.notifyOffPeakEnabled) return;
    for (final session in _tracked.values.toList()) {
      if (session.status != DeviceStatus.connected) continue;
      await _pollOffPeak(session);
      if (_disposed) return;
    }
  }

  Future<void> _pollOffPeak(NotifiableSession session) async {
    try {
      final tasks = await session.offPeak.list();
      if (_disposed) return;
      final prev = _offPeakStatuses.putIfAbsent(session.deviceId, () => {});
      final coldStart = prev.isEmpty && tasks.isNotEmpty;
      final events = offPeakEvents(previousStatuses: prev, tasks: tasks);
      _offPeakStatuses[session.deviceId] = {
        for (final t in tasks) t.id: t.status,
      };
      if (coldStart) return; // first sight baselines silently
      if (!_master || !ui.notifyOffPeakEnabled) return;
      for (final e in events) {
        final title =
            e.failed ? _tr('notify.offPeak.failed') : _tr('notify.offPeak.done');
        final body = e.task.title.isEmpty ? e.task.prompt : e.task.title;
        unawaited(service.show(
          NotifyChannel.offPeak,
          NotificationService.stableId(
              '${session.deviceId}:offpeak:${e.task.id}'),
          title,
          body,
          {
            'type': 'offPeak',
            'deviceId': session.deviceId,
            'sessionId': e.task.sessionId ?? e.task.conversationId,
            'title': body,
          },
        ));
      }
    } catch (_) {
      // Offline desktops / absent channels are expected on every poll.
    }
  }

  /// Polls automation runs of every connected session.
  Future<void> pollAutomationsNow() async {
    if (_disposed || !_master || !ui.notifyAutoEnabled) return;
    for (final session in _tracked.values.toList()) {
      if (session.status != DeviceStatus.connected) continue;
      await _pollAutomations(session);
      if (_disposed) return;
    }
  }

  Future<void> _pollAutomations(NotifiableSession session) async {
    try {
      final items = await session.automation.list();
      if (_disposed) return;
      final prev = _autoLastRunAt.putIfAbsent(session.deviceId, () => {});
      final events = automationRunEvents(
          previousLastRunAt: prev, items: items);
      _autoLastRunAt[session.deviceId] = {
        for (final item in items)
          if (item.lastRunAt != null) item.id: item.lastRunAt!,
      };
      // No cold-start baseline here (unlike off-peak): a new lastRunAt on
      // the first poll IS a fresh run worth notifying; replays are already
      // impossible because the per-device cache survives reconnects.
      if (!_master || !ui.notifyAutoEnabled) return;
      for (final e in events) {
        final title =
            e.failed ? _tr('notify.auto.failed') : _tr('notify.auto.done');
        final body = e.item.title.isEmpty ? e.item.id : e.item.title;
        unawaited(service.show(
          NotifyChannel.automations,
          NotificationService.stableId(
              '${session.deviceId}:auto:${e.item.id}:${e.item.lastRunAt}'),
          title,
          body,
          {
            'type': 'auto',
            'deviceId': session.deviceId,
            'sessionId': e.item.targetTaskId,
            'title': body,
          },
        ));
      }
    } catch (_) {
      // Older desktops without the automation port land here every poll.
    }
  }

  void dispose() {
    _disposed = true;
    _offPeakTimer?.cancel();
    _autoTimer?.cancel();
    for (final t in _pendingTasks.values) {
      t.cancel();
    }
    _pendingTasks.clear();
    _tracked.clear();
    _taskPhases.clear();
    _runningSince.clear();
    _offPeakStatuses.clear();
    _autoLastRunAt.clear();
  }
}
