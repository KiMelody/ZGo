import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';

import '../helpers/fake_device_session.dart';

/// Cross-terminal deletion tombstones (task 10-06 chat tombstone): session
/// ids that vanish from the live sessions-index while the subscription is
/// held are recorded by [DeviceSession.recordVanishedSessions] (wired in
/// the fake exactly like production `_onSessionsChanged`) and surface
/// through `isSessionDeleted`. The chat page drops its own id on dispose
/// (`forgetDeletedSession`).
///
/// The second group locks the 10-11 anti-false-positive rules (bridge-swing
/// resubscribes and delta→snapshot boundaries must never tombstone) plus
/// the 10-06 red line (same-generation removal deltas still do).
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.14.0',
  )!;

  Map<String, dynamic> liveRow(String id) =>
      {'sessionId': id, 'title': 'live-$id', 'phase': 'idle'};

  /// A fresh snapshot frame replacing the index contents wholesale.
  Map<String, dynamic> snapshot(List<Map<String, dynamic>> entries) => {
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {'workspaceId': 'ws-1', 'sessions': entries},
        },
      };

  Map<String, dynamic> removedDelta(String id, [int fromSeq = 1, int toSeq = 2]) => {
        'fromSeq': fromSeq,
        'toSeq': toSeq,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'session.removed', 'sessionId': id},
          ],
        },
      };

  /// One `session.upserted` delta — how the desktop pushes a new or
  /// updated session row.
  Map<String, dynamic> upsertDelta(
    Map<String, dynamic> session,
    int fromSeq,
    int toSeq,
  ) =>
      {
        'fromSeq': fromSeq,
        'toSeq': toSeq,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'session.upserted', 'session': session},
          ],
        },
      };

  test('a snapshot without a previously held id records the tombstone', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('s1'), liveRow('s2')],
    );
    expect(session.isSessionDeleted('s1'), isFalse);

    session.sessions.applyFrame(snapshot([liveRow('s2')]), onGap: () {});

    expect(session.isSessionDeleted('s1'), isTrue);
    expect(session.isSessionDeleted('s2'), isFalse);
  });

  test('a session.removed delta records the tombstone', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('s1'), liveRow('s2')],
    );

    session.sessions.applyFrame(removedDelta('s1'), onGap: () {});

    expect(session.isSessionDeleted('s1'), isTrue);
    expect(session.isSessionDeleted('s2'), isFalse);
  });

  test('frames without vanishings record nothing (negative case)', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('s1')],
    );

    // An upsert frame with the same id set, then the same snapshot again.
    session.sessions.applyFrame(
      {
        'fromSeq': 1,
        'toSeq': 2,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'session.upserted',
              'session': {
                'sessionId': 's1',
                'title': 'renamed',
                'phase': 'idle',
              },
            },
          ],
        },
      },
      onGap: () {},
    );
    session.sessions.applyFrame(snapshot([liveRow('s1')]), onGap: () {});

    expect(session.isSessionDeleted('s1'), isFalse);
  });

  test('a fresh baseline does not mass-record: the first frame after a new '
      'subscription only establishes the diff base', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('s1'), liveRow('s2'), liveRow('s3')],
    );

    // Production resets the baseline on every workspace open (new
    // subscription): simulate by driving the frames a fresh subscription
    // would deliver — a full listing first, deletions only count from the
    // NEXT frame on. Here: empty seeding is the fresh-base shape.
    final fresh = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: const [],
    );
    // First frame of the fresh subscription: a full listing without ids
    // the fake was seeded with — nothing held, nothing recorded.
    fresh.sessions.applyFrame(snapshot([liveRow('s2')]), onGap: () {});
    expect(fresh.isSessionDeleted('s1'), isFalse);
    expect(fresh.isSessionDeleted('s2'), isFalse);

    // Only the SECOND frame (ids vanish relative to a held baseline)
    // records.
    fresh.sessions.applyFrame(snapshot(const []), onGap: () {});
    expect(fresh.isSessionDeleted('s2'), isTrue);

    expect(session.isSessionDeleted('s3'), isFalse);
  });

  test('a frame under a different workspace key never records (second '
      'line of defense for the openWorkspace baseline reset)', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('s1')],
    );
    // Seeded frame established the baseline under the (null) key.
    expect(session.isSessionDeleted('s1'), isFalse);

    // Production resets the baseline on every openWorkspace, so a frame
    // from a different workspace normally arrives with a fresh baseline.
    // If it ever did not, the key check must refuse the cross-workspace
    // diff: ws-2's listing lacking ws-1's s1 is NOT a deletion.
    session.sessions.subscribedWorkspaceKey = 'ws-2';
    session.sessions.applyFrame(snapshot(const []), onGap: () {});

    expect(session.isSessionDeleted('s1'), isFalse);

    // The re-keyed baseline is now live: a later same-key frame diffs
    // against ws-2's (empty) ids, still nothing.
    session.sessions.applyFrame(snapshot(const []), onGap: () {});
    expect(session.isSessionDeleted('s1'), isFalse);
  });

  test('forgetDeletedSession drops the id (page-dispose recovery)', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('s1'), liveRow('s2')],
    );
    session.sessions.applyFrame(snapshot([liveRow('s2')]), onGap: () {});
    expect(session.isSessionDeleted('s1'), isTrue);

    session.forgetDeletedSession('s1');

    expect(session.isSessionDeleted('s1'), isFalse);
    // Other tombstones are untouched.
    session.sessions.applyFrame(snapshot(const []), onGap: () {});
    expect(session.isSessionDeleted('s2'), isTrue);
  });

  // --- 10-11 bridge-swing false positives, now regressions (task
  // 10-11-acceptance-fix-batch; ex forensic suite
  // tombstone_hypothesis_proof_test.dart, rewritten to assert the FIX).
  // The ~45s replayGraceExceeded pendulum resubscribes the SAME
  // SessionsIndexState without an openWorkspace; before the
  // generation + frame-kind rules landed, the rebuilt subscription's
  // re-seeded first frame diffed against pre-swing ids and tombstoned
  // live sessions (H1/H2/H3 in the 10-11 findings). The H2 control — a
  // genuinely fresh subscription's first frame only establishes the
  // baseline — stays covered by "a fresh baseline does not mass-record"
  // above.

  test('H1 regression: a delta-admitted id missing from a later snapshot '
      'is not a deletion', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('A'), liveRow('B')],
    );
    // The desktop pushes the brand-new session X as a delta...
    session.deliver(upsertDelta(liveRow('X'), 1, 2));
    expect(session.isSessionDeleted('X'), isFalse);

    // ...and a same-workspace snapshot omits it again (re-seed lag).
    session.deliver(snapshot([liveRow('A'), liveRow('B')]));

    expect(
      session.isSessionDeleted('X'),
      isFalse,
      reason: 'X was never snapshot-confirmed — a snapshot after a delta '
          'must re-baseline, not diff "missing means deleted"',
    );
    expect(session.isSessionDeleted('A'), isFalse);
    expect(session.isSessionDeleted('B'), isFalse);
  });

  test('H2 regression: a resubscribe never diffs against pre-swing ids', () {
    // Real-world 10-11 10:34 shape: createSession lands between two ~45s
    // bridge swings; the rebuilt subscription's first re-seeded snapshot
    // reaches the SAME state + baseline (no openWorkspace ran).
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('A'), liveRow('B'), liveRow('X')],
    );
    expect(session.isSessionDeleted('X'), isFalse);

    session.resubscribeSessionsIndex();
    session.deliver(snapshot([liveRow('A'), liveRow('B')]));

    expect(
      session.isSessionDeleted('X'),
      isFalse,
      reason: 'the new generation must establish its own baseline first',
    );

    // X returns with the next re-seeded frame and stays un-banned (the
    // add-only set no longer records the false positive at all).
    session.deliver(snapshot([liveRow('A'), liveRow('B'), liveRow('X')]));
    expect(session.isSessionDeleted('X'), isFalse);
  });

  test('H3 regression: a gap-resync snapshot does not tombstone '
      'delta-admitted ids', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('A')],
    );
    session.deliver(upsertDelta(liveRow('X'), 1, 2));
    expect(session.isSessionDeleted('X'), isFalse);

    // A seq-mismatched delta fires onGap -> production runs _resync() ->
    // the desktop answers with a fresh snapshot (which lags X).
    var gapFired = false;
    session.deliver(
      {
        'fromSeq': 9, // != state.seq (2) -> gap
        'toSeq': 10,
        'payload': {
          'kind': 'deltas',
          'deltas': const [],
        },
      },
      onGap: () => gapFired = true,
    );
    expect(gapFired, isTrue, reason: 'delta seq gap must call onGap');
    expect(session.isSessionDeleted('X'), isFalse);

    // The resync snapshot omits X: re-seed lag, not a deletion.
    session.deliver(snapshot([liveRow('A')]));
    expect(session.isSessionDeleted('X'), isFalse);
  });

  test('red line: a same-generation session.removed delta still records '
      'the tombstone', () {
    // 10-06 red line under the frame-kind rules: removal deltas stay
    // immediately trusted within one subscription generation.
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('A'), liveRow('B'), liveRow('X')],
    );
    session.deliver(removedDelta('X'));
    expect(session.isSessionDeleted('X'), isTrue);
    expect(session.isSessionDeleted('A'), isFalse);
    expect(session.isSessionDeleted('B'), isFalse);
  });

  test('red line: a removal delta of a delta-admitted id records too '
      '(no snapshot confirmed it yet)', () {
    // The other half of the red line: a session created via an upsert
    // delta (createSession) and remotely deleted before any snapshot
    // confirmed it — the removal delta is an explicit op, so it must
    // tombstone even though the id never entered the snapshot baseline
    // (which stays delta-free so H1/H3 re-seed lag cannot tombstone).
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('A'), liveRow('B')],
    );
    session.deliver(upsertDelta(liveRow('X'), 1, 2));
    expect(session.isSessionDeleted('X'), isFalse);

    session.deliver(removedDelta('X', 2, 3));

    expect(session.isSessionDeleted('X'), isTrue);
    expect(session.isSessionDeleted('A'), isFalse);
  });
}
