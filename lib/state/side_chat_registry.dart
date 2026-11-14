/// Ordinal of one side-chat tab under its parent session.
class SideChatTab {
  final String sessionId;

  /// 1-based rank within the parent's tab list, assigned by the registry
  /// (smallest unused positive integer; a freed number is reused).
  final int ordinal;

  const SideChatTab({required this.sessionId, required this.ordinal});

  @override
  String toString() => 'SideChatTab($sessionId #$ordinal)';
}

/// In-memory side-chat (`selection_side_chat`) tab bookkeeping, keyed by the
/// parent session id (design 11-11-btw-side-chat §2/D1).
///
/// Pure logic: no wire, no timers, no UI, no storage. [DeviceSession] owns one
/// instance and drives every mutation (register/close/destroy/restore); pages
/// only read through the host port.
///
/// Lifecycle semantics (two tiers, R8/R9):
/// - close = collapse-to-removable. The record leaves [tabsOf]; the desktop
///   session row survives (closeSession only stops the runtime) and the
///   persistent tab manifest keeps its entry, so the next page entry restores
///   the tab through [restoreFromEntries].
/// - destroy = permanent. The caller soft-deletes the session and drops the
///   manifest entry, so no restore can ever bring the tab back.
///
/// The manifest lives outside this class (`SideChatTabStore`): the registry
/// only replays its records, so the restoration matrix stays testable without
/// storage or wire.
class SideChatRegistry {
  /// The V4 `sessionKind` naming a side chat (`zcode-session.listSessions`
  /// rows carry it; the desktop's `task_type` column is `selection_side_chat`).
  /// The identity check uses this value verbatim — the sessions-index never
  /// carries the kind at all (host whitelist), which is why restore cannot
  /// read it from there.
  static const sessionKind = 'selection_side_chat';

  final Map<String, List<SideChatTab>> _tabs = {};

  /// Tabs of [parent], ordered by ordinal ascending — the tab bar renders
  /// them in this order. Read-only view — mutations go through the methods
  /// below. (Insertion order and ordinal order diverge once a closed tab's
  /// freed number is taken back by a restore or a fresh registration.)
  List<SideChatTab> tabsOf(String parent) {
    final tabs = _tabs[parent];
    if (tabs == null || tabs.isEmpty) return const <SideChatTab>[];
    final sorted = [...tabs]..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    return List.unmodifiable(sorted);
  }

  /// Appends [sessionId] under [parent] with the smallest unused positive
  /// ordinal and answers the tab. Re-registering an id already present is a
  /// no-op answering the existing tab (the create path may retry after a
  /// late ack).
  SideChatTab register(String parent, String sessionId) {
    final tabs = _tabs.putIfAbsent(parent, () => <SideChatTab>[]);
    for (final tab in tabs) {
      if (tab.sessionId == sessionId) return tab;
    }
    final used = {for (final tab in tabs) tab.ordinal};
    var ordinal = 1;
    while (used.contains(ordinal)) {
      ordinal++;
    }
    final tab = SideChatTab(sessionId: sessionId, ordinal: ordinal);
    tabs.add(tab);
    return tab;
  }

  /// Drops the record of [sessionId] under [parent] (close path). The
  /// persistent manifest keeps its entry — close is a restorable collapse,
  /// not a deletion.
  void close(String parent, String sessionId) => _remove(parent, sessionId);

  /// Drops the record of [sessionId] under [parent] (destroy path). Same
  /// in-memory effect as [close]; the permanence lives in the manifest, which
  /// the caller prunes separately.
  void destroy(String parent, String sessionId) => _remove(parent, sessionId);

  /// Replays manifest [entries] under [parent] (recovery, R8/AC9).
  ///
  /// - Each entry carries the ordinal it was persisted with; the tab is
  ///   re-created verbatim (the bar keeps the numbering the user saw).
  /// - Ids already live are skipped untouched — no renumbering, and a repeated
  ///   page entry is idempotent.
  /// - Defensive: an invalid ordinal (< 1) or one already taken falls back to
  ///   the smallest unused positive ordinal, so a hand-edited manifest can
  ///   never break the bar's ordering contract.
  ///
  /// Answers whether any tab was added — the session notifies only on a real
  /// change, so a repeated entry cannot ping-pong with host listeners.
  bool restoreFromEntries(String parent, Iterable<SideChatTab> entries) {
    final existing = _tabs[parent] ?? const <SideChatTab>[];
    final known = {for (final tab in existing) tab.sessionId};
    final used = {for (final tab in existing) tab.ordinal};
    final added = <SideChatTab>[];
    for (final entry in entries) {
      if (entry.sessionId.isEmpty) continue;
      if (!known.add(entry.sessionId)) continue;
      var ordinal = entry.ordinal;
      if (ordinal < 1 || used.contains(ordinal)) {
        ordinal = 1;
        while (used.contains(ordinal)) {
          ordinal++;
        }
      }
      used.add(ordinal);
      added.add(SideChatTab(sessionId: entry.sessionId, ordinal: ordinal));
    }
    if (added.isEmpty) return false;
    (_tabs[parent] ??= <SideChatTab>[]).addAll(added);
    return true;
  }

  void _remove(String parent, String sessionId) {
    final tabs = _tabs[parent];
    if (tabs == null) return;
    tabs.removeWhere((tab) => tab.sessionId == sessionId);
    if (tabs.isEmpty) _tabs.remove(parent);
  }
}
