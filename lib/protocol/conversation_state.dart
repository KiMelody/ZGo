// Newer style lints are suppressed so this file keeps its protocol
// handling readable as a single, self-contained unit.
// ignore_for_file: use_null_aware_elements, prefer_initializing_formals
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

// Bundle anchor: the official web bundle's store/state region — the
// conversation/sessions-index state containers and delta application
// ([ConversationState], [SessionsIndexState], [SessionEntry]) plus the
// presentation model family ([WorkspacePrep], [SkillEntry],
// [ConfigOption], [SlashCommand], [ContextUsageView]). Split out of the
// former single-file conversation.dart; bundle diffs for these functions
// land here (see docs/adr/0013 appendix for the grep procedure).

class WorkspacePrep {
  final List<ConfigOption> configOptions;
  final List<SlashCommand> slashCommands;
  final Map raw;

  WorkspacePrep(this.raw)
    : configOptions = [
        if (raw['configOptions'] is List)
          for (final o in raw['configOptions'] as List)
            if (o is Map) ConfigOption._(o),
      ],
      slashCommands = [
        if (raw['slashCommands'] is List)
          for (final c in raw['slashCommands'] as List)
            if (c is Map) SlashCommand._(c),
      ];

  /// Public constructor (tests / manual construction).
  factory WorkspacePrep.fromMap(Map raw) => WorkspacePrep(raw);

  ConfigOption? option(String id) {
    for (final o in configOptions) {
      if (o.id == id) return o;
    }
    return null;
  }
}

/// A desktop skill (`skills.list`), triggered in the composer as `$name`.
class SkillEntry {
  final String id;
  final String name;
  final String path;
  final String scope;
  final String? description;
  final String? argumentHint;
  final bool enabled;

  /// Internal: wire constructor, exposed for the transport file split
  /// out of this library; not public API.
  SkillEntry(Map raw)
    : id = '${raw['id'] ?? ''}',
      name = '${raw['name'] ?? ''}',
      path = '${raw['path'] ?? ''}',
      scope = '${raw['scope'] ?? 'workspace'}',
      description = raw['description'] as String?,
      argumentHint = raw['argumentHint'] as String?,
      enabled = raw['enabled'] != false;
}

class ConfigOption {
  final String id;
  final String name;
  final String category;
  final String type;
  final Object? currentValue;
  final List<ConfigOptionValue> options;

  ConfigOption._(Map raw)
    : id = '${raw['id'] ?? ''}',
      name = '${raw['name'] ?? ''}',
      category = '${raw['category'] ?? ''}',
      type = '${raw['type'] ?? ''}',
      currentValue = raw['currentValue'],
      options = [
        if (raw['options'] is List)
          for (final v in raw['options'] as List)
            if (v is Map) ConfigOptionValue._(v),
      ];
}

class ConfigOptionValue {
  final String value;
  final String name;
  final String? description;
  final String? modelProviderName;

  ConfigOptionValue._(Map raw)
    : value = '${raw['value'] ?? ''}',
      name = '${raw['name'] ?? raw['value'] ?? ''}',
      description = raw['description'] as String?,
      modelProviderName = raw['modelProviderName'] as String?;

  /// Public constructor: synthesizes sheet-side entries from other
  /// catalogs (the chat config sheet's model-provider fallback, PRD
  /// 09-19) in the same shape the wire parser produces.
  ConfigOptionValue({
    required this.value,
    required this.name,
    this.description,
    this.modelProviderName,
  });
}

class SlashCommand {
  final String name;
  final String description;
  final String? inputHint;
  final String source;

  SlashCommand._(Map raw)
    : name = '${raw['name'] ?? ''}',
      description = '${raw['description'] ?? ''}',
      inputHint = raw['inputHint'] as String?,
      source = '${raw['source'] ?? ''}';
}


/// Live sessions-index state (task list of a workspace), fed by the
/// sessions-index subscription (`QAe` delta application).
class SessionEntry {
  final String sessionId;
  final String? parentSessionId;
  final String title;
  final String phase;
  final String? lastAssistantPreview;
  final int lastActivityAt;
  final int createdAt;
  final bool hasBackgroundWork;
  final Map<String, dynamic>? pendingInteraction;
  final Map<String, dynamic> raw;

  SessionEntry(this.raw)
    : sessionId = '${raw['sessionId'] ?? ''}',
      parentSessionId = raw['parentSessionId'] as String?,
      title = '${raw['title'] ?? ''}',
      phase = '${raw['phase'] ?? ''}',
      lastAssistantPreview = raw['lastAssistantPreview'] as String?,
      lastActivityAt = (raw['lastActivityAt'] as num?)?.toInt() ?? 0,
      createdAt = (raw['createdAt'] as num?)?.toInt() ?? 0,
      hasBackgroundWork = raw['hasBackgroundWork'] == true,
      pendingInteraction = (raw['pendingInteraction'] as Map?)
          ?.cast<String, dynamic>();

  /// Adapts a relay task (`Dg` model from bootstrap / workspace-list-updated)
  /// into a row entry so the task list can render non-active workspaces and
  /// the archive view from the relay overview. `displayStatus`
  /// (idle|running|completed|error) maps onto the phase-pill vocabulary.
  factory SessionEntry.fromRelayTask(Map<String, dynamic> task) {
    const statusToPhase = {
      'idle': 'idle',
      'running': 'running',
      'completed': 'completedSuccess',
      'error': 'error',
    };
    final status = '${task['displayStatus'] ?? 'idle'}';
    return SessionEntry({
      'sessionId': task['taskId'],
      'title': task['title'],
      'phase': statusToPhase[status] ?? status,
      'createdAt': task['createdAt'],
      'lastActivityAt': task['updatedAt'],
      'pinned': task['pinned'],
      'unreadAt': task['unreadAt'],
      'workspacePath': task['workspacePath'],
      'workspaceIdentity': task['workspaceIdentity'],
      // Task-meta error object (hzi: `{code?, message, traceId?, taskId?,
      // attribution?}`, runtime @805550) — pass-through for the Copy TraceID
      // surface; [lastErrorTraceId] does the defensive read.
      'lastError': task['lastError'],
    });
  }

  /// Error TraceID of the row's `lastError` meta, null when absent — the
  /// only wire carrier traceId has (F7: the conversation snapshot's status
  /// lastError is a strict schema WITHOUT traceId). Callers treat null as
  /// "don't render", never as an error.
  String? get lastErrorTraceId {
    final err = raw['lastError'];
    if (err is! Map) return null;
    final traceId = err['traceId'];
    if (traceId is! String || traceId.isEmpty) return null;
    return traceId;
  }
}

class SessionsIndexState extends ChangeNotifier {
  String? workspaceId;
  String? logEpoch;
  int seq = 0;
  final Map<String, SessionEntry> sessions = {};
  bool ready = false;

