import 'channel_client.dart';
import 'method_probe.dart';

/// Typed results of the desktop `gitService` (`git` channel). Field names are
/// the desktop zod shapes (research `design-inputs.md` §1, static forensics
/// of the 3.14.x bundle); parsing is defensive — a missing primary field
/// throws a [StateError] naming the port instead of degrading to empty data.
///
/// Method names are probed at runtime ([MethodProbe]) with BOTH naming sets
/// in the candidate table: the remote facade names first (`getChanges` /
/// `stagePaths` / …) because they have UI-call evidence, then the internal
/// service names (`getStatus` / `stage` / …) trailing, so a divergent desktop
/// build still resolves on the first probe.
class GitRepositoryInfo {
  /// `main-tree` | `linked-worktree` | `not-repository` ('' when the desktop
  /// answered a summary shape without `kind`).
  final String kind;
  final bool isRepository;
  final bool isGitAvailable;
  final String? branchName;
  final String? trackingBranchName;

  /// `branch` | `detached`.
  final String? headRefType;
  final int ahead;
  final int behind;
  final bool isDirty;

  const GitRepositoryInfo({
    required this.kind,
    required this.isRepository,
    required this.isGitAvailable,
    this.branchName,
    this.trackingBranchName,
    this.headRefType,
    this.ahead = 0,
    this.behind = 0,
    this.isDirty = false,
  });

  bool get isNotRepository => kind == 'not-repository' || !isRepository;
  bool get isDetached => headRefType == 'detached';
}

/// One changed-file row (`Mg buildFileChange`, @270657934): the desktop
/// answers absolute `path` plus workspace/repo-relative forms.
class GitChangeEntry {
  final String path;
  final String? repoRelativePath;
  final String? workspaceRelativePath;

  /// `modified` | `added` | `deleted` | `renamed` ('' when unknown).
  final String kind;

  /// `staged` | `unstaged` | `untracked` | `conflicted`.
  final String section;
  final int added;
  final int removed;
  final bool isStaged;
  final bool isUntracked;
  final bool isConflicted;

  const GitChangeEntry({
    required this.path,
    this.repoRelativePath,
    this.workspaceRelativePath,
    this.kind = '',
    this.section = '',
    this.added = 0,
    this.removed = 0,
    this.isStaged = false,
    this.isUntracked = false,
    this.isConflicted = false,
  });

  /// The path shown to the user: workspace-relative when the desktop gives
  /// it, else repo-relative, else the absolute path.
  String get displayPath {
    final ws = workspaceRelativePath;
    if (ws != null && ws.isNotEmpty) return ws;
    final repo = repoRelativePath;
    if (repo != null && repo.isNotEmpty) return repo;
    return path;
  }
}

/// `{fileCount, totalAdded, totalRemoved}` aggregate — computed client-side
/// over the change rows when the desktop does not ship explicit stats (the
/// official UI sums likewise, @315028049).
class GitChangeStats {
  final int fileCount;
  final int added;
  final int removed;
  const GitChangeStats({
    this.fileCount = 0,
    this.added = 0,
    this.removed = 0,
  });

  static const empty = GitChangeStats();

  /// Sums the rows of one section (the client-side fallback).
  factory GitChangeStats.of(Iterable<GitChangeEntry> rows) {
    var files = 0, added = 0, removed = 0;
    for (final r in rows) {
      files++;
      added += r.added;
      removed += r.removed;
    }
    return GitChangeStats(fileCount: files, added: added, removed: removed);
  }
}

/// `getChanges` / `getStatus` answer: the changed rows plus the staged and
/// unstaged aggregates.
class GitChanges {
  final List<GitChangeEntry> entries;
  final GitChangeStats stagedStats;
  final GitChangeStats unstagedStats;

  const GitChanges({
    this.entries = const [],
    this.stagedStats = GitChangeStats.empty,
    this.unstagedStats = GitChangeStats.empty,
  });

  static const empty = GitChanges();

  Iterable<GitChangeEntry> get staged =>
      entries.where((e) => e.section == 'staged' || e.isStaged);
  Iterable<GitChangeEntry> get unstaged => entries.where(
      (e) => e.section == 'unstaged' || (!e.isStaged && !e.isUntracked));
  Iterable<GitChangeEntry> get untracked =>
      entries.where((e) => e.section == 'untracked' || e.isUntracked);
  Iterable<GitChangeEntry> get conflicted =>
      entries.where((e) => e.section == 'conflicted' || e.isConflicted);
}

