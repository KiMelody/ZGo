import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/state/side_chat_registry.dart';

/// SideChatRegistry pure-logic matrix (design 11-11-btw-side-chat §2/§3,
/// A1-rev2).
///
/// Identity is no longer probed on the wire: a side chat is a manifest member,
/// so the registry only replays `{sessionId, ordinal}` records the store hands
/// it. What remains testable here is the ordinal rule, the two-tier lifecycle
/// (close keeps the record recoverable, destroy drops it for good) and the
/// replay contract.
void main() {
  List<String> ids(List<SideChatTab> tabs) =>
      [for (final t in tabs) t.sessionId];
  List<int> ordinals(List<SideChatTab> tabs) =>
      [for (final t in tabs) t.ordinal];

  SideChatTab entry(String id, int ordinal) =>
      SideChatTab(sessionId: id, ordinal: ordinal);

  group('ordinal assignment', () {
    test('starts at 1 and increments per parent', () {
      final reg = SideChatRegistry();
      expect(reg.register('p', 'a').ordinal, 1);
      expect(reg.register('p', 'b').ordinal, 2);
      expect(reg.register('p', 'c').ordinal, 3);
      // A different parent keeps its own sequence.
      expect(reg.register('q', 'x').ordinal, 1);
      expect(ordinals(reg.tabsOf('p')), [1, 2, 3]);
    });

    test('re-registering a known id answers the same tab, no duplicate', () {
      final reg = SideChatRegistry();
      final first = reg.register('p', 'a');
      final again = reg.register('p', 'a');
      expect(again.sessionId, 'a');
      expect(again.ordinal, first.ordinal);
      expect(reg.tabsOf('p'), hasLength(1));
    });

    test('closing ordinal 1 frees it for the next registration', () {
      final reg = SideChatRegistry();
      reg.register('p', 'a'); // 1
      reg.register('p', 'b'); // 2
      reg.register('p', 'c'); // 3

      reg.close('p', 'a');
      expect(ordinals(reg.tabsOf('p')), [2, 3]);

      expect(reg.register('p', 'd').ordinal, 1);
      // The view is ordinal-ordered: d took the freed 1 and leads even
      // though it was appended last.
      expect(ids(reg.tabsOf('p')), ['d', 'b', 'c']);
      expect(ordinals(reg.tabsOf('p')), [1, 2, 3]);
    });

    test('the smallest unused ordinal wins across holes', () {
      final reg = SideChatRegistry();
      reg.register('p', 'a'); // 1
      reg.register('p', 'b'); // 2
      reg.register('p', 'c'); // 3
      reg.close('p', 'b');
      reg.close('p', 'a');

      expect(reg.register('p', 'd').ordinal, 1);
      expect(reg.register('p', 'e').ordinal, 2);
      expect(reg.register('p', 'f').ordinal, 4);
    });

    test('an unknown parent answers an empty list', () {
      expect(SideChatRegistry().tabsOf('nope'), isEmpty);
    });
  });

  group('close / destroy', () {
    test('close removes only the named record', () {
      final reg = SideChatRegistry();
      reg.register('p', 'a');
      reg.register('p', 'b');

      reg.close('p', 'a');

      expect(ids(reg.tabsOf('p')), ['b']);
      // The parent bucket is dropped once the last tab goes.
      reg.close('p', 'b');
      expect(reg.tabsOf('p'), isEmpty);
    });

    test('close is a no-op for an unknown parent or id', () {
      final reg = SideChatRegistry();
      reg.register('p', 'a');
      reg.close('other', 'zzz');
      reg.close('p', 'zzz');
      expect(ids(reg.tabsOf('p')), ['a']);
    });

    test(
        'destroy removes the same in-memory record as close; the difference '
        'is the manifest the caller keeps', () {
      final reg = SideChatRegistry();
      reg.register('p', 'a');
      reg.register('p', 'b');

      reg.destroy('p', 'a');

      expect(ids(reg.tabsOf('p')), ['b']);
    });

    test(
        'a closed tab is restorable: replaying the manifest brings it back '
        'with its ordinal', () {
      final reg = SideChatRegistry();
      reg.register('p', 'a1');
      reg.close('p', 'a1');
      expect(reg.tabsOf('p'), isEmpty);

      // close only stops the desktop runtime; the session row and the
      // manifest entry survive, so the next page entry replays it.
      expect(reg.restoreFromEntries('p', [entry('a1', 1)]), isTrue);

      expect(ids(reg.tabsOf('p')), ['a1']);
      expect(ordinals(reg.tabsOf('p')), [1]);
    });
  });

  group('restoreFromEntries', () {
    test('replays the persisted ordinals verbatim', () {
      final reg = SideChatRegistry();
      reg.restoreFromEntries('p', [
        entry('second', 2),
        entry('first', 1),
        entry('fifth', 5),
      ]);

      expect(ids(reg.tabsOf('p')), ['first', 'second', 'fifth']);
      expect(ordinals(reg.tabsOf('p')), [1, 2, 5]);
    });

    test('known ids are never renumbered; new ones fill around them', () {
      final reg = SideChatRegistry();
      // Live tab registered in-page: ordinal 1.
      reg.register('p', 'live');

      reg.restoreFromEntries('p', [
        entry('older', 1),
        entry('live', 1),
        entry('newer', 3),
      ]);

      expect(ids(reg.tabsOf('p')), ['live', 'older', 'newer'],
          reason: 'live keeps ordinal 1; the colliding older entry is '
              'renumbered to the smallest unused one');
      expect(ordinals(reg.tabsOf('p')), [1, 2, 3]);
    });

    test(
        'an invalid or colliding persisted ordinal falls back to the '
        'smallest unused number', () {
      final reg = SideChatRegistry();
      reg.restoreFromEntries('p', [
        entry('zero', 0),
        entry('neg', -3),
        entry('dupA', 7),
        entry('dupB', 7),
      ]);

      expect(ordinals(reg.tabsOf('p')), [1, 2, 3, 7],
          reason: 'zero/neg are invalid (1, 2); the first 7 is kept, the '
              'second takes the smallest unused number 3');
      expect(ids(reg.tabsOf('p')), ['zero', 'neg', 'dupB', 'dupA']);
    });

    test('restoring twice is idempotent and answers false the second time', () {
      final reg = SideChatRegistry();
      final rows = [entry('a', 1), entry('b', 2)];
      expect(reg.restoreFromEntries('p', rows), isTrue);
      expect(reg.restoreFromEntries('p', rows), isFalse);

      expect(ids(reg.tabsOf('p')), ['a', 'b']);
      expect(ordinals(reg.tabsOf('p')), [1, 2]);
    });

    test('an empty or blank-id candidate set leaves the registry untouched',
        () {
      final reg = SideChatRegistry();
      expect(reg.restoreFromEntries('p', const []), isFalse);
      expect(reg.restoreFromEntries('p', [entry('', 4)]), isFalse);
      expect(reg.tabsOf('p'), isEmpty);
    });

    test('a restore only touches the requested parent', () {
      final reg = SideChatRegistry();
      reg.restoreFromEntries('p', [entry('a', 1)]);
      reg.restoreFromEntries('q', [entry('b', 1)]);

      expect(ids(reg.tabsOf('p')), ['a']);
      expect(ids(reg.tabsOf('q')), ['b']);
    });
  });
}
