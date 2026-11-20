import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/chat_page.dart';

/// Pure arithmetic of the turn-navigator jump chain (task
/// 11-19-nav-landing-blank-fix, design D1/D2): the proportional probe's
/// fraction and the restore-then-clamp decision. No widget tree, no
/// controller — the page-side chain feeds these numbers.
void main() {
  group('queryJumpFraction (proportional probe)', () {
    test('edges: first query probes the top, past-the-end probes the bottom', () {
      expect(queryJumpFraction(0, 200), 0);
      expect(queryJumpFraction(200, 200), 1);
    });

    test('middle indexes scale linearly', () {
      expect(queryJumpFraction(50, 200), 0.25);
      expect(queryJumpFraction(100, 200), 0.5);
      expect(queryJumpFraction(150, 200), 0.75);
    });

    test('degenerate directories probe at the top', () {
      expect(queryJumpFraction(0, 0), 0);
      expect(queryJumpFraction(3, 0), 0);
      expect(queryJumpFraction(0, -1), 0);
    });

    test('out-of-range indexes clamp to [0, 1]', () {
      expect(queryJumpFraction(-4, 200), 0);
      expect(queryJumpFraction(999, 200), 1);
    });
  });

  group('shouldClampAfterRestore (restore-then-clamp decision)', () {
    test('clamps only when the settled offset exceeds the real max', () {
      expect(shouldClampAfterRestore(1200, 800), isTrue);
      expect(shouldClampAfterRestore(800, 800), isFalse);
      expect(shouldClampAfterRestore(200, 800), isFalse);
    });

    test('zero-extent content: any positive offset clamps', () {
      expect(shouldClampAfterRestore(1, 0), isTrue);
      expect(shouldClampAfterRestore(0, 0), isFalse);
    });
  });
}