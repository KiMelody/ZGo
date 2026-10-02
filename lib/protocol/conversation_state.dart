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
    });
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
        for (final d in deltas) {
          if (d is Map) _applyDelta(d.cast<String, dynamic>());
        }
      }
      seq = toSeq;
    }
    ready = true;
    notifyListeners();
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
          if (snapshot != null) {
            snapshot = {...snapshot!, ...patch.cast<String, dynamic>()};
          } else {
            // Patch arrived before the initial snapshot — buffer and
            // merge when the snapshot lands (otherwise config/queue/
            // control updates are silently lost).
            _pendingPatch = {
              ...?_pendingPatch,
              ...patch.cast<String, dynamic>(),
            };
          }
        }
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
