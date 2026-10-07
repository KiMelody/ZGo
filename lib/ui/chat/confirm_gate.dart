import 'dart:async';

/// "Condition held for [window]" gate: one-shot confirmation that a
/// transient condition has persisted long enough to act on. Owns the
/// timer; callers own their business state (fields, setState, pop) and do
/// the still-true re-check inside [onConfirmed] — the gate only decides
/// that the window elapsed.
///
/// Anchoring is idempotent under repeated [observe](true) frames: the
/// window anchors once and repeats never postpone it (bridge-replay
/// defense — degraded links replay the same terminal frame for seconds).
/// [observe](false) cancels and disarms; re-arming starts a fresh window.
/// Strictly side-effect-free when the condition is unchanged, so it is
/// safe to call from inside builders.
class ConfirmGate {
  ConfirmGate({required this.window, required this.onConfirmed});

  final Duration window;
  final void Function() onConfirmed;

  Timer? _t;
  bool _confirmed = false;
  bool _disposed = false;

  /// Whether [onConfirmed] already fired for the current arm — semantics
  /// are "window elapsed", not "caller re-check passed" (the re-check is
  /// the caller's business). Callers short-circuit on this the way
  /// `_TurnGroupWidgetState` guards on `_terminalConfirmed`.
  bool get confirmed => _confirmed;

  /// Drives the gate. condition=true anchors (once) / stays armed;
  /// condition=false cancels and disarms (re-arming starts a fresh
  /// window). Repeated calls with the same argument do nothing.
  void observe(bool condition) {
    if (_disposed) return;
    if (!condition) {
      _t?.cancel();
      _t = null;
      _confirmed = false;
      return;
    }
    if (_confirmed || _t != null) return;
    _t = Timer(window, () {
      _t = null;
      _confirmed = true;
      onConfirmed();
    });
  }

  /// Cancels the pending window; the gate stays inert afterwards.
  void dispose() {
    _t?.cancel();
    _t = null;
    _disposed = true;
  }
}