  /// Workspace key the opener recorded at subscribe time — the identity of
  /// the workspace whose data this index carries. Live-only rows (not yet
  /// in the relay overview) fall back to it for attribution; recording the
  /// identity on the data itself immunizes them against the switch /
  /// re-subscribe drift window where the page-level active workspace
  /// disagrees with this index's contents (2026-09-22 device report:
  /// sessions jumped into foreign groups). In-memory projection state
  /// only — never serialized.
  String? subscribedWorkspaceKey;

  /// Deleted-task tombstone ids the opener recorded right after the
  /// subscription landed (probed via `zcode-task.listDeletedTaskIds`). The
  /// desktop registry keeps `deleted=1` rows, the relay overview omits
  /// them, yet the live sessions-index (session-library view) still lists
  /// those tasks — without this set the live merge resurrects deleted
  /// tasks (2026-09-23 device report: default 12 → 22 after leaving a
  /// conversation). Empty on probe failure / older desktops = no
  /// filtering, the pre-probe behavior. In-memory projection state only —
  /// never serialized.
  Set<String> deletedTaskIds = const {};

  bool _deactivated = false;

  /// Same lazy shutdown as [ConversationState.deactivateState]: UI listening
  /// to the sessions index may outlive the subscription, so dispose-time
  /// asserts must not fire while listeners detach.
  void deactivateState() {
    _deactivated = true;
  }

  @override
  void notifyListeners() {
    if (_deactivated) return;
    super.notifyListeners();
  }

  List<SessionEntry> get list {
    final values = sessions.values.toList()
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    return values;
  }

  void applyFrame(
    Map<String, dynamic> frame, {
    required void Function() onGap,
  }) {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? seq;

    if (payload['kind'] == 'snapshot') {
      final snap = (payload['snapshot'] as Map).cast<String, dynamic>();
      workspaceId = snap['workspaceId'] as String?;
      logEpoch = snap['logEpoch'] as String?;
      sessions.clear();
      final list = snap['sessions'];
      if (list is List) {
        for (final s in list) {
          if (s is Map) {
            final entry = SessionEntry(s.cast<String, dynamic>());
            sessions[entry.sessionId] = entry;
          }
        }
      }
      seq = toSeq;
    } else if (payload['kind'] == 'deltas') {
      final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? seq;
      if (fromSeq != seq) {
        onGap();
        return;
      }
      final deltas = payload['deltas'];
      if (deltas is List) {
        for (final d in deltas) {
          if (d is! Map) continue;
          if (d['op'] == 'session.upserted' && d['session'] is Map) {
            final entry = SessionEntry(
              (d['session'] as Map).cast<String, dynamic>(),
            );
            sessions[entry.sessionId] = entry;
          } else if (d['op'] == 'session.removed') {
            sessions.remove('${d['sessionId']}');
          }
        }
      }
      seq = toSeq;
    }
    ready = true;
    notifyListeners();
  }
}


/// Workflow-run family mirror for one conversation: the session snapshot
/// `workflowRuns: {revision, runs[]}` plus the `workflowRun.updated` /
/// `workflowRun.removed` delta ops (capability `workflowRunDeltas`; without
/// the capability the snapshot carries the full list).
///
/// Semantics are the official runtime's — `applyWorkflowRunUpdated`
/// (`$Zt` @1090914), `applyWorkflowRunRemoved` (`qZt` @1091603),
/// `coalesceConversationDeltas` (`sQe` @1109227) and
/// `mergeWorkflowRunUpdates` (`Ehr` @1093700). Runs stay raw maps (wire
/// pass-through); [WorkflowRun] is the typed read view the UI consumes.
class WorkflowRuns {
  /// Monotonic wire revision: `max` over every applied delta
  /// (official `Math.max(state.revision, delta.revision)`).
  final int revision;

  /// Raw run maps in wire order.
  final List<Map<String, dynamic>> runs;

  const WorkflowRuns({this.revision = 0, this.runs = const []});

  bool get isEmpty => runs.isEmpty;
  bool get isNotEmpty => runs.isNotEmpty;

  List<WorkflowRun> get views => [for (final r in runs) WorkflowRun(r)];

  WorkflowRun? byRunId(String runId) {
    for (final r in runs) {
      if ('${r['runId'] ?? ''}' == runId) return WorkflowRun(r);
    }
    return null;
  }

  /// Official `QRt` (@315497351) keys the by-toolCallId map on `toolCallId`;
  /// runs without one are not addressable from a tool card.
  WorkflowRun? byToolCallId(String toolCallId) {
    for (final r in runs) {
      if ('${r['toolCallId'] ?? ''}' == toolCallId) return WorkflowRun(r);
    }
    return null;
  }
}

/// Typed read view over one raw workflow run (wire schema renderer
/// @269852039).
class WorkflowRun {
  final Map<String, dynamic> raw;

  WorkflowRun(this.raw);

  String get runId => '${raw['runId'] ?? ''}';
  String get status => '${raw['status'] ?? ''}';
  String? get stopReason => raw['stopReason'] as String?;

  String? get toolCallId {
    final id = raw['toolCallId'];
    return id is String && id.isNotEmpty ? id : null;
  }

  bool get resumable => raw['resumable'] == true;

  int get actorsCount {
    final actors = raw['actors'];
    return actors is List ? actors.length : 0;
  }

  List<Map<String, dynamic>> get nodes => [
    if (raw['nodes'] is List)
      for (final n in raw['nodes'] as List)
        if (n is Map) n.cast<String, dynamic>(),
  ];

  int get nodesTotal => nodes.length;

  /// Nodes that reached a terminal phase (outcome set or phase `settled`) —
  /// the official progress numerator. Exact official `iu` projection is not
  /// re-derived here (bundle-resident); real-device shape check pending
  /// (PRD acceptance).
  int get nodesSettled {
    var settled = 0;
    for (final n in nodes) {
      if (n['outcome'] != null || n['phase'] == 'settled') settled++;
    }
    return settled;
  }
}

/// Official `workflowRunEntryKey` (`Oz` @1088066): `siteId\0ordinal`.
String workflowRunEntryKey(Map entry) =>
    '${entry['siteId']}\u0000${entry['ordinal']}';

/// Official `isCompleteWorkflowRunHeader` (`jQi` @1088732): every required
/// run key present. Required set = the run schema's mandatory keys minus
/// actors/nodes (renderer @269852039: runId / status / usage /
/// lastEventSequence).
const _workflowRunRequiredKeys = <String>[
  'runId',
  'status',
  'usage',
  'lastEventSequence',
];

bool _isCompleteWorkflowRunHeader(Object? run) {
  if (run is! Map) return false;
  for (final key in _workflowRunRequiredKeys) {
    if (run[key] == null) return false;
  }
  return true;
}

int _revisionOf(Object? value) => (value as num?)?.toInt() ?? 0;

