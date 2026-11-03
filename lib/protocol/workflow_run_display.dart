// Typed read views over the `display` payloads the desktop attaches to
// workflow tool rows (`create_workflow` / `resume_workflow_run` /
// `get_workflow_run` / `list_workflow_runs`). Pure Dart, no Flutter imports:
// these are wire-schema projections, not UI models.
//
// Schemas (renderer): get_workflow_run @311611423, list_workflow_runs
// @311611423, create_workflow @311594067, resume_workflow_run @311611423.
// Everything is defensive: a malformed member reads as empty instead of
// throwing (tool displays are optional and version-drifty).

Map<String, dynamic>? _asMap(Object? value) {
  if (value is Map) return value.cast<String, dynamic>();
  return null;
}

List<Map<String, dynamic>> _maps(Object? value) {
  if (value is! List) return const [];
  return [
    for (final v in value)
      if (v is Map) v.cast<String, dynamic>(),
  ];
}

String? _asString(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

int _asInt(Object? value) => value is num ? value.toInt() : 0;

int? _asIntOrNull(Object? value) => value is num ? value.toInt() : null;

/// `get_workflow_run` payload: a complete run snapshot (the agent asked the
/// desktop for the run's current state).
class WorkflowRunDisplay {
  final Map<String, dynamic> raw;

  WorkflowRunDisplay._(this.raw);

  static WorkflowRunDisplay? tryParse(Object? value) {
    final map = _asMap(value);
    if (map == null || map['kind'] != 'get_workflow_run') return null;
    if (_asString(map['runId']) == null) return null;
    return WorkflowRunDisplay._(map);
  }

  String get runId => _asString(raw['runId']) ?? '';
  String get label => _asString(raw['label']) ?? '';
  String get status => _asString(raw['status']) ?? '';
  String? get stopReason => _asString(raw['stopReason']);
  bool get possiblyInterrupted => raw['possiblyInterrupted'] == true;
  String? get summary => _asString(raw['summary']);
  int? get generatedAt => _asIntOrNull(raw['generatedAt']);

  WorkflowDisplayUsage? get usage {
    final value = _asMap(raw['usage']);
    return value == null ? null : WorkflowDisplayUsage(value);
  }

  List<WorkflowDisplayPhase> get phases => [
    for (final p in _maps(raw['phases'])) WorkflowDisplayPhase(p),
  ];

  List<WorkflowDisplaySubagent> get subagents => [
    for (final s in _maps(raw['subagents'])) WorkflowDisplaySubagent(s),
  ];

  WorkflowDisplayHealth? get health {
    final value = _asMap(raw['health']);
    return value == null ? null : WorkflowDisplayHealth(value);
  }

  List<WorkflowDisplayActor> get actors => [
    for (final a in _maps(raw['actors'])) WorkflowDisplayActor(a),
  ];

  List<WorkflowDisplayLog> get logTail => [
    for (final l in _maps(raw['logTail'])) WorkflowDisplayLog(l),
  ];

  String? get result => _asString(raw['result']);

  WorkflowDisplayError? get error {
    final value = _asMap(raw['error']);
    return value == null ? null : WorkflowDisplayError(value);
  }

  bool get truncated => raw['truncated'] == true;
}

class WorkflowDisplayUsage {
  final Map<String, dynamic> raw;

  WorkflowDisplayUsage(this.raw);

  int get spentTokens => _asInt(raw['spentTokens']);
  int get nodesObserved => _asInt(raw['nodesObserved']);
  int get nodesRunning => _asInt(raw['nodesRunning']);
  int get nodesCompleted => _asInt(raw['nodesCompleted']);
  int get nodesFailed => _asInt(raw['nodesFailed']);
}

class WorkflowDisplayPhase {
  final Map<String, dynamic> raw;

  WorkflowDisplayPhase(this.raw);

  String get name => _asString(raw['name']) ?? '';
  String get state => _asString(raw['state']) ?? '';
  int get rounds => _asInt(raw['rounds']);
  int get nodesSettled => _asInt(raw['nodesSettled']);
  int get nodesRunning => _asInt(raw['nodesRunning']);
  int? get enteredAt => _asIntOrNull(raw['enteredAt']);
  int? get exitedAt => _asIntOrNull(raw['exitedAt']);
}

class WorkflowDisplaySubagent {
  final Map<String, dynamic> raw;

  WorkflowDisplaySubagent(this.raw);

  String get siteId => '${raw['siteId'] ?? ''}';
  int get ordinal => _asInt(raw['ordinal']);
  String? get name => _asString(raw['name']);
  String get state => _asString(raw['state']) ?? '';
  String? get phaseName => _asString(raw['phaseName']);
  String? get instructionsHead => _asString(raw['instructionsHead']);
  int? get startedAt => _asIntOrNull(raw['startedAt']);
  int? get turn => _asIntOrNull(raw['turn']);
  int? get toolCalls => _asIntOrNull(raw['toolCalls']);

  WorkflowDisplayLastTool? get lastTool {
    final value = _asMap(raw['lastTool']);
    return value == null ? null : WorkflowDisplayLastTool(value);
  }

  String? get waitCause => _asString(raw['waitCause']);
  int? get retryAfterMs => _asIntOrNull(raw['retryAfterMs']);
  int? get waitSince => _asIntOrNull(raw['waitSince']);
  String? get parkedOn => _asString(raw['parkedOn']);
  int get stepsSettled => _asInt(raw['stepsSettled']);
  int get stepsFailed => _asInt(raw['stepsFailed']);
  int get tokens => _asInt(raw['tokens']);
  int? get lastProgressAt => _asIntOrNull(raw['lastProgressAt']);

  String get key => '$siteId\u0000$ordinal';
}

class WorkflowDisplayLastTool {
  final Map<String, dynamic> raw;

  WorkflowDisplayLastTool(this.raw);

  String get name => _asString(raw['name']) ?? '';
  String? get target => _asString(raw['target']);
  int? get at => _asIntOrNull(raw['at']);
}

class WorkflowDisplayHealth {
  final Map<String, dynamic> raw;

  WorkflowDisplayHealth(this.raw);

  int? get lastProgressAt => _asIntOrNull(raw['lastProgressAt']);
  int? get stalledSince => _asIntOrNull(raw['stalledSince']);

  WorkflowDisplayConcurrency? get concurrency {
    final value = _asMap(raw['concurrency']);
    return value == null ? null : WorkflowDisplayConcurrency(value);
  }

  int get consecutiveFailures => _asInt(raw['consecutiveFailures']);
  int get cachedSteps => _asInt(raw['cachedSteps']);
  int? get leftoverRunning => _asIntOrNull(raw['leftoverRunning']);
  bool get pendingQuestionsKnown => raw['pendingQuestionsKnown'] == true;
}

class WorkflowDisplayConcurrency {
  final Map<String, dynamic> raw;

  WorkflowDisplayConcurrency(this.raw);

  int get effective => _asInt(raw['effective']);
  int get cap => _asInt(raw['cap']);
  String? get reason => _asString(raw['reason']);
  int? get since => _asIntOrNull(raw['since']);
}

class WorkflowDisplayActor {
  final Map<String, dynamic> raw;

  WorkflowDisplayActor(this.raw);

  String get siteId => '${raw['siteId'] ?? ''}';
  int get ordinal => _asInt(raw['ordinal']);
  String? get name => _asString(raw['name']);

  String get key => '$siteId\u0000$ordinal';
}

class WorkflowDisplayLog {
  final Map<String, dynamic> raw;

  WorkflowDisplayLog(this.raw);

  int get sequence => _asInt(raw['sequence']);
  String get message => _asString(raw['message']) ?? '';
  int? get at => _asIntOrNull(raw['at']);
}

class WorkflowDisplayError {
  final Map<String, dynamic> raw;

  WorkflowDisplayError(this.raw);

  String get code => _asString(raw['code']) ?? '';
  String get message => _asString(raw['message']) ?? '';
}

/// `list_workflow_runs` payload: run headers for the session's directory.
class WorkflowRunListDisplay {
  final Map<String, dynamic> raw;

  WorkflowRunListDisplay._(this.raw);

  static WorkflowRunListDisplay? tryParse(Object? value) {
    final map = _asMap(value);
    if (map == null || map['kind'] != 'list_workflow_runs') return null;
    return WorkflowRunListDisplay._(map);
  }

  List<WorkflowRunListItem> get runs => [
    for (final r in _maps(raw['runs'])) WorkflowRunListItem(r),
  ];

  bool get truncated => raw['truncated'] == true;
}

class WorkflowRunListItem {
  final Map<String, dynamic> raw;

  WorkflowRunListItem(this.raw);

  String get runId => _asString(raw['runId']) ?? '';
  String get label => _asString(raw['label']) ?? '';
  String get labelSource => _asString(raw['labelSource']) ?? '';
  String get status => _asString(raw['status']) ?? '';
  String? get stopReason => _asString(raw['stopReason']);
  bool get ownedByThisSession => raw['ownedByThisSession'] == true;
  bool get possiblyInterrupted => raw['possiblyInterrupted'] == true;
  int get createdAt => _asInt(raw['createdAt']);
  int get updatedAt => _asInt(raw['updatedAt']);
  int get spentTokens => _asInt(raw['spentTokens']);
}

/// `create_workflow` payload: compile outcome. It carries no runId — the run
/// is joined through the tool row's `toolCallId`.
class WorkflowCreateDisplay {
  final Map<String, dynamic> raw;

  WorkflowCreateDisplay._(this.raw);

  static WorkflowCreateDisplay? tryParse(Object? value) {
    final map = _asMap(value);
    if (map == null || map['kind'] != 'create_workflow') return null;
    return WorkflowCreateDisplay._(map);
  }

  bool get ok => raw['ok'] == true;
  int get errorCount => _asInt(raw['errorCount']);

  List<WorkflowDiagnostic> get diagnostics => [
    for (final d in _maps(raw['diagnostics'])) WorkflowDiagnostic(d),
  ];

  /// Present when the script has a `fill` placeholder the desktop resolved
  /// into a draft workflow path.
  WorkflowCreateFill? get fill {
    final value = _asMap(raw['fill']);
    return value == null ? null : WorkflowCreateFill(value);
  }

  bool get truncated => raw['truncated'] == true;
}

class WorkflowCreateFill {
  final Map<String, dynamic> raw;

  WorkflowCreateFill(this.raw);

  String get siteId => _asString(raw['siteId']) ?? '';
  String get name => _asString(raw['name']) ?? '';
  String? get draftPath => _asString(raw['draftPath']);
  int? get line => _asIntOrNull(raw['line']);
}

class WorkflowDiagnostic {
  final Map<String, dynamic> raw;

  WorkflowDiagnostic(this.raw);

  int get line => _asInt(raw['line']);
  int get column => _asInt(raw['column']);
  int get code => _asInt(raw['code']);
  String get message => _asString(raw['message']) ?? '';
}

/// `resume_workflow_run` payload.
class WorkflowResumeDisplay {
  final Map<String, dynamic> raw;

  WorkflowResumeDisplay._(this.raw);

  static WorkflowResumeDisplay? tryParse(Object? value) {
    final map = _asMap(value);
    if (map == null || map['kind'] != 'resume_workflow_run') return null;
    if (_asString(map['runId']) == null) return null;
    return WorkflowResumeDisplay._(map);
  }

  String get runId => _asString(raw['runId']) ?? '';
}
