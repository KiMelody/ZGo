import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zlinker/notifications/notification_service.dart';
import 'package:zlinker/notifications/notify_rules.dart';
import 'package:zlinker/notifications/phase_snapshot_store.dart';
import 'package:zlinker/protocol/automation.dart';
import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/protocol/off_peak.dart';
import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/state/notification_hub.dart';
import 'package:zlinker/ui/ui_settings.dart';

/// Records what the hub would have shown; plugin-backed members no-op.
class RecordingService implements NotificationService {
  @override
  bool isReady = true;
  final shown =
      <(NotifyChannel, int, String, String, Map<String, dynamic>)>[];

  @override
  Future<void> show(NotifyChannel channel, int id, String title,
      String body, Map<String, dynamic> payload) async {
    shown.add((channel, id, title, body, payload));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake device link with a real SessionsIndexState (snapshots applied in
/// place) plus table-backed automation / off-peak ports.
class FakeNotifiableSession extends ChangeNotifier
    implements NotifiableSession {
  @override
  final String deviceId;
  @override
  DeviceStatus status;
  @override
  Map<String, dynamic> offPeakScope = const {};

  @override
  Map<String, dynamic> get automationScope => const {'workspacePath': '/repo'};

  List<Map<String, dynamic>> automationItems = [];
  List<Map<String, dynamic>> offPeakTasks = [];

  /// Relay task overview of every workspace (empty until one arrives).
  @override
  List<Map<String, dynamic>> relayTasks = [];

  @override
  late final AutomationPort automation =
      AutomationPort((m, a) async => automationItems);
  @override
  late final OffPeakPort offPeak =
      OffPeakPort((m, a) async => offPeakTasks);

  final SessionsIndexState _state = SessionsIndexState();

  /// Mirrors the real session: [sessions] stays null until the workspace
  /// subscription is up. That window is when the hub adopts the disk
  /// baseline, so tests of the restart path must start with it closed.
  bool sessionsReady = true;

  FakeNotifiableSession(this.deviceId,
      {this.status = DeviceStatus.connected, this.sessionsReady = true});

  @override
  SessionsIndexState? get sessions => sessionsReady ? _state : null;

  /// Applies a full snapshot (title/phase per session) and notifies.
  void setEntries(List<(String, String, String)> entries) {
    setEntriesWithParent([
      for (final (id, title, phase) in entries) (id, title, phase, parent: null),
    ]);
  }

  /// Same, with an optional parentSessionId per row (subagent sessions).
  void setEntriesWithParent(
      List<(String, String, String, {String? parent})> entries) {
    _state.applyFrame({
      'toSeq': (_state.seq + 1),
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessions': [
            for (final (id, title, phase, parent: parent) in entries)
              {
                'sessionId': id,
                'title': title,
                'phase': phase,
                if (parent != null) 'parentSessionId': parent,
              },
          ],
        },
      },
    }, onGap: () {});
    notifyListeners();
  }

