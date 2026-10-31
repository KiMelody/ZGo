/// Pure parsers for the z.ai billing REST plane (`zcode.z.ai/api/v1/
/// zcode-plan/billing/*`, wire facts in the 10-11-plan-quota-query task).
///
/// Zero IO, widget-free. Every field is optional and defensively typed:
/// shape drift degrades to `null` / empty collections instead of throwing,
/// so the UI hides an item rather than guessing a value (the null-handling
/// discipline shared with the entitlement quota spec).
library;

/// One balance bucket of the account's coding plan (a row of
/// `data.balances[]`).
class PlanBucket {
  final String entitlementId;
  final String showName;

  /// `capabilities[]` items carrying the `model:` prefix, prefix stripped
  /// (e.g. `model:glm-5.3-flash` → `glm-5.3-flash`).
  final List<String> modelCapabilities;

  /// Unit counts; `null` = absent or wrong-typed in the payload.
  final int? total;
  final int? used;
  final int? remaining;
  final int? available;

  /// `expires_at` (falling back to `period_end`).
  final DateTime? periodEnd;

  const PlanBucket({
    required this.entitlementId,
    required this.showName,
    required this.modelCapabilities,
    required this.total,
    required this.used,
    required this.remaining,
    required this.available,
    required this.periodEnd,
  });
}

/// One entitlement row of a plan definition (`data.plans[].entitlements[]`).
/// The grant is a plan fact, not a balance: `grant_units` is what the plan
/// allocates, never a remaining/used figure.
class PlanEntitlement {
  final String entitlementId;
  final String showName;

  /// `grant_units`; `null` = absent or wrong-typed in the payload.
  final int? grantUnits;

  /// `capabilities[]` items carrying the `model:` prefix, prefix stripped
  /// (same discipline as [PlanBucket.modelCapabilities]).
  final List<String> modelCapabilities;

  /// `effective_at` — when the grant starts. The server may report the plan
  /// active before this moment and before any balance bucket exists.
  final DateTime? effectiveAt;

  const PlanEntitlement({
    required this.entitlementId,
    required this.showName,
    required this.grantUnits,
    required this.modelCapabilities,
    required this.effectiveAt,
  });
}

/// A billing-plane plan definition (`data.plans[]` row, shared by
/// `billing/balance` and `billing/current`).
class PlanDefinition {
  final String id;
  final String name;
  final String status;

  /// `starts_at` / `ends_at` (epoch on the wire; null when absent).
  final DateTime? startsAt;
  final DateTime? endsAt;

  /// `entitlements[]`; empty when absent or unparseable.
  final List<PlanEntitlement> entitlements;

  const PlanDefinition({
    required this.id,
    required this.name,
    required this.status,
    this.startsAt,
    this.endsAt,
    this.entitlements = const [],
  });

  /// The server's own plan-existence verdict (official `hasActiveStartPlan`):
  /// status only. `ends_at` expiry is judged server-side; the card merely
  /// renders the date it is given.
  bool get isActive => status == 'active';

  /// Latest `effective_at` across entitlements, `null` when none carries a
  /// date. A plan whose max grant moment is still ahead has not started
  /// granting yet.
  DateTime? get latestEffectiveAt {
    DateTime? latest;
    for (final e in entitlements) {
      final at = e.effectiveAt;
      if (at != null && (latest == null || at.isAfter(latest))) latest = at;
    }
    return latest;
  }
}

/// The account-level plan data pulled at one moment (the "数据时间" the UI
/// shows when a later refresh fails).
class PlanSnapshot {
  final DateTime fetchedAt;
  final List<PlanBucket> buckets;

  /// `data.plans[]` — plan existence and grants. The server reports an
  /// active plan before its balance buckets materialize, so the empty-bucket
  /// state reads "has a plan" from here (official `hasActiveStartPlan`) and
  /// only the numbers from [buckets].
  final List<PlanDefinition> plans;

  const PlanSnapshot({
    required this.fetchedAt,
    required this.buckets,
    this.plans = const [],
  });

