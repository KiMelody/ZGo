import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/state/link_supervisor.dart';

/// Deterministic clock + recording escalation sink. No fake timers: the
/// debounce is stamp-based, so advancing [current] drives the window
/// directly. The clock starts at a wall-clock-ish instant (NOT the epoch)
/// because the escalation stamp initializes to the epoch — production
/// relies on the real clock being far past it for the first escalation to
/// pass the window.
class _Harness {
  /// [onEscalate] may veto a rebuild (return false) to simulate a refused
  /// action; the vetoed call is still recorded in [escalations].
  _Harness({bool Function(String reason)? onEscalate}) {
    supervisor = LinkSupervisor(
      onEscalate: (reason) {
        escalations.add(reason);
        return onEscalate == null || onEscalate(reason);
      },
      now: () => current,
    );
  }

  DateTime current = DateTime(2026, 1, 1, 12, 0, 0);
  late final LinkSupervisor supervisor;
  final escalations = <String>[];

  void advance(Duration d) => current = current.add(d);
}

void main() {
  test('channel tri-strike escalates once and resets', () {
    final h = _Harness();
    // Two consecutive failures stay below the threshold.
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp1');
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp2');
    expect(h.escalations, isEmpty);
    // The third escalates...
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp3');
    expect(h.escalations, ['mp3']);
    // ...and consumed the streak: a follow-up failure starts from zero.
    h.advance(const Duration(seconds: 31));
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp4');
    expect(h.escalations, hasLength(1));
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp5');
    expect(h.escalations, hasLength(1));
  });

  test('channels keep separate streaks', () {
    final h = _Harness();
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp1');
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp2');
    h.supervisor.noteChannelLevelFailure('usage-stats', 'us1');
    h.supervisor.noteChannelLevelFailure('usage-stats', 'us2');
    // 2+2 spread across two channels: nobody strikes.
    expect(h.escalations, isEmpty);
    // Only the channel that reached three consecutive failures escalates.
    h.supervisor.noteChannelLevelFailure('usage-stats', 'us3');
    expect(h.escalations, ['us3']);
    // The other channel still needs its full run (after the window passes).
    h.advance(const Duration(seconds: 31));
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp3');
    expect(h.escalations, hasLength(2));
  });

  test('a success clears only its own channel streak', () {
    final h = _Harness();
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp1');
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp2');
    h.supervisor.noteChannelLevelFailure('usage-stats', 'us1');
    h.supervisor.noteChannelLevelFailure('usage-stats', 'us2');
    // One success proves model-provider rides a live bridge again and
    // clears ITS streak only.
    h.supervisor.noteChannelSuccess('model-provider');
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp3');
    expect(h.escalations, isEmpty);
    // usage-stats was untouched by that success and is one failure away.
    h.supervisor.noteChannelLevelFailure('usage-stats', 'us3');
    expect(h.escalations, ['us3']);
  });

  test(
      'escalations inside the debounce window are suppressed; '
      'the window is shared across channels and gate timeouts', () {
    final h = _Harness();
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp1');
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp2');
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp3');
    expect(h.escalations, hasLength(1));
    // A second channel tri-striking inside the window must not rebuild
    // again...
    h.advance(const Duration(seconds: 10));
    h.supervisor.noteChannelLevelFailure('usage-stats', 'us1');
    h.supervisor.noteChannelLevelFailure('usage-stats', 'us2');
    h.supervisor.noteChannelLevelFailure('usage-stats', 'us3');
    expect(h.escalations, hasLength(1));
    // ...nor must a bridge-level gate expiry that lands in the same
    // window (one stamp, one window — modern DeviceSession semantics).
    h.supervisor.noteGateTimeout('workspace bridge unhealthy > 12s');
    expect(h.escalations, hasLength(1));
    // Once the window has passed, the next escalation goes through.
    h.advance(const Duration(seconds: 21));
    h.supervisor.noteGateTimeout('workspace bridge unhealthy > 12s');
    expect(h.escalations, hasLength(2));
  });

  test(
      'a gate timeout escalates on the first hit and leaves channel '
      'streaks alone', () {
    final h = _Harness();
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp1');
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp2');
    // Bridge-level: no tri-strike needed, the first expiry escalates.
    h.supervisor.noteGateTimeout('workspace bridge unhealthy > 12s');
    expect(h.escalations, hasLength(1));
    // The gate expiry says nothing about the channel: its streak survived.
    // (Had the gate timeout cleared it, mp3 would start from zero and the
    // escalation below would NOT happen.)
    h.advance(const Duration(seconds: 31));
    h.supervisor.noteChannelLevelFailure('model-provider', 'mp3');
    expect(h.escalations, hasLength(2));
  });

  test('a rejected rebuild does not arm the debounce window', () {
    // onEscalate returning false = the rebuild was refused (e.g. a rebuild
    // already in flight / kicked). Only an ACCEPTED escalation may stamp.
    final h = _Harness(onEscalate: (_) => false);
    h.supervisor.noteChannelLevelFailure('a', '1');
    h.supervisor.noteChannelLevelFailure('a', '2');
    h.supervisor.noteChannelLevelFailure('a', '3');
    expect(h.escalations, hasLength(1));
    // The window stayed unarmed, so the next tri-strike reaches the
    // rebuild action again instead of being debounced into silence.
    h.supervisor.noteChannelLevelFailure('b', '1');
    h.supervisor.noteChannelLevelFailure('b', '2');
    h.supervisor.noteChannelLevelFailure('b', '3');
    expect(h.escalations, hasLength(2));
  });

  test('reset clears the streaks but keeps the debounce stamp', () {
    final h = _Harness();
    h.supervisor.noteChannelLevelFailure('a', '1');
    h.supervisor.noteChannelLevelFailure('a', '2');
    // suspend() mid-session: streaks drop, the escalation stamp survives
    // (a rebuild that just ran keeps its window across the suspend).
    h.supervisor.reset();
    h.supervisor.noteChannelLevelFailure('a', '3');
    h.supervisor.noteChannelLevelFailure('a', '4');
    expect(h.escalations, isEmpty);
    h.supervisor.noteChannelLevelFailure('a', '5');
    expect(h.escalations, hasLength(1));
    // And the stamp from that escalation still debounces the window.
    h.advance(const Duration(seconds: 10));
    h.supervisor.noteGateTimeout('gate');
    expect(h.escalations, hasLength(1));
  });
}