class GitBranchInfo {
  final String name;
  final bool isCurrent;
  final String? upstreamName;
  final String? commitHash;
  final int? commitTimestampMs;
  const GitBranchInfo({
    required this.name,
    this.isCurrent = false,
    this.upstreamName,
    this.commitHash,
    this.commitTimestampMs,
  });
}

class GitBranchList {
  final String? headRefType;
  final String? currentBranchName;
  final List<GitBranchInfo> branches;
  const GitBranchList({
    this.headRefType,
    this.currentBranchName,
    this.branches = const [],
  });

  static const empty = GitBranchList();

  bool get isDetached => headRefType == 'detached';
}

/// The eight `switchBranch` issue codes (parseGitBranchMutationIssues
/// @270626278 + server-side pre-check @270648036).
enum GitBranchIssueCode {
  trackedOverwrite,
  untrackedOverwrite,
  branchAlreadyExists,
  targetBranchNotFound,
  branchInOtherWorktree,
  conflictsPresent,
  operationInProgress,
  unknown;

  static GitBranchIssueCode parse(String wire) => switch (wire) {
        'tracked-changes-would-be-overwritten' => trackedOverwrite,
        'untracked-changes-would-be-overwritten' => untrackedOverwrite,
        'branch-already-exists' => branchAlreadyExists,
        'target-branch-not-found' => targetBranchNotFound,
        'branch-in-other-worktree' => branchInOtherWorktree,
        'conflicts-present' => conflictsPresent,
        'operation-in-progress' => operationInProgress,
        _ => unknown,
      };
}

class GitBranchIssue {
  final GitBranchIssueCode code;
  final String? message;
  final List<String> paths;
  final String? detail;
  const GitBranchIssue({
    required this.code,
    this.message,
    this.paths = const [],
    this.detail,
  });
}

/// Structured `switchBranch` result — the desktop answers `{ok:false, issues}`
/// instead of throwing.
class GitBranchMutationResult {
  final bool ok;
  final bool didChange;
  final bool created;
  final String? branchName;
  final List<GitBranchIssue> issues;
  final GitRepositoryInfo? summary;
  const GitBranchMutationResult({
    required this.ok,
    this.didChange = false,
    this.created = false,
    this.branchName,
    this.issues = const [],
    this.summary,
  });

  factory GitBranchMutationResult.fromMap(Map<dynamic, dynamic> map) {
    final rawIssues = map['issues'];
    return GitBranchMutationResult(
      ok: map['ok'] == true,
      didChange: map['didChange'] == true,
      created: map['created'] == true,
      branchName: map['branchName'] is String
          ? map['branchName'] as String
          : null,
      issues: [
        if (rawIssues is List)
          for (final i in rawIssues)
            if (i is Map)
              GitBranchIssue(
                code: GitBranchIssueCode.parse('${i['code'] ?? ''}'),
                message: i['message'] is String ? i['message'] as String : null,
                paths: [
                  if (i['paths'] is List)
                    for (final p in (i['paths'] as List))
                      if (p is String) p,
                ],
                detail: i['detail'] is String ? i['detail'] as String : null,
              ),
      ],
      summary: map['summary'] is Map
          ? parseGitRepositoryInfo(map['summary'])
          : null,
    );
  }
}

/// `getDiff` answer; `availability` ∈ `patch|binary|truncated|unavailable`.
class GitDiff {
  final String path;
  final String availability;
  final String? patch;
  final String? summary;
  const GitDiff({
    required this.path,
    required this.availability,
    this.patch,
    this.summary,
  });

  bool get isPatch => availability == 'patch' || availability.isEmpty;
}

class GitIdentity {
  final String? userName;
  final String? userEmail;
  final String? scopeLabel;
  const GitIdentity({this.userName, this.userEmail, this.scopeLabel});

  /// The desktop answers null fields on a non-repo workspace; the UI blocks
  /// commit on either field missing (not a server error code).
  bool get isMissing =>
      (userName == null || userName!.isEmpty) ||
      (userEmail == null || userEmail!.isEmpty);
}

class GitCommitResult {
  final String? commitHash;
  final String? summary;
  const GitCommitResult({this.commitHash, this.summary});
}

class GitPushResult {
  final String? branchName;
  final String? trackingBranchName;
  final String? remoteName;
  final bool setUpstream;
  final String? summary;
  const GitPushResult({
    this.branchName,
    this.trackingBranchName,
    this.remoteName,
    this.setUpstream = false,
    this.summary,
  });
}

