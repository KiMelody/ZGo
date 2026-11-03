// Shared workflow wire fixtures (protocol + UI tests).
//
// Shapes follow the desktop renderer schemas recorded in
// `.trellis/tasks/11-03-workflow-run-readonly/research.md`; values mirror a
// real run captured from the local ZCode database. Keep these as raw wire
// maps — tests exercise the defensive projections, not a domain model.

Map<String, dynamic> workflowRunFixture({
  String status = 'running',
  String? stopReason,
}) => {
  'runId': 'dwfrun-714b4217-a5d7-4f02-89b2-b5eed096edf1',
  'toolCallId': 'call_6314e8f0988a403ba9f39e53',
  'status': status,
  if (stopReason != null) 'stopReason': stopReason,
  'usage': {
    'spentTokens': 38994588,
    'nodesUsed': 6,
    'nodesUnlisted': 2,
    'nodesUnlistedSettled': 1,
  },
  'actors': [
    {
      'siteId': 'actor#1',
      'ordinal': 1,
      'name': '设计架构师',
      'sessionId': 'sess_dwf-dwfrun-714b-actor_1_1',
      'status': 'completed',
      'phaseName': '勘察现有界面',
      'model': 'provider/model-x',
    },
    {
      'siteId': 'actor#2',
      'ordinal': 1,
      'name': '品牌与主题',
      'sessionId': 'sess_dwf-dwfrun-714b-actor_2_1',
      'status': 'running',
      'phaseName': '落地品牌',
      'model': 'provider/model-x',
    },
  ],
  'nodes': [
    {
      'siteId': 'ask#1',
      'ordinal': 1,
      'kind': 'ask',
      'phase': 'settled',
      'outcome': 'ok',
      'actorSiteId': 'actor#1',
      'actorOrdinal': 1,
      'phaseName': '勘察现有界面',
      'instructionsHead': '盘点现有页面',
      'turn': 2,
      'toolCalls': 5,
      'lastTool': {'name': 'Read', 'target': 'MainActivity.kt'},
    },
    {
      'siteId': 'ask#2',
      'ordinal': 1,
      'kind': 'ask',
      'phase': 'executing',
      'actorSiteId': 'actor#2',
      'actorOrdinal': 1,
      'phaseName': '落地品牌',
      'instructionsHead': '改主题',
      'turn': 1,
      'toolCalls': 2,
      'lastTool': {'name': 'Edit', 'target': 'Color.kt'},
    },
    {
      'siteId': 'world-read#1',
      'ordinal': 1,
      'kind': 'world-read',
      'phase': 'queued',
      'phaseName': '落地品牌',
      'cached': true,
    },
    {
      'siteId': 'ask#3',
      'ordinal': 2,
      'kind': 'ask',
      'phase': 'waiting',
      'actorSiteId': 'actor#2',
      'actorOrdinal': 1,
      'phaseName': '落地品牌',
      'instructionsHead': '等待回答',
      'turn': 1,
    },
  ],
  'phases': [
    {'name': '勘察现有界面', 'rounds': 1},
    {'name': '落地品牌', 'rounds': 2},
  ],
  'phaseNames': ['勘察现有界面', '落地品牌'],
  'currentPhase': '落地品牌',
  'pendingQuestions': [
    {
      'qid': 'q1',
      'actorSiteId': 'actor#2',
      'actorOrdinal': 1,
      'actorName': '品牌与主题',
      'question': '主色使用哪一版？',
      'context': '设计稿有两个方案',
      'askedAt': 1793699000000,
    },
  ],
  'artifacts': [
    {
      'id': 'progress',
      'kind': 'board',
      'title': '改造进度',
      'version': 2,
      'itemCount': 8,
      'primary': true,
    },
  ],
  'reports': [
    {
      'siteId': 'report#1',
      'ordinal': 1,
      'preview': '设计规格：…',
      'artifactId': 'progress',
    },
  ],
  'concurrency': {'cap': 14, 'ceiling': 14, 'limit': 14},
  'subagentModel': 'provider/model-x',
  'unlistedByPhase': [
    {'phaseName': '落地品牌', 'actors': 1, 'actorsSettled': 1, 'settled': 1},
  ],
  'lastEventSequence': 42,
};

