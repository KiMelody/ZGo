import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

/// Phase of one entitlement snapshot — mirrors the web entitlement panel's
/// status enum (Active/Error/Loading/LoginRequired/NoPlan/NotConfigured);
/// the desktop's `unavailableReason` maps onto these.
enum EntitlementPhase {
  loading,
  ok,
  notConfigured,
  noPlan,
  loginRequired,
  error,
}

/// Immutable result of one entitlement fetch, shared by the usage page and
/// the chat warning banner.
class EntitlementView {
  final EntitlementPhase phase;

  /// Raw snapshot (generatedAt / authenticated / unavailableReason /
  /// provider / remaining / subscription / quota). Rendering stays limited
  /// to the live-probed field structure — no invented fields.
  final Map<String, dynamic>? data;
  final DateTime? fetchedAt;
  final String? error;

  const EntitlementView({
    required this.phase,
    this.data,
    this.fetchedAt,
    this.error,
  });

  /// Token/credit limit types whose exhaustion drives the chat warning
  /// banner — the official bundle's token-class group. `TIME_LIMIT` is the
  /// monthly built-in MCP tool quota (search-prime / web-reader / zread)
  /// and is deliberately excluded: it does not limit LLM chat, so topping
  /// it out must not raise the "switch model" banner
  /// (research/entitlement-limits-probe.md).
  static const _tokenLimitTypes = {'TOKENS_LIMIT', 'CREDIT_LIMIT'};

  /// Whether the snapshot reports a token/credit limit topped out.
  ///
  /// The top-level `remaining` block is the `TIME_LIMIT` aggregate mirror
  /// and never participates: a zero count there means the monthly MCP
  /// calls ran out, not the chat plan.
  bool get exhausted {
    final quota = data?['quota'];
    if (quota is! Map || quota['limits'] is! List) return false;
    for (final limit in quota['limits'] as List) {
      if (limit is! Map) continue;
      if (!_tokenLimitTypes.contains(limit['type'])) continue;
      final percentage = limit['percentage'];
      if (percentage is num && percentage >= 100) return true;
    }
    return false;
  }
}

/// Session-wide entitlement fetch policy: one cached snapshot per device
/// session, refreshed when a page opens (silently reused within
/// [staleness]) or on an explicit force. No background timer — the desktop
/// pushes no quota events (research/entitlement-probe.md), so fetching
/// happens only when a consumer opens or refreshes.
///
/// A failed fetch keeps the previous payload (and its fetch time) and only
/// flips the phase to [EntitlementPhase.error], so a transient RPC error
/// never blanks already-known data. Errors are never served from cache.
class EntitlementPoller extends ValueNotifier<EntitlementView> {
  final Future<dynamic> Function() fetch;
  final Duration staleness;

  static const defaultStaleness = Duration(minutes: 5);

  Future<EntitlementView>? _inFlight;

  EntitlementPoller({
    required this.fetch,
    this.staleness = defaultStaleness,
  }) : super(const EntitlementView(phase: EntitlementPhase.loading));

  /// Whether the current snapshot may stand in for a refresh: fetched
  /// recently enough and not an error (errors must re-fetch).
  bool get _cacheFresh {
    final view = value;
    final at = view.fetchedAt;
    if (at == null || view.phase == EntitlementPhase.error) return false;
    return clock.now().difference(at) < staleness;
  }

  /// Returns the cached snapshot within the staleness window, otherwise
  /// fetches a fresh one. [force] bypasses the cache. Concurrent callers
  /// share one in-flight fetch.
  Future<EntitlementView> refresh({bool force = false}) {
    if (!force && _cacheFresh) return Future.value(value);
    return _inFlight ??= _fetchNow();
  }

  Future<EntitlementView> _fetchNow() async {
    // No payload ever landed (first load, or failures only so far): show
    // loading instead of holding the stale error view. An existing payload
    // stays visible while it refreshes.
    if (value.fetchedAt == null && value.phase != EntitlementPhase.loading) {
      value = const EntitlementView(phase: EntitlementPhase.loading);
    }
    try {
      final res = await fetch();
      if (res is! Map) {
        throw StateError('entitlement: unexpected payload');
      }
      final data = Map<String, dynamic>.from(res);
      value = EntitlementView(
        phase: phaseOf(data),
        data: data,
        fetchedAt: clock.now(),
      );
    } catch (e) {
      // Keep the previous payload visible; only phase and error change.
      value = EntitlementView(
        phase: EntitlementPhase.error,
        data: value.data,
        fetchedAt: value.fetchedAt,
        error: '$e',
      );
    } finally {
      _inFlight = null;
    }
    return value;
  }

  /// Maps a raw snapshot onto the render phases (design.md table):
  /// `unavailableReason=='not_configured'` → [EntitlementPhase.notConfigured],
  /// `authenticated!=true` → [EntitlementPhase.loginRequired],
  /// authenticated without provider and remaining → [EntitlementPhase.noPlan],
  /// else [EntitlementPhase.ok].
  static EntitlementPhase phaseOf(Map<String, dynamic> data) {
    if (data['unavailableReason'] == 'not_configured') {
      return EntitlementPhase.notConfigured;
    }
    if (data['authenticated'] != true) return EntitlementPhase.loginRequired;
    if (data['provider'] == null && data['remaining'] == null) {
      return EntitlementPhase.noPlan;
    }
    return EntitlementPhase.ok;
  }
}