/// Workspace Git operations on the desktop `git` channel (`Channels.git`, a
/// fixed channel name outside the probing surface).
///
/// Read surface: [repositoryInfo] (non-repo verdict `kind:'not-repository'`),
/// [refresh], [getChanges], [getLocalBranches], [getDiff], [getIdentity].
/// Write surface: [switchBranch], [stagePaths], [unstagePaths], [commit],
/// [push], [generateCommitMessage]. `discardPaths` is deliberately NOT
/// wired — the official review panel has it but it is destructive and out of
/// scope for this task (recorded in the task research as backlog).
///
/// Two error tracks follow the desktop: [switchBranch] answers a structured
/// `{ok:false, issues}` (never throws for branch conflicts) while
/// commit/push/generate surface their failures as thrown [ChannelRpcError]s
/// (raw git stderr). identityMissing is a client-side verdict from
/// [getIdentity] returning null fields.
class GitPort {
  /// Binds one RPC: the channel is fixed by the port owner, method/args vary.
  final Future<dynamic> Function(String method, List<Object?> args) call;

  GitPort(this.call);

  late final MethodProbe _probe = MethodProbe(call);

  // Candidate tables (new→old): remote facade names first (UI-call evidence
  // @314985630/@315014733), internal service names trailing.
  static const _repoInfoCandidates = [
    'getRepositorySummary',
    'getWorkspaceRepositoryInfo',
    'getStatus',
  ];
  static const _refreshCandidates = ['refresh'];
  static const _changesCandidates = ['getChanges', 'getStatus'];
  static const _branchesCandidates = ['getLocalBranches', 'listLocalBranches'];
  static const _switchCandidates = ['switchBranch'];
  static const _stageCandidates = ['stagePaths', 'stage'];
  static const _unstageCandidates = ['unstagePaths', 'unstage'];
  static const _diffCandidates = ['getDiff'];
  static const _identityCandidates = ['getIdentity'];
  static const _generateCandidates = ['generateCommitMessage'];
  static const _commitCandidates = ['commit'];
  static const _pushCandidates = ['push'];

  Map<String, dynamic> _scope(String workspacePath, [Map<String, dynamic>? extra]) =>
      {'workspacePath': workspacePath, ...?extra};

  static Map<dynamic, dynamic> _asMap(dynamic res, String op) {
    if (res is! Map) {
      throw StateError('gitService.$op: unexpected answer ${res.runtimeType}');
    }
    return res;
  }

  /// Repository verdict. Accepts BOTH answer shapes — the
  /// `getWorkspaceRepositoryInfo` `{kind}` form and the `getRepositorySummary`
  /// summary form (`isRepository` / `isGitAvailable`) — so one op key covers
  /// the naming variants.
  Future<GitRepositoryInfo> repositoryInfo(String workspacePath) async {
    final res = await _probe.run(
      'getRepositorySummary',
      _repoInfoCandidates,
      argsOf: (_) => <Object?>[_scope(workspacePath)],
    );
    return parseGitRepositoryInfo(_asMap(res, 'getRepositorySummary'));
  }

  /// Asks the desktop to re-read its Git state (`{summary, identity,
  /// unstagedChanges, stagedChanges}` aggregate). Returns true when the
  /// desktop accepted; false when the method is missing (older desktop) —
  /// the caller then reads through [getChanges] alone. Any other error
  /// rethrows.
  Future<bool> refresh(String workspacePath) async {
    try {
      await _probe.run(
        'refresh',
        _refreshCandidates,
        argsOf: (_) => <Object?>[_scope(workspacePath)],
      );
      return true;
    } on ChannelRpcError catch (e) {
      if (MethodProbe.missingMethod(e.message)) return false;
      rethrow;
    }
  }

  /// Changed-file rows plus staged/unstaged aggregates. [sourceId] (staged /
  /// unstaged) filters server-side when given; omitted, the desktop returns
  /// every section and the caller groups locally.
  Future<GitChanges> getChanges(
    String workspacePath, {
    String? sourceId,
  }) async {
    final res = await _probe.run(
      'getChanges',
      _changesCandidates,
      argsOf: (_) => <Object?>[
        _scope(workspacePath, {
          if (sourceId != null) 'sourceId': sourceId,
        }),
      ],
    );
    return parseGitChanges(res);
  }

