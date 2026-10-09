import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/git_service.dart';

void main() {
  test('candidate order: remote facade name first, internal name trailing; '
      'misses advance and the winner is remembered', () async {
    final calls = <String>[];
    final port = GitPort((method, args) async {
      calls.add(method);
      if (method == 'getChanges') {
        throw ChannelRpcError('no such method: $method', null);
      }
      if (method == 'getStatus') return <String, Object?>{'entries': []};
      throw StateError('unexpected $method');
    });

    await port.getChanges('/repo');
    expect(calls, ['getChanges', 'getStatus']);

    calls.clear();
    await port.getChanges('/repo');
    expect(calls, ['getStatus'], reason: 'second call reuses the winner');
  });

  test('getLocalBranches probes getLocalBranches → listLocalBranches and '
      'parses the branch rows', () async {
    final calls = <String>[];
    final port = GitPort((method, args) async {
      calls.add(method);
      if (method == 'getLocalBranches') {
        throw ChannelRpcError('unknown method: $method', null);
      }
      return <String, Object?>{
        'headRefType': 'branch',
        'currentBranchName': 'main',
        'branches': [
          {'name': 'main', 'isCurrent': true, 'upstreamName': 'origin/main'},
          {'name': 'dev', 'isCurrent': false, 'commitTimestampMs': 42},
        ],
      };
    });

    final res = await port.getLocalBranches('/repo');
    expect(calls, ['getLocalBranches', 'listLocalBranches']);
    expect(res.currentBranchName, 'main');
    expect(res.branches.map((b) => b.name).toList(), ['main', 'dev']);
    expect(res.branches.first.isCurrent, isTrue);
    expect(res.branches.first.upstreamName, 'origin/main');
    expect(res.branches[1].commitTimestampMs, 42);
  });

  test('stagePaths/unstagePaths carry both naming sets and the paths payload',
      () async {
    final calls = <String>[];
    final payloads = <Map<String, Object?>>[];
    final port = GitPort((method, args) async {
      calls.add(method);
      payloads.add((args.single as Map).cast<String, Object?>());
      if (method == 'stagePaths' || method == 'unstagePaths') {
        throw ChannelRpcError('no such method: $method', null);
      }
    });

    await port.stagePaths('/repo', ['a.dart']);
    await port.unstagePaths('/repo', ['b.dart']);
    expect(calls, ['stagePaths', 'stage', 'unstagePaths', 'unstage']);
    // Every candidate attempt re-sends the same args during probing.
    expect(payloads.first, {'workspacePath': '/repo', 'paths': ['a.dart']});
    expect(payloads.last, {'workspacePath': '/repo', 'paths': ['b.dart']});
  });

  test('repositoryInfo: kind not-repository verdict and summary shape',
      () async {
    GitPort port(dynamic answer) => GitPort((method, args) async => answer);

    final kind = await port({'kind': 'not-repository', 'isGitAvailable': true})
        .repositoryInfo('/repo');
    expect(kind.isNotRepository, isTrue);
    expect(kind.isGitAvailable, isTrue);

    final summary = await port({
      'isRepository': true,
      'branchName': 'main',
      'isDirty': true,
      'ahead': 2,
      'behind': 1,
      'headRefType': 'branch',
    }).repositoryInfo('/repo');
    expect(summary.isNotRepository, isFalse);
    expect(summary.branchName, 'main');
    expect(summary.isDirty, isTrue);
    expect(summary.ahead, 2);
    expect(summary.behind, 1);

    final repoFalse = await port({'isRepository': false, 'isGitAvailable': true})
        .repositoryInfo('/repo');
    expect(repoFalse.isNotRepository, isTrue);
  });

  test('getChanges: list answer sums client-side; map answer takes server stats',
      () async {
    final port = GitPort((method, args) async => method == 'getChanges'
        ? [
            {
              'path': '/repo/a.dart',
              'workspaceRelativePath': 'lib/a.dart',
              'kind': 'modified',
              'section': 'unstaged',
              'added': 5,
              'removed': 2,
            },
            {
              'path': '/repo/new.dart',
              'kind': 'added',
              'section': 'untracked',
              'isUntracked': true,
              'added': 3,
            },
          ]
        : throw StateError('unexpected'));

    final res = await port.getChanges('/repo');
    expect(res.entries, hasLength(2));
    expect(res.entries.first.displayPath, 'lib/a.dart');
    expect(res.unstagedStats.fileCount, 1);
    expect(res.unstagedStats.added, 5);
    expect(res.unstagedStats.removed, 2);
    expect(res.untracked.map((e) => e.path), ['/repo/new.dart']);

    final withStats = GitPort((method, args) async => {
          'entries': [
            {
              'path': '/a',
              'section': 'staged',
              'isStaged': true,
              'added': 1,
            },
          ],
          'stagedStats': {'fileCount': 9, 'totalAdded': 90, 'totalRemoved': 7},
        });
    final res2 = await withStats.getChanges('/repo');
    expect(res2.stagedStats.fileCount, 9);
    expect(res2.stagedStats.added, 90);
    expect(res2.stagedStats.removed, 7);
  });

  test('getChanges sourceId rides the payload only when given', () async {
    final payloads = <Map<String, Object?>>[];
    final port = GitPort((method, args) async {
      payloads.add((args.single as Map).cast<String, Object?>());
      return <Object?>[];
    });
    await port.getChanges('/repo');
    await port.getChanges('/repo', sourceId: 'staged');
    expect(payloads[0], {'workspacePath': '/repo'});
    expect(payloads[1], {'workspacePath': '/repo', 'sourceId': 'staged'});
  });

  test('switchBranch: structured ok:false with the full 8-code mapping',
      () async {
    final port = GitPort((method, args) async => {
          'ok': false,
          'didChange': false,
          'created': false,
          'issues': [
            {'code': 'tracked-changes-would-be-overwritten', 'paths': ['a']},
            {'code': 'untracked-changes-would-be-overwritten'},
            {'code': 'branch-already-exists'},
            {'code': 'target-branch-not-found'},
            {'code': 'branch-in-other-worktree'},
            {'code': 'conflicts-present'},
            {'code': 'operation-in-progress'},
            {'code': 'something-new'},
          ],
        });
    final res = await port.switchBranch('/repo', 'dev');
    expect(res.ok, isFalse);
    expect(res.issues.map((i) => i.code).toList(), [
      GitBranchIssueCode.trackedOverwrite,
      GitBranchIssueCode.untrackedOverwrite,
      GitBranchIssueCode.branchAlreadyExists,
      GitBranchIssueCode.targetBranchNotFound,
      GitBranchIssueCode.branchInOtherWorktree,
      GitBranchIssueCode.conflictsPresent,
      GitBranchIssueCode.operationInProgress,
      GitBranchIssueCode.unknown,
    ]);
    expect(res.issues.first.paths, ['a']);
  });

  test('switchBranch payload carries workspacePath + targetBranchName', () async {
    final payloads = <Map<String, Object?>>[];
    final port = GitPort((method, args) async {
      payloads.add((args.single as Map).cast<String, Object?>());
      return {'ok': true, 'didChange': true};
    });
    final ok = await port.switchBranch('/repo', 'main');
    expect(payloads.single,
        {'workspacePath': '/repo', 'targetBranchName': 'main'});
    expect(ok.ok, isTrue);
    expect(ok.didChange, isTrue);
  });

  test('getDiff parses availability + patch; missing availability with a patch '
      'reads as patch', () async {
    final port = GitPort((method, args) async => {
          'path': 'lib/a.dart',
          'availability': 'patch',
          'patch': '@@ -1 +1 @@\n-a\n+b',
        });
    final diff = await port.getDiff('/repo', 'lib/a.dart');
    expect(diff.isPatch, isTrue);
    expect(diff.patch, contains('@@'));

    final legacy = GitPort((method, args) async => {'patch': '@@'});
    expect((await legacy.getDiff('/repo', 'x')).availability, 'patch');

    final binary = GitPort((method, args) async => {'availability': 'binary'});
    final b = await binary.getDiff('/repo', 'x');
    expect(b.isPatch, isFalse);
    expect(b.availability, 'binary');
  });

  test('getIdentity: null fields → isMissing', () async {
    final port = GitPort((method, args) async =>
        {'userName': 'Ada', 'userEmail': 'ada@example.com'});
    final id = await port.getIdentity('/repo');
    expect(id.isMissing, isFalse);

    final missing = GitPort((method, args) async =>
        {'userName': null, 'userEmail': null});
    expect((await missing.getIdentity('/repo')).isMissing, isTrue);
  });

  test('generateCommitMessage returns {message} and surfaces the fixed '
      'unavailable string', () async {
    final port = GitPort((method, args) async => {'message': 'feat: x'});
    expect(await port.generateCommitMessage('/repo'), 'feat: x');

    final unavailable = GitPort((method, args) async =>
        throw ChannelRpcError(
            'Commit message generation is not available.', null));
    await expectLater(
      unavailable.generateCommitMessage('/repo'),
      throwsA(isA<ChannelRpcError>().having((e) => e.message, 'message',
          'Commit message generation is not available.')),
    );
  });

  test('commit/push payloads and parsed results', () async {
    final payloads = <Map<String, Object?>>[];
    final port = GitPort((method, args) async {
      payloads.add((args.single as Map).cast<String, Object?>());
      if (method == 'commit') {
        return {'commitHash': 'abc123', 'summary': 'feat'};
      }
      return {
        'branchName': 'main',
        'trackingBranchName': 'origin/main',
        'remoteName': 'origin',
        'setUpstream': true,
      };
    });

    final c = await port.commit('/repo', message: 'feat', stagedOnly: false);
    expect(payloads[0], {
      'workspacePath': '/repo',
      'message': 'feat',
      'stagedOnly': false,
    });
    expect(c.commitHash, 'abc123');

    final p = await port.push('/repo');
    expect(payloads[1], {'workspacePath': '/repo'});
    expect(p.trackingBranchName, 'origin/main');
    expect(p.setUpstream, isTrue);
  });

  test('refresh returns false on a missing method, true when accepted, and '
      'rethrows a real error', () async {
    final missing = GitPort((method, args) async =>
        throw ChannelRpcError('no such method: $method', null));
    expect(await missing.refresh('/repo'), isFalse);

    final ok = GitPort((method, args) async => <String, Object?>{});
    expect(await ok.refresh('/repo'), isTrue);

    final broken = GitPort((method, args) async =>
        throw ChannelRpcError('validation failed', null));
    await expectLater(broken.refresh('/repo'), throwsA(isA<ChannelRpcError>()));
  });

  test('malformed answers throw explicit StateErrors', () async {
    GitPort answering(dynamic res) => GitPort((method, args) async => res);

    await expectLater(answering('nope').repositoryInfo('/repo'), throwsStateError);
    await expectLater(
        answering(<String, dynamic>{}).generateCommitMessage('/repo'),
        throwsStateError);
    await expectLater(answering(42).commit('/repo', message: 'm'),
        throwsStateError);
    await expectLater(answering(42).push('/repo'), throwsStateError);
    await expectLater(answering(42).getLocalBranches('/repo'),
        throwsStateError);
    await expectLater(answering(42).getChanges('/repo'), throwsStateError);
    await expectLater(answering(42).switchBranch('/repo', 'dev'),
        throwsStateError);
  });
}