/// Official `whr` removeWorkflowRunEntries: filter out entries whose
/// `siteId\0ordinal` key appears in [removed]; empty/none removed returns
/// the input list unchanged (reference equality preserved, official).
List<Map<String, dynamic>> _removeEntries(
  List<Map<String, dynamic>> entries,
  Object? removed,
) {
  if (removed is! List || removed.isEmpty) return entries;
  final keys = <String>{
    for (final r in removed)
      if (r is Map) workflowRunEntryKey(r),
  };
  final kept = [
    for (final e in entries)
      if (!keys.contains(workflowRunEntryKey(e))) e,
  ];
  return kept.length == entries.length ? entries : kept;
}

/// Official `UZt` upsertWorkflowRunEntries: same-key overwrite in place,
/// new keys appended in order.
List<Map<String, dynamic>> _upsertEntries(
  List<Map<String, dynamic>> entries,
  List<Map<String, dynamic>> items,
) {
  final out = List<Map<String, dynamic>>.of(entries);
  final index = <String, int>{};
  for (var i = 0; i < out.length; i++) {
    index[workflowRunEntryKey(out[i])] = i;
  }
  for (final item in items) {
    final key = workflowRunEntryKey(item);
    final at = index[key];
    if (at == null) {
      index[key] = out.length;
      out.add(item);
    } else {
      out[at] = item;
    }
  }
  return out;
}

List<Map<String, dynamic>> _entries(Object? value) => [
  if (value is List)
    for (final e in value)
      if (e is Map) e.cast<String, dynamic>(),
];

List<String> _stringList(Object? value) =>
    [if (value is List) for (final e in value) '$e'];

/// Official `mergeRemovedRefs` (`khr` @1092914): union deduped by
/// `siteId\0ordinal`; both absent or empty → null.
List<Map<String, dynamic>>? _mergeRemovedRefs(Object? a, Object? b) {
  final first = _entries(a);
  final second = _entries(b);
  if (first.isEmpty && second.isEmpty) return null;
  final seen = <String>{};
  final out = <Map<String, dynamic>>[];
  for (final e in [...first, ...second]) {
    if (seen.add(workflowRunEntryKey(e))) out.add(e);
  }
  return out.isEmpty ? null : out;
}

/// Official `mergeEntryLists` (`xhr` @1093087): drop [removed] then upsert
/// [items]; both absent → null.
List<Map<String, dynamic>>? _mergeEntryLists(
  Object? base,
  Object? items,
  Object? removed,
) {
  if (base == null && items == null) return null;
  final filtered = _removeEntries(_entries(base), removed);
  final merged = _upsertEntries(filtered, _entries(items));
  return merged.isEmpty ? null : merged;
}

/// Official `workflowRunUpdateWithinWireBounds` (`Chr` @1092071): the
/// per-update entry lists stay within maxActors (1024) / maxNodes (1024).
bool _withinWorkflowRunBounds(Map<String, dynamic> delta) {
  const maxActors = 1024;
  const maxNodes = 1024;
  final actors = _entries(delta['actors']).length;
  final removedActors = _entries(delta['removedActors']).length;
  final nodes = _entries(delta['nodes']).length;
  final removedNodes = _entries(delta['removedNodes']).length;
  return actors <= maxActors &&
      removedActors <= maxActors &&
      nodes <= maxNodes &&
      removedNodes <= maxNodes;
}

/// Official `mergeWorkflowRunUpdates` (`Ehr` @1092251): folds two
/// `workflowRun.updated` deltas into one. Run patches merge (second wins),
/// `cleared` is the union, removed refs union, actors/nodes are
/// filtered-then-upserted, revision is the max. The result may omit empty
/// members exactly like the official builder.
Map<String, dynamic> mergeWorkflowRunUpdates(
  Map<String, dynamic> first,
  Map<String, dynamic> second,
) {
  final run = <String, dynamic>{};
  if (first['run'] is Map) run.addAll((first['run'] as Map).cast<String, dynamic>());
  if (second['run'] is Map) {
    run.addAll((second['run'] as Map).cast<String, dynamic>());
  }
  for (final key in _stringList(second['cleared'])) {
    run.remove(key);
  }
  final cleared = <String>[];
  for (final key in _stringList(first['cleared'])) {
    if (run[key] == null && !cleared.contains(key)) cleared.add(key);
  }
  for (final key in _stringList(second['cleared'])) {
    if (!cleared.contains(key)) cleared.add(key);
  }
  final removedActors = _mergeRemovedRefs(
    first['removedActors'],
    second['removedActors'],
  );
  final removedNodes = _mergeRemovedRefs(
    first['removedNodes'],
    second['removedNodes'],
  );
  final actors = _mergeEntryLists(
    first['actors'],
    second['actors'],
    second['removedActors'],
  );
  final nodes = _mergeEntryLists(
    first['nodes'],
    second['nodes'],
    second['removedNodes'],
  );
  final revisionA = _revisionOf(first['revision']);
  final revisionB = _revisionOf(second['revision']);
  return {
    'op': 'workflowRun.updated',
    'runId': second['runId'] ?? first['runId'],
    'revision': revisionA > revisionB ? revisionA : revisionB,
    if (run.isNotEmpty) 'run': run,
    if (cleared.isNotEmpty) 'cleared': cleared,
    if (removedActors != null) 'removedActors': removedActors,
    if (removedNodes != null) 'removedNodes': removedNodes,
    if (actors != null) 'actors': actors,
    if (nodes != null) 'nodes': nodes,
  };
}

/// Applies ONE workflow-run delta to [state] (official `$Zt`/`qZt`).
///
/// A delta whose revision lags the current one is dropped unchanged
/// (design D2 stale-drop; the server's revision is monotonic). A removed
/// run that isn't present returns [state] itself when the revision did not
/// move — object identity is the "no change" signal the caller can trust.
WorkflowRuns applyWorkflowRunDelta(
  WorkflowRuns state,
  Map<String, dynamic> delta,
) {
  final revision = _revisionOf(delta['revision']);
  if (revision < state.revision) return state;
  final maxRevision = revision > state.revision ? revision : state.revision;
  switch (delta['op']) {
    case 'workflowRun.updated':
      return _applyWorkflowRunUpdated(state, delta, maxRevision);
    case 'workflowRun.removed':
      final runId = '${delta['runId']}';
      final kept = [
        for (final r in state.runs)
          if ('${r['runId']}' != runId) r,
      ];
      if (kept.length == state.runs.length) {
        return maxRevision == state.revision
            ? state
            : WorkflowRuns(revision: maxRevision, runs: state.runs);
      }
      return WorkflowRuns(revision: maxRevision, runs: kept);
  }
  return state;
}