  Future<GitBranchList> getLocalBranches(String workspacePath) async {
    final res = await _probe.run(
      'getLocalBranches',
      _branchesCandidates,
      argsOf: (_) => <Object?>[_scope(workspacePath)],
    );
    final map = _asMap(res, 'getLocalBranches');
    final raw = map['branches'];
    return GitBranchList(
      headRefType:
          map['headRefType'] is String ? map['headRefType'] as String : null,
      currentBranchName: map['currentBranchName'] is String
          ? map['currentBranchName'] as String
          : null,
      branches: [
        if (raw is List)
          for (final b in raw)
            if (b is Map && b['name'] is String)
              GitBranchInfo(
                name: b['name'] as String,
                isCurrent: b['isCurrent'] == true,
                upstreamName: b['upstreamName'] is String
                    ? b['upstreamName'] as String
                    : null,
                commitHash:
                    b['commitHash'] is String ? b['commitHash'] as String : null,
                commitTimestampMs:
                    (b['commitTimestampMs'] as num?)?.toInt(),
              ),
      ],
    );
  }

  /// Structured branch switch — never throws for a branch conflict; returns
  /// `ok:false` with typed [GitBranchIssue]s.
  Future<GitBranchMutationResult> switchBranch(
    String workspacePath,
    String targetBranchName,
  ) async {
    final res = await _probe.run(
      'switchBranch',
      _switchCandidates,
      argsOf: (_) => <Object?>[
        _scope(workspacePath, {'targetBranchName': targetBranchName}),
      ],
    );
    return GitBranchMutationResult.fromMap(_asMap(res, 'switchBranch'));
  }

  Future<void> stagePaths(String workspacePath, List<String> paths) async {
    await _probe.run(
      'stagePaths',
      _stageCandidates,
      argsOf: (_) => <Object?>[_scope(workspacePath, {'paths': paths})],
    );
  }

  Future<void> unstagePaths(String workspacePath, List<String> paths) async {
    await _probe.run(
      'unstagePaths',
      _unstageCandidates,
      argsOf: (_) => <Object?>[_scope(workspacePath, {'paths': paths})],
    );
  }

  Future<GitDiff> getDiff(
    String workspacePath,
    String path, {
    String? sourceId,
    bool? staged,
  }) async {
    final res = await _probe.run(
      'getDiff',
      _diffCandidates,
      argsOf: (_) => <Object?>[
        _scope(workspacePath, {
          'path': path,
          if (sourceId != null) 'sourceId': sourceId,
          if (staged != null) 'staged': staged,
        }),
      ],
    );
    final map = _asMap(res, 'getDiff');
    final availability = map['availability'] is String
        ? map['availability'] as String
        : (map['patch'] is String ? 'patch' : 'unavailable');
    return GitDiff(
      path: map['path'] is String ? map['path'] as String : path,
      availability: availability,
      patch: map['patch'] is String ? map['patch'] as String : null,
      summary: map['summary'] is String ? map['summary'] as String : null,
    );
  }

  Future<GitIdentity> getIdentity(String workspacePath) async {
    final res = await _probe.run(
      'getIdentity',
      _identityCandidates,
      argsOf: (_) => <Object?>[_scope(workspacePath)],
    );
    final map = _asMap(res, 'getIdentity');
    return GitIdentity(
      userName: map['userName'] is String ? map['userName'] as String : null,
      userEmail: map['userEmail'] is String ? map['userEmail'] as String : null,
      scopeLabel:
          map['scopeLabel'] is String ? map['scopeLabel'] as String : null,
    );
  }

  /// AI commit-message generation. The desktop throws the exact English
  /// string `"Commit message generation is not available."` when the host did
  /// not inject a generator — the UI catches that once and hides the button
  /// permanently (no capability probe needed).
  Future<String> generateCommitMessage(
    String workspacePath, {
    bool includeUnstaged = true,
  }) async {
    final res = await _probe.run(
      'generateCommitMessage',
      _generateCandidates,
      argsOf: (_) => <Object?>[
        _scope(workspacePath, {'includeUnstaged': includeUnstaged}),
      ],
    );
    if (res is String) return res;
    final map = _asMap(res, 'generateCommitMessage');
    final message = map['message'];
    if (message is! String || message.isEmpty) {
      throw StateError('gitService.generateCommitMessage: no message field '
          'keys=${map.keys.take(8).toList()}');
    }
    return message;
  }

  Future<GitCommitResult> commit(
    String workspacePath, {
    required String message,
    List<String>? paths,
    bool? stagedOnly,
  }) async {
    final res = await _probe.run(
      'commit',
      _commitCandidates,
      argsOf: (_) => <Object?>[
        _scope(workspacePath, {
          'message': message,
          if (paths != null) 'paths': paths,
          if (stagedOnly != null) 'stagedOnly': stagedOnly,
        }),
      ],
    );
    final map = _asMap(res, 'commit');
    return GitCommitResult(
      commitHash:
          map['commitHash'] is String ? map['commitHash'] as String : null,
      summary: map['summary'] is String ? map['summary'] as String : null,
    );
  }