  /// Applies a relay task overview and notifies, mirroring
  /// `DeviceSession._onWorkspaceListUpdated`.
  void setRelayTasks(List<Map<String, dynamic>> tasks) {
    relayTasks = tasks;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('taskCompletionEvents (pure rules)', () {
    test('fires once per running→terminal transition', () {
      final events = taskCompletionEvents(
        previousPhases: {'s1': 'running', 's2': 'running', 's3': 'draft'},
        sessions: [
          (
            sessionId: 's1',
            title: '修复登录',
            phase: 'completedSuccess',
            parentSessionId: null,
          ),
          (
            sessionId: 's2',
            title: '部署',
            phase: 'error',
            parentSessionId: null,
          ),
          (
            sessionId: 's3',
            title: '草稿任务',
            phase: 'completedSuccess',
            parentSessionId: null,
          ),
        ],
      );
      expect(events, hasLength(2));
      expect(events[0].failed, isFalse);
      expect(events[1].failed, isTrue);
    });

    test('re-running fires again; unchanged terminal stays silent', () {
      const sessions = [
        (sessionId: 's1', title: 't', phase: 'completedSuccess',
         parentSessionId: null)
      ];
      expect(
          taskCompletionEvents(
              previousPhases: {'s1': 'running'}, sessions: sessions),
          hasLength(1));
      expect(
          taskCompletionEvents(
              previousPhases: {'s1': 'completedSuccess'},
              sessions: sessions),
          isEmpty);
    });

    test('prewarming counts as running; empty title falls back to id', () {
      final events = taskCompletionEvents(
        previousPhases: {'s1': 'prewarming'},
        sessions: [
          (sessionId: 's1', title: '', phase: 'error', parentSessionId: null)
        ],
      );
      expect(events.single.title, 's1');
      expect(events.single.failed, isTrue);
    });

    test('subagent rows (parentSessionId set) never notify', () {
      final events = taskCompletionEvents(
        previousPhases: {'s1': 'running', 's2': 'running'},
        sessions: [
          (
            sessionId: 's1',
            title: '主任务',
            phase: 'running',
            parentSessionId: null,
          ),
          (
            sessionId: 's2',
            title: '子代理',
            phase: 'completedSuccess',
            parentSessionId: 's1',
          ),
        ],
      );
      expect(events, isEmpty);
    });
  });

  group('relay overview rows (session-entry mapping)', () {
    // The hub's base table is built from this mapping: every workspace's
    // tasks arrive as `displayStatus`, the diff vocabulary is `phase`.
    SessionEntry row(Map<String, dynamic> task) =>
        SessionEntry.fromRelayTask(task);

    test('maps the four displayStatus values onto phases', () {
      String phaseOf(String status) =>
          row({'taskId': 't1', 'title': '任务', 'displayStatus': status}).phase;
      expect(phaseOf('idle'), 'idle');
      expect(phaseOf('running'), 'running');
      expect(phaseOf('completed'), 'completedSuccess');
      expect(phaseOf('error'), 'error');
    });

    test('an absent displayStatus reads as idle; taskId is the session id',
        () {
      final entry = row({'taskId': 't9', 'title': '无状态'});
      expect(entry.sessionId, 't9');
      expect(entry.phase, 'idle');
      // The overview carries no parent link, so its rows are top-level tasks
      // (child sessions only ever ride the subscribed index).
      expect(entry.parentSessionId, isNull);
    });
  });

  group('offPeakEvents (pure rules)', () {
    test('notifies on transitions only', () {
      var events = offPeakEvents(
        previousStatuses: {'t1': 'queued', 't2': 'running'},
        tasks: [
          OffPeakTask({'offPeakTaskId': 't1', 'status': 'completed'}),
          OffPeakTask({'offPeakTaskId': 't2', 'status': 'failed'}),
        ],
      );
      expect(events, hasLength(2));
      expect(events[0].failed, isFalse);
      expect(events[1].failed, isTrue);

      events = offPeakEvents(
        previousStatuses: {'t1': 'completed', 't2': 'failed'},
        tasks: [
          OffPeakTask({'offPeakTaskId': 't1', 'status': 'completed'}),
          OffPeakTask({'offPeakTaskId': 't2', 'status': 'failed'}),
        ],
      );
      expect(events, isEmpty);
    });

    test('first sight of already-finished history stays silent', () {
      final events = offPeakEvents(
        previousStatuses: {},
        tasks: [
          OffPeakTask({
            'offPeakTaskId': 't1',
            'status': 'completed',
            'finishedAt': 123,
          }),
        ],
      );
      expect(events, isEmpty);
    });
  });

  group('automationRunEvents (pure rules)', () {
    test('notifies when lastRunAt bumps, classifying failures', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final events = automationRunEvents(
        previousLastRunAt: {'a1': now - 100, 'a2': now - 100},
        items: [
          AutomationItem({
            'automationId': 'a1',
            'title': '日报',
            'lastRunAt': now,
            'lastResult': 'success'
          }),
          AutomationItem({
            'automationId': 'a2',
            'title': '备份',
            'lastRunAt': now,
            'lastResult': 'error'
          }),
        ],
      );
      expect(events, hasLength(2));
      expect(events[0].failed, isFalse);
      expect(events[1].failed, isTrue);
    });

    test('first sight of an old run stays silent', () {
      final old = DateTime.now()
          .subtract(const Duration(hours: 2))
          .millisecondsSinceEpoch;
      expect(
          automationRunEvents(
            previousLastRunAt: {},
            items: [AutomationItem({'automationId': 'a1', 'lastRunAt': old})],
          ),
          isEmpty);
    });
  });

