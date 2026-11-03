// Widget tests for the read-only workflow run detail page (step 4):
// section rendering for a live run, terminal states, mirror + snapshot
// merge, display-only snapshots, evicted runs, empty hints, live delta
// refresh and the zero-write-affordance guarantee.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/i18n/lexicon.dart';
import 'package:zgo/protocol/conversation_state.dart';
import 'package:zgo/ui/chat/workflow_run_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../protocol/workflow_fixtures.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  builder: (context, child) =>
      UiSettingsProvider(settings: UiSettings(), child: child!),
  home: child,
);

ConversationState stateWith({List<Map<String, dynamic>> runs = const []}) =>
    ConversationState()..workflowRuns = WorkflowRuns(runs: runs);

/// Tall surface so every section of the page is laid out (ListView only
/// mounts its visible children).
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

String runIdOf(Map<String, dynamic> run) => '${run['runId']}';

/// Resolved copy for the default zh-CN locale (the page reads the lexicon).
String zh(String key, [List<String> args = const []]) =>
    trByKeyP('zh-CN', key, args);

/// Status chips live in the header Wrap; scoping keeps them distinct from the
/// agent state label (a completed run and a done agent both read 已完成).
Finder statusChip(String key) => find.descendant(
  of: find.byType(Wrap).first,
  matching: find.text(zh(key)),
);

