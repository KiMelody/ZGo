import 'dart:async';

import 'package:flutter/foundation.dart';

import '../i18n/lexicon.dart';
import '../notifications/notification_service.dart';
import '../notifications/notify_rules.dart';
import '../notifications/phase_snapshot_store.dart';
import '../ui/ui_settings.dart';
import 'device_session.dart';

/// One task row of the merged notification view, matching the row shape
/// [taskCompletionEvents] consumes. [workspacePath] / [workspaceIdentity]
/// are the merged row's own origin fields (the home copy's) — the tap side
/// resolves the task's workspace from them, so a notification of a
/// non-active workspace still opens the right bridge scope.
typedef _TaskRow = ({
  String sessionId,
  String title,
  String phase,
  String? parentSessionId,
  String? workspacePath,
  String? workspaceIdentity,
  /// The relay overview reports this task id (derived from the overview
  /// itself, NOT from the merged row's raw: a live-index overlay strips the
  /// relay origin fields in TaskDirectory's merge, so the active workspace's
  /// rows would lose the anchor exactly where catch-up edges need it).
  bool relayAnchored,
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
/// A device's first diff waits for that baseline to land (see
/// [_restorePhases]); past it, a terminal row the baseline never saw is a
/// task that ran while the app was not watching and notifies.
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
    this.errorConfirmWindow = const Duration(seconds: 10),
    this.regressionHysteresis = const Duration(seconds: 15),
    this.phaseSnapshots = const PhaseSnapshotStore(),
  });

  static const offPeakPollInterval = Duration(seconds: 60);
  static const automationPollInterval = Duration(seconds: 120);

  /// A completion notice waits this long and re-checks the live phase
  /// before firing (see [_scheduleTaskNotice]).
  final Duration taskConfirmWindow;

  /// The confirm window for an `error` edge, treated as a SOFT terminal: a
  /// trailing model-only helper turn (title generation etc.) can fail after
  /// the main turn completed and persist `error` on the session, which
  /// [taskConfirmWindow] is too short to see through (the false "任务失败"
  /// of the 2026-09-22 report). The behavior derivation: error edge → hold
  /// this window → if completedSuccess lands inside it, the correction edge
  /// in [taskCompletionEvents] fires first and the same-key remove-cancel
  /// replaces the error timer with a completed one — only the completion
  /// shows; if the error persists past the window, the failure notifies,
  /// merely delayed. No cancel-notice logic is needed beyond what already
  /// exists.
  final Duration errorConfirmWindow;

  /// A task the baseline already saw finish only reverts to running once the
  /// running report has persisted this long (see [_effectivePhases]).
  final Duration regressionHysteresis;

  final _tracked = <String, NotifiableSession>{};
  final _taskPhases = <String, Map<String, String>>{};

  /// Devices whose baseline is primed for the runtime-newcomer edge. The
  /// priming diff itself never emits a newcomer edge, and it only counts
  /// once the relay overview leg has delivered: that leg is the whole-table
  /// authority, while a live-index frame can beat it on a cold start
  /// (subscribe answers before the channel pull) — priming there would
  /// replay every historical row of the overview when it lands. Until then,
  /// a terminal row the baseline never saw is HISTORY.
  final _newcomerPrimed = <String>{};

  /// Devices whose disk baseline read is still in flight: list frames are
  /// dropped until it lands (see [_restorePhases]).
  final _restoring = <String>{};

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
        // The first diff of a fresh track waits for the shutdown baseline
        // (see [_restorePhases]): a frame baselining now would forfeit
        // exactly the snapshot the cold-start / handover catch-up needs.
        // Frames are high-frequency, so dropping them until the (millisecond
        // scale) prefs read lands is lossless.
        _restoring.add(session.deviceId);
        unawaited(_restorePhases(session));
      }
    }
    for (final id in _tracked.keys.toList()) {
      if (!seen.contains(id)) {
        _tracked.remove(id);
        _taskPhases.remove(id);
        _newcomerPrimed.remove(id);
        // A restore still in flight for the departed track must not adopt a
        // snapshot into a map this loop just cleared (its tracked guard
        // covers the ordering, the gate covers another re-track in between).
        _restoring.remove(id);
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

  /// Adopts the baseline a previous process left for this device, then opens
  /// the first-diff gate. While [syncWith] has it closed, list frames are
  /// dropped instead of baselining an empty table — an empty baseline is
  /// "already baselined" for the restore and would discard the snapshot
  /// (the handover re-track and the cold-start race both lost their catch-up
  /// that way). A missing snapshot simply leaves no baseline, so the next
  /// frame diffs as the cold-start first sight it is.
  Future<void> _restorePhases(NotifiableSession session) async {
    final deviceId = session.deviceId;
    try {
      final restored = await phaseSnapshots.restore(deviceId);
      if (_disposed || !_tracked.containsKey(deviceId)) return;
      // Guard against a pathological overlapping restore (untrack, instant
      // re-track): the first one opened the gate already, so a baseline the
      // frames have built since must not be overwritten. On every normal
      // path this is a no-op — the gate keeps frames out until restore
      // lands, so no baseline exists here.
      if (_taskPhases.containsKey(deviceId)) return;
      if (restored == null) return;
      debugPrint('[notify] restored ${restored.length} phases for $deviceId');
      _taskPhases[deviceId] = restored;
    } finally {
      // A failed or absent restore must still open the gate: the very next
      // frame then baselines exactly like the cold start it is.
      _restoring.remove(deviceId);
    }
  }

  /// Every task of the device as diffable rows, read off the session's
  /// [TaskDirectory] — the one merged view (relay overview ⊕ live
  /// sessions-index, archived tasks included so a task archived mid-run
  /// still reports its completion). Keying by task id keeps a task reported
  /// by both sources a single row, so the shared baseline de-dupes the pair.
  Map<String, _TaskRow> _taskRows(NotifiableSession session) {
    // The overview membership is the anchor's fact source — the merged
    // row's raw loses the relay origin fields under a live overlay
    // (TaskDirectory._withRelayMeta inherits only pinned/unreadAt/
    // lastError), so raw['workspacePath'] would underreport exactly the
    // active workspace's tasks.
    final relayIds = {
      for (final task in session.relayTasks) '${task['taskId']}',
    };
    return {
      for (final entry in session.taskDirectory.notificationRows())
        entry.sessionId: (
          sessionId: entry.sessionId,
          title: entry.title,
          phase: entry.phase,
          parentSessionId: entry.parentSessionId,
          // The merged row's body rides the RELAY home copy, whose
          // origin fields are the ownership evidence (live index rows
          // often carry none — probe3162_p1 schema).
          workspacePath: entry.raw['workspacePath'] as String?,
          workspaceIdentity: entry.raw['workspaceIdentity'] as String?,
          relayAnchored: relayIds.contains(entry.sessionId),
        ),
    };
  }

  /// Neither source has reported yet: the workspace subscription is not up
  /// and no relay overview has arrived. The baseline must stay untouched
  /// then — a diff over that empty view would record nothing useful and the
  /// disk copy already holds the only record of what was running.
  static bool _silent(NotifiableSession session) =>
      session.sessions == null && session.relayTasks.isEmpty;

  void _snapshotPhases(NotifiableSession session, Map<String, String> phases) {
    if (_silent(session)) return;
    final deviceId = session.deviceId;
    // Chat frames update the index at high frequency; only an actual phase
    // change is worth writing to disk. An unchanged map also means the disk
    // copy already says exactly this.
    final current = _taskPhases[deviceId];
    if (current == null) {
      _taskPhases[deviceId] = phases;
      unawaited(phaseSnapshots.save(deviceId, phases));
      return;
    }
    // The baseline is a UNION, never a wholesale swap: the merged view's
    // row set flaps (an open swaps the active subscription, a bridge
    // rebuild re-arrives sidecar snapshots), and a frame whose table is
    // momentarily MISSING rows must not delete their baseline entries —
    // the rows' return would read as unseen newcomers and replay finished
    // tasks (the 2026-11-08 cold-start burst of 12, and the resume pull
    // that never fired). A row that left the view keeps its last phase as
    // a tombstone: returning terminal-over-terminal is silent, returning
    // terminal over a running tombstone is the completion edge it really
    // is. untrack is the one real deletion point.
    final merged = {...current, ...phases};
    if (mapEquals(current, merged)) return;
    _taskPhases[deviceId] = merged;
    unawaited(phaseSnapshots.save(deviceId, merged));
  }

  /// A dropped confirmation must not strand the baseline on the edge's
  /// phase: rewind to what the live view actually says so the next frame
  /// (a real terminal landing, or the resume pull after a background gap)
  /// diffs a fresh running→terminal edge instead of terminal→terminal.
  void _rollbackPhase(
    NotifiableSession session,
    String sessionId,
    String phase,
  ) {
    final phases = _taskPhases[session.deviceId];
    if (phases == null || phases[sessionId] == phase) return;
    // In place: [_snapshotPhases] swaps whole maps, so no other holder sees
    // this map change underneath it.
    phases[sessionId] = phase;
    unawaited(phaseSnapshots.save(session.deviceId, phases));
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
    // The shutdown baseline has not landed yet: diffing now would baseline
    // the live table and forfeit it (see [_restorePhases]).
    if (_restoring.contains(session.deviceId)) return;
    final prev = _taskPhases.putIfAbsent(session.deviceId, () => {});
    final rows = _taskRows(session);
    final phases = _effectivePhases(session.deviceId, rows);
    final events = taskCompletionEvents(
      previousPhases: prev,
      // The resume-recovery edges (runtime newcomer + idle start) only fire
      // past the first diff, and only for rows the relay overview anchors:
      // sidecar snapshots re-arrive on every reconnect and their terminal
      // rows are history (the 2026-11-08 acceptance burst).
      catchUpEdges: _newcomerPrimed.contains(session.deviceId),
      sessions: [
        for (final row in rows.values)
          (
            sessionId: row.sessionId,
            title: row.title,
            phase: phases[row.sessionId] ?? row.phase,
            parentSessionId: row.parentSessionId,
            // The relay home copy's origin fields are the anchor evidence;
            // live/sidecar rows carry none (probe3162_p1 schema).
            relayAnchored: row.relayAnchored,
          ),
      ],
    );
    // Track phases even while silenced so re-enabling doesn't replay
    // history. Diff and disk copy both read the effective view, so a bridge
    // blip neither doubles a notice nor lands on disk.
    _snapshotPhases(session, phases);
    // The diff just consumed the baseline's first sight of this device:
    // every later unseen row is runtime-new, not history. Priming waits for
    // the relay overview leg because it is the whole-table authority — a
    // live-index frame answers first on a cold start (subscribe before the
    // channel pull), and priming off that partial table would replay every
    // historical overview row that lands next.
    if (session.relayTasks.isNotEmpty) {
      _newcomerPrimed.add(session.deviceId);
    }
    if (!_master || !ui.notifyTasksEnabled) return;
    for (final e in events) {
      _scheduleTaskNotice(session, e);
    }
  }

  /// Delays a completion notice by a phase-dependent confirm window and
  /// re-checks the live phase before showing. Sending a message briefly
  /// flips the session running→terminal→running again (model-only helper
  /// turns like title generation), which used to fire a bogus "已完成" the
  /// moment a turn STARTED. A blip reverts inside the window and is
  /// dropped; a real terminal phase (including a fast error) persists and
  /// notifies — only delayed. An `error` edge waits the longer
  /// [errorConfirmWindow] instead: a trailing helper turn can fail after
  /// the main turn completed and persist `error`, so the short window
  /// produced a false "任务失败" before the real completion landed (see
  /// the field doc for the full derivation).
  ///
  /// A drop rewinds the task's baseline to the phase the re-check actually
  /// saw ([_rollbackPhase]): the edge baselined its own phase before this
  /// point, so without the rewind a task that finishes while the app is in
  /// the background would keep a terminal baseline and its resume-pull
  /// completion frame would diff terminal→terminal and stay silent.
  void _scheduleTaskNotice(
    NotifiableSession session,
    TaskCompletionEvent e,
  ) {
    final key = '${session.deviceId}:${e.sessionId}';
    final window =
        e.phase == 'error' ? errorConfirmWindow : taskConfirmWindow;
    debugPrint('[notify] task edge $key → ${e.phase} "${e.title}", '
        'confirming in ${window.inSeconds}s');
    _pendingTasks.remove(key)?.cancel();
    _pendingTasks[key] = Timer(window, () {
      _pendingTasks.remove(key);
      if (_disposed) return;
      // The merged view, not just the subscribed index: a task of another
      // workspace only exists in the relay overview and would look gone here.
      final still = _taskRows(session)[e.sessionId]?.phase;
      if (still != e.phase) {
        debugPrint('[notify] task edge $key dropped, phase now $still');
        // The edge already wrote its phase into the baseline; without the
        // rewind the drop would freeze it there and every later frame would
        // diff terminal→terminal (the background-completion freeze).
        if (still != null) _rollbackPhase(session, e.sessionId, still);
        return;
      }
      if (!_master || !ui.notifyTasksEnabled) return;
      final title = switch (e.phase) {
        'error' => _tr('notify.task.failed'),
        'completedInterrupted' => _tr('notify.task.interrupted'),
        _ => _tr('notify.task.done'),
      };
      // Ownership rides the payload (design 11-07 R1): the notification
      // covers EVERY workspace, so the tap must know where the task lives
      // to point the bridge before subscribing. First source is the same
      // merged row the diff consumed; when its body lacks the origin
      // fields (a live-row notice, or the overview copy not merged yet),
      // the RAW relay row of the same task is the fallback — its scope
      // fields are what the directory merge would have used (2026-11-07
      // acceptance AC4: a hint-less payload dead-ended a cold-start tap in
      // scopeUnknown). Absent fields stay
      // ABSENT (an empty string would read as a real scope downstream).
      final row = _taskRows(session)[e.sessionId];
      var wsPath = row?.workspacePath;
      var wsIdentity = row?.workspaceIdentity;
      if (wsPath == null || wsPath.isEmpty) {
        Map<String, dynamic>? relayRow;
        for (final task in session.relayTasks) {
          if ('${task['taskId']}' == e.sessionId) {
            relayRow = task;
            break;
          }
        }
        final path = relayRow?['workspacePath'];
        if (path is String && path.isNotEmpty) {
          wsPath = path;
          final identity = relayRow?['workspaceIdentity'];
          if ((wsIdentity == null || wsIdentity.isEmpty) &&
              identity is String &&
              identity.isNotEmpty) {
            wsIdentity = identity;
          }
        }
      }
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
          if (wsPath != null && wsPath.isNotEmpty) 'workspacePath': wsPath,
          if (wsIdentity != null && wsIdentity.isNotEmpty)
            'workspaceIdentity': wsIdentity,
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
    _newcomerPrimed.clear();
    _restoring.clear();
    _runningSince.clear();
    _offPeakStatuses.clear();
    _autoLastRunAt.clear();
  }
}