WorkflowRuns _applyWorkflowRunUpdated(
  WorkflowRuns state,
  Map<String, dynamic> delta,
  int maxRevision,
) {
  final runs = List<Map<String, dynamic>>.of(state.runs);
  final runId = '${delta['runId']}';
  final index = runs.indexWhere((r) => '${r['runId']}' == runId);
  if (index < 0) {
    // A missing run may only be inserted by a complete header; otherwise
    // only the revision advances (official jQi branch).
    if (!_isCompleteWorkflowRunHeader(delta['run'])) {
      return maxRevision == state.revision
          ? state
          : WorkflowRuns(revision: maxRevision, runs: runs);
    }
    final header = (delta['run'] as Map).cast<String, dynamic>();
    runs.add({
      ...header,
      'actors': _entries(delta['actors']),
      'nodes': _entries(delta['nodes']),
    });
    return WorkflowRuns(revision: maxRevision, runs: runs);
  }
  final existing = runs[index];
  final merged = <String, dynamic>{...existing};
  final patch = delta['run'];
  if (patch is Map) {
    for (final entry in patch.entries) {
      merged['${entry.key}'] = entry.value;
    }
  }
  for (final key in _stringList(delta['cleared'])) {
    merged.remove(key);
  }
  final existingActors = _entries(existing['actors']);
  var actors = _removeEntries(existingActors, delta['removedActors']);
  final addedActors = _entries(delta['actors']);
  if (addedActors.isNotEmpty) actors = _upsertEntries(actors, addedActors);
  if (!identical(actors, existingActors)) merged['actors'] = actors;
  final existingNodes = _entries(existing['nodes']);
  var nodes = _removeEntries(existingNodes, delta['removedNodes']);
  final addedNodes = _entries(delta['nodes']);
  if (addedNodes.isNotEmpty) nodes = _upsertEntries(nodes, addedNodes);
  if (!identical(nodes, existingNodes)) merged['nodes'] = nodes;
  runs[index] = merged;
  return WorkflowRuns(revision: maxRevision, runs: runs);
}

bool _workflowRunBarrier(Map<String, dynamic> delta, String runId) {
  if (delta['op'] == 'state.updated') {
    final patch = delta['patch'];
    return patch is Map && patch['workflowRuns'] != null;
  }
  return delta['op'] == 'workflowRun.removed' && '${delta['runId']}' == runId;
}

/// Official `coalesceConversationDeltas` (`sQe` @1109227), restricted to the
/// workflow-run family: a `workflowRun.removed` swallows earlier
/// `workflowRun.updated` deltas of the same runId back to the last barrier,
/// and a `workflowRun.updated` folds into the nearest previous same-run
/// update when the merge stays within wire bounds. Every other op passes
/// through in order untouched. Barrier = a same-runId
/// `workflowRun.removed` or a `state.updated` patch carrying `workflowRuns`.
List<Map<String, dynamic>> coalesceWorkflowRunDeltas(
  List<Map<String, dynamic>> deltas,
) {
  final out = <Map<String, dynamic>>[];
  for (final delta in deltas) {
    final op = delta['op'];
    if (op == 'workflowRun.removed') {
      final runId = '${delta['runId']}';
      for (var i = out.length - 1; i >= 0; i--) {
        final prev = out[i];
        if (_workflowRunBarrier(prev, runId)) break;
        if (prev['op'] == 'workflowRun.updated' &&
            '${prev['runId']}' == runId) {
          out.removeAt(i);
        }
      }
      out.add(delta);
      continue;
    }
    if (op == 'workflowRun.updated') {
      final runId = '${delta['runId']}';
      var merged = false;
      for (var i = out.length - 1; i >= 0; i--) {
        final prev = out[i];
        if (_workflowRunBarrier(prev, runId)) break;
        if (prev['op'] == 'workflowRun.updated' &&
            '${prev['runId']}' == runId) {
          final combined = mergeWorkflowRunUpdates(prev, delta);
          if (_withinWorkflowRunBounds(combined)) {
            out[i] = combined;
            merged = true;
          }
          break;
        }
      }
      if (!merged) out.add(delta);
      continue;
    }
    out.add(delta);
  }
  return out;
}

/// Conversation snapshot + row state, from the `fke()`/`pke()` delta
/// application.
class ConversationState extends ChangeNotifier {
  Map<String, dynamic>? snapshot;
  List<Map<String, dynamic>> rows = [];
  int seq = 0;
  String? logEpoch;
  int? firstRowId;
  int totalCount = 0;
  bool ready = false;

  /// Set by [deactivateState]; the notification path below checks it.
  bool _deactivated = false;

  /// Lazy deactivation instead of ChangeNotifier.dispose(): modal routes
  /// (usage sheet) can outlive the subscription that owns this state, and a
  /// hard dispose would trip ChangeNotifier's post-dispose asserts when those
  /// routes detach their listeners (crash: 'used after being disposed' +
  /// '_dependents.isEmpty'). Notifications stop; reads keep working; the
  /// notifier is GC'd together with its last listeners.
  void deactivateState() {
    _deactivated = true;
  }

  @override
  void notifyListeners() {
    if (_deactivated) return;
    super.notifyListeners();
  }

  /// `hasMore` from the latest conversationRowsRangeV4 response — the web
  /// store pages on this flag. Null until the first load-older runs (older
  /// builds fall back to the totalCount heuristic).
  bool? hasMore;

  /// Workflow-run family: snapshot `workflowRuns` + the
  /// `workflowRun.updated`/`workflowRun.removed` deltas. Every snapshot
  /// rebuilds it (with the `workflowRunDeltas` capability the snapshot may
  /// omit the full list; without it the snapshot always carries all runs).
  WorkflowRuns workflowRuns = const WorkflowRuns();

  void applyFrame(
    Map<String, dynamic> frame, {
    required void Function() onGap,
  }) {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? seq;

    if (payload['kind'] == 'snapshot') {
      final snap = (payload['snapshot'] as Map).cast<String, dynamic>();
      _applySnapshot(snap, toSeq);
    } else if (payload['kind'] == 'deltas') {
      final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? seq;
      if (fromSeq != seq) {
        onGap();
        return;
      }
      final deltas = payload['deltas'];
      if (deltas is List) {
        final typed = [
          for (final d in deltas)
            if (d is Map) d.cast<String, dynamic>(),
        ];
        // Workflow-run deltas fold before application (official sQe
        // compression: same-runId updates/removals collapse).
        for (final d in coalesceWorkflowRunDeltas(typed)) {
          _applyDelta(d);
        }
      }
      seq = toSeq;
    }
    ready = true;
    notifyListeners();
  }

  /// Parses a `workflowRuns` snapshot member (`{revision, runs[]}`) into the
  /// typed mirror; anything else resets to empty (snapshot is authoritative).
  static WorkflowRuns _parseWorkflowRuns(Object? raw) {
    if (raw is! Map) return const WorkflowRuns();
    final runs = raw['runs'];
    return WorkflowRuns(
      revision: (raw['revision'] as num?)?.toInt() ?? 0,
      runs: [
        if (runs is List)
          for (final r in runs)
            if (r is Map) r.cast<String, dynamic>(),
      ],
    );
  }

