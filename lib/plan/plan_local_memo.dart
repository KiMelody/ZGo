import 'package:shared_preferences/shared_preferences.dart';

/// Non-sensitive local memory for the plan plane: the latest plan expiry
/// date ever observed in a successful snapshot. The server silently drops
/// expired buckets (`billing/balance` keeps returning code=0 with
/// `balances:[]`), so without this memo an expired plan is indistinguishable
/// from never having had one. A date is not a credential — it deliberately
/// lives in shared_preferences, never in secure storage or beside the token.
abstract class PlanLocalMemo {
  Future<DateTime?> readPlanExpiry();
  Future<void> writePlanExpiry(DateTime d);
  Future<void> clearPlanExpiry();
}

/// [PlanLocalMemo] backed by shared_preferences: one epoch-milliseconds int
/// key. The instance is resolved lazily per call (SharedPreferences itself
/// memoizes), so merely constructing the memo never spawns a future that
/// could fail unawaited. Callers own the never-throw contract (the
/// controller wraps every memo access); a failed read or write degrades to
/// "no memory" there.
class SharedPrefsPlanMemo implements PlanLocalMemo {
  static const _expiryKey = 'zgo.plan.last_expiry';

  @override
  Future<DateTime?> readPlanExpiry() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_expiryKey);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  @override
  Future<void> writePlanExpiry(DateTime d) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_expiryKey, d.millisecondsSinceEpoch);
  }

  @override
  Future<void> clearPlanExpiry() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_expiryKey);
  }
}
