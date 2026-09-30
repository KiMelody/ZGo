import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/remote_page.dart';

void main() {
  group('buildDeepLinkJs', () {
    test('embeds the session id as a JSON string', () {
      final js = buildDeepLinkJs('sess-123', 'My task');
      expect(js, contains('var SID = "sess-123";'));
      expect(js, contains('var TITLE = "My task";'));
    });

    test('escapes quotes and newlines in id/title', () {
      final js = buildDeepLinkJs('bad\'"\\id', 'line1\nline2"quoted"');
      expect(js, contains('var SID = "bad\'\\"\\\\id";'));
      expect(js, contains('var TITLE = "line1\\nline2\\"quoted\\"";'));
    });

    test('contains the selector contract', () {
      final js = buildDeepLinkJs('s', null);
      expect(js, contains('li[data-testid], [data-task-item-key]'));
      expect(js, contains('[data-mobile-active-task="true"]'));
      expect(js, contains('下一步|确认|进入'));
    });

    test('null title embeds as empty string', () {
      final js = buildDeepLinkJs('s', null);
      expect(js, contains('var TITLE = "";'));
    });
  });
}