  static final PlanSnapshot empty = PlanSnapshot(
    fetchedAt: DateTime.fromMillisecondsSinceEpoch(0),
    buckets: const [],
  );

  /// Plans the server currently reports active, in wire order.
  List<PlanDefinition> get activePlans => [
        for (final p in plans)
          if (p.isActive) p,
      ];

  bool get hasActivePlan => plans.any((p) => p.isActive);
}

/// Envelope `code` from a decoded response body (`{code,msg,data,logid}`);
/// `null` when the body is not a map or the code is not an int (a numeric
/// string is shape drift, not a code). The API layer classifies non-zero
/// codes as [PlanApiError].
int? envelopeCode(dynamic body) {
  final v = body is Map ? body['code'] : null;
  return v is int ? v : null;
}

/// Envelope `data` payload; `null` when absent.
dynamic envelopeData(dynamic body) => body is Map ? body['data'] : null;

/// Parses the balance endpoint's `data` into a snapshot. Malformed input
/// (wrong type, missing `balances`/`plans`, junk rows) yields empty
/// collections — never a throw.
PlanSnapshot parseBalanceSnapshot(
  dynamic data, {
  DateTime? fetchedAt,
}) {
  final balances = data is Map ? data['balances'] : null;
  final buckets = <PlanBucket>[];
  if (balances is List) {
    for (final row in balances) {
      if (row is! Map) continue;
      buckets.add(PlanBucket(
        entitlementId: _asString(row['entitlement_id']),
        showName: _asString(row['show_name']),
        modelCapabilities: _modelCapabilities(row['capabilities']),
        total: _asInt(row['total_units']),
        used: _asInt(row['used_units']),
        remaining: _asInt(row['remaining_units']),
        available: _asInt(row['available_units']),
        periodEnd: _asEpoch(row['expires_at']) ?? _asEpoch(row['period_end']),
      ));
    }
  }
  return PlanSnapshot(
    fetchedAt: fetchedAt ?? DateTime.now(),
    buckets: buckets,
    plans: _parsePlans(data),
  );
}

/// Parses the plan definitions out of a `billing/current`-shaped `data`
/// (same `plans[]` family as the balance response). Bad shapes → empty list.
List<PlanDefinition> parsePlanDefinitions(dynamic data) => _parsePlans(data);

List<PlanDefinition> _parsePlans(dynamic data) {
  final plans = data is Map ? data['plans'] : null;
  final out = <PlanDefinition>[];
  if (plans is List) {
    for (final row in plans) {
      if (row is! Map) continue;
      out.add(PlanDefinition(
        id: _asString(row['plan_id']),
        name: _asString(row['name']),
        status: _asString(row['status']),
        startsAt: _asEpoch(row['starts_at']),
        endsAt: _asEpoch(row['ends_at']),
        entitlements: _parseEntitlements(row['entitlements']),
      ));
    }
  }
  return out;
}

List<PlanEntitlement> _parseEntitlements(dynamic v) {
  if (v is! List) return const [];
  final out = <PlanEntitlement>[];
  for (final row in v) {
    if (row is! Map) continue;
    out.add(PlanEntitlement(
      entitlementId: _asString(row['entitlement_id']),
      showName: _asString(row['show_name']),
      grantUnits: _asInt(row['grant_units']),
      modelCapabilities: _modelCapabilities(row['capabilities']),
      effectiveAt: _asEpoch(row['effective_at']),
    ));
  }
  return out;
}

String _asString(dynamic v) => v is String ? v : '';

List<String> _modelCapabilities(dynamic v) {
  if (v is! List) return const [];
  return [
    for (final item in v)
      if (item is String && item.startsWith('model:')) item.substring(6),
  ];
}

/// Lenient int reader: ints/nums pass through, numeric strings parse,
/// everything else (bools, maps, lists) is `null` rather than a guess.
int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// Epoch reader accepting seconds and milliseconds (the wire mixes both
/// across fields; magnitudes are unambiguous above 1e11).
DateTime? _asEpoch(dynamic v) {
  final n = _asInt(v);
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    n > 100000000000 ? n : n * 1000,
  );
}