Map<String, dynamic> workflowGetRunDisplayFixture({
  bool withError = false,
  bool withLogs = true,
}) => {
  'kind': 'get_workflow_run',
  'runId': 'dwfrun-714b4217-a5d7-4f02-89b2-b5eed096edf1',
  'label': '日计 UI 改造',
  'status': withError ? 'errored' : 'completed',
  'summary': 'Completed in 2h 16m, across 8 phases. 55 steps settled.',
  'generatedAt': 1793703745582,
  'usage': {
    'spentTokens': 75674618,
    'nodesObserved': 55,
    'nodesRunning': withError ? 2 : 0,
    'nodesCompleted': withError ? 50 : 55,
    'nodesFailed': withError ? 3 : 0,
  },
  'phases': [
    {
      'name': '勘察现有界面',
      'state': 'done',
      'rounds': 1,
      'nodesSettled': 1,
      'nodesRunning': 0,
      'enteredAt': 1793695512511,
      'exitedAt': 1793696310502,
    },
    {
      'name': '落地品牌',
      'state': withError ? 'unfinished' : 'done',
      'rounds': 2,
      'nodesSettled': 3,
      'nodesRunning': withError ? 2 : 0,
      'enteredAt': 1793696310502,
      'exitedAt': withError ? null : 1793697630751,
    },
  ],
  'subagents': [
    {
      'siteId': 'actor#1',
      'ordinal': 1,
      'name': '设计架构师',
      'state': 'done',
      'phaseName': '勘察现有界面',
      'stepsSettled': 1,
      'stepsFailed': 0,
      'tokens': 1421809,
      'lastProgressAt': 1793696310451,
    },
    {
      'siteId': 'actor#2',
      'ordinal': 1,
      'name': '品牌与主题',
      'state': withError ? 'failed' : 'done',
      'phaseName': '落地品牌',
      'instructionsHead': '改主题',
      'startedAt': 1793696310600,
      'turn': 3,
      'toolCalls': 12,
      'lastTool': {'name': 'Edit', 'target': 'Color.kt', 'at': 1793697630000},
      'waitCause': withError ? null : 'backoff',
      'retryAfterMs': withError ? null : 5000,
      'stepsSettled': 3,
      'stepsFailed': withError ? 1 : 0,
      'tokens': 998877,
      'lastProgressAt': 1793697630000,
    },
  ],
  'health': {
    'lastProgressAt': 1793703708202,
    'consecutiveFailures': withError ? 3 : 0,
    'cachedSteps': 1,
    'pendingQuestionsKnown': true,
  },
  'actors': [
    {'siteId': 'actor#1', 'ordinal': 1, 'name': '设计架构师'},
    {'siteId': 'actor#2', 'ordinal': 1, 'name': '品牌与主题'},
  ],
  'logTail': withLogs
      ? [
          {
            'sequence': 41,
            'message': 'node-settled ask#2',
            'at': 1793703700000,
          },
          {
            'sequence': 42,
            'message': 'report published: progress',
            'at': 1793703708202,
          },
        ]
      : <Object?>[],
  'result': '{"conclusion":"日计 UI 改造已落地","findings":[]}',
  if (withError)
    'error': {'code': 'provider_error', 'message': 'model request failed'},
  'truncated': true,
};

Map<String, dynamic> workflowListDisplayFixture() => {
  'kind': 'list_workflow_runs',
  'runs': [
    {
      'runId': 'dwfrun-e9dd9750',
      'label': '批次 A · 支付渠道铺开',
      'labelSource': 'name',
      'status': 'completed',
      'ownedByThisSession': true,
      'createdAt': 1793587863699,
      'updatedAt': 1793588801708,
      'spentTokens': 1844264,
    },
    {
      'runId': 'dwfrun-714b4217',
      'label': '日计 UI 改造',
      'labelSource': 'script',
      'status': 'running',
      'ownedByThisSession': false,
      'possiblyInterrupted': true,
      'createdAt': 1793695512371,
      'updatedAt': 1793699974238,
      'spentTokens': 38994588,
    },
  ],
  'truncated': false,
};

Map<String, dynamic> workflowCreateDisplayFixture({bool ok = true}) => {
  'kind': 'create_workflow',
  'ok': ok,
  'errorCount': ok ? 0 : 1,
  'diagnostics': ok
      ? <Object?>[]
      : [
          {
            'line': 262,
            'column': 9,
            'code': 9009,
            'message': 'artifact "x" is marked primary, but "y" already is.',
          },
        ],
};

Map<String, dynamic> workflowResumeDisplayFixture() => {
  'kind': 'resume_workflow_run',
  'runId': 'dwfrun-714b4217-a5d7-4f02-89b2-b5eed096edf1',
};
