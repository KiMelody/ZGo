import 'connection_params.dart';

/// Where a capability's version value comes from.
enum CapabilitySource {
  /// Only the paired link's `app_version` snapshot. The link is generated
  /// once and can lag the running desktop, so a stale snapshot answers
  /// "unsupported" on a newer desktop.
  snapshot,

  /// The live `desktopAppVersion` carried by the latest bootstrap frame
  /// when present, else the link snapshot. A live value that parses to no
  /// version (e.g. `3.16.3-beta`) answers false and does NOT fall back to
  /// the snapshot — the live answer is authoritative once it exists.
  liveThenSnapshot,
}

/// Runtime routing of the model-provider entry (PRD 09-28 providers-revival).
///
/// - [providerSettings]: a known 3.14+ desktop — the `provider-settings`
///   channel page, zero probes.
/// - [legacy]: a known older desktop — the `model-provider` page verbatim.
/// - [unknown]: the link carries no usable version — the page probes at
///   runtime before deciding.
enum ProviderRoute { legacy, providerSettings, unknown }

/// Named desktop capability matrix (protocol layer, widget-free).
///
/// The single owner of desktop version thresholds: every consumer reads
/// named booleans here instead of comparing `app_version` inline. Version
/// thresholds and their sources are the wire contract and live in this
/// file's [_gate] call sites (ADR-0003: method *names* still go through
/// MethodProbe at runtime — this object holds no method literals).
///
/// Live values are callbacks evaluated on every read, never cached at
/// construction: the state layer creates one long-lived instance, and a
/// construction-time copy of the live version would reproduce the snapshot
/// lag this matrix exists to remove.
class DesktopCapabilities {
  DesktopCapabilities(
    this.params, {
    String? Function()? liveDesktopVersion,
    bool? Function()? providerVerdict,
  })  : _liveDesktopVersion = liveDesktopVersion,
        _providerVerdict = providerVerdict;

  final RemoteConnectionParams params;

  /// Live desktop version callback; null when the host has no live source
  /// (RemoteClient constructs without one). Re-evaluated per read.
  final String? Function()? _liveDesktopVersion;

  /// Read-only view of the host's cached probe verdict (null = not probed).
  /// Probe orchestration (await, dedup, call counts) stays with the host;
  /// this object never starts a probe.
  final bool? Function()? _providerVerdict;

  bool _gate(
    int major,
    int minor,
    int patch, {
    required CapabilitySource source,
  }) {
    if (source == CapabilitySource.liveThenSnapshot) {
      final live = _liveDesktopVersion?.call();
      // Live answer is authoritative even when malformed: false, no
      // snapshot fallback (same semantics the bridge-addressing gate has
      // carried since the 2026-10-26 live fix).
      if (live != null) return versionAtLeast(live, major, minor, patch);
    }
    return params.atLeast(major, minor, patch);
  }

  // --- Protocol capabilities -------------------------------------------------

  /// 3.17.1 archived-row delete pair (`deleteArchivedTask` /
  /// `deleteArchivedTasks`) — the archive view's delete entries. The task
  /// service gained the methods in 3.16.3 but the channel registration is
  /// only confirmed for 3.17.1, hence live-then-snapshot.
  bool get archivedDelete =>
      _gate(3, 17, 1, source: CapabilitySource.liveThenSnapshot);

  /// 3.16.3 bridge-open project/host addressing second leg.
  bool get bridgeAddressing =>
      _gate(3, 16, 3, source: CapabilitySource.liveThenSnapshot);

  /// 3.16.2 project layer: merged workspace list + resolver reads.
  bool get projectLayer =>
      _gate(3, 16, 2, source: CapabilitySource.snapshot);

  /// 3.16.2 `createSession` project attribution.
  bool get projectCreateAddressing =>
      _gate(3, 16, 2, source: CapabilitySource.liveThenSnapshot);

  /// 3.12.3 task-options / presentation variant of workspace preparation.
  bool get prepareWorkspaceTaskOptions =>
      _gate(3, 12, 3, source: CapabilitySource.liveThenSnapshot);

  /// 3.12.3 full-parameter usage/quota wire (one capability, five sites).
  bool get quotaWire =>
      _gate(3, 12, 3, source: CapabilitySource.liveThenSnapshot);

  /// 3.12.3 workspace scope prefix + new wire for automation / off-peak
  /// (both are `late final` port constructor parameters).
  bool get scopeFirstWire =>
      _gate(3, 12, 3, source: CapabilitySource.snapshot);

  /// 3.14.0 off-peak take-a-number status probes.
  bool get offPeakStatusProbes =>
      _gate(3, 14, 0, source: CapabilitySource.snapshot);

  /// 3.12.3 replayable command queue hook (paired gate A).
  bool get replayableQueue =>
      _gate(3, 12, 3, source: CapabilitySource.snapshot);

  /// 3.12.3 workspace hook review UI clientHello capability (paired gate B).
  bool get workspaceHookReviewUi =>
      _gate(3, 12, 3, source: CapabilitySource.snapshot);

  /// 3.14.0 model-selection catalog (`model-provider` was removed).
  bool get modelSelectionCatalog =>
      _gate(3, 14, 0, source: CapabilitySource.snapshot);

  /// 3.18.0 conservative floor for the `conversationQuotes` sendText field
  /// (quote-comment-lite, PRD R4). The field family is present in
  /// `editUserQuery` since 3.15.1; `sendText`'s introduction is not
  /// fully proven, and an unsupported desktop silently strips unknown keys
  /// (zod default — the citation disappears without an error). Prefer the
  /// live bootstrap version: the paired link's snapshot can lag a running
  /// desktop.
  bool get conversationQuoteComment =>
      _gate(3, 18, 0, source: CapabilitySource.liveThenSnapshot);

  // --- UI-derived surface ----------------------------------------------------

  /// Cached legacy-channel verdict; null until probed, re-read per call.
  bool? get providerVerdict => _providerVerdict?.call();

  /// Three-state entry route (see [ProviderRoute]).
  ProviderRoute get providerRoute {
    if (params.atLeast(3, 14, 0)) return ProviderRoute.providerSettings;
    if (params.hasKnownVersion) return ProviderRoute.legacy;
    return ProviderRoute.unknown;
  }

  /// Whether the model-provider entry stays enabled: known new and unknown
  /// versions are enabled, known old versions follow the cached verdict
  /// (unknown verdict = available; only an explicit false disables).
  bool get providersEntryEnabled =>
      providerRoute != ProviderRoute.legacy || providerVerdict != false;

  /// Whether the entry should prime the legacy-channel probe: known 3.14+
  /// desktops skip the doomed call; known old and unknown versions run it.
  bool get shouldPrimeProviderProbe =>
      providerRoute != ProviderRoute.providerSettings;
}
