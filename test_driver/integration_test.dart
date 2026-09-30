// Host-side driver for integration_test runs. The SDK's integrationDriver
// ships without an onScreenshot hook, so screenshots ride back inside
// reportData['screenshots'] ({screenshotName, bytes}); this driver unpacks
// them to PNGs (see docs/store/SCREENSHOTS.md).
//
//   ZLINKER_SHOT_DIR=docs/screenshots flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/screenshots_test.dart -d <device> \
//     --dart-define=SHOT_LOCALE=en-US
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  final dir = Platform.environment['ZLINKER_SHOT_DIR'] ?? 'build/screenshots';
  await Directory(dir).create(recursive: true);
  await integrationDriver(
    responseDataCallback: (data) async {
      for (final shot in (data?['screenshots'] as List<dynamic>? ?? <dynamic>[])) {
        final name = shot['screenshotName'] as String;
        final bytes = (shot['bytes'] as List<dynamic>).cast<int>();
        await File('$dir/$name.png').writeAsBytes(bytes);
        stdout.writeln('saved $dir/$name.png (${bytes.length} bytes)');
      }
    },
  );
}
