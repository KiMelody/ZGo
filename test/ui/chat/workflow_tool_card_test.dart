// Pure-function tests for the workflow tool card projections (step 2) plus
// the widget tests for the four chat-card forms (step 3): run title
// fallback, summary parts, mirror + snapshot merge, create/resume/get/list
// rendering, the fallback gate and the navigation callback.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/i18n/lexicon.dart';
import 'package:zgo/protocol/conversation_state.dart';
import 'package:zgo/protocol/workflow_run_display.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/chat/workflow_card.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';
import '../../protocol/workflow_fixtures.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  builder: (context, child) =>
      UiSettingsProvider(settings: UiSettings(), child: child!),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// Resolved copy for the default zh-CN locale (the card reads the lexicon).
String zh(String key, [List<String> args = const []]) =>
    trByKeyP('zh-CN', key, args);

Map<String, dynamic> _toolRow({
  Object? toolCallId,
  String toolName = 'CreateWorkflow',
  Map<String, dynamic>? input,
  String? inputText,
  Map<String, dynamic>? display,
}) => {
  'rowId': 1,
  'kind': 'toolCall',
  'toolName': toolName,
  if (toolCallId != null) 'toolCallId': toolCallId,
  if (input != null) 'input': input,
  if (inputText != null) 'inputText': inputText,
  if (display != null) 'display': display,
};