void main() {
  testWidgets('running run renders status/progress/questions/phases/agents/'
      'artifacts/reports and the elapsed meta', (tester) async {
    useTallSurface(tester);
    final run = workflowRunFixture();
    final state = stateWith(runs: [run]);

    await tester.pumpWidget(
      wrap(
        WorkflowRunPage(
          state: state,
          runId: runIdOf(run),
          workStartedAt: 60000,
          workEndedAt: 125000,
        ),
      ),
    );

    // AppBar fallback title + live status chip + elapsed/tokens meta.
    expect(find.text(zh('chat.workflowDetail.titleFallback')), findsOneWidget);
    expect(find.text(zh('chat.workflowCard.status.running')), findsOneWidget);
    expect(find.textContaining('已工作 1 分 5 秒'), findsOneWidget);
    // No snapshot health → the mirror's `concurrency.cap` backs the line.
    expect(
      find.textContaining(zh('chat.workflowDetail.health.concurrency', ['14'])),
      findsOneWidget,
    );

    // Progress (mirror projection: 2 settled of 6 total).
    expect(find.text(zh('chat.workflowDetail.progress')), findsOneWidget);
    expect(find.text(zh('chat.workflowCard.steps', ['2', '6'])), findsOneWidget);

    // Pending questions are read-only and carry the desktop hint.
    expect(
      find.text(zh('chat.workflowDetail.section.questions')),
      findsOneWidget,
    );
    expect(find.text('主色使用哪一版？'), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.questionReadonly')), findsOneWidget);

    // Phase rows; the live run's second phase is the current one.
    // (The exact phase names also head each actor's meta line, hence
    // `findsWidgets`.)
    expect(find.text(zh('chat.workflowDetail.section.phases')), findsOneWidget);
    expect(find.text('勘察现有界面'), findsWidgets);
    expect(find.text('落地品牌'), findsWidgets);
    expect(
      find.textContaining(zh('chat.workflowDetail.phaseState.current')),
      findsOneWidget,
    );

    // Agent roster (the pending-question card repeats its actor name).
    expect(find.text(zh('chat.workflowDetail.section.agents')), findsOneWidget);
    expect(find.text('设计架构师'), findsWidgets);
    expect(find.text('品牌与主题'), findsWidgets);

    // Artifact chips and report previews.
    expect(
      find.text(zh('chat.workflowDetail.section.artifacts')),
      findsOneWidget,
    );
    expect(find.text('改造进度'), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.section.reports')), findsOneWidget);
    expect(find.text('设计规格：…'), findsOneWidget);

    // No snapshot → no logs/health sections and no snapshot badge.
    expect(find.text(zh('chat.workflowDetail.section.logs')), findsNothing);
    expect(find.text(zh('chat.workflowDetail.section.health')), findsNothing);
    expect(
      find.textContaining(zh('chat.workflowDetail.snapshotOnly')),
      findsNothing,
    );

    // Expanding a phase renders its node rows (mirror nodes only).
    await tester.tap(find.text('勘察现有界面').first);
    await tester.pumpAndSettle();
    expect(
      find.textContaining(zh('chat.workflowDetail.nodeKind.ask')),
      findsOneWidget,
    );
    expect(find.text('盘点现有页面'), findsOneWidget);
    expect(
      find.textContaining(zh('chat.workflowDetail.outcome.ok')),
      findsOneWidget,
    );
  });

  testWidgets('completed / errored / stopped terminal states', (tester) async {
    useTallSurface(tester);

    // completed: mirror status + snapshot result/logs.
    final completed = workflowRunFixture(status: 'completed');
    await tester.pumpWidget(
      wrap(
        WorkflowRunPage(
          state: stateWith(runs: [completed]),
          runId: runIdOf(completed),
          display: workflowGetRunDisplayFixture(),
        ),
      ),
    );
    expect(statusChip('chat.workflowCard.status.completed'), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.section.result')), findsOneWidget);
    expect(find.textContaining('日计 UI 改造已落地'), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.section.logs')), findsOneWidget);
    expect(find.textContaining('node-settled ask#2'), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.section.error')), findsNothing);
    expect(find.text(zh('chat.workflowDetail.truncated')), findsOneWidget);

    // errored: snapshot error plus failure counters.
    final errored = workflowRunFixture(status: 'errored');
    await tester.pumpWidget(
      wrap(
        WorkflowRunPage(
          state: stateWith(runs: [errored]),
          runId: runIdOf(errored),
          display: workflowGetRunDisplayFixture(withError: true),
        ),
      ),
    );
    expect(find.text(zh('chat.workflowCard.status.errored')), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.section.error')), findsOneWidget);
    expect(find.text('model request failed'), findsOneWidget);
    expect(
      find.textContaining(zh('chat.workflowDetail.health.failures', ['3'])),
      findsOneWidget,
    );

    // stopped: stop reason chip and the no-result hint.
    final stopped = workflowRunFixture(status: 'stopped', stopReason: 'user');
    await tester.pumpWidget(
      wrap(
        WorkflowRunPage(
          state: stateWith(runs: [stopped]),
          runId: runIdOf(stopped),
        ),
      ),
    );
    expect(find.text(zh('chat.workflowCard.status.stopped')), findsOneWidget);
    expect(
      find.text(zh('chat.workflowDetail.stopReason.user')),
      findsOneWidget,
    );
    expect(find.text(zh('chat.workflowDetail.noResult')), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.section.logs')), findsNothing);
  });

  testWidgets('mirror + snapshot merge keeps live status/actors and adds '
      'the snapshot rich fields', (tester) async {
    useTallSurface(tester);
    final run = workflowRunFixture(status: 'running');
    final display = workflowGetRunDisplayFixture();

    await tester.pumpWidget(
      wrap(
        WorkflowRunPage(
          state: stateWith(runs: [run]),
          runId: runIdOf(run),
          display: display,
        ),
      ),
    );

    // Live status wins over the snapshot's "completed".
    expect(find.text(zh('chat.workflowCard.status.running')), findsOneWidget);
    expect(statusChip('chat.workflowCard.status.completed'), findsNothing);

    // Official display phases win over the mirror approximation: the
    // second phase reads done (snapshot) instead of current (mirror).
    expect(
      find.textContaining(zh('chat.workflowDetail.phaseState.current')),
      findsNothing,
    );

    // Actor status stays live: running mirror → executing; the snapshot's
    // done state only fills the other actor.
    expect(
      find.text(zh('chat.workflowDetail.agentState.executing')),
      findsOneWidget,
    );
    expect(
      find.text(zh('chat.workflowDetail.agentState.done')),
      findsOneWidget,
    );

    // Snapshot-only rich fields: steps/tokens/instructions + logs/health/
    // result/truncated. Both snapshot subagents carry step counts.
    expect(
      find.textContaining('步已完成'),
      findsNWidgets(2),
    );
    expect(find.text('改主题'), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.section.logs')), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.section.health')), findsOneWidget);
    expect(
      find.textContaining(zh('chat.workflowDetail.health.cached', ['1'])),
      findsOneWidget,
    );
    expect(find.textContaining('日计 UI 改造已落地'), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.truncated')), findsOneWidget);
  });

  testWidgets('display-only snapshot shows the badge, age and no mirror '
      'sections', (tester) async {
    useTallSurface(tester);
    final display = workflowGetRunDisplayFixture();

    await tester.pumpWidget(
      wrap(
        WorkflowRunPage(
          state: stateWith(),
          runId: '${display['runId']}',
          display: display,
        ),
      ),
    );

    // Snapshot badge with the real relative age of generatedAt; the label
    // backs the AppBar title.
    final context = tester.element(find.byType(WorkflowRunPage));
    expect(find.text('日计 UI 改造'), findsOneWidget);
    expect(
      find.text(
        '${zh('chat.workflowDetail.snapshotOnly')} · '
        '${zh('chat.workflowDetail.snapshotAge', [
          relativeTime(context, display['generatedAt'] as int),
        ])}',
      ),
      findsOneWidget,
    );

    // Snapshot fallbacks: phase windows give the elapsed span (earliest
    // enteredAt → latest exitedAt) and usage.spentTokens backs the tokens
    // line (the mirror is absent).
    expect(find.textContaining('已工作 35 分 18 秒'), findsOneWidget);
    final spentTokens = (display['usage'] as Map)['spentTokens'] as int;
    expect(
      find.textContaining(
        zh('chat.workflowCard.tokens', [compactTokens(context, spentTokens)]),
      ),
      findsOneWidget,
    );

    // Snapshot counters replace the missing mirror progress bar.
    expect(find.text(zh('chat.workflowDetail.progress')), findsOneWidget);
    expect(
      find.textContaining(zh('chat.workflowCard.nodesObserved', ['55'])),
      findsOneWidget,
    );

    // Snapshot phases render as plain rows (no nodes), the roster from the
    // snapshot, and the snapshot-only log/health/result sections.
    expect(find.text('勘察现有界面'), findsOneWidget);
    expect(find.text('设计架构师'), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.section.logs')), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.section.health')), findsOneWidget);
    expect(find.textContaining('日计 UI 改造已落地'), findsOneWidget);

    // No mirror questions, health says they are known → no section.
    expect(find.text(zh('chat.workflowDetail.section.questions')), findsNothing);
  });

  testWidgets('snapshot chips, unknown questions and wait causes render', (
    tester,
  ) async {
    useTallSurface(tester);
    final base = workflowGetRunDisplayFixture();
    final subagents = [
      for (final subagent in base['subagents'] as List)
        Map<String, dynamic>.from(subagent as Map),
    ];
    subagents[0]['waitCause'] = 'slot';
    final health = Map<String, dynamic>.from(base['health'] as Map)
      ..['pendingQuestionsKnown'] = false
      ..['stalledSince'] = 1793703708202;
    final display = <String, dynamic>{
      ...base,
      'possiblyInterrupted': true,
      'subagents': subagents,
      'health': health,
    };

    await tester.pumpWidget(
      wrap(
        WorkflowRunPage(
          state: stateWith(),
          runId: '${display['runId']}',
          display: display,
        ),
      ),
    );

    // Status-header chip.
    expect(
      statusChip('chat.workflowDetail.possiblyInterrupted'),
      findsOneWidget,
    );

    // No mirror roster → the snapshot's health flag decides.
    expect(
      find.text(zh('chat.workflowDetail.section.questions')),
      findsOneWidget,
    );
    expect(
      find.text(zh('chat.workflowDetail.questionsUnknown')),
      findsOneWidget,
    );

    // Display wait causes on the roster: slot on actor#1 (injected) and
    // backoff on actor#2 (fixture 5000ms → 5s).
    expect(
      find.textContaining(zh('chat.workflowDetail.agentWaitingSlot')),
      findsOneWidget,
    );
    expect(
      find.textContaining(zh('chat.workflowDetail.agentBackoff', ['5'])),
      findsOneWidget,
    );

    // Stalled health reads as「上次进展：<relative time>」.
    final context = tester.element(find.byType(WorkflowRunPage));
    expect(
      find.textContaining(
        zh('chat.workflowDetail.health.stalled', [
          relativeTime(context, 1793703708202),
        ]),
      ),
      findsOneWidget,
    );
  });

  testWidgets('evicted run without a snapshot is unavailable', (tester) async {
    await tester.pumpWidget(
      wrap(
        WorkflowRunPage(
          state: stateWith(),
          runId: 'dwfrun-missing',
          title: '已移除的运行',
        ),
      ),
    );
    expect(find.text('已移除的运行'), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.notInSession')), findsOneWidget);
  });

  testWidgets('a live-removed run without a snapshot falls back to the '
      'unavailable page', (tester) async {
    useTallSurface(tester);
    final run = workflowRunFixture(status: 'running');
    final state = stateWith(runs: [run]);

    await tester.pumpWidget(
      wrap(WorkflowRunPage(state: state, runId: runIdOf(run))),
    );
    expect(find.text(zh('chat.workflowCard.status.running')), findsOneWidget);

    // `workflowRun.removed` arrives: the mirror drops the run.
    state.workflowRuns = const WorkflowRuns();
    state.notifyListeners();
    await tester.pump();

    expect(find.text(zh('chat.workflowDetail.notInSession')), findsOneWidget);
    expect(find.text(zh('chat.workflowCard.status.running')), findsNothing);
  });

  testWidgets('a live-removed run with a snapshot keeps the snapshot page '
      'and badge', (tester) async {
    useTallSurface(tester);
    final run = workflowRunFixture(status: 'running');
    final display = workflowGetRunDisplayFixture();
    final state = stateWith(runs: [run]);

    await tester.pumpWidget(
      wrap(
        WorkflowRunPage(
          state: state,
          runId: runIdOf(run),
          display: display,
        ),
      ),
    );
    expect(find.text(zh('chat.workflowCard.status.running')), findsOneWidget);
    expect(
      find.textContaining(zh('chat.workflowDetail.snapshotOnly')),
      findsNothing,
    );

    state.workflowRuns = const WorkflowRuns();
    state.notifyListeners();
    await tester.pump();

    // The snapshot carries the run; the page stays with the badge and the
    // snapshot's status.
    expect(
      find.textContaining(zh('chat.workflowDetail.snapshotOnly')),
      findsWidgets,
    );
    expect(statusChip('chat.workflowCard.status.completed'), findsOneWidget);
    expect(find.text(zh('chat.workflowCard.status.running')), findsNothing);
    expect(find.text(zh('chat.workflowDetail.notInSession')), findsNothing);
  });

  testWidgets('empty run shows the short no-phases/no-agents hints', (
    tester,
  ) async {
    useTallSurface(tester);
    final run = <String, dynamic>{'runId': 'r-empty', 'status': 'running'};

    await tester.pumpWidget(
      wrap(
        WorkflowRunPage(state: stateWith(runs: [run]), runId: 'r-empty'),
      ),
    );
    expect(find.text(zh('chat.workflowDetail.noPhases')), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.noAgents')), findsOneWidget);
    expect(find.text(zh('chat.workflowDetail.noResult')), findsOneWidget);
  });

  testWidgets('page exposes no write affordance: no stop/resume/answer/'
      'artifact-open buttons', (tester) async {
    useTallSurface(tester);
    final run = workflowRunFixture()..['resumable'] = true;

    await tester.pumpWidget(
      wrap(
        WorkflowRunPage(
          state: stateWith(runs: [run]),
          runId: runIdOf(run),
          display: workflowGetRunDisplayFixture(),
        ),
      ),
    );

    // Resumable renders as a read-only chip, never a button.
    expect(find.text(zh('chat.workflowDetail.resumable')), findsOneWidget);

    expect(
      find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
      findsNothing,
    );
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);

    // The question card and artifact chips have no tap target.
    expect(
      find.ancestor(
        of: find.text('主色使用哪一版？'),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.text('改造进度'),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.text('改造进度'),
        matching: find.byType(GestureDetector),
      ),
      findsNothing,
    );
  });

  testWidgets('a live delta refreshes the page through ListenableBuilder', (
    tester,
  ) async {
    useTallSurface(tester);
    final state = stateWith(runs: [workflowRunFixture()]);
    final runId = '${workflowRunFixture()['runId']}';

    await tester.pumpWidget(
      wrap(WorkflowRunPage(state: state, runId: runId)),
    );
    expect(find.text(zh('chat.workflowCard.status.running')), findsOneWidget);

    state.workflowRuns = WorkflowRuns(
      runs: [workflowRunFixture(status: 'completed')],
    );
    state.notifyListeners();
    await tester.pump();

    expect(statusChip('chat.workflowCard.status.completed'), findsOneWidget);
    expect(find.text(zh('chat.workflowCard.status.running')), findsNothing);
  });
}