  Future<GitPushResult> push(String workspacePath) async {
    final res = await _probe.run(
      'push',
      _pushCandidates,
      argsOf: (_) => <Object?>[_scope(workspacePath)],
    );
    final map = _asMap(res, 'push');
    return GitPushResult(
      branchName:
          map['branchName'] is String ? map['branchName'] as String : null,
      trackingBranchName: map['trackingBranchName'] is String
          ? map['trackingBranchName'] as String
          : null,
      remoteName:
          map['remoteName'] is String ? map['remoteName'] as String : null,
      setUpstream: map['setUpstream'] == true,
      summary: map['summary'] is String ? map['summary'] as String : null,
    );
  }
}

/// Parses the repository verdict from either answer shape. Pure.
GitRepositoryInfo parseGitRepositoryInfo(Map<dynamic, dynamic> map) {
  final kind = map['kind'] is String ? map['kind'] as String : '';
  final rawRepo = map['isRepository'];
  final isRepository = kind == 'not-repository'
      ? false
      : rawRepo is bool
          ? rawRepo
          : true;
  return GitRepositoryInfo(
    kind: kind,
    isRepository: isRepository,
    isGitAvailable: map['isGitAvailable'] is bool
        ? map['isGitAvailable'] as bool
        : true,
    branchName:
        map['branchName'] is String ? map['branchName'] as String : null,
    trackingBranchName: map['trackingBranchName'] is String
        ? map['trackingBranchName'] as String
        : null,
    headRefType:
        map['headRefType'] is String ? map['headRefType'] as String : null,
    ahead: (map['ahead'] as num?)?.toInt() ?? 0,
    behind: (map['behind'] as num?)?.toInt() ?? 0,
    isDirty: map['isDirty'] == true,
  );
}

/// Parses a `getChanges` / `getStatus` answer. Accepts an array of change rows
/// or a map with `entries`/`changes`. Pure (no RPC), used by tests directly.
GitChanges parseGitChanges(dynamic res) {
  List<GitChangeEntry>? rows;
  GitChangeStats? stagedStats;
  GitChangeStats? unstagedStats;
  if (res is List) {
    rows = _parseChangeRows(res);
  } else if (res is Map) {
    final raw = res['entries'] ?? res['changes'];
    rows = raw is List ? _parseChangeRows(raw) : <GitChangeEntry>[];
    stagedStats = _parseStats(res['stagedStats']);
    unstagedStats = _parseStats(res['unstagedStats']);
  } else {
    throw StateError('gitService.getChanges: unexpected answer '
        '${res.runtimeType}');
  }
  final entries = rows;
  return GitChanges(
    entries: entries,
    stagedStats: stagedStats ??
        GitChangeStats.of(entries.where((e) => e.section == 'staged' || e.isStaged)),
    unstagedStats: unstagedStats ??
        GitChangeStats.of(entries.where(
            (e) => e.section == 'unstaged' || (!e.isStaged && !e.isUntracked))),
  );
}

List<GitChangeEntry> _parseChangeRows(List<dynamic> raw) => [
      for (final e in raw)
        if (e is Map)
          GitChangeEntry(
            path: '${e['path'] ?? e['filePath'] ?? ''}',
            repoRelativePath: e['repoRelativePath'] is String
                ? e['repoRelativePath'] as String
                : null,
            workspaceRelativePath: e['workspaceRelativePath'] is String
                ? e['workspaceRelativePath'] as String
                : null,
            kind: '${e['kind'] ?? ''}',
            section: '${e['section'] ?? ''}',
            added: (e['added'] as num?)?.toInt() ?? 0,
            removed: (e['removed'] as num?)?.toInt() ?? 0,
            isStaged: e['isStaged'] == true,
            isUntracked: e['isUntracked'] == true,
            isConflicted: e['isConflicted'] == true,
          ),
    ];

GitChangeStats? _parseStats(dynamic raw) {
  if (raw is! Map) return null;
  final added = raw['added'] ?? raw['totalAdded'];
  final removed = raw['removed'] ?? raw['totalRemoved'];
  return GitChangeStats(
    fileCount: (raw['fileCount'] as num?)?.toInt() ?? 0,
    added: added is num ? added.toInt() : 0,
    removed: removed is num ? removed.toInt() : 0,
  );
}