  group('NotificationService.ensureCopy (empty-copy fallback)', () {
    test('blank title/body fall back to the channel name', () {
      final (title, body) = NotificationService.ensureCopy(
          'zh-CN', NotifyChannel.offPeak, '', '');
      expect(title, '闲时事件');
      expect(body, '闲时事件');
    });

    test('whitespace-only counts as blank; title backfills the body', () {
      final (title, body) =
          NotificationService.ensureCopy('zh-CN', NotifyChannel.tasks, '  ', ' ');
      expect(title, '任务事件');
      expect(body, '任务事件');
    });

    test('real copy passes through untouched, en table honoured', () {
      final (title, body) = NotificationService.ensureCopy(
          'en', NotifyChannel.automations, 'Backup', '');
      expect(title, 'Backup');
      expect(body, 'Backup');
    });
  });

  group('NotificationHub glue', () {
    late RecordingService service;
    late UiSettings ui;
    late NotificationHub hub;
    late FakeNotifiableSession session;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      service = RecordingService();
      ui = UiSettings();
      await ui.load();
      hub = NotificationHub(
          service: service,
          ui: ui,
          deviceLabelOf: (id) => 'my-device',
          // Zero window: the confirm timer fires on the next event-loop
          // turn, so tests mutate state then pumpEventQueue.
          taskConfirmWindow: Duration.zero,
          // These tests drive single edges off a stable baseline; the
          // regression guard needs real elapsed time to expire, so it has
          // its own group below with a 200ms window.
          regressionHysteresis: Duration.zero);
      session = FakeNotifiableSession('d1');
      hub.syncWith([session]);
    });

    test('task running→completed notifies with deep-link payload', () async {
      session.setEntries([('s1', '修复登录', 'running')]);
      expect(service.shown, isEmpty);
      session.setEntries([('s1', '修复登录', 'completedSuccess')]);
      await pumpEventQueue();

      expect(service.shown, hasLength(1));
      final (channel, _, title, body, payload) = service.shown.single;
      expect(channel, NotifyChannel.tasks);
      expect(title, '任务完成');
      expect(body, '修复登录');
      expect(payload, {
        'type': 'task',
        'deviceId': 'd1',
        'sessionId': 's1',
        'title': '修复登录',
      });
    });

    test('master switch off silences but keeps tracking', () async {
      ui.notificationsEnabled = false;
      session.setEntries([('s1', 't', 'running')]);
      session.setEntries([('s1', 't', 'error')]);
      expect(service.shown, isEmpty);

      // Re-enable: the next NEW transition notifies, no replay.
      ui.notificationsEnabled = true;
      session.setEntries([('s1', 't', 'running')]);
      session.setEntries([('s1', 't', 'completedSuccess')]);
      await pumpEventQueue();
      expect(service.shown, hasLength(1));
      expect(service.shown.single.$3, '任务完成');
    });

    test('a blip that reverts to running inside the window is dropped',
        () async {
      session.setEntries([('s1', 't', 'running')]);
      // Model-only helper turn flips the phase terminal for an instant…
      session.setEntries([('s1', 't', 'completedSuccess')]);
      // …then the real turn is still going and the phase reverts, all
      // before the confirm timer fires.
      session.setEntries([('s1', 't', 'running')]);
      await pumpEventQueue();
      expect(service.shown, isEmpty);
    });

    test('a terminal phase that persists notifies after the window',
        () async {
      session.setEntries([('s1', 't', 'running')]);
      session.setEntries([('s1', 't', 'error')]);
      await pumpEventQueue();
      expect(service.shown, hasLength(1));
      expect(service.shown.single.$3, '任务失败');
    });

