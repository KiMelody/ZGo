import '../protocol/conversation.dart';

/// Workspace key:
/// key = workspaceIdentity?.trim() || workspacePath.
String? workspaceKeyOf(Map<String, dynamic> w) {
  final identity = w['workspaceIdentity'];
  if (identity is String && identity.trim().isNotEmpty) {
    return identity.trim();
  }
  final path = w['workspacePath'];
  if (path is String && path.isNotEmpty) return path;
  for (final key in const ['workspaceKey', 'key', 'id']) {
    final v = w[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

/// Merged view of every task on one device — the one home of the
/// 「relay 任务总览打底、live 会话索引按 Task id 胜出；同 id 多副本分层定
/// home（持久锚 → 冷启动稳定 pick），displayStatus 字段级合成」rule
/// (design 10-15). Live rows whose id is in the deleted-tombstone set
/// ([SessionsIndexState.deletedTaskIds]) are skipped — the desktop's live
/// index still lists tasks the user deleted (its session-library view has
/// no deleted concept) while the relay overview omits them, so unfiltered
/// they resurrect. Previously coded twice (task list page +
/// notification hub) with diverging archived handling; consumers now read
/// this projection instead.
///
/// Stateless: every read recomputes from the inputs, nothing is cached —
/// rows are tens, not thousands, and rebuilds already re-invoke the readers.
class TaskDirectory {
  /// Relay task overview (`Dg` maps from bootstrap /
  /// `workspace-list-updated`): every workspace's tasks.
  final List<Map<String, dynamic>> relayTasks;

  /// Live sessions-index of the subscribed workspace (null until subscribed).
  final SessionsIndexState? sessions;

  /// Locally-confirmed deletes (design 10-02 Step 3, persisted since
  /// design 10-15 §1.2 via the session's [TaskHomeStore]): task ids whose
  /// delete RPC returned success on this device. Unlike the probe-derived
  /// [SessionsIndexState.deletedTaskIds] — which guards the live loops
  /// only so a relay base row survives — this set filters BOTH sources:
  /// a successful delete is definitive, while the relay overview row can
  /// lag in memory when a reloadTasks response is swallowed by a bridge
  /// reopen. Owned by the session's [TaskHomeStore] — add-only with a
  /// 7-day TTL (check P1-1, 2026-10-15: a re-listing overview never lifts
  /// a tombstone; expiry is the only removal) — and re-read fresh on every
  /// [DeviceSession.taskDirectory] construction, so new tombstones are
  /// seen at once.
  final Set<String> locallyDeletedTaskIds;

  /// Persisted home anchors (design 10-15 §1.1, [TaskHomeStore] backed):
  /// task id → workspace key, written by three sources only — the phone
  /// itself creating the session (App = source of truth), a live
  /// confirmation while the id's relay set holds exactly one copy, and a
  /// live confirmation agreeing with an existing anchor (refresh). The
  /// FIRST layer of home resolution: the anchored copy becomes the home
  /// row and its key the group, ahead of the cold pick — a bridge swing's
  /// resubscribe window (live coverage down) can no longer flip a
  /// confirmed row's group, and neither can a touched copy. Multi-copy
  /// ids' live frames never establish or flip an anchor (the
  /// anti-pollution gate lives on the session's confirmLiveHomes). Aliased
  /// without copying, like [locallyDeletedTaskIds]; a cold start passes
  /// the empty map and keeps the pure cold-pick behavior.
  final Map<String, String> confirmedHomeKeys;

  /// Workspace key aliases (check P1-2, 2026-10-15): path-spelled →
  /// canonical [workspaceKeyOf]-spelled keys, built by the session from its
  /// workspace list. [bestRelayRow]'s anchor matching canonicalizes each
  /// row's key through this before comparing against the anchor (which the
  /// session always writes in canonical spelling), so one workspace
  /// carrying two string forms cannot read as a move. Defaults to empty =
  /// raw comparison (every pre-existing call site's behavior unchanged).
  final Map<String, String> keyAliases;

  const TaskDirectory({
    this.relayTasks = const [],
    this.sessions,
    this.locallyDeletedTaskIds = const {},
    this.confirmedHomeKeys = const {},
    this.keyAliases = const {},
  });

  /// Merged rows plus the source marker of the live rows
  /// ([sessionOnlyIds]) — one pass so the marker can never drift from the
  /// merge itself. The pick / override rules below are unchanged by the
  /// marker; it only observes which live rows found no surviving relay
  /// anchor.
  ///
  /// Merged rows: relay base, live override per task id. Each row carries
  /// its workspace key and the archived flag read off the RELAY map only —
  /// the relay `archived` field is the sole authority (live-probed
  /// bootstrap frame; live sessions-index frames carry no reliable
  /// `archived` field, so the old `entry.raw['archived']` fallback is gone
  /// — R1, 2026-09-17). Unarchive propagates back via
  /// workspace-list-updated. Rows without a task id are dropped — nothing
  /// can address them.
  ///
  /// Live rows attribute by the INDEX's subscription identity
  /// ([liveKeyOf]): the live sessions-index is the product of
  /// `listSessions(directory = workspace)`, so membership in it IS the
  /// ground truth of a session's home — it outranks even the
  /// corrected relay pick key (2026-09-23 emulator acceptance:
  /// inheriting that key could keep a desktop copy's key, leaving the
  /// session viewable in the wrong group but unoperable). Live-only rows
  /// (not yet in the relay overview) key off their own fields first, then
  /// the same subscription identity
  /// ([SessionsIndexState.subscribedWorkspaceKey]) — recorded at subscribe
  /// time, the data self-certifies its home and stays immune to the
  /// page-level switch / re-subscribe drift window.
  ({List<(SessionEntry, String?, bool)> rows, Set<String> sessionOnlyIds})
      _merge() {
    final byId = <String, (SessionEntry, String?, bool)>{};
    final sessionOnlyIds = <String>{};
    // Relay phase, group + pick: duplicate rows (desktop mirror copies)
    // collect per id first, then [bestRelayRow] resolves each group — the
    // SAME pure pick the mutation scope reads
    // (DeviceSession._taskMutationScope), so the row a user sees IS the
    // row a delete addresses. Grouping key mirrors
    // [SessionEntry.fromRelayTask] ('${task['taskId'] ?? ''}' — same
    // derivation as the entry's sessionId, so a null/missing taskId is ''
    // and drops here instead of grouping under the literal string 'null'
    // and dead-ending the pick's null-assert), and the tombstone /
    // empty-id filters keep their original order ahead of it.
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final task in relayTasks) {
      final id = '${task['taskId'] ?? ''}';
      if (id.isEmpty) continue;
      // Locally-confirmed delete: drop the relay row too — the overview
      // in memory may be stale (see [locallyDeletedTaskIds]).
      if (locallyDeletedTaskIds.contains(id)) continue;
      (grouped[id] ??= []).add(task);
    }
    for (final MapEntry(key: id, value: rows) in grouped.entries) {
      // Layered home (design 10-15 §2.1): the anchored copy when one still
      // carries the anchored key, else the cold stable pick ([bestRelayRow]
      // — the SAME pure pick the mutation scope reads, so the row a user
      // sees IS the row a delete addresses).
      final task = bestRelayRow(
        rows,
        id,
        homeKeys: confirmedHomeKeys,
        keyAliases: keyAliases,
      )!;
      // Field-level synthesis (design 10-15 §2.2): the body fields
      // (title/pinned/archived/unreadAt/lastError/workspace) ride the home
      // copy; `displayStatus` comes from the M1 terminal-first winner over
      // the WHOLE group ([displayStatusWinner]) — the same selection
      // DeviceSession.taskDisplayStatus reads, the two former picks merged.
      final status = displayStatusWinner(rows, id);
      final entry = SessionEntry.fromRelayTask({
        ...task,
        // The winner's exact value: a null (missing on the winning copy)
        // erases the home copy's own field so the phase derives as
        // running-class exactly like the M1 rules.
        'displayStatus': status,
      });
      // Group key: the anchor pins it even when no copy carries the
      // anchored key anymore (transient — the relay-reconcile self-heal in
      // DeviceSession.reconcileTaskHomes follows the single-copy
      // evidence); otherwise the home copy's own key. The live loop below
      // still outranks a pinned key whenever the index is ready.
      final key = confirmedHomeKeys[id] ?? relayKeyOf(task);
      byId[id] = (entry, key, task['archived'] == true);
    }
    if (sessions?.ready == true) {
      for (final entry in sessions!.list) {
        // Deleted-task tombstones: the live index still lists tasks the
        // user deleted on the desktop, and relay has no anchor row for
        // them — without this filter the live merge resurrects them
        // (Addendum 2, 2026-09-23 device report: default 12 → 22). The
        // local set covers deletes this device confirmed while the
        // desktop index (and its probe) lag behind.
        if (sessions!.deletedTaskIds.contains(entry.sessionId) ||
            locallyDeletedTaskIds.contains(entry.sessionId)) {
          continue;
        }
        // Source marker (C1-D2): no surviving relay anchor above → the
        // row exists only in the live sessions-index.
        if (!byId.containsKey(entry.sessionId)) {
          sessionOnlyIds.add(entry.sessionId);
        }
        byId[entry.sessionId] = (
          entry,
          liveKeyOf(entry, sessions!.subscribedWorkspaceKey),
          byId[entry.sessionId]?.$3 ?? false,
        );
      }
    }
    return (rows: byId.values.toList(), sessionOnlyIds: sessionOnlyIds);
  }

  List<(SessionEntry, String?, bool)> _rows() => _merge().rows;

  /// Ids of rows that exist ONLY in the live sessions-index — no
  /// surviving task-registry (relay) anchor behind them (design C1-D2).
  /// The desktop parks fork drafts in the session library with
  /// `persistence:'deferred'`, deliberately skipping the task index
  /// (createZCodeDeferredDraftRegistry, research.md R2): these rows have
  /// no registry row, so registry mutations (deleteTask…) can never
  /// resolve them — consumers route them to session commands instead.
  /// Recomputed with the merge like every other read (stateless class);
  /// a late relay row unmarks the id on the next read, mirroring how the
  /// row itself gains its anchor.
  Set<String> get sessionOnlyIds => _merge().sessionOnlyIds;

  /// Workspace key of a LIVE sessions-index row (not yet in the relay
  /// overview): its own fields under the same rule as [relayKeyOf], then
  /// the index's subscription identity ([SessionsIndexState
  /// .subscribedWorkspaceKey]).
  static String? liveKeyOf(SessionEntry entry, String? fallback) {
    final identity = entry.raw['workspaceIdentity'];
    if (identity is String && identity.trim().isNotEmpty) {
      return identity.trim();
    }
    final path = entry.raw['workspacePath'];
    if (path is String && path.isNotEmpty) return path;
    return fallback;
  }

  /// Workspace key of a relay task (`Dg.workspaceIdentity ?? workspacePath`,
  /// same rule as `workspaceKeyOf`).
  static String? relayKeyOf(Map<String, dynamic> task) {
    final identity = task['workspaceIdentity'];
    if (identity is String && identity.trim().isNotEmpty) {
      return identity.trim();
    }
    final path = task['workspacePath'];
    if (path is String && path.isNotEmpty) return path;
    return null;
  }

  /// The workspace behind a directory key: the listed workspace whose
  /// [workspaceKeyOf] matches, else a minimal scope built from the task
  /// row's own origin fields (`workspacePath`/`workspaceIdentity` — relay
  /// overview and sessions-index rows carry them). The fallback covers the
  /// key divergence between the overview and the workspace list: without
  /// it, opening a foreign task silently reused the active workspace's
  /// scope and the server rejected every command (proto.sessionNotFound —
  /// the "can see, can't act" dead page). Only fields the row actually
  /// carries go into the map (path required — every scoped wire call needs
  /// it); null means ownership is undeterminable and the caller must not
  /// open the chat.
  static Map<String, dynamic>? workspaceForKey(
    List<Map<String, dynamic>> workspaces,
    SessionEntry entry,
    String? key,
  ) {
    for (final ws in workspaces) {
      if (key != null && workspaceKeyOf(ws) == key) return ws;
    }
    // No directory anchor (archived rows are filtered out of allEntries,
    // session-only rows never had one): the row's own origin fields still
    // say where it belongs — cross-workspace rows keep their chip.
    final path = entry.raw['workspacePath'];
    if (path is! String || path.isEmpty) return null;
    return {
      'workspacePath': path,
      if (entry.raw['workspaceIdentity'] != null)
        'workspaceIdentity': entry.raw['workspaceIdentity'],
    };
  }

  /// Whether a duplicate relay row for one task id displaces the row already
  /// kept — the COLD stable pick (design 10-15 §2.1, replacing the
  /// 2026-09-23 updatedAt rule whose input kept changing: every touched
  /// copy re-won and the group flapped). Pure function of STABLE fields
  /// only:
  /// 1. terminal status first (completed|error beats running-class) — a
  ///    settled copy outranks a zombie running one (the §3.6 direction);
  /// 2. greater `createdAt` — mirror copies share the real row's creation
  ///    millisecond (spec §3.1), so this separates genuinely different
  ///    ages without ever flipping on activity;
  /// 3. lexicographically smaller workspace key — the mirror case's
  ///    deterministic tie-break.
  /// `updatedAt` is deliberately OUT of the comparison keys: it changes on
  /// every touch, and only a change in the row SET (a copy added or
  /// removed) may now move the pick — a touched copy cannot. Terminal
  /// classes read the mapped phase ([SessionEntry.fromRelayTask]:
  /// completed→completedSuccess, error→error); unrecognized values count
  /// as running-class (spec §3.6 rule 4).
  static bool _relayRowBeats(
    SessionEntry candidate,
    String? candidateKey,
    SessionEntry incumbent,
    String? incumbentKey,
  ) {
    final candidateTerminal = _isTerminalPhase(candidate.phase);
    final incumbentTerminal = _isTerminalPhase(incumbent.phase);
    if (candidateTerminal != incumbentTerminal) return candidateTerminal;
    if (candidate.createdAt != incumbent.createdAt) {
      return candidate.createdAt > incumbent.createdAt;
    }
    return (candidateKey ?? '').compareTo(incumbentKey ?? '') < 0;
  }

  /// Terminal phases after [SessionEntry.fromRelayTask]'s mapping
  /// (displayStatus completed|error → completedSuccess|error); everything
  /// else — including unrecognized values — is running-class.
  static bool _isTerminalPhase(String phase) =>
      phase == 'completedSuccess' || phase == 'error';

  /// The M1 displayStatus pick over one id's relay copies (spec
  /// task-registry-semantics §3.6, 2026-10-11) — moved here from
  /// DeviceSession.taskDisplayStatus as the SHARED static behind both the
  /// synthesized row's status (field-level synthesis, design 10-15 §2.2)
  /// and [DeviceSession.taskDisplayStatus], so the two former picks can no
  /// longer disagree. The rule itself is UNCHANGED from M1 — this one
  /// keeps `updatedAt` as its same-class tie-break on purpose: it decides
  /// the STATUS field only, never the grouping (a touched copy may flip a
  /// status string inside one class, never the row's group):
  /// 1. terminal (completed|error) beats running-class;
  /// 2. same class → greater updatedAt (the real row keeps receiving
  ///    activity updates while its copies freeze at registration);
  /// 3. remaining ties → lexicographically smaller workspacePath, then
  ///    the status string (total order backstop);
  /// 4. unrecognized / missing values count as running-class.
  static String? displayStatusWinner(
    List<Map<String, dynamic>> relayTasks,
    String taskId,
  ) {
    const terminalStatuses = {'completed', 'error'};
    ({bool terminal, int updatedAt, String workspace, String status}) rankOf(
      Map<String, dynamic> task,
    ) {
      final status = task['displayStatus'] as String?;
      return (
        terminal: terminalStatuses.contains(status),
        updatedAt: (task['updatedAt'] as num?)?.toInt() ?? 0,
        workspace: '${task['workspacePath'] ?? ''}',
        status: status ?? '',
      );
    }

    bool beats(
      ({bool terminal, int updatedAt, String workspace, String status}) c,
      ({bool terminal, int updatedAt, String workspace, String status}) i,
    ) {
      if (c.terminal != i.terminal) return c.terminal;
      if (c.updatedAt != i.updatedAt) return c.updatedAt > i.updatedAt;
      if (c.workspace != i.workspace) {
        return c.workspace.compareTo(i.workspace) < 0;
      }
      return c.status.compareTo(i.status) < 0;
    }

    Map<String, dynamic>? best;
    var bestRank = (terminal: false, updatedAt: 0, workspace: '', status: '');
    for (final task in relayTasks) {
      // Same id derivation as the grouping key / sessionId.
      if ('${task['taskId'] ?? ''}' != taskId) continue;
      final rank = rankOf(task);
      if (best == null || beats(rank, bestRank)) {
        best = task;
        bestRank = rank;
      }
    }
    return best?['displayStatus'] as String?;
  }

  /// The home relay row for [taskId] among its duplicates (desktop
  /// mirror copies) — the layered resolution of design 10-15 §2.1:
  /// 1. the anchored copy ([homeKeys][taskId]) when one still carries
  ///    that workspace key — the persisted anchor is the first layer.
  ///    Row keys canonicalize through [keyAliases] before the comparison
  ///    (check P1-2: the anchor is workspaceKeyOf-spelled, the row may be
  ///    path-spelled — same workspace, two strings);
  /// 2. otherwise the cold stable pick ([_relayRowBeats]: terminal →
  ///    createdAt → key lex, `updatedAt` out of the comparison keys).
  /// Frame order never decides. Consumed by [_merge], [pinnedEntries] and
  /// `DeviceSession._taskMutationScope` — the mutation address must be the
  /// visible (home) row, not the first row in frame order (the desktop
  /// resolves mutations by the exact taskId+scope triple, so a frame-order
  /// pick addresses a twin copy while the visible row stays, 2026-10-11).
  /// Deliberately NO tombstone filtering — that stays on the [_merge]
  /// consumption side; the scope caller cannot hit a tombstone anyway (a
  /// task enters that set only after its delete succeeded).
  static Map<String, dynamic>? bestRelayRow(
    List<Map<String, dynamic>> relayTasks,
    String taskId, {
    Map<String, String> homeKeys = const {},
    Map<String, String> keyAliases = const {},
  }) {
    final anchor = homeKeys[taskId];
    Map<String, dynamic>? anchorRow;
    Map<String, dynamic>? best;
    SessionEntry? bestEntry;
    String? bestKey;
    for (final task in relayTasks) {
      // Same id derivation as the grouping key / sessionId ('?? ''': a
      // null/missing taskId never matches a real id).
      if ('${task['taskId'] ?? ''}' != taskId) continue;
      final entry = SessionEntry.fromRelayTask(task);
      if (entry.sessionId.isEmpty) continue;
      final key = relayKeyOf(task);
      if (anchor != null &&
          anchorRow == null &&
          (keyAliases[key] ?? key) == anchor) {
        anchorRow = task;
      }
      if (best == null || _relayRowBeats(entry, key, bestEntry!, bestKey)) {
        best = task;
        bestEntry = entry;
        bestKey = key;
      }
    }
    // The anchor pins the home copy; when no copy still carries the
    // anchored key the cold pick stands in as the body while the group
    // key stays anchored (callers read confirmedHomeKeys for it).
    return anchorRow ?? best;
  }

  /// Entries of one workspace, merged; archived rows in or out per
  /// [includeArchived].
  List<(SessionEntry, String?)> entriesFor(
    String workspaceKey, {
    bool includeArchived = false,
  }) =>
      [
        for (final (entry, key, archived) in _rows())
          if (key == workspaceKey && archived == includeArchived)
            (entry, key),
      ];

  /// Every non-archived task of the device — the page-wide set (timeline
  /// grouping et al).
  List<(SessionEntry, String?)> allEntries() =>
      [
        for (final (entry, key, archived) in _rows())
          if (!archived) (entry, key),
      ];

  /// Pinned tasks across the device, most recently active first. Live rows
  /// win per task id and keep a pinned live task even when archived.
  /// Archived live tasks remain pinned. Duplicate pinned relay rows
  /// resolve through the SAME layered home + field synthesis as [_merge]
  /// (design 10-15) — the pinned section can no longer disagree with the
  /// main list about a twin's body or status.
  List<(SessionEntry, String?)> pinnedEntries() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final task in relayTasks) {
      if (task['pinned'] != true || task['archived'] == true) continue;
      final id = '${task['taskId'] ?? ''}';
      if (id.isEmpty) continue;
      // Same locally-deleted rule as [_rows] — a confirmed delete never
      // pins, whatever the stale overview says.
      if (locallyDeletedTaskIds.contains(id)) continue;
      (grouped[id] ??= []).add(task);
    }
    final byId = <String, (SessionEntry, String?)>{};
    for (final MapEntry(key: id, value: rows) in grouped.entries) {
      final task = bestRelayRow(
        rows,
        id,
        homeKeys: confirmedHomeKeys,
        keyAliases: keyAliases,
      );
      if (task == null) continue;
      final status = displayStatusWinner(rows, id);
      final entry = SessionEntry.fromRelayTask({
        ...task,
        'displayStatus': status,
      });
      // Same anchor-pins-the-group rule as [_merge].
      byId[id] = (entry, confirmedHomeKeys[id] ?? relayKeyOf(task));
    }
    if (sessions?.ready == true) {
      for (final entry in sessions!.list) {
        // Same tombstone rules as [_rows] — deleted live rows never pin.
        if (sessions!.deletedTaskIds.contains(entry.sessionId) ||
            locallyDeletedTaskIds.contains(entry.sessionId)) {
          continue;
        }
        if (entry.raw['pinned'] == true) {
          byId[entry.sessionId] = (
            entry,
            liveKeyOf(entry, sessions!.subscribedWorkspaceKey),
          );
        }
      }
    }
    final list = byId.values.toList()
      ..sort((a, b) => b.$1.lastActivityAt.compareTo(a.$1.lastActivityAt));
    return list;
  }

  /// Task count for the summary line: all non-archived relay
  /// tasks, falling back to the live index when no overview has arrived.
  /// Locally-confirmed deletes come off the relay count (the live
  /// fallback stays raw — same accepted over-count as the probe
  /// tombstones, task-registry-semantics §4).
  int get totalTaskCount {
    final relay = relayTasks
        .where(
          (t) =>
              t['archived'] != true &&
              !locallyDeletedTaskIds.contains(t['taskId']),
        )
        .length;
    if (relay > 0) return relay;
    return sessions?.list.where((e) => e.raw['archived'] != true).length ?? 0;
  }

  /// Merged rows for phase diffing (the notification hub's view). Archived
  /// tasks STAY in the notification scope — a task archived mid-run must
  /// still report its completion — and the default makes that ruling
  /// explicit in the signature instead of a comment (Q3a).
  List<SessionEntry> notificationRows({bool includeArchived = true}) => [
        for (final (entry, _, archived) in _rows())
          if (includeArchived || !archived) entry,
      ];
}