  void _applySnapshot(Map<String, dynamic> snap, int toSeq) {
    _detectConfigRevert(snap);
    snapshot = snap;
    _usageEvent = null;
    if (_pendingPatch != null) {
      snapshot = {...snap, ..._pendingPatch!};
      _pendingPatch = null;
    }
    seq = toSeq;
    logEpoch = snap['logEpoch'] as String?;
    final rowsObj = snap['rows'];
    List<Map<String, dynamic>> snapRows;
    // The EXPLICIT firstRowId is the paging-cursor authority (it can sit
    // outside the window — live-probed placeholder, see
    // live_child_rows_probe); the window head is only the fallback.
    int? declaredFirstRowId;
    if (rowsObj is Map) {
      final window = rowsObj['window'];
      snapRows = window is List
          ? window
                .whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList()
          : [];
      totalCount = (rowsObj['totalCount'] as num?)?.toInt() ?? snapRows.length;
      declaredFirstRowId = (rowsObj['firstRowId'] as num?)?.toInt();
    } else {
      snapRows = [];
      totalCount = 0;
      declaredFirstRowId = null;
    }
    final windowFirstRowId = snapRows.isNotEmpty
        ? (snapRows.first['rowId'] as num?)?.toInt()
        : null;
    // Keep the already-held OLDER rows across EVERY snapshot refresh, not
    // just same-epoch ones (round 23). The original bridge-crash fix
    // (2026-09-22) gated the merge on an unchanged log epoch — but the
    // desktop advances the epoch while streaming (a fresh snapshot every
    // ~10s during output, device log 09-22 13:54), and each such refresh
    // then threw away every prepended history page: max collapsed and the
    // viewport clamped (the "jumping"), and the paging cursor (derived
    // from the held rows) rewound to the snapshot window head so the next
    // load re-fetched the SAME page ("the top timestamp never changes",
    // then the fetches started silently dying to the epoch race =
    // "stuck loading"). The held rows are immutable log entries — an
    // epoch drift does not invalidate them; rows overlapping the fresh
    // window are still dropped in favor of its newer data.
    if (snapRows.isNotEmpty && windowFirstRowId != null) {
      final older = rows
          .where(
            (r) => ((r['rowId'] as num?)?.toInt() ?? 0) < windowFirstRowId,
          )
          .toList();
      rows = older.isNotEmpty ? [...older, ...snapRows] : snapRows;
    } else {
      rows = snapRows;
    }
    // The paging-cursor authority is the oldest signal we hold: the oldest
    // HELD row when history pages were prepended, else the snapshot's
    // declared firstRowId (which can sit OUTSIDE the window — the
    // live-probed placeholder that says earlier history exists). Either
    // way the smaller wins — a larger snapshot-side value must not rewind
    // what the reader already paged past.
    var oldestSignal = rows.isNotEmpty
        ? (rows.first['rowId'] as num?)?.toInt()
        : null;
    if (declaredFirstRowId != null &&
        (oldestSignal == null || declaredFirstRowId < oldestSignal)) {
      oldestSignal = declaredFirstRowId;
    }
    firstRowId = oldestSignal;
    workflowRuns = _parseWorkflowRuns(snapshot?['workflowRuns']);
  }

  void _applyDelta(Map<String, dynamic> delta) {
    switch (delta['op']) {
      case 'row.appended':
        final row = (delta['row'] as Map).cast<String, dynamic>();
        rows.add(row);
        totalCount += 1;
        firstRowId ??= (row['rowId'] as num?)?.toInt();
        break;
      case 'row.upserted':
        final row = (delta['row'] as Map).cast<String, dynamic>();
        final id = (row['rowId'] as num?)?.toInt();
        final index = rows.indexWhere(
          (r) => (r['rowId'] as num?)?.toInt() == id,
        );
        if (index != -1) rows[index] = row;
        break;
      case 'row.removed':
        // Delta application: KEEP rows with
        // rowId < fromRowId (i.e. remove rows >= fromRowId).
        final fromRowId = (delta['fromRowId'] as num?)?.toInt() ?? 0;
        final kept = rows
            .where((r) => ((r['rowId'] as num?)?.toInt() ?? 0) < fromRowId)
            .toList();
        final removed = rows.length - kept.length;
        rows = kept;
        if (firstRowId != null && fromRowId <= firstRowId!) {
          totalCount = 0;
          firstRowId = null;
        } else {
          totalCount = (totalCount - removed).clamp(0, 1 << 31);
        }
        break;
      case 'row.delta':
        final rowId = (delta['rowId'] as num?)?.toInt();
        final path = delta['path'] as String?;
        final append = delta['append'] as String? ?? '';
        final index = rows.indexWhere(
          (r) => (r['rowId'] as num?)?.toInt() == rowId,
        );
        if (index != -1) {
          rows[index] = _appendToRow(rows[index], path, append);
        }
        break;
      case 'state.updated':
        final patch = delta['patch'];
        if (patch is Map) {
          final typedPatch = patch.cast<String, dynamic>();
          if (snapshot != null) {
            snapshot = {...snapshot!, ...typedPatch};
            // A patch carrying `workflowRuns` replaces the whole family
            // (that member is the delta-coalescing barrier, official r0r);
            // refresh the typed mirror from it.
            if (typedPatch['workflowRuns'] is Map) {
              workflowRuns = _parseWorkflowRuns(typedPatch['workflowRuns']);
            }
          } else {
            // Patch arrived before the initial snapshot — buffer and
            // merge when the snapshot lands (otherwise config/queue/
            // control updates are silently lost). The workflowRuns member
            // is picked up by [_applySnapshot]'s parse.
            _pendingPatch = {...?_pendingPatch, ...typedPatch};
          }
        }
        break;
      case 'workflowRun.updated':
      case 'workflowRun.removed':
        workflowRuns = applyWorkflowRunDelta(workflowRuns, delta);
        break;
    }
  }

  Map<String, dynamic>? _pendingPatch;

  /// Optimistic local update (command already accepted; the confirming
  /// `state.updated` frame may lag). Merges into snapshot immediately.
  ///
  /// Never arms the revert trace (design 10-02 Step 3): the desktop keeps
  /// the OLD config in authoritative snapshots until the user's next
  /// message (its pending semantics), so arming on every write misread
  /// every acknowledged switch as a lost command. Arming is the lost-ack
  /// path's job — [armConfigRevertTrace].
  void optimisticPatch(Map<String, dynamic> patch) {
    if (snapshot == null) return;
    snapshot = {...snapshot!, ...patch};
    notifyListeners();
  }

  /// Arms the revert trace WITHOUT landing a patch (design 10-02 Step 3):
  /// the lost-ack path only — the sheet's onTimeoutOptimistic callback,
  /// where the switch response never arrived and a later authoritative
  /// snapshot still carrying the old config is evidence the command died
  /// in a bridge swing. [patch] has the same shape as [optimisticPatch]'s;
  /// its `config` member becomes the compared value.
  void armConfigRevertTrace(Map<String, dynamic> patch) {
    final config = patch['config'];
    if (config is! Map) return;
    _optimisticConfig = (
      value: Map<String, dynamic>.from(config),
      at: clock.now(),
    );
  }

