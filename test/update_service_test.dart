import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/update/app_channel.dart';
import 'package:zlinker/update/update_service.dart';

void main() {
  group('compareVersions', () {
    test('equal versions', () {
      expect(compareVersions('1.0.0', '1.0.0'), 0);
      expect(compareVersions('1.2', '1.2.0'), 0);
    });

    test('newer detection', () {
      expect(compareVersions('1.1.0', '1.0.0'), greaterThan(0));
      expect(compareVersions('2.0.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('1.0.10', '1.0.9'), greaterThan(0));
    });

    test('older detection', () {
      expect(compareVersions('0.9.0', '1.0.0'), lessThan(0));
      expect(compareVersions('1.0.9', '1.0.10'), lessThan(0));
    });

    test('malformed segments treated as zero', () {
      expect(compareVersions('x.y', '0.0.0'), 0);
      expect(compareVersions('1.x', '1.0.0'), 0);
    });
  });

  group('app channel', () {
    test('default channel is github', () {
      // Not overridden in `flutter test`, so the default applies.
      expect(appChannel, 'github');
    });

    test('store listing urls only exist on store channels', () {
      // On the default github channel there is no store listing.
      expect(storeListingUrl, isNull);
    });
  });
}
