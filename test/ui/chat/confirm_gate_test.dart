import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/confirm_gate.dart';

/// ConfirmGate state machine — pure timer semantics, driven through the
/// tester's fake clock (tester.pump), the same way the chat-page confirm
/// window tests advance time (no fake_async, project convention).
void main() {
  const window = Duration(milliseconds: 100);
  const half = Duration(milliseconds: 50);

  testWidgets('repeated observe(true) anchors once — frames never postpone '
      'the window', (tester) async {
    var fires = 0;
    final gate = ConfirmGate(window: window, onConfirmed: () => fires++);
    gate.observe(true);
    await tester.pump(half);
    gate.observe(true); // bridge-replay frames: must not restart the window
    gate.observe(true);
    await tester.pump(half);
    expect(fires, 1);
    expect(gate.confirmed, isTrue);
    await tester.pump(window); // one-shot: no second fire
    expect(fires, 1);
    gate.dispose();
  });

  testWidgets('window elapse fires onConfirmed once and flips confirmed', (
    tester,
  ) async {
    var fires = 0;
    final gate = ConfirmGate(window: window, onConfirmed: () => fires++);
    gate.observe(true);
    await tester.pump(window - const Duration(milliseconds: 1));
    expect(fires, 0);
    expect(gate.confirmed, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(fires, 1);
    expect(gate.confirmed, isTrue);
    await tester.pump(window);
    expect(fires, 1);
    gate.dispose();
  });

  testWidgets('observe(false) cancels; re-arming starts a fresh window', (
    tester,
  ) async {
    var fires = 0;
    final gate = ConfirmGate(window: window, onConfirmed: () => fires++);
    gate.observe(true);
    await tester.pump(half);
    gate.observe(false);
    expect(gate.confirmed, isFalse);
    await tester.pump(window); // the old window would have elapsed by now
    expect(fires, 0);
    gate.observe(true);
    await tester.pump(half);
    expect(fires, 0); // fresh window counts from the new anchor
    await tester.pump(half);
    expect(fires, 1);
    gate.dispose();
  });

  testWidgets('condition flicker (true-false-true) confirms once, window '
      'counts from the last true', (tester) async {
    var fires = 0;
    final gate = ConfirmGate(window: window, onConfirmed: () => fires++);
    gate.observe(true);
    await tester.pump(half);
    gate.observe(false);
    gate.observe(true);
    await tester.pump(half);
    expect(fires, 0);
    await tester.pump(half);
    expect(fires, 1);
    expect(gate.confirmed, isTrue);
    gate.dispose();
  });

  testWidgets('dispose silences the gate — no late fire, no re-arm', (
    tester,
  ) async {
    var fires = 0;
    final gate = ConfirmGate(window: window, onConfirmed: () => fires++);
    gate.observe(true);
    gate.dispose();
    await tester.pump(window);
    expect(fires, 0);
    gate.observe(true); // post-dispose: inert, must not schedule a timer
    await tester.pump(window);
    expect(fires, 0);
    expect(gate.confirmed, isFalse);
  });
}