  /// Clears an armed trace without a verdict (design 10-02 Step 3): the
  /// accepted path — a switch that was acknowledged, even late, must not
  /// be judged by later old-config snapshots (those are the desktop's
  /// pending semantics, not a lost command).
  void clearConfigRevertTrace() {
    _optimisticConfig = null;
  }

  /// Optimistic-config trace (design 09-25 D3): what [armConfigRevertTrace]
  /// last armed under the `config` key and when — the "switch did not
  /// take effect" detector's baseline. Null when no lost-ack switch is
  /// pending comparison.
  ({Map<String, dynamic> value, DateTime at})? _optimisticConfig;

  /// How long an optimistic write stays worth comparing (design D3:
  /// stale optimism is not worth mentioning).
  static const Duration _optimisticRevertWindow = Duration(seconds: 60);

  /// One-shot flag raised by [_detectConfigRevert]; the chat page consumes
  /// it (SnackBar) via [consumeConfigReverted] — read-and-clear.
  bool _configReverted = false;

  /// Reads and clears the revert flag.
  bool consumeConfigReverted() {
    final reverted = _configReverted;
    _configReverted = false;
    return reverted;
  }

  /// Revert detection (design D3), run against each authoritative
  /// snapshot's `config`: a value differing from a still-fresh (≤60s)
  /// armed trace (armed on the lost-ack path only, design 10-02 Step 3)
  /// means the switch command was lost in a bridge swing
  /// and this snapshot silently rolled the UI back to the desktop's old
  /// setting — raise the one-shot flag. Same value = the switch survived
  /// (trace clears, no flag). Snapshots without `config` are not a
  /// verdict; the `state.updated` merge path never runs this (an
  /// incremental patch is the confirmation, not a rollback).
  void _detectConfigRevert(Map<String, dynamic> snap) {
    final trace = _optimisticConfig;
    if (trace == null) return;
    final incoming = snap['config'];
    if (incoming is! Map) return;
    _optimisticConfig = null; // one config-bearing snapshot = one verdict
    if (mapEquals(incoming, trace.value)) return;
    if (clock.now().difference(trace.at) > _optimisticRevertWindow) return;
    _configReverted = true;
  }

  /// Optimistic row edit (e.g. feedback) — mutates the row in place and
  /// notifies; the server row.upserted will confirm.
  void optimisticRowUpdate(num? rowId, Map<String, dynamic> patch) {
    final index = rows.indexWhere(
      (r) => (r['rowId'] as num?)?.toInt() == rowId?.toInt(),
    );
    if (index == -1) return;
    rows[index] = {...rows[index], ...patch};
    notifyListeners();
  }

  /// Optimistic queue removal (sendQueuedNow / deleteQueueItem accepted).
  void optimisticRemoveQueueItem(String queueItemId) {
    final q = queue;
    if (q == null) return;
    final items = (q['items'] as List?)
        ?.where((i) => i is Map && '${i['queueItemId']}' != queueItemId)
        .toList();
    snapshot = {
      ...snapshot!,
      'queue': {...q, 'items': items ?? []},
    };
    notifyListeners();
  }

  /// Appends streamed text to a row field.
  Map<String, dynamic> _appendToRow(
    Map<String, dynamic> row,
    String? path,
    String append,
  ) {
    switch (path) {
      case 'text':
        if (row['kind'] == 'assistantText' || row['kind'] == 'reasoning') {
          return {...row, 'text': '${row['text'] ?? ''}$append'};
        }
        return row;
      case 'inputText':
        if (row['kind'] == 'toolCall') {
          return {...row, 'inputText': '${row['inputText'] ?? ''}$append'};
        }
        return row;
      case 'output.text':
        if (row['kind'] == 'toolCall' && row['output'] is Map) {
          final output = (row['output'] as Map).cast<String, dynamic>();
          return {
            ...row,
            'output': {...output, 'text': '${output['text'] ?? ''}$append'},
          };
        }
        return row;
      case 'summaryText':
        if (row['kind'] == 'subagent') {
          return {...row, 'summaryText': '${row['summaryText'] ?? ''}$append'};
        }
        return row;
      default:
        return row;
    }
  }

  Map<String, dynamic>? get control =>
      (snapshot?['control'] as Map?)?.cast<String, dynamic>();

  /// Current conversation revision (CAS commands base this on).
  int get revision => (snapshot?['revision'] as num?)?.toInt() ?? 0;

  String get phase => control?['phase'] as String? ?? '';

  bool get canStop => control?['canStop'] == true;

  bool get isRunning => phase == 'running' || phase == 'prewarming';

  /// Session config: {provider, model, thought, thoughtLevels, followupMode,
  /// mode}.
  Map<String, dynamic>? get config =>
      (snapshot?['config'] as Map?)?.cast<String, dynamic>();

  String get currentModel => config?['model'] as String? ?? '';
  String get currentThought => config?['thought'] as String? ?? '';
  String get currentMode => config?['mode'] as String? ?? 'build';
  List<String> get thoughtLevels => config?['thoughtLevels'] is List
      ? (config!['thoughtLevels'] as List).map((e) => '$e').toList()
      : const [];

  /// Held queue: {items: [...], autoDrain}.
  Map<String, dynamic>? get queue =>
      (snapshot?['queue'] as Map?)?.cast<String, dynamic>();

