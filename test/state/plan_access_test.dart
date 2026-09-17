import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/state/device_session.dart';

void main() {
  group('parsePlanAccess', () {
    test('zai coding-plan id → accountAccess pair', () {
      final plan = DeviceSession.parsePlanAccess(
          'account:zai-individual-coding-plan');
      expect(plan, {
        'providerId': 'account:zai-individual-coding-plan',
        'accountAccess': {
          'type': 'zhipu-account',
          'family': 'zai',
          'planKind': 'individual-coding-plan',
        },
      });
    });

    test('bigmodel family parses', () {
      final plan =
          DeviceSession.parsePlanAccess('account:bigmodel-team-coding-plan');
      expect(plan!['accountAccess'],
          {'type': 'zhipu-account', 'family': 'bigmodel', 'planKind': 'team-coding-plan'});
    });

    test('non-account provider → null', () {
      expect(DeviceSession.parsePlanAccess('openrouter/glm-4.6'), isNull);
      expect(DeviceSession.parsePlanAccess(''), isNull);
    });

    test('account prefix with unknown family → null', () {
      // The family enum is zai|bigmodel; anything else is not a coding-plan
      // route and must fall back, not send a bogus accountAccess.
      expect(DeviceSession.parsePlanAccess('account:claude-max'), isNull);
      expect(DeviceSession.parsePlanAccess('account:zai'), isNull);
    });
  });
}
