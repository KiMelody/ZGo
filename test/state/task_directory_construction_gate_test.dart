import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Production construction gate (design 10-29 §2.12): the merged directory
/// has exactly ONE production construction site — `TaskHomeService` builds
/// a `TaskDirectoryView` per dirty revision. Everything else reaches it
/// through `DeviceSession.taskDirectory` (getter delegation), so no widget
/// or state file may hand-build the pure core. Tests may still construct
/// `TaskDirectory` directly (the pure-core contract).
void main() {
  test('lib/ builds the merged directory exactly once, in TaskHomeService',
      () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final viewPattern = RegExp(r'\bTaskDirectoryView\s*\((?!\s*\{)');
    final directoryPattern = RegExp(r'\bTaskDirectory\s*\(');
    final viewSites = <String>[];
    final directorySites = <String>[];

    for (final file in files) {
      final normalized = file.path.replaceAll(r'\', '/');
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final where = '$normalized:${i + 1}';
        if (viewPattern.hasMatch(lines[i])) {
          viewSites.add(where);
        }
        // The pure core's own constructor declaration is the only allowed
        // non-service occurrence.
        if (directoryPattern.hasMatch(lines[i]) &&
            !normalized.endsWith('lib/state/task_directory.dart')) {
          directorySites.add(where);
        }
      }
    }

    expect(viewSites, hasLength(1),
        reason: 'TaskDirectoryView must be constructed exactly once: '
            '$viewSites');
    expect(viewSites.single, contains('lib/state/task_home_service.dart:'),
        reason: 'the single construction lives in TaskHomeService');
    expect(directorySites, isEmpty,
        reason: 'no production file may hand-build TaskDirectory: '
            '$directorySites');
  });
}