    test('subagent rows never notify end-to-end', () async {
      session.setEntriesWithParent([
        ('s1', '主任务', 'running', parent: null),
        ('s2', '子代理', 'running', parent: 's1'),
      ]);
      session.setEntriesWithParent([
        ('s1', '主任务', 'running', parent: null),
        ('s2', '子代理', 'completedSuccess', parent: 's1'),
      ]);
      await pumpEventQueue();
      expect(service.shown, isEmpty);
    });

    test('channel switch off silences only that channel', () async {
      ui.notifyTasksEnabled = false;
      session.setEntries([('s1', 't', 'running')]);
      session.setEntries([('s1', 't', 'completedSuccess')]);
      expect(service.shown, isEmpty);
    });

    test('reconnect does not replay old off-peak completions', () async {
      session.offPeakTasks = [
        {'offPeakTaskId': 'op1', 'title': 'CI 报告', 'status': 'running'},
      ];
      await hub.pollOffPeakNow();
      session.offPeakTasks = [
        {'offPeakTaskId': 'op1', 'title': 'CI 报告', 'status': 'completed'},
      ];
      await hub.pollOffPeakNow();
      expect(service.shown, hasLength(1));

      // Session leaves the hub (WebView handover / relay flap) and comes
      // back: the same completed task must NOT notify again.
      hub.syncWith([]);
      hub.syncWith([session]);
      await hub.pollOffPeakNow();
      expect(service.shown, hasLength(1),
          reason: 'status cache survives reconnects');
    });

    test('cold-start first poll baselines existing completions silently',
        () async {
      session.offPeakTasks = [
        {'offPeakTaskId': 'op1', 'title': '旧任务', 'status': 'completed'},
      ];
      await hub.pollOffPeakNow();
      expect(service.shown, isEmpty);
    });

    test('off-peak poll notifies completion with session deep-link',
        () async {
      session.offPeakTasks = [
        {'offPeakTaskId': 'op1', 'title': 'CI 报告', 'status': 'queued'},
      ];
      await hub.pollOffPeakNow();
      expect(service.shown, isEmpty); // queued is not an event

      session.offPeakTasks = [
        {
          'offPeakTaskId': 'op1',
          'title': 'CI 报告',
          'status': 'completed',
          'sessionId': 's-77',
        },
      ];
      await hub.pollOffPeakNow();

      expect(service.shown, hasLength(1));
      final (channel, _, title, body, payload) = service.shown.single;
      expect(channel, NotifyChannel.offPeak);
      expect(title, '闲时任务完成');
      expect(body, 'CI 报告');
      expect(payload['sessionId'], 's-77');
      expect(payload['type'], 'offPeak');
    });

