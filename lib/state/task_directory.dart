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

/// Whether a workspace path names a 3.16.2 conversation (draft) workspace:
/// `<home>/.zcode/workspace/draft-*`.
///
/// Live 3.16.2 bootstrap frames do NOT carry `workspacePurpose` for draft
/// workspaces (acceptance round 1, 2026-10-22: draft rows are
/// `{kind:'local', label:'draft-…', workspacePath}`; only project rows carry
/// `workspacePurpose:'project'`), so the path is the only durable signal.
/// The marker matches the desktop's own task-area filter semantics
/// (`root_path NOT GLOB '*/.zcode/workspace/*'`, tool/design/
/// fix_task_project.py's DRAFT_DIR_MARK): slash-normalized `indexOf`, so
/// both Windows and POSIX spellings match. `~/.zcode/workspace/default` has
/// no `draft-` prefix and stays an ordinary group.
bool isConversationWorkspacePath(String path) {
  final normalized = path.replaceAll(r'\', '/');
  const marker = '/.zcode/workspace/draft-';
  return normalized.contains(marker);
}

/// Whether a listed workspace is a 3.16.2 conversation workspace: the
/// `workspacePurpose` marker (schema enum — future desktops may populate it)
/// OR the draft path convention (the live 3.16.2 shape). Single gate shared
/// by the merge layer, the card construction and the 「对话」 badge.
bool isConversationWorkspace(Map<String, dynamic> ws) {
  if (ws['workspacePurpose'] == 'conversation') return true;
  final path = ws['workspacePath'];
  return path is String && path.isNotEmpty && isConversationWorkspacePath(path);
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

  /// Group-key aliases: row ownership keys → display group keys. Used ONLY
  /// by the group assignment in [_merge] / [pinnedEntries]: 3.16.2
  /// conversation workspace paths redirect to the default group (design
  /// 10-21 A2a). Distinct from [keyAliases] on purpose — the latter also
  /// canonicalizes path/identity spellings for ANCHOR matching, a
  /// normalization that must not change a row's group (or its open-scope
  /// fallback). Defaults to empty = raw keys (pre-existing behavior).
  final Map<String, String> groupKeyAliases;

  /// Cached last live sessions-index snapshot per workspace key (design
  /// 10-15-task-live-snapshot-cache): the merge layer's gap filler. A row
  /// participates ONLY when neither the relay layer nor the ACTIVE live
  /// index carries its id — switching workspaces disposes the old
  /// subscription while the new session's registry row is still stuck in
  /// the desktop's stale overview cache, and without this layer the row
  /// vanishes until the workspace is re-entered. Evidence channels (anchor
  /// confirmation / reconcile / relay pick) never read it. Key =
  /// `subscribedWorkspaceKey` recorded at subscribe time; rows are
  /// probe- and tombstone-filtered at the write point.
  final Map<String, List<SessionEntry>> cachedSessions;

  const TaskDirectory({
    this.relayTasks = const [],
    this.sessions,
    this.locallyDeletedTaskIds = const {},
    this.confirmedHomeKeys = const {},
    this.keyAliases = const {},
    this.groupKeyAliases = const {},
    this.cachedSessions = const {},
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
      // The winner's exact value: a null (missing on the winning copy)
      // erases the home copy's own fields so the phase derives as
      // running-class exactly like the M1 rules. `status` is removed too —
      // the dual-read fallback would otherwise resurrect the home copy's
      // 3.16.2 value when the synthesized `displayStatus` is null.
      final synthesized = {...task, 'displayStatus': status}..remove('status');
      final entry = SessionEntry.fromRelayTask(synthesized);
      // Group key: the anchor pins it even when no copy carries the
      // anchored key anymore (transient — the relay-reconcile self-heal in
      // DeviceSession.reconcileTaskHomes follows the single-copy
      // evidence); otherwise the home copy's own key. The live loop below
      // still outranks a pinned key whenever the index is ready. Group
      // keys canonicalize through [groupKeyAliases] (conversation paths
      // merge into the default group — design 10-21 A2a).
      final rawKey = confirmedHomeKeys[id] ?? relayKeyOf(task);
      byId[id] = (entry, _canonicalKey(rawKey), task['archived'] == true);
    }
    if (sessions?.ready == true) {
      for (final entry in sessions!.list) {
        // Deleted-task tombstones: the live index still lists tasks the
        // user deleted on the desktop, and relay has no anchor row for
        // them — without this filter the live merge resurrects them
        // (Addendum 2, 2026-09-23 device report: default 12 → 22). The
        // local set covers deletes this device confirmed while the
        // desktop index (and its probe) lag behind.
        final id = entry.sessionId;
        if (sessions!.deletedTaskIds.contains(id) ||
            locallyDeletedTaskIds.contains(id)) {
          continue;
        }
        // Source marker (C1-D2): no surviving relay anchor above → the
        // row exists only in the live sessions-index.
        if (!byId.containsKey(id)) {
          sessionOnlyIds.add(id);
        }
        // Multi-copy ids (registry pollution, design 10-15
        // multi-copy-stable-group): the live index of EVERY workspace
        // carrying a copy claims membership, so liveKeyOf follows
        // whichever workspace is ACTIVE — switching = migration = the
        // "vanishing row" (PMA110 round-2 forensics, sess_b6f8f415). Keep
        // the relay-layer key (anchor ?? cold pick, stable on
        // untouchable fields); the live body still rides the row, so
        // status stays real-time.
        String? key;
        if (grouped[id] != null && grouped[id]!.length > 1) {
          // Canonicalize through keyAliases (§3.8 alias contract): the
          // cold-pick branch spells path-form while folders/live keys
          // are workspaceKeyOf-form — a raw path key matches no folder
          // and the row becomes unopenable.
          final relayKey = byId[id]?.$2;
          key = relayKey == null ? null : keyAliases[relayKey] ?? relayKey;
        }
        final membershipKey =
            liveKeyOf(entry, sessions!.subscribedWorkspaceKey);
        key ??= membershipKey;
        // Canonicalize membership keys too: a conversation workspace's
        // index is subscribed under its own draft path, yet its rows
        // display in the default group (design 10-21 A2a).
        key = _canonicalKey(key);
        // The live frame owns none of the archived bit (probed 3.12.1: the
        // field is absent, and a stray one is untrusted) — carry the relay
        // authority into the replacement row's raw so consumers reading
        // `entry.raw['archived']` (swipe / action sheet) still see it.
        final archived = byId[id]?.$3 ?? false;
        byId[id] = (
          SessionEntry({
            ..._stampedEntry(entry, membershipKey).raw,
            'archived': archived
          }),
          key,
          archived,
        );
      }
    }
    // Cached snapshots (third layer): gap filler only — any id the relay
    // layer or the active live index already carries wins, so this never
    // touches the anchored-home / pick semantics above. Same attribution
    // rule as the live loop (liveKeyOf with the snapshot's own key), so a
    // row keeps the group it had before the workspace was switched away
    // from. Archived is relay's sole authority → false, like live rows.
    for (final MapEntry(key: cacheKey, value: rows) in cachedSessions.entries) {
      for (final entry in rows) {
        final id = entry.sessionId;
        if (locallyDeletedTaskIds.contains(id)) continue;
        if (byId.containsKey(id)) continue;
        sessionOnlyIds.add(id);
        // No relay anchor → not archived. Stamp the raw bit too: the
        // cached row is live-derived and consumers read archived off
        // `entry.raw`, so an unstamped row would offer a bogus
        // 「取消归档」 that no registry row can resolve. The draft-path
        // stamp keeps a cached conversation row openable (see
        // [_stampedEntry]).
        final cacheRowKey = liveKeyOf(entry, cacheKey);
        byId[id] = (
          SessionEntry(
              {..._stampedEntry(entry, cacheRowKey).raw, 'archived': false}),
          _canonicalKey(cacheRowKey),
          false,
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
  ///
  /// Conversation rows are the exception to key-first matching: their
  /// [key] is the DEFAULT group (design 10-21 A2a display merge), but the
  /// session still lives under its own `.zcode/workspace/draft-*` scope.
  /// Resolving them by the display key would subscribe the default
  /// workspace and dead-end every command, so the row's own path wins
  /// whenever it names a listed conversation workspace.
  static Map<String, dynamic>? workspaceForKey(
    List<Map<String, dynamic>> workspaces,
    SessionEntry entry,
    String? key,
  ) {
    final originPath = entry.raw['workspacePath'];
    if (originPath is String && originPath.isNotEmpty) {
      for (final ws in workspaces) {
        if (isConversationWorkspace(ws) &&
            ws['workspacePath'] == originPath) {
          return ws;
        }
      }
    }
    for (final ws in workspaces) {
      if (key != null && workspaceKeyOf(ws) == key) return ws;
    }
    // No directory anchor (archived rows are filtered out of allEntries,
    // session-only rows never had one): the row's own origin fields still
    // say where it belongs — cross-workspace rows keep their chip.
    if (originPath is! String || originPath.isEmpty) return null;
    return {
      'workspacePath': originPath,
      if (entry.raw['workspaceIdentity'] != null)
        'workspaceIdentity': entry.raw['workspaceIdentity'],
    };
  }

  /// Whether a duplicate relay row for one task id displaces the row already
  /// kept — the COLD stable pick (design 10-15 §2.1, replacing the
  /// 2026-09-23 updatedAt rule whose input kept changing: every touched
  /// copy re-won and the group flapped). Pure function of STABLE fields
  /// only:
  /// 1. pinned copy first (10-16 pollution forensics): mirror copies don't
  ///    carry the user's pin — pin is a per-workspace registry field and
  ///    the user pins in the true home. Above createdAt/lex, both of which
  ///    are pollution-blind (copies share the birth millisecond, spec
  ///    §3.1; the lex order is a systemic bias — 'F:\ZLinker' beats every
  ///    lowercase-named workspace). The residual no-pin cases fall through
  ///    to the user adjudication channel (anchor source ④,
  ///    DeviceSession.correctTaskHome);
  /// 2. greater `createdAt` — mirror copies share the real row's creation
  ///    millisecond (spec §3.1), so this separates genuinely different
  ///    ages without ever flipping on activity;
  /// 3. lexicographically smaller workspace key — the mirror case's
  ///    deterministic tie-break.
  /// `updatedAt` is deliberately OUT of the comparison keys: it changes on
  /// every touch, and only a change in the row SET (a copy added or
  /// removed) may now move the pick — a touched copy cannot. Terminal
  /// status is OUT too (10-16): a settled copy outranking a live one made
  /// a RUNNING true row lose its group to a frozen mirror copy (both
  /// directions of the alive/frozen split occur in pollution, so it never
  /// discriminated) — terminal judgment lives in [displayStatusWinner],
  /// which decides the STATUS field only.
  static bool _relayRowBeats(
    SessionEntry candidate,
    String? candidateKey,
    SessionEntry incumbent,
    String? incumbentKey,
  ) {
    final candidatePinned = candidate.raw['pinned'] == true;
    final incumbentPinned = incumbent.raw['pinned'] == true;
    if (candidatePinned != incumbentPinned) return candidatePinned;
    if (candidate.createdAt != incumbent.createdAt) {
      return candidate.createdAt > incumbent.createdAt;
    }
    return (candidateKey ?? '').compareTo(incumbentKey ?? '') < 0;
  }

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
      // Dual-read (design 10-21-drift-3162 R4): 3.16.2 timeline rows carry
      // `status`, legacy bootstrap rows `displayStatus`; the legacy field
      // keeps precedence when both exist.
      final status = (task['displayStatus'] ?? task['status']) as String?;
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
    return best == null
        ? null
        : (best['displayStatus'] ?? best['status']) as String?;
  }

  /// The home relay row for [taskId] among its duplicates (desktop
  /// mirror copies) — the layered resolution of design 10-15 §2.1:
  /// 1. the anchored copy ([homeKeys][taskId]) when one still carries
  ///    that workspace key — the persisted anchor is the first layer.
  ///    Row keys canonicalize through [keyAliases] before the comparison
  ///    (check P1-2: the anchor is workspaceKeyOf-spelled, the row may be
  ///    path-spelled — same workspace, two strings);
  /// 2. otherwise the cold stable pick ([_relayRowBeats]: pinned →
  ///    createdAt → key lex, `updatedAt` and terminal status out of the
  ///    comparison keys).
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
    SessionEntry? anchorEntry;
    String? anchorKey;
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
      if (anchor != null && (keyAliases[key] ?? key) == anchor) {
        // Several copies can canonicalize to one anchor now that
        // conversation paths alias to their display group; pick among them
        // with the same stable rule instead of frame order.
        if (anchorRow == null ||
            _relayRowBeats(entry, key, anchorEntry!, anchorKey)) {
          anchorRow = task;
          anchorEntry = entry;
          anchorKey = key;
        }
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

  /// Canonicalizes a row / group key through [groupKeyAliases]: relay rows
  /// spell a workspace as `workspacePath`, live rows and folders in the
  /// [workspaceKeyOf] form, and 3.16.2 conversation paths alias to the
  /// default group. A miss keeps the raw key (aliases empty = old behavior).
  String? _canonicalKey(String? key) =>
      key == null ? null : groupKeyAliases[key] ?? key;

  /// Stamps the pre-canonicalization ownership key back into a LIVE / cached
  /// row's raw when the display merge rewrote its group: 3.16.2 live index
  /// rows carry no `workspacePath` (probe3162_p1 schema), so once the row
  /// merges into the default group nothing in its body names the draft
  /// workspace anymore — [workspaceForKey]'s conversation branch would fall
  /// through to the DEFAULT workspace and dead-end every command
  /// (proto.sessionNotFound). Only fires when the key was actually rewritten
  /// by [groupKeyAliases] (conversation workspaces carry no identity, so the
  /// raw key IS the path) and the raw lacks a path; every other row keeps
  /// its exact pre-merge body.
  SessionEntry _stampedEntry(SessionEntry entry, String? rawKey) {
    final raw = entry.raw;
    if (rawKey == null ||
        groupKeyAliases[rawKey] == null ||
        raw['workspacePath'] is String) {
      return entry;
    }
    return SessionEntry({...raw, 'workspacePath': rawKey});
  }

  /// Entries of one workspace, merged; archived rows in or out per
  /// [includeArchived].
  List<(SessionEntry, String?)> entriesFor(
    String workspaceKey, {
    bool includeArchived = false,
  }) =>
      [
        for (final (entry, key, archived) in _rows())
          if (key == workspaceKey && archived == includeArchived) (entry, key),
      ];

  /// Every non-archived task of the device — the page-wide set (timeline
  /// grouping et al).
  List<(SessionEntry, String?)> allEntries() => [
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
      final synthesized = {...task, 'displayStatus': status}..remove('status');
      final entry = SessionEntry.fromRelayTask(synthesized);
      // Same anchor-pins-the-group rule as [_merge], canonicalized through
      // [groupKeyAliases] so a conversation copy lands in the default group.
      final rawKey = confirmedHomeKeys[id] ?? relayKeyOf(task);
      byId[id] = (entry, _canonicalKey(rawKey));
    }
    if (sessions?.ready == true) {
      // Multi-copy attribution needs the FULL relay set: this projection's
      // own `grouped` above only holds pinned copies, so a multi-copy id
      // whose relay copies are all unpinned/stale would flip with the
      // active workspace here while staying stable in [_merge] (design
      // 10-15 multi-copy-stable-group §pinned, check P1-2).
      final allCopies = <String, List<Map<String, dynamic>>>{};
      for (final task in relayTasks) {
        final id = '${task['taskId'] ?? ''}';
        if (id.isEmpty) continue;
        if (locallyDeletedTaskIds.contains(id)) continue;
        (allCopies[id] ??= []).add(task);
      }
      for (final entry in sessions!.list) {
        // Same tombstone rules as [_rows] — deleted live rows never pin.
        final id = entry.sessionId;
        if (sessions!.deletedTaskIds.contains(id) ||
            locallyDeletedTaskIds.contains(id)) {
          continue;
        }
        if (entry.raw['pinned'] != true) continue;
        String? key;
        final copies = allCopies[id];
        if (copies != null && copies.length > 1) {
          // Anchor → canonicalized cold-pick key; null falls through to
          // the live attribution below (a null key would make the pinned
          // row unopenable — workspaceForKey skips list matching then
          // live rows carry no path).
          final anchored = confirmedHomeKeys[id];
          if (anchored != null) {
            key = anchored;
          } else {
            final task = bestRelayRow(
              copies,
              id,
              homeKeys: confirmedHomeKeys,
              keyAliases: keyAliases,
            );
            final rawKey = task == null ? null : relayKeyOf(task);
            if (rawKey != null) key = keyAliases[rawKey] ?? rawKey;
          }
        }
        key ??= liveKeyOf(entry, sessions!.subscribedWorkspaceKey);
        byId[id] = (entry, _canonicalKey(key));
      }
    }
    // Cached snapshots: same gap-filler rule as [_merge] — without this a
    // pinned row that survives via the cache would sit in its workspace
    // group yet vanish from the pinned section on the same page (check
    // P2-4).
    for (final MapEntry(key: cacheKey, value: rows) in cachedSessions.entries) {
      for (final entry in rows) {
        if (locallyDeletedTaskIds.contains(entry.sessionId)) continue;
        if (byId.containsKey(entry.sessionId)) continue;
        if (entry.raw['pinned'] == true) {
          byId[entry.sessionId] = (
            entry,
            _canonicalKey(liveKeyOf(entry, cacheKey)),
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
