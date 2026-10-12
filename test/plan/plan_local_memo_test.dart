import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/plan/plan_local_memo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // One test only: SharedPreferences.getInstance() memoizes its instance for
  // the whole isolate, so a second setMockInitialValues seed would be
  // invisible after the first getInstance().
  test('round-trips an expiry through shared_preferences', () async {
    final seeded = DateTime.fromMillisecondsSinceEpoch(1000000000000);
    SharedPreferences.setMockInitialValues({
      'zgo.plan.last_expiry': seeded.millisecondsSinceEpoch,
    });
    final memo = SharedPrefsPlanMemo();

    // Pre-seeded value from an earlier run reads back.
    expect(await memo.readPlanExpiry(), seeded);

    final d = DateTime.fromMillisecondsSinceEpoch(1795000000000);
    await memo.writePlanExpiry(d);
    expect(await memo.readPlanExpiry(), d);

    await memo.clearPlanExpiry();
    expect(await memo.readPlanExpiry(), isNull);
  });
}