    test('automation poll notifies fresh runs', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      session.automationItems = [
        {'automationId': 'a1', 'title': '日报', 'lastRunAt': now},
      ];
      await hub.pollAutomationsNow();

      expect(service.shown, hasLength(1));
      final (channel, _, title, body, payload) = service.shown.single;
      expect(channel, NotifyChannel.automations);
      expect(title, '自动化触发成功');
      expect(body, '日报');
      expect(payload['type'], 'auto');

      // Second poll with no change: silent.
      await hub.pollAutomationsNow();
      expect(service.shown, hasLength(1));
    });

    test('untracking a removed device drops its history', () async {
      hub.syncWith(const []);
      expect(hub, isNotNull);
      // After untracking, polls have nothing to iterate.
      await hub.pollOffPeakNow();
      expect(service.shown, isEmpty);
    });

    /// A relay overview row as workspace-list-updated delivers it.
    Map<String, dynamic> relayTask(String id, String title, String status) => {
          'taskId': id,
          'title': title,
          'workspacePath': '/repo/beta',
          'workspaceIdentity': 'beta',
          'displayStatus': status,
          'updatedAt': 1,
        };

    test('a task of a non-subscribed workspace still notifies', () async {
      // The overview is the ONLY source for workspaces the native link never
      // subscribed: the sessions-index stays empty throughout.
      session.setRelayTasks([relayTask('rb1', '中继任务乙', 'running')]);
      expect(service.shown, isEmpty, reason: 'running is not an event');
      session.setRelayTasks([relayTask('rb1', '中继任务乙', 'completed')]);
      await pumpEventQueue();

      expect(service.shown, hasLength(1));
      final (channel, _, title, body, payload) = service.shown.single;
      expect(channel, NotifyChannel.tasks);
      expect(title, '任务完成');
      expect(body, '中继任务乙');
      expect(payload['sessionId'], 'rb1');
    });

    test('the live index overrides a stale overview row', () async {
      session.setRelayTasks([relayTask('s1', '修复登录', 'running')]);
      session.setEntries([('s1', '修复登录', 'running')]);
      // The overview already says completed while the subscribed index still
      // knows the turn is going: the index wins, so this is not an edge.
      session.setRelayTasks([relayTask('s1', '修复登录', 'completed')]);
      expect(service.shown, isEmpty, reason: 'index still says running');

      session.setEntries([('s1', '修复登录', 'completedSuccess')]);
      await pumpEventQueue();
      expect(service.shown, hasLength(1));
      expect(service.shown.single.$3, '任务完成');
    });

    test('both sources reporting the same completion fire once', () async {
      session.setRelayTasks([relayTask('s1', '修复登录', 'running')]);
      session.setEntries([('s1', '修复登录', 'running')]);
      // The index reports the terminal phase first…
      session.setEntries([('s1', '修复登录', 'completedSuccess')]);
      await pumpEventQueue();
      expect(service.shown, hasLength(1));

      // …the overview catches up with the same phase: the shared baseline
      // has already flipped, so the second source is a no-op.
      session.setRelayTasks([relayTask('s1', '修复登录', 'completed')]);
      await pumpEventQueue();
      expect(service.shown, hasLength(1), reason: 'no double notice');
    });

    test('the confirm window keeps a non-subscribed task alive', () async {
      // A real window, unlike the zero-window hub above: the post-window
      // re-check used to read only the sessions-index, where a task of
      // another workspace does not exist — it looked vanished and the
      // notice was dropped.
      final other = FakeNotifiableSession('d2');
      final slowHub = NotificationHub(
          service: service,
          ui: ui,
          deviceLabelOf: (id) => 'my-device',
          taskConfirmWindow: const Duration(milliseconds: 20));
      slowHub.syncWith([other]);
      other.setRelayTasks([relayTask('rb2', '别的任务', 'running')]);
      other.setRelayTasks([relayTask('rb2', '别的任务', 'completed')]);
      expect(service.shown, isEmpty, reason: 'still inside the window');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(service.shown, hasLength(1));
      expect(service.shown.single.$4, '别的任务');
      slowHub.dispose();
    });

    test('the disk snapshot covers every workspace', () async {
      session.setRelayTasks([
        relayTask('rb1', '乙工作区运行中', 'running'),
        relayTask('rb2', '乙工作区已完成', 'completed'),
      ]);
      session.setEntries([('s1', '活跃区任务', 'running')]);
      await pumpEventQueue();

      final prefs = await SharedPreferences.getInstance();
      final saved =
          jsonDecode(prefs.getString('notify.taskPhases.d1')!) as Map;
      expect(saved['phases'], {
        'rb1': 'running',
        'rb2': 'completedSuccess',
        's1': 'running',
      });
    });
  });

  group('phase regression guard (bridge flap)', () {
    late RecordingService service;
    late UiSettings ui;
    late NotificationHub hub;
    late FakeNotifiableSession session;

    /// Test-scale window: the guard is driven by real elapsed time (no clock
    /// abstraction), so the wait is shrunk instead of faked.
    const window = Duration(milliseconds: 200);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      service = RecordingService();
      ui = UiSettings();
      await ui.load();
      hub = NotificationHub(
          service: service,
          ui: ui,
          deviceLabelOf: (id) => 'my-device',
          taskConfirmWindow: Duration.zero,
          regressionHysteresis: window);
      session = FakeNotifiableSession('d1');
      hub.syncWith([session]);
    });

    tearDown(() => hub.dispose());

    /// The phases the hub last wrote to disk for d1.
    Future<Map<String, dynamic>> savedPhases() async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('notify.taskPhases.d1');
      return raw == null
          ? {}
          : (jsonDecode(raw) as Map)['phases'] as Map<String, dynamic>;
    }

    test('a stale running frame inside the window is not a regression',
        () async {
      session.setEntries([('s1', '修复登录', 'running')]);
      session.setEntries([('s1', '修复登录', 'completedSuccess')]);
      await pumpEventQueue();
      expect(service.shown, hasLength(1));
      expect(await savedPhases(), {'s1': 'completedSuccess'});

      // The bridge recovered and its frame reports the finished task as
      // running again — shorter than the window, so the baseline holds.
      session.setEntries([('s1', '修复登录', 'running')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();
      expect(await savedPhases(), {'s1': 'completedSuccess'},
          reason: 'the blip must not reach the disk baseline');

      // The fresh frame follows: the baseline never saw a running edge, so
      // there is no second running→terminal edge to notify.
      session.setEntries([('s1', '修复登录', 'completedSuccess')]);
      await pumpEventQueue();
      expect(service.shown, hasLength(1), reason: 'no duplicate notice');
    });

    test('a running report held past the window reverts the baseline',
        () async {
      session.setEntries([('s1', 't', 'running')]);
      session.setEntries([('s1', 't', 'completedSuccess')]);
      await pumpEventQueue();
      expect(service.shown, hasLength(1));

      // A real re-run: running long past the window, so the baseline (and
      // the disk copy) revert and the next completion is a fresh edge.
      session.setEntries([('s1', 't', 'running')]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      session.setEntries([('s1', 't', 'running')]);
      await pumpEventQueue();
      expect(await savedPhases(), {'s1': 'running'});

      session.setEntries([('s1', 't', 'completedSuccess')]);
      await pumpEventQueue();
      expect(service.shown, hasLength(2), reason: 'the re-run notifies');
    });

    test('the window restarts when the running report goes away', () async {
      session.setEntries([('s1', 't', 'running')]);
      session.setEntries([('s1', 't', 'completedSuccess')]);
      await pumpEventQueue();
      expect(service.shown, hasLength(1));

      // Blip, then back to terminal: the stopwatch is over.
      session.setEntries([('s1', 't', 'running')]);
      session.setEntries([('s1', 't', 'completedSuccess')]);
      await pumpEventQueue();
      // Long past the first stopwatch, so a leaked timestamp would accept
      // the second blip at once.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      session.setEntries([('s1', 't', 'running')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();
      expect(await savedPhases(), {'s1': 'completedSuccess'},
          reason: 'the second blip is timed from scratch');

      // Sustained this time: the fresh window expires and it reverts.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      session.setEntries([('s1', 't', 'running')]);
      await pumpEventQueue();
      expect(await savedPhases(), {'s1': 'running'});
      expect(service.shown, hasLength(1), reason: 'still not a completion');
    });

    test('a task that left the merged view re-baselines from scratch',
        () async {
      session.setEntries([('s1', 't', 'running')]);
      session.setEntries([('s1', 't', 'completedSuccess')]);
      await pumpEventQueue();
      expect(service.shown, hasLength(1));

      // Stale frame, then the task leaves the merged view entirely
      // (archived/deleted, or a snapshot without it). The baseline drops the
      // row, so nothing holds a terminal phase for it afterwards.
      session.setEntries([('s1', 't', 'running')]);
      session.setEntries(const []);
      await pumpEventQueue();
      expect(await savedPhases(), isEmpty);

      // Back as running: a first sight again, so it is accepted at once…
      session.setEntries([('s1', 't', 'running')]);
      await pumpEventQueue();
      expect(await savedPhases(), {'s1': 'running'});

      // …and the completion that follows is a fresh edge, not history.
      session.setEntries([('s1', 't', 'completedSuccess')]);
      await pumpEventQueue();
      expect(service.shown, hasLength(2));
    });
  });

  group('kill-and-restart catch-up (PhaseSnapshotStore)', () {
    late RecordingService service;
    late UiSettings ui;

    setUp(() {
      service = RecordingService();
      // Defaults (all switches on, zh-CN) are all these tests need, so the
      // settings never touch prefs and cannot fight the preset snapshot.
      ui = UiSettings();
    });

    int nowMs() => DateTime.now().millisecondsSinceEpoch;

    /// A timestamp just past the store's window (13h for the 12h ttl).
    int staleMs() =>
        nowMs() -
        PhaseSnapshotStore.ttl.inMilliseconds -
        const Duration(hours: 1).inMilliseconds;

    /// Raw payload exactly as [PhaseSnapshotStore.save] writes it.
    String snapshot(int ts, Map<String, String> phases) =>
        jsonEncode({'ts': ts, 'phases': phases});

    /// Tracks a session whose index subscription has not opened yet (the
    /// production state at track time) and lets the disk restore land before
    /// any list frame can baseline silently instead.
    Future<NotificationHub> trackPending(FakeNotifiableSession session) async {
      final hub = NotificationHub(
          service: service,
          ui: ui,
          deviceLabelOf: (id) => 'my-device',
          taskConfirmWindow: Duration.zero);
      hub.syncWith([session]);
      await pumpEventQueue();
      return hub;
    }

    test('a fresh running snapshot reports the completion after restart',
        () async {
      SharedPreferences.setMockInitialValues({
        'notify.taskPhases.d1': snapshot(nowMs(), {'s1': 'running'}),
      });
      final session = FakeNotifiableSession('d1', sessionsReady: false);
      final hub = await trackPending(session);

      // First list frame after the restart: the task finished while we were
      // gone, and the disk baseline is what makes the edge visible.
      session.sessionsReady = true;
      session.setEntries([('s1', '修复登录', 'completedSuccess')]);
      await pumpEventQueue();

      expect(service.shown, hasLength(1));
      final (channel, _, title, body, payload) = service.shown.single;
      expect(channel, NotifyChannel.tasks);
      expect(title, '任务完成');
      expect(body, '修复登录');
      expect(payload, {
        'type': 'task',
        'deviceId': 'd1',
        'sessionId': 's1',
        'title': '修复登录',
      });
      hub.dispose();
    });

    test('a snapshot past the 12h window stays silent', () async {
      expect(PhaseSnapshotStore.ttl, const Duration(hours: 12));
      SharedPreferences.setMockInitialValues({
        'notify.taskPhases.d1': snapshot(staleMs(), {'s1': 'running'}),
      });
      final session = FakeNotifiableSession('d1', sessionsReady: false);
      final hub = await trackPending(session);

      session.sessionsReady = true;
      session.setEntries([('s1', '旧任务', 'completedSuccess')]);
      await pumpEventQueue();

      expect(service.shown, isEmpty,
          reason: 'a stale snapshot cold-starts silently, as before');
      hub.dispose();
    });

    test('an empty store baselines silently too', () async {
      SharedPreferences.setMockInitialValues({});
      final session = FakeNotifiableSession('d1', sessionsReady: false);
      final hub = await trackPending(session);

      session.sessionsReady = true;
      session.setEntries([('s1', '重启前完成的旧任务', 'completedSuccess')]);
      await pumpEventQueue();

      expect(service.shown, isEmpty, reason: 'nothing to restore');
      hub.dispose();
    });

    test('start() sweeps expired keys and keeps fresh ones', () async {
      final fresh = snapshot(nowMs(), {'s1': 'running'});
      final stale = snapshot(staleMs(), {'s2': 'running'});
      SharedPreferences.setMockInitialValues({
        'notify.taskPhases.d1': fresh,
        'notify.taskPhases.d2': stale,
      });

      final hub = NotificationHub(
          service: service, ui: ui, deviceLabelOf: (id) => 'my-device');
      hub.start();
      await pumpEventQueue();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('notify.taskPhases.d1'), fresh);
      expect(prefs.containsKey('notify.taskPhases.d2'), isFalse);
      hub.dispose();
    });
  });
}
