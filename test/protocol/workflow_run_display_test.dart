// Projection tests for the desktop's workflow tool `display` payloads.
// Shapes come from the renderer schemas recorded in
// `.trellis/tasks/11-03-workflow-run-readonly/research.md`; every parser is
// defensive, so malformed members read as empty/null instead of throwing.
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/workflow_run_display.dart';

import 'workflow_fixtures.dart';

void main() {
  group('WorkflowRunDisplay (get_workflow_run)', () {
    test('parses the complete fixture', () {
      final display = WorkflowRunDisplay.tryParse(
        workflowGetRunDisplayFixture(),
      )!;

      expect(display.runId, 'dwfrun-714b4217-a5d7-4f02-89b2-b5eed096edf1');
      expect(display.label, '日计 UI 改造');
      expect(display.status, 'completed');
      expect(display.stopReason, isNull);
      expect(display.possiblyInterrupted, isFalse);
      expect(display.summary, startsWith('Completed in 2h 16m'));
      expect(display.generatedAt, 1793703745582);
      expect(display.result, startsWith('{"conclusion"'));
      expect(display.error, isNull);
      expect(display.truncated, isTrue);

      expect(display.usage?.spentTokens, 75674618);
      expect(display.usage?.nodesObserved, 55);
      expect(display.usage?.nodesRunning, 0);
      expect(display.usage?.nodesCompleted, 55);
      expect(display.usage?.nodesFailed, 0);

      expect(display.phases, hasLength(2));
      final firstPhase = display.phases.first;
      expect(firstPhase.name, '勘察现有界面');
      expect(firstPhase.state, 'done');
      expect(firstPhase.rounds, 1);
      expect(firstPhase.nodesSettled, 1);
      expect(firstPhase.nodesRunning, 0);
      expect(firstPhase.enteredAt, 1793695512511);
      expect(firstPhase.exitedAt, 1793696310502);

      expect(display.subagents, hasLength(2));
      final subagent = display.subagents.last;
      expect(subagent.siteId, 'actor#2');
      expect(subagent.ordinal, 1);
      expect(subagent.name, '品牌与主题');
      expect(subagent.state, 'done');
      expect(subagent.phaseName, '落地品牌');
      expect(subagent.instructionsHead, '改主题');
      expect(subagent.startedAt, 1793696310600);
      expect(subagent.turn, 3);
      expect(subagent.toolCalls, 12);
      expect(subagent.lastTool?.name, 'Edit');
      expect(subagent.lastTool?.target, 'Color.kt');
      expect(subagent.lastTool?.at, 1793697630000);
      expect(subagent.waitCause, 'backoff');
      expect(subagent.retryAfterMs, 5000);
      expect(subagent.waitSince, isNull);
      expect(subagent.parkedOn, isNull);
      expect(subagent.stepsSettled, 3);
      expect(subagent.stepsFailed, 0);
      expect(subagent.tokens, 998877);
      expect(subagent.lastProgressAt, 1793697630000);
      expect(subagent.key, 'actor#2\u00001');

      expect(display.health?.lastProgressAt, 1793703708202);
      expect(display.health?.stalledSince, isNull);
      expect(display.health?.concurrency, isNull);
      expect(display.health?.consecutiveFailures, 0);
      expect(display.health?.cachedSteps, 1);
      expect(display.health?.leftoverRunning, isNull);
      expect(display.health?.pendingQuestionsKnown, isTrue);

      expect(display.actors, hasLength(2));
      expect(display.actors.first.siteId, 'actor#1');
      expect(display.actors.first.ordinal, 1);
      expect(display.actors.first.name, '设计架构师');

      expect(display.logTail, hasLength(2));
      expect(display.logTail.first.sequence, 41);
      expect(display.logTail.first.message, 'node-settled ask#2');
      expect(display.logTail.first.at, 1793703700000);
      expect(display.logTail.last.sequence, 42);
    });

    test('parses the errored fixture (error + running counters)', () {
      final display = WorkflowRunDisplay.tryParse(
        workflowGetRunDisplayFixture(withError: true),
      )!;

      expect(display.status, 'errored');
      expect(display.usage?.nodesRunning, 2);
      expect(display.usage?.nodesCompleted, 50);
      expect(display.usage?.nodesFailed, 3);
      expect(display.error?.code, 'provider_error');
      expect(display.error?.message, 'model request failed');
      expect(display.phases.last.state, 'unfinished');
      expect(display.phases.last.exitedAt, isNull);
      expect(display.subagents.last.state, 'failed');
      expect(display.health?.consecutiveFailures, 3);
    });

    test('empty logTail parses to an empty list', () {
      final display = WorkflowRunDisplay.tryParse(
        workflowGetRunDisplayFixture(withLogs: false),
      )!;
      expect(display.logTail, isEmpty);
    });

    test('wrong kind, missing runId and null all read as null', () {
      expect(WorkflowRunDisplay.tryParse(workflowListDisplayFixture()), isNull);
      expect(WorkflowRunDisplay.tryParse(workflowResumeDisplayFixture()), isNull);
      expect(WorkflowRunDisplay.tryParse(null), isNull);
      expect(WorkflowRunDisplay.tryParse('not-a-map'), isNull);
      expect(WorkflowRunDisplay.tryParse(<String, Object?>{}), isNull);
      expect(
        WorkflowRunDisplay.tryParse({
          'kind': 'get_workflow_run',
          'runId': '',
          'label': 'x',
          'status': 'running',
        }),
        isNull,
      );
      expect(
        WorkflowRunDisplay.tryParse({'kind': 'get_workflow_run', 'label': 'x'}),
        isNull,
      );
    });

    test('malformed members read as empty/null instead of throwing', () {
      final display = WorkflowRunDisplay.tryParse({
        'kind': 'get_workflow_run',
        'runId': 'r1',
        'label': 'run',
        'status': 'running',
        'summary': '   ',
        'generatedAt': 'yesterday',
        'usage': 'nope',
        'phases': 'nope',
        'subagents': [1, 'x', null],
        'health': 'nope',
        'actors': {'siteId': 'a'},
        'logTail': 42,
        'result': '   ',
        'error': 'not-a-map',
        'truncated': 'yes',
      })!;

      expect(display.summary, isNull);
      expect(display.generatedAt, isNull);
      expect(display.usage, isNull);
      expect(display.phases, isEmpty);
      expect(display.subagents, isEmpty);
      expect(display.health, isNull);
      expect(display.actors, isEmpty);
      expect(display.logTail, isEmpty);
      expect(display.result, isNull);
      expect(display.error, isNull);
      expect(display.truncated, isFalse);
    });

    test('malformed health members read as empty/null', () {
      final display = WorkflowRunDisplay.tryParse({
        'kind': 'get_workflow_run',
        'runId': 'r1',
        'label': 'run',
        'status': 'running',
        'health': {
          'lastProgressAt': 'later',
          'stalledSince': null,
          'concurrency': 'nope',
          'consecutiveFailures': 'many',
          'cachedSteps': 3.9,
          'leftoverRunning': 'one',
          'pendingQuestionsKnown': 'yes',
        },
      })!;

      final health = display.health!;
      expect(health.lastProgressAt, isNull);
      expect(health.stalledSince, isNull);
      expect(health.concurrency, isNull);
      expect(health.consecutiveFailures, 0);
      expect(health.cachedSteps, 3);
      expect(health.leftoverRunning, isNull);
      expect(health.pendingQuestionsKnown, isFalse);
    });

    test('malformed phase and subagent fields read as empty/0', () {
      final display = WorkflowRunDisplay.tryParse({
        'kind': 'get_workflow_run',
        'runId': 'r1',
        'label': 'run',
        'status': 'running',
        'usage': {'spentTokens': 12.9, 'nodesObserved': '55'},
        'phases': [
          {'name': 'phase-a', 'rounds': '2'},
        ],
        'subagents': [
          {
            'siteId': 'actor#1',
            'ordinal': '1',
            'state': null,
            'lastTool': 'nope',
            'stepsSettled': '3',
          },
        ],
        'logTail': [
          {'sequence': '4', 'message': '  ', 'at': 'later'},
        ],
      })!;

      expect(display.usage?.spentTokens, 12);
      expect(display.usage?.nodesObserved, 0);
      expect(display.phases.single.name, 'phase-a');
      expect(display.phases.single.rounds, 0);
      final subagent = display.subagents.single;
      expect(subagent.siteId, 'actor#1');
      expect(subagent.ordinal, 0);
      expect(subagent.state, '');
      expect(subagent.lastTool, isNull);
      expect(subagent.stepsSettled, 0);
      expect(display.logTail.single.sequence, 0);
      expect(display.logTail.single.message, '');
      expect(display.logTail.single.at, isNull);
    });
  });

  group('WorkflowRunListDisplay (list_workflow_runs)', () {
    test('parses runs, flags and truncation', () {
      final display = WorkflowRunListDisplay.tryParse(
        workflowListDisplayFixture(),
      )!;
      expect(display.truncated, isFalse);
      expect(display.runs, hasLength(2));

      final first = display.runs.first;
      expect(first.runId, 'dwfrun-e9dd9750');
      expect(first.label, '批次 A · 支付渠道铺开');
      expect(first.labelSource, 'name');
      expect(first.status, 'completed');
      expect(first.stopReason, isNull);
      expect(first.ownedByThisSession, isTrue);
      expect(first.possiblyInterrupted, isFalse);
      expect(first.createdAt, 1793587863699);
      expect(first.updatedAt, 1793588801708);
      expect(first.spentTokens, 1844264);

      final second = display.runs.last;
      expect(second.labelSource, 'script');
      expect(second.status, 'running');
      expect(second.ownedByThisSession, isFalse);
      expect(second.possiblyInterrupted, isTrue);
    });

    test('missing members fall back to empty/false/0', () {
      final display = WorkflowRunListDisplay.tryParse({
        'kind': 'list_workflow_runs',
        'runs': [
          {'runId': 'r1'},
        ],
      })!;
      final run = display.runs.single;
      expect(run.label, '');
      expect(run.labelSource, '');
      expect(run.status, '');
      expect(run.stopReason, isNull);
      expect(run.ownedByThisSession, isFalse);
      expect(run.possiblyInterrupted, isFalse);
      expect(run.createdAt, 0);
      expect(run.updatedAt, 0);
      expect(run.spentTokens, 0);
      expect(display.truncated, isFalse);
    });

    test('malformed runs / truncated read as empty/false', () {
      final badRuns = WorkflowRunListDisplay.tryParse({
        'kind': 'list_workflow_runs',
        'runs': 'nope',
        'truncated': 'yes',
      })!;
      expect(badRuns.runs, isEmpty);
      expect(badRuns.truncated, isFalse);

      final mixed = WorkflowRunListDisplay.tryParse({
        'kind': 'list_workflow_runs',
        'runs': [
          1,
          {'runId': 'r2'},
        ],
        'truncated': true,
      })!;
      expect(mixed.runs, hasLength(1));
      expect(mixed.runs.single.runId, 'r2');
      expect(mixed.truncated, isTrue);
    });

    test('wrong kind or null reads as null', () {
      expect(
        WorkflowRunListDisplay.tryParse(workflowGetRunDisplayFixture()),
        isNull,
      );
      expect(
        WorkflowRunListDisplay.tryParse(workflowCreateDisplayFixture()),
        isNull,
      );
      expect(WorkflowRunListDisplay.tryParse(null), isNull);
    });
  });

  group('WorkflowCreateDisplay (create_workflow)', () {
    test('parses the ok fixture (no diagnostics)', () {
      final display = WorkflowCreateDisplay.tryParse(
        workflowCreateDisplayFixture(),
      )!;
      expect(display.ok, isTrue);
      expect(display.errorCount, 0);
      expect(display.diagnostics, isEmpty);
      expect(display.fill, isNull);
      expect(display.truncated, isFalse);
    });

    test('parses the failed fixture (diagnostics)', () {
      final display = WorkflowCreateDisplay.tryParse(
        workflowCreateDisplayFixture(ok: false),
      )!;
      expect(display.ok, isFalse);
      expect(display.errorCount, 1);
      final diagnostic = display.diagnostics.single;
      expect(diagnostic.line, 262);
      expect(diagnostic.column, 9);
      expect(diagnostic.code, 9009);
      expect(diagnostic.message, startsWith('artifact "x"'));
    });

    test('parses fill and truncation', () {
      final display = WorkflowCreateDisplay.tryParse({
        'kind': 'create_workflow',
        'ok': true,
        'errorCount': 0,
        'diagnostics': <Object?>[],
        'fill': {
          'siteId': 'fill#1',
          'name': '支付渠道铺开',
          'draftPath': '/workflows/draft.md',
          'line': 12,
        },
        'truncated': true,
      })!;
      expect(display.fill?.siteId, 'fill#1');
      expect(display.fill?.name, '支付渠道铺开');
      expect(display.fill?.draftPath, '/workflows/draft.md');
      expect(display.fill?.line, 12);
      expect(display.truncated, isTrue);
    });

    test('malformed members read as empty/null', () {
      final display = WorkflowCreateDisplay.tryParse({
        'kind': 'create_workflow',
        'ok': 'yes',
        'errorCount': 'two',
        'diagnostics': 'nope',
        'fill': 'nope',
      })!;
      expect(display.ok, isFalse);
      expect(display.errorCount, 0);
      expect(display.diagnostics, isEmpty);
      expect(display.fill, isNull);
      expect(display.truncated, isFalse);
    });

    test('wrong kind or null reads as null', () {
      expect(
        WorkflowCreateDisplay.tryParse(workflowGetRunDisplayFixture()),
        isNull,
      );
      expect(
        WorkflowCreateDisplay.tryParse(workflowListDisplayFixture()),
        isNull,
      );
      expect(WorkflowCreateDisplay.tryParse(null), isNull);
    });
  });

  group('WorkflowResumeDisplay (resume_workflow_run)', () {
    test('parses runId', () {
      final display = WorkflowResumeDisplay.tryParse(
        workflowResumeDisplayFixture(),
      )!;
      expect(display.runId, 'dwfrun-714b4217-a5d7-4f02-89b2-b5eed096edf1');
    });

    test('missing runId reads as null', () {
      expect(
        WorkflowResumeDisplay.tryParse({'kind': 'resume_workflow_run'}),
        isNull,
      );
      expect(
        WorkflowResumeDisplay.tryParse({
          'kind': 'resume_workflow_run',
          'runId': '   ',
        }),
        isNull,
      );
    });

    test('wrong kind or null reads as null', () {
      expect(
        WorkflowResumeDisplay.tryParse(workflowGetRunDisplayFixture()),
        isNull,
      );
      expect(WorkflowResumeDisplay.tryParse(null), isNull);
    });
  });
}