  List<Map<String, dynamic>> get queueItems {
    final items = queue?['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  bool get autoDrain => queue?['autoDrain'] != false;

  /// Usage pushed by the `usage_update` task-stream event (whitelist
  /// parsed, see [applyUsageUpdate]). Reset on every snapshot re-apply so
  /// a fresh authoritative snapshot is never shadowed by stale merges.
  Map<String, dynamic>? _usageEvent;

  /// Token usage — the single UI exit for context/cumulative numbers.
  /// Two schemas coexist by design: the snapshot's
  /// `{contextWindow: {usedTokens, maxTokens, cache: {hitRate, …},
  /// breakdown: […]}, cumulative: {…}}` (live-updated by state.updated
  /// patches on 3.11.2 desktops) and the event's
  /// `{size, used, cost, cache, breakdown}`. Event fields win, snapshot
  /// fields fill the gaps (research「关系」节 strategy); read the
  /// normalized view from [contextUsage].
  Map<String, dynamic>? get usage {
    final snap = snapshot?['usage'];
    final base = snap is Map ? snap.cast<String, dynamic>() : null;
    final event = _usageEvent;
    if (event == null || event.isEmpty) return base;
    if (base == null) return event;
    return {...base, ...event};
  }

  /// Applies one `usage_update` task-stream event
  /// (`{type: 'usage_update', size, used, cost, cache?, breakdown?}`),
  /// whitelist-parsed and defensively read: any missing/invalid field is
  /// simply absent and falls back to the snapshot in [usage]. Guards: an
  /// update without a usable `used` never
  /// clobbers current usage, and an update lacking a breakdown keeps the
  /// previous one while used/size are unchanged.
  void applyUsageUpdate(Map<String, dynamic> event) {
    final parsed = _parseUsageUpdate(event);
    if (parsed.isEmpty) return;
    final current = usage;
    final currentUsed = _finiteNum(current?['used']);
    final currentSize = _finiteNum(current?['size']);
    final incomingUsed = _finiteNum(parsed['used']);
    if (currentUsed != null &&
        currentUsed > 0 &&
        currentSize != null &&
        currentSize > 0 &&
        (incomingUsed == null || incomingUsed <= 0)) {
      return; // official s0t: keep the valid current usage intact
    }
    if (!parsed.containsKey('breakdown') && current != null) {
      final prev = current['breakdown'];
      if (prev != null &&
          _finiteNum(current['used']) == parsed['used'] &&
          _finiteNum(current['size']) == parsed['size']) {
        parsed['breakdown'] = prev;
      }
    }
    _usageEvent = parsed;
    notifyListeners();
  }

  /// Whitelist parser for one `usage_update` event. `cost` is parsed but
  /// never rendered (PRD R7); `size`/`used` must be finite and positive
  /// (usage is hidden at <= 0); `cache` reduces to
  /// `{hitRate}`; breakdown entries need a string `source` and finite
  /// `chars` (<= 0 entries are dropped later in [contextUsage]).
  static Map<String, dynamic> _parseUsageUpdate(Map<String, dynamic> event) {
    final out = <String, dynamic>{};
    final size = _finiteNum(event['size']);
    if (size != null && size > 0) out['size'] = size;
    final used = _finiteNum(event['used']);
    if (used != null && used > 0) out['used'] = used;
    final cost = _finiteNum(event['cost']);
    if (cost != null) out['cost'] = cost;
    final cache = event['cache'];
    if (cache is Map) {
      final hitRate = _finiteNum(cache['hitRate']);
      if (hitRate != null) out['cache'] = {'hitRate': hitRate};
    }
    final breakdown = event['breakdown'];
    if (breakdown is List) {
      final items = [
        for (final e in breakdown)
          if (e is Map &&
              e['source'] is String &&
              (_finiteNum(e['chars']) ?? 0) > 0)
            {'chars': _finiteNum(e['chars']), 'source': e['source']},
      ];
      if (items.isNotEmpty) out['breakdown'] = items;
    }
    return out;
  }

  static num? _finiteNum(Object? value) =>
      value is num && value.isFinite ? value : null;

  /// Breakdown weight order: primary sort is chars
  /// descending, ties break by this table; unknown sources trail in
  /// first-seen order.
  static const _breakdownWeights = {
    'messages': 0,
    'system_prompt': 1,
    'meta_user_context': 2,
    'skills': 3,
    'tool_prompt': 4,
    'system_tool_schemas': 5,
    'mcp_tool_schemas': 6,
  };

  /// Normalized context-usage projection for the UI (usage sheet + ring):
  /// used/max from event or snapshot, cache hit rate, and the aggregated
  /// breakdown (per-source chars summed, <= 0 dropped, chars descending
  /// with the weight tie-break, percent of the retained total).
  ContextUsageView get contextUsage {
    final usage = this.usage;
    final window = usage?['contextWindow'];
    final used = _finiteNum(usage?['used']) ??
        (window is Map ? _finiteNum(window['usedTokens']) : null);
    final max = _finiteNum(usage?['size']) ??
        (window is Map ? _finiteNum(window['maxTokens']) : null);
    // 3.11.2 desktops ship cache/breakdown inside the snapshot's
    // contextWindow (live-merged via state.updated patches); the flat
    // event shape only arrives where the task-stream broadcast exists.
    final cache = usage?['cache'] ?? (window is Map ? window['cache'] : null);
    final hitRate = cache is Map ? _finiteNum(cache['hitRate']) : null;

    final items = <ContextUsageBreakdownItem>[];
    final breakdown =
        usage?['breakdown'] ?? (window is Map ? window['breakdown'] : null);
    if (breakdown is List) {
      // Aggregate per source, then rank: known sources by
      // the weight table, unknown ones after them in first-seen order.
      final bySource = <String, num>{};
      for (final e in breakdown) {
        if (e is! Map) continue;
        final source = e['source'];
        final chars = _finiteNum(e['chars']);
        if (source is! String || chars == null || chars <= 0) continue;
        bySource[source] = (bySource[source] ?? 0) + chars;
      }
      final total = bySource.values.fold<num>(0, (a, b) => a + b);
      final ranks = {
        for (final source in bySource.keys)
          source: _breakdownWeights[source] ??
              _breakdownWeights.length + bySource.keys.toList().indexOf(source),
      };
      if (total > 0) {
        final entries = bySource.entries.toList()
          ..sort((a, b) {
            final byChars = b.value.compareTo(a.value);
            if (byChars != 0) return byChars;
            return ranks[a.key]!.compareTo(ranks[b.key]!);
          });
        for (final e in entries) {
          items.add(
            ContextUsageBreakdownItem(
              source: e.key,
              chars: e.value,
              percent: e.value / total,
            ),
          );
        }
      }
    }
    return ContextUsageView(
      used: used?.toInt(),
      max: max?.toInt(),
      hitRate: hitRate?.toDouble().clamp(0.0, double.infinity).toDouble(),
      breakdown: items,
    );
  }

  /// Older history exists beyond the current window. Prefers the server's
  /// `hasMore` once known; falls back to the totalCount
  /// heuristic for the initial state.
  bool get canLoadOlder {
    if (firstRowId == null) return false;
    if (hasMore != null) return hasMore! && rows.isNotEmpty;
    return totalCount > rows.length;
  }

  /// Oldest row actually held — the rowsRange paging cursor. Snapshot
  /// `firstRowId` can be a placeholder (live-probed 1), so「加载更早」and
  /// the subagent sheet page back from this value instead.
  int? get oldestRowId {
    int? oldest;
    for (final r in rows) {
      final id = (r['rowId'] as num?)?.toInt();
      if (id != null && (oldest == null || id < oldest)) oldest = id;
    }
    return oldest;
  }

  /// Applies a conversationRowsRangeV4 response envelope: the web store
  /// drops the result when its log epoch no longer matches the live
  /// subscription, and pages on `hasMore`.
  bool rangeEnvelopeMatches(String? atLogEpoch) =>
      atLogEpoch == null || atLogEpoch == logEpoch;

  /// Prepends older rows loaded via rowsRange (deduped by rowId).
  ///
  /// The new cursor is the smallest ACTUALLY prepended rowId. Snapshot and
  /// response `firstRowId` can be a placeholder (live-probed 1 while real
  /// rows start far higher) — trusting it rewound the paging cursor and
  /// broke the second「加载更早」page, so the response value is ignored
  /// here; callers derive the request cursor from the held rows too.
  /// No fresh rows → no cursor write: the response carries no new evidence.
  /// Prepends older rows (deduped by rowId). Returns how many rows were
  /// actually inserted — 0 means the whole page was already held (a re-fire
  /// raced the prepend window), which the caller must NOT treat as a
  /// content shift (anchoring a no-op prepend jumps the view out and back).
  int prependOlderRows(List<Map<String, dynamic>> older) {
    final existing = rows.map((r) => (r['rowId'] as num?)?.toInt()).toSet();
    final fresh = older
        .where((r) => !existing.contains((r['rowId'] as num?)?.toInt()))
        .toList();
    if (fresh.isEmpty) return 0;
    int? firstFresh;
    for (final r in fresh) {
      final id = (r['rowId'] as num?)?.toInt();
      if (id != null && (firstFresh == null || id < firstFresh)) {
        firstFresh = id;
      }
    }
    rows = [...fresh, ...rows];
    if (firstFresh != null) firstRowId = firstFresh;
    notifyListeners();
    return fresh.length;
  }

  List<Map<String, dynamic>> get backgroundWorks {
    final list = snapshot?['backgroundWorks'];
    if (list is! List) return const [];
    return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// `subagents` typed: {revision, childSessionIds, running, endedTotal}.
  /// `running` entries carry childSessionId/agentId/toolCallId/subagentType/
  /// title/status/startedAt (live-probed 2026-09-13).
  Map<String, dynamic>? get subagentsInfo =>
      (snapshot?['subagents'] as Map?)?.cast<String, dynamic>();

  Map<String, dynamic>? get goal =>
      (snapshot?['goal'] as Map?)?.cast<String, dynamic>();

  Map<String, dynamic>? get plan =>
      (snapshot?['plan'] as Map?)?.cast<String, dynamic>();

  /// inputRouting: {mode: startNow|enqueue|guide|reject|choice, reasonCode?}
  String get inputRoutingMode =>
      (snapshot?['inputRouting'] as Map?)?['mode'] as String? ?? 'startNow';

  /// Pending interaction cards, two wire forms:
  /// - full interaction list (online `state.updated` deltas) — the snapshot
  ///   field is a List and is authoritative as-is;
  /// - summary count object `{permissionCount, userInputCount}` — the 3.12.3
  ///   snapshot assembly only projects the summary (session overlay),
  ///   so after a resubscribe the cards are rebuilt from the held rows
  ///   instead ([_rebuildPendingAskUserQuestions]).
  List<Map<String, dynamic>> get pendingInteractions {
    final list = snapshot?['pendingInteractions'];
    if (list is List) {
      return list
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    return _rebuildPendingAskUserQuestions();
  }

  /// Rebuilds pending AskUserQuestion interactions from the held rows.
  ///
  /// Waits on the agent core's permission request: a tool call row waiting
  /// on the user carries `status:'pendingApproval'` plus
  /// `approvalInteractionId` — the resolveInteraction id, derived
  /// server-side as `requestId ?? 'perm-${toolCallId}'` — and the questions
  /// travel in the row's `input`. The id is cleared (and the interaction
  /// settled) server-side on resolve, so its presence is the pending signal.
  /// Permission-kind interactions are not rebuilt: their option list is
  /// generated outside the row and cannot be recovered.
  List<Map<String, dynamic>> _rebuildPendingAskUserQuestions() {
    final rebuilt = <Map<String, dynamic>>[];
    for (final row in rows) {
      if (row['kind'] != 'toolCall') continue;
      final interactionId = row['approvalInteractionId'];
      if (interactionId is! String || interactionId.isEmpty) continue;
      if ('${row['toolName'] ?? ''}' != 'AskUserQuestion') continue;
      final input = row['input'] is Map
          ? (row['input'] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      rebuilt.add({
        'interactionId': interactionId,
        'kind': 'userInput',
        'anchorRowId': row['rowId'],
        'createdAt': row['createdAt'],
        'payload': {
          'kind': 'userInput',
          'freeText': true,
          'toolCallId': '${row['toolCallId'] ?? ''}',
          'toolName': 'AskUserQuestion',
          'input': input,
          'questions': _askUserQuestionsFromInput(input),
        },
      });
    }
    return rebuilt;
  }

  /// Normalizes the tool input's `questions` into the payload form the card
  /// consumes (agent core `oIs`): drop entries without question text or
  /// options, fall back header→question and label↔value, keep the rest
  /// verbatim.
  List<Map<String, dynamic>> _askUserQuestionsFromInput(
    Map<String, dynamic> input,
  ) {
    final raw = input['questions'];
    if (raw is! List) return const [];
    final questions = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final question = '${entry['question'] ?? ''}';
      final options = (entry['options'] as List?)?.whereType<Map>().toList();
      if (question.isEmpty || options == null || options.isEmpty) continue;
      final header = '${entry['header'] ?? ''}';
      questions.add({
        'question': question,
        'header': header.isNotEmpty ? header : question,
        if (entry['multiSelect'] == true) 'multiSelect': true,
        'options': [
          for (final option in options)
            if (_normalizedQuestionOption(option) case final o?) o,
        ],
      });
    }
    return questions;
  }

  /// One option's `value`/`label` fallback pair; null when both are empty.
  Map<String, dynamic>? _normalizedQuestionOption(Map option) {
    final label = '${option['label'] ?? ''}';
    final value = '${option['value'] ?? ''}';
    if (label.isEmpty && value.isEmpty) return null;
    return {
      'value': value.isNotEmpty ? value : label,
      'label': label.isNotEmpty ? label : value,
      if (option['description'] is String) 'description': option['description'],
    };
  }
}

/// Normalized view over [ConversationState.usage] (snapshot + merged
/// `usage_update` events). `used`/`max` are null when absent/invalid; the
/// sheet hides the section unless `hasData` (usage is hidden at
/// used/max <= 0).
class ContextUsageView {
  final int? used;
  final int? max;

  /// 0..1 when readable (clamped at 0).
  final double? hitRate;
  final List<ContextUsageBreakdownItem> breakdown;

  const ContextUsageView({
    this.used,
    this.max,
    this.hitRate,
    this.breakdown = const [],
  });

  bool get hasData => used != null && max != null && max! > 0;

  double? get ratio {
    if (used == null || max == null || max! <= 0) return null;
    return (used! / max!).clamp(0.0, 1.0);
  }
}

/// One aggregated breakdown row.
class ContextUsageBreakdownItem {
  final String source;
  final num chars;

  /// Share of the retained breakdown total, 0..1.
  final double percent;

  const ContextUsageBreakdownItem({
    required this.source,
    required this.chars,
    required this.percent,
  });
}