void main() {
  group('workflowRunName', () {
    test('get_workflow_run display label wins when runId matches', () {
      final display = workflowGetRunDisplayFixture();
      expect(
        workflowRunName(
          rows: const [],
          runId: '${display['runId']}',
          display: display,
          workTitle: 'work title',
        ),
        '日计 UI 改造',
      );
    });

    test('display of a different run is ignored', () {
      final display = workflowGetRunDisplayFixture();
      expect(
        workflowRunName(
          rows: const [],
          runId: 'another-run',
          display: display,
          workTitle: ' Parent work ',
        ),
        'Parent work',
      );
      expect(
        workflowRunName(
          rows: const [],
          runId: 'another-run',
          display: display,
        ),
        isNull,
      );
    });

    test('launch tool row input map carries the name', () {
      final rows = [
        _toolRow(
          toolCallId: 'call-1',
          input: const {'name': 'Input Map Name', 'path': 'a.md'},
          display: workflowCreateDisplayFixture(),
        ),
      ];
      expect(
        workflowRunName(rows: rows, runId: 'r1', toolCallId: 'call-1'),
        'Input Map Name',
      );
    });

    test('launch tool row inputText JSON carries the name '
        '(snake_case tool name)', () {
      final rows = [
        _toolRow(
          toolCallId: 'call-2',
          toolName: 'resume_workflow_run',
          inputText: '{"name":"Text JSON Name"}',
        ),
      ];
      expect(
        workflowRunName(rows: rows, runId: 'r1', toolCallId: 'call-2'),
        'Text JSON Name',
      );
    });

    test('launch row display title/label is the second fallback', () {
      final rows = [
        _toolRow(
          toolCallId: 'call-3',
          input: const {},
          inputText: '',
          display: const {
            'kind': 'create_workflow',
            'ok': true,
            'title': 'Row Display Title',
          },
        ),
      ];
      expect(
        workflowRunName(rows: rows, runId: 'r1', toolCallId: 'call-3'),
        'Row Display Title',
      );

      final noRowDisplay = [_toolRow(toolCallId: 'call-4')];
      expect(
        workflowRunName(
          rows: noRowDisplay,
          runId: 'r1',
          toolCallId: 'call-4',
          display: const {'kind': 'create_workflow', 'label': 'Param Label'},
        ),
        'Param Label',
      );
    });

    test('malformed inputText never throws and falls through', () {
      final broken = [
        _toolRow(toolCallId: 'call-1', inputText: '{not-json'),
      ];
      expect(
        workflowRunName(
          rows: broken,
          runId: 'r1',
          toolCallId: 'call-1',
          workTitle: 'Work Title',
        ),
        'Work Title',
      );

      final wrongType = [
        _toolRow(toolCallId: 'call-2', inputText: '{"name":42}'),
      ];
      expect(
        workflowRunName(
          rows: wrongType,
          runId: 'r1',
          toolCallId: 'call-2',
        ),
        isNull,
      );
    });

    test('non-launch tool rows with the same toolCallId are ignored', () {
      final rows = [
        _toolRow(
          toolCallId: 'call-1',
          toolName: 'Read',
          input: const {'name': 'not a workflow'},
        ),
      ];
      expect(
        workflowRunName(
          rows: rows,
          runId: 'r1',
          toolCallId: 'call-1',
          workTitle: 'Work Title',
        ),
        'Work Title',
      );
    });

    test('turnHeader workflowLaunch name for the matching run', () {
      final rows = <Map<String, dynamic>>[
        {
          'rowId': 2,
          'kind': 'turnHeader',
          'workflowLaunch': {'runId': 'r1', 'name': 'Launch Name'},
        },
      ];
      expect(workflowRunName(rows: rows, runId: 'r1'), 'Launch Name');
      expect(
        workflowRunName(rows: rows, runId: 'other', workTitle: 'Work Title'),
        'Work Title',
      );
    });

    test('display of another run cannot leak through the launch row', () {
      final rows = [_toolRow(toolCallId: 'call-1')];
      final otherDisplay = workflowGetRunDisplayFixture()
        ..['runId'] = 'another-run';
      expect(
        workflowRunName(
          rows: rows,
          runId: 'r1',
          toolCallId: 'call-1',
          display: otherDisplay,
        ),
        isNull,
      );
    });

    test('workTitle fallback and fully empty stack', () {
      expect(
        workflowRunName(rows: const [], runId: 'r1', workTitle: '  T  '),
        'T',
      );
      expect(workflowRunName(rows: const [], runId: 'r1'), isNull);
      expect(
        workflowRunName(rows: const [], runId: 'r1', workTitle: '   '),
        isNull,
      );
    });
  });

  group('workflowProgressParts', () {
    test('mirror run lists only non-zero quantities in design order', () {
      final run = WorkflowRun(workflowRunFixture());
      final parts = workflowProgressParts(run);

      expect(parts.map((p) => p.kind), const [
        WorkflowSummaryKind.nodesProgress,
        WorkflowSummaryKind.agentsRunning,
        WorkflowSummaryKind.tokens,
        WorkflowSummaryKind.artifacts,
        WorkflowSummaryKind.questions,
      ]);
      expect(parts[0].value, 2); // one settled node + one unlisted settled
      expect(parts[0].total, 6); // four wire nodes + two unlisted
      expect(parts[1].value, 1);
      expect(parts[2].value, 38994588);
      expect(parts[3].value, 1);
      expect(parts[4].value, 1);
    });

    test('empty run yields no parts', () {
      expect(workflowProgressParts(null), isEmpty);
      expect(
        workflowProgressParts(
          WorkflowRun(const {'runId': 'r1', 'status': 'pending'}),
        ),
        isEmpty,
      );
    });

    test('a settled run falls back to the roster size for the agent count', () {
      final raw = workflowRunFixture(status: 'completed');
      for (final actor in (raw['actors'] as List).cast<Map<String, dynamic>>()) {
        actor['status'] = 'completed';
      }
      final parts = workflowProgressParts(WorkflowRun(raw));

      expect(
        parts.map((p) => p.kind),
        isNot(contains(WorkflowSummaryKind.agentsRunning)),
      );
      final agents = parts.singleWhere(
        (p) => p.kind == WorkflowSummaryKind.agents,
      );
      expect(agents.value, 2); // both fixture actors, none running
    });
  });

  group('workflowSummary', () {
    test('snapshot counters and subagent count in design order', () {
      final display = WorkflowRunDisplay.tryParse(
        workflowGetRunDisplayFixture(withError: true),
      )!;
      final parts = workflowSummary(display);

      expect(parts.map((p) => p.kind), const [
        WorkflowSummaryKind.nodesObserved,
        WorkflowSummaryKind.nodesCompleted,
        WorkflowSummaryKind.nodesRunning,
        WorkflowSummaryKind.nodesFailed,
        WorkflowSummaryKind.agents,
      ]);
      expect(parts.map((p) => p.value), const [55, 50, 2, 3, 2]);
    });

    test('zero counters and no roster yield no parts', () {
      final display = WorkflowRunDisplay.tryParse(const {
        'kind': 'get_workflow_run',
        'runId': 'r1',
        'label': 'x',
        'status': 'running',
        'usage': {
          'spentTokens': 100,
          'nodesObserved': 0,
          'nodesRunning': 0,
          'nodesCompleted': 0,
          'nodesFailed': 0,
        },
        'subagents': <Object?>[],
        'actors': <Object?>[],
      })!;
      expect(workflowSummary(display), isEmpty);
      expect(workflowSummary(null), isEmpty);
    });

    test('identity-only actors back the agent count', () {
      final display = WorkflowRunDisplay.tryParse(const {
        'kind': 'get_workflow_run',
        'runId': 'r1',
        'actors': [
          {'siteId': 'a', 'ordinal': 1},
          {'siteId': 'b', 'ordinal': 1},
        ],
      })!;
      final parts = workflowSummary(display);
      expect(parts.single.kind, WorkflowSummaryKind.agents);
      expect(parts.single.value, 2);
    });
  });

  group('WorkflowViewData merge', () {
    test('mirror wins live fields, display fills phases/rich actors', () {
      final rawRun = workflowRunFixture(status: 'running', stopReason: 'user')
        ..['resumable'] = true;
      final run = WorkflowRun(rawRun);
      final display = WorkflowRunDisplay.tryParse(
        workflowGetRunDisplayFixture(withError: true),
      )!;
      final data = WorkflowViewData(run: run, display: display);

      expect(data.runId, run.runId);
      expect(data.status, 'running'); // live mirror beats snapshot 'errored'
      expect(data.stopReason, 'user');
      expect(data.resumable, isTrue);
      expect(data.possiblyInterrupted, isFalse);
      expect(data.truncated, isTrue); // snapshot truncated
      expect(data.generatedAt, 1793703745582);
      expect(data.isDisplayOnly, isFalse);
      expect(data.hasSnapshot, isTrue);
      expect(data.hasProgress, isTrue);
      expect(data.nodesSettled, 2);
      expect(data.nodesTotal, 6);

      // Phases come from the official display projection.
      expect(data.phases, hasLength(2));
      expect(data.phases.first.fromDisplay, isTrue);
      expect(data.phases.first.state, 'done');
      expect(data.phases.last.state, 'unfinished');

      // Mirror-only collections.
      expect(data.nodes, hasLength(4));
      expect(data.pendingQuestions.single.question, '主色使用哪一版？');
      expect(data.artifacts.single.id, 'progress');
      expect(data.reports.single.preview, '设计规格：…');

      // Actor status stays live; the snapshot adds the rich fields.
      expect(data.actors, hasLength(2));
      final brand = data.actors.firstWhere(
        (a) => a.key == 'actor#2\u00001',
      );
      expect(brand.fromMirror, isTrue);
      expect(brand.hasSnapshot, isTrue);
      expect(brand.name, '品牌与主题');
      expect(brand.status, 'running');
      expect(brand.snapshotState, 'failed');
      expect(brand.stepsSettled, 3);
      expect(brand.stepsFailed, 1);
      expect(brand.tokens, 998877);
      expect(brand.lastTool?.name, 'Edit');
      expect(brand.waitCause, isNull);

      expect(data.result, startsWith('{"conclusion"'));
      expect(data.error, 'model request failed');
      expect(data.logTail, hasLength(2));
      expect(data.health?.consecutiveFailures, 3);
    });

    test('mirror-only run approximates phases and hides snapshot sections', () {
      final run = WorkflowRun(workflowRunFixture());
      final data = WorkflowViewData(run: run);

      expect(data.hasSnapshot, isFalse);
      expect(data.isDisplayOnly, isFalse);
      expect(data.logTail, isEmpty);
      expect(data.health, isNull);
      expect(data.truncated, isFalse);

      expect(data.phases, hasLength(2));
      final first = data.phases.first;
      expect(first.fromDisplay, isFalse);
      expect(first.name, '勘察现有界面');
      expect(first.state, 'done');
      expect(first.rounds, 1);
      expect(first.nodesSettled, 1);
      expect(first.nodesRunning, 0);

      final second = data.phases.last;
      expect(second.state, 'current');
      expect(second.rounds, 2);
      expect(second.nodesSettled, 1); // no wire settled + one unlisted
      expect(second.nodesRunning, 2); // executing + waiting

      final architect = data.actors.firstWhere(
        (a) => a.key == 'actor#1\u00001',
      );
      expect(architect.fromMirror, isTrue);
      expect(architect.hasSnapshot, isFalse);
      expect(architect.status, 'completed');
      expect(architect.stepsSettled, 0);
      expect(architect.lastTool, isNull);

      expect(data.result, isNull);
      expect(data.error, isNull);
    });

    test('terminal mirror marks under-settled phases unfinished', () {
      final data = WorkflowViewData(
        run: WorkflowRun(workflowRunFixture(status: 'completed')),
      );
      expect(data.phases.map((p) => p.state), const ['done', 'unfinished']);
    });

    test('running mirror without currentPhase marks every phase ahead', () {
      final raw = workflowRunFixture()..remove('currentPhase');
      final data = WorkflowViewData(run: WorkflowRun(raw));
      expect(data.phases.map((p) => p.state), const ['ahead', 'ahead']);
    });

    test('display-only snapshot exposes the badge inputs and data', () {
      final display = WorkflowRunDisplay.tryParse(
        workflowGetRunDisplayFixture(),
      )!;
      final data = WorkflowViewData(display: display);

      expect(data.run, isNull);
      expect(data.isDisplayOnly, isTrue);
      expect(data.hasSnapshot, isTrue);
      expect(data.runId, display.runId);
      expect(data.status, 'completed');
      expect(data.resumable, isFalse);
      expect(data.possiblyInterrupted, isFalse);
      expect(data.hasProgress, isFalse);
      expect(data.nodesSettled, 0);
      expect(data.nodesTotal, 0);
      expect(data.nodes, isEmpty);
      expect(data.pendingQuestions, isEmpty);
      expect(data.artifacts, isEmpty);
      expect(data.reports, isEmpty);

      expect(data.phases, hasLength(2));
      expect(data.phases.every((p) => p.fromDisplay), isTrue);
      expect(data.actors, hasLength(2));
      expect(data.actors.first.fromMirror, isFalse);
      expect(data.actors.first.status, 'done');

      expect(data.logTail, hasLength(2));
      expect(data.health, isNotNull);
      expect(data.result, isNotNull);
      expect(data.truncated, isTrue);
      expect(data.generatedAt, 1793703745582);
    });

    test('mirror result/error fallbacks and run-side truncated', () {
      final raw = workflowRunFixture()
        ..['resultPreview'] = 'preview result'
        ..['error'] = 'mirror failure'
        ..['truncated'] = true;
      final displayMap = workflowGetRunDisplayFixture(withLogs: false)
        ..remove('truncated')
        ..remove('result');
      final display = WorkflowRunDisplay.tryParse(displayMap)!;
      final data = WorkflowViewData(
        run: WorkflowRun(raw),
        display: display,
      );

      expect(data.result, 'preview result');
      expect(data.error, 'mirror failure');
      expect(data.truncated, isTrue);
    });

    test('empty display phases fall back to the mirror approximation', () {
      final displayMap = workflowGetRunDisplayFixture()
        ..['phases'] = <Object?>[];
      final display = WorkflowRunDisplay.tryParse(displayMap)!;
      final data = WorkflowViewData(
        run: WorkflowRun(workflowRunFixture()),
        display: display,
      );
      expect(data.phases, hasLength(2));
      expect(data.phases.every((p) => p.fromDisplay), isFalse);
    });

    test('identity-only snapshot actors fill a missing mirror roster', () {
      final display = WorkflowRunDisplay.tryParse(const {
        'kind': 'get_workflow_run',
        'runId': 'r1',
        'label': 'x',
        'actors': [
          {'siteId': 'a', 'ordinal': 1, 'name': 'Actor A'},
        ],
      })!;
      final data = WorkflowViewData(display: display);
      expect(data.actors.single.name, 'Actor A');
      expect(data.actors.single.status, '');
    });

    test('malformed mirror members read as empty instead of throwing', () {
      final data = WorkflowViewData(
        run: WorkflowRun(const {
          'runId': 'r1',
          'status': 'running',
          'nodes': 'not-a-list',
          'actors': 42,
          'phases': 'not-a-list',
          'phaseNames': 'not-a-list',
          'pendingQuestions': 'not-a-list',
          'artifacts': 'not-a-list',
          'reports': 'not-a-list',
        }),
      );
      expect(data.runId, 'r1');
      expect(data.nodes, isEmpty);
      expect(data.actors, isEmpty);
      expect(data.phases, isEmpty);
      expect(data.pendingQuestions, isEmpty);
      expect(data.artifacts, isEmpty);
      expect(data.reports, isEmpty);
      expect(data.result, isNull);
      expect(data.error, isNull);
    });

    test('empty view is unavailable and harmless', () {
      final data = WorkflowViewData();
      expect(data.runId, '');
      expect(data.status, '');
      expect(data.isDisplayOnly, isFalse);
      expect(data.hasSnapshot, isFalse);
      expect(data.hasProgress, isFalse);
      expect(data.phases, isEmpty);
      expect(data.actors, isEmpty);
      expect(data.logTail, isEmpty);
      expect(data.health, isNull);
      expect(data.result, isNull);
      expect(data.error, isNull);
      expect(data.truncated, isFalse);
    });
  });

  group('isWorkflowToolRow / hasWorkflowCard', () {
    test('workflow display kinds and normalized tool names hit', () {
      for (final kind in const [
        'create_workflow',
        'resume_workflow_run',
        'get_workflow_run',
        'list_workflow_runs',
      ]) {
        expect(
          isWorkflowToolRow({
            'display': {'kind': kind},
          }),
          isTrue,
        );
      }
      for (final name in const [
        'CreateWorkflow',
        'create_workflow',
        'ResumeWorkflowRun',
        'resume-workflow-run',
        'GetWorkflowRun',
        'get_workflow_run',
        'ListWorkflowRuns',
        'list workflow runs',
      ]) {
        expect(isWorkflowToolRow({'toolName': name}), isTrue, reason: name);
      }
      expect(isWorkflowToolRow({'toolName': 'Read'}), isFalse);
      // A non-workflow display never promotes a non-workflow tool name.
      expect(
        isWorkflowToolRow({
          'toolName': 'NodeRepl',
          'display': {'kind': 'node_repl_images'},
        }),
        isFalse,
      );
    });

    test('card gate needs a workflow display or a mirror run', () {
      final row = _toolRow(toolCallId: 'call-gate');
      expect(isWorkflowToolRow(row), isTrue);
      expect(hasWorkflowCard(ConversationState(), row), isFalse);

      final withRun = ConversationState()
        ..workflowRuns = WorkflowRuns(
          runs: [workflowRunFixture()..['toolCallId'] = 'call-gate'],
        );
      expect(hasWorkflowCard(withRun, row), isTrue);

      final displayOnly = _toolRow(display: workflowCreateDisplayFixture());
      expect(hasWorkflowCard(ConversationState(), displayOnly), isTrue);
    });
  });

  group('WorkflowToolCard widget', () {
    testWidgets('create success card shows status/name/progress and opens', (
      tester,
    ) async {
      final run = workflowRunFixture(status: 'running');
      final row = _toolRow(
        toolCallId: '${run['toolCallId']}',
        input: const {'name': '日计 UI 改造'},
        display: workflowCreateDisplayFixture(),
      );
      final state = _stateWith(rows: [row], runs: [run]);
      final opened = <String>[];
      Map<String, dynamic>? openedDisplay;
      String? openedTitle;

      await tester.pumpWidget(
        wrap(
          WorkflowToolCard(
            row: row,
            state: state,
            openWorkflowRun:
                (context, {
                  required runId,
                  display,
                  title,
                  workStartedAt,
                  workEndedAt,
                }) {
                  opened.add(runId);
                  openedDisplay = display;
                  openedTitle = title;
                },
          ),
        ),
      );

      expect(find.text(zh('chat.workflowCard.running')), findsOneWidget);
      expect(find.text('日计 UI 改造'), findsOneWidget);
      expect(
        find.textContaining(zh('chat.workflowCard.steps', ['2', '6'])),
        findsOneWidget,
      );
      expect(
        find.textContaining(zh('chat.workflowCard.agentsWorking', ['1'])),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      // The drill-in keeps the zTouch hit box and carries a spoken label.
      expect(
        find.byTooltip(zh('chat.workflowCard.openDetails')),
        findsOneWidget,
      );
      final chevron = find.ancestor(
        of: find.byIcon(Icons.chevron_right),
        matching: find.byType(IconButton),
      );
      expect(chevron, findsOneWidget);
      final chevronSize = tester.getSize(chevron);
      expect(chevronSize.width, greaterThanOrEqualTo(zTouchWidth));
      expect(chevronSize.height, greaterThanOrEqualTo(zTouchHeight));

      await tester.tap(find.byIcon(Icons.chevron_right));
      expect(opened, ['${run['runId']}']);
      expect(openedTitle, '日计 UI 改造');
      // The create display is not a run snapshot — nothing to hand over.
      expect(openedDisplay, isNull);

      await tester.tap(find.text(zh('chat.workflowCard.running')));
      await tester.pump();
      expect(find.text('勘察现有界面'), findsOneWidget);
      expect(find.text('落地品牌'), findsOneWidget);
      expect(
        find.textContaining(zh('chat.workflowDetail.phaseState.done')),
        findsOneWidget,
      );
    });

    testWidgets('create failure shows notStarted/errorCount and no chevron', (
      tester,
    ) async {
      final row = _toolRow(
        toolCallId: 'call-bad-create',
        input: const {'name': '坏工作流'},
        display: workflowCreateDisplayFixture(ok: false),
      );
      final state = _stateWith(rows: [row]);

      await tester.pumpWidget(
        wrap(WorkflowToolCard(row: row, state: state)),
      );

      expect(find.text(zh('chat.workflowCard.notStarted')), findsOneWidget);
      expect(
        find.textContaining(zh('chat.workflowCard.errorCount', ['1'])),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.chevron_right), findsNothing);

      await tester.tap(find.text(zh('chat.workflowCard.notStarted')));
      await tester.pump();
      expect(find.textContaining('artifact "x"'), findsOneWidget);
    });

    testWidgets('resume card resolves the mirror through display.runId', (
      tester,
    ) async {
      final run = workflowRunFixture()..remove('toolCallId');
      final row = _toolRow(
        toolCallId: 'call-resume',
        toolName: 'ResumeWorkflowRun',
        input: const {'name': '恢复运行'},
        display: workflowResumeDisplayFixture(),
      );
      final state = _stateWith(rows: [row], runs: [run]);
      final opened = <String>[];

      await tester.pumpWidget(
        wrap(
          WorkflowToolCard(
            row: row,
            state: state,
            openWorkflowRun:
                (context, {
                  required runId,
                  display,
                  title,
                  workStartedAt,
                  workEndedAt,
                }) {
                  opened.add(runId);
                },
          ),
        ),
      );

      expect(find.text(zh('chat.workflowCard.running')), findsOneWidget);
      expect(find.text('恢复运行'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.chevron_right));
      expect(opened, ['${run['runId']}']);
    });

    testWidgets('get card renders display-only logs/phases/result', (
      tester,
    ) async {
      final display = workflowGetRunDisplayFixture();
      final row = _toolRow(
        toolCallId: 'call-get',
        toolName: 'GetWorkflowRun',
        display: display,
      );
      final state = _stateWith(rows: [row]);
      final opened = <String>[];
      Map<String, dynamic>? openedDisplay;

      await tester.pumpWidget(
        wrap(
          WorkflowToolCard(
            row: row,
            state: state,
            openWorkflowRun:
                (context, {
                  required runId,
                  display,
                  title,
                  workStartedAt,
                  workEndedAt,
                }) {
                  opened.add(runId);
                  openedDisplay = display;
                },
          ),
        ),
      );

      expect(find.text(zh('chat.workflowCard.completed')), findsOneWidget);
      expect(find.text('日计 UI 改造'), findsOneWidget);
      // The snapshot marker (with its real relative age) heads the card.
      final context = tester.element(find.byType(WorkflowToolCard));
      expect(
        find.text(
          '${zh('chat.workflowCard.snapshot')} · '
          '${zh('chat.workflowDetail.snapshotAge', [
            relativeTime(context, display['generatedAt'] as int),
          ])}',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(zh('chat.workflowCard.nodesObserved', ['55'])),
        findsOneWidget,
      );

      await tester.tap(find.text(zh('chat.workflowCard.completed')));
      await tester.pump();
      expect(find.text('勘察现有界面'), findsOneWidget);
      expect(find.text('设计架构师'), findsOneWidget);
      expect(find.textContaining('node-settled ask#2'), findsOneWidget);
      expect(find.textContaining('日计 UI 改造已落地'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_right));
      expect(opened, ['${display['runId']}']);
      expect(openedDisplay, isNotNull);
    });

    testWidgets('list card opens mirrored runs and toasts evicted ones', (
      tester,
    ) async {
      final mirrorRun = <String, dynamic>{
        'runId': 'dwfrun-e9dd9750',
        'status': 'completed',
        'usage': const {'spentTokens': 1844264},
        'actors': const [],
        'nodes': const [],
        'phases': const [],
        'phaseNames': const [],
      };
      final row = _toolRow(
        toolCallId: 'call-list',
        toolName: 'ListWorkflowRuns',
        display: workflowListDisplayFixture(),
      );
      final state = _stateWith(rows: [row], runs: [mirrorRun]);
      final opened = <String>[];
      String? openedTitle;

      await tester.pumpWidget(
        wrap(
          WorkflowToolCard(
            row: row,
            state: state,
            openWorkflowRun:
                (context, {
                  required runId,
                  display,
                  title,
                  workStartedAt,
                  workEndedAt,
                }) {
                  opened.add(runId);
                  openedTitle = title;
                },
          ),
        ),
      );

      expect(find.text(zh('chat.workflowCard.listTitle')), findsOneWidget);
      await tester.tap(find.text(zh('chat.workflowCard.listTitle')));
      await tester.pump();
      expect(find.text('批次 A · 支付渠道铺开'), findsOneWidget);
      expect(find.text('日计 UI 改造'), findsOneWidget);

      await tester.tap(find.text('批次 A · 支付渠道铺开'));
      await tester.pump();
      expect(opened, ['dwfrun-e9dd9750']);
      expect(openedTitle, '批次 A · 支付渠道铺开');

      await tester.tap(find.text('日计 UI 改造'));
      await tester.pump();
      expect(find.text(zh('chat.workflowCard.runNotInSession')), findsOneWidget);
      expect(opened, ['dwfrun-e9dd9750']);
    });

    testWidgets('workflow-named row without display or mirror keeps bare tile', (
      tester,
    ) async {
      final row = _toolRow(toolName: 'CreateWorkflow');
      final state = _stateWith(rows: [row]);
      expect(isWorkflowToolRow(row), isTrue);
      expect(hasWorkflowCard(state, row), isFalse);

      final recording = RecordingCalls();
      await tester.pumpWidget(
        wrap(
          ChatRow(
            row: row,
            conversation: FakeConversation(recording),
            sessionId: 's1',
            onAction: (_, __) async {},
            state: state,
            preview: ChatPreview(FakeWorkspaceContext(recording)),
          ),
        ),
      );

      expect(find.byType(WorkflowToolCard), findsNothing);
      expect(find.text('CreateWorkflow'), findsOneWidget);
    });

    testWidgets('missing openWorkflowRun hides the chevron, expansion stays', (
      tester,
    ) async {
      final run = workflowRunFixture(status: 'completed');
      final row = _toolRow(
        toolCallId: '${run['toolCallId']}',
        input: const {'name': '无入口运行'},
        display: workflowCreateDisplayFixture(),
      );
      final state = _stateWith(rows: [row], runs: [run]);

      await tester.pumpWidget(
        wrap(WorkflowToolCard(row: row, state: state)),
      );

      expect(find.text(zh('chat.workflowCard.completed')), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);

      await tester.tap(find.text(zh('chat.workflowCard.completed')));
      await tester.pump();
      expect(find.text('勘察现有界面'), findsOneWidget);
    });

    testWidgets('readOnly rows never get the parent workflow drill-in', (
      tester,
    ) async {
      // The inline child transcript renders the parent page's actions with
      // readOnly: true — the workflow card must not inherit the drill-in.
      final run = workflowRunFixture(status: 'running');
      final row = _toolRow(
        toolCallId: '${run['toolCallId']}',
        input: const {'name': '内联运行'},
        display: workflowCreateDisplayFixture(),
      );
      final state = _stateWith(rows: [row], runs: [run]);
      var opened = 0;
      final recording = RecordingCalls();

      await tester.pumpWidget(
        wrap(
          ChatRow(
            row: row,
            conversation: FakeConversation(recording),
            sessionId: 's1',
            onAction: (_, __) async {},
            state: state,
            preview: ChatPreview(FakeWorkspaceContext(recording)),
            actions: ChatPageActions(
              openWorkflowRun:
                  (context, {
                    required runId,
                    display,
                    title,
                    workStartedAt,
                    workEndedAt,
                  }) {
                    opened++;
                  },
            ),
            readOnly: true,
          ),
        ),
      );

      expect(find.text(zh('chat.workflowCard.running')), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);

      // Local expansion stays available without the drill-in.
      await tester.tap(find.text(zh('chat.workflowCard.running')));
      await tester.pump();
      expect(find.text('勘察现有界面'), findsOneWidget);
      expect(opened, 0);
    });
  });
}

ConversationState _stateWith({
  List<Map<String, dynamic>> rows = const [],
  List<Map<String, dynamic>> runs = const [],
}) {
  return ConversationState()
    ..rows = rows
    ..workflowRuns = WorkflowRuns(runs: runs);
}
