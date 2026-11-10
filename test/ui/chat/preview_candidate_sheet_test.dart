import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/preview_candidate_sheet.dart';
import 'package:zgo/ui/chat/relative_link_resolver.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

Widget _wrap(Widget child, {String locale = 'zh-CN'}) => MaterialApp(
      theme: buildDarkTheme(),
      builder: (context, child) => UiSettingsProvider(
        settings: UiSettings()..locale = locale,
        child: child!,
      ),
      home: Scaffold(body: child),
    );

void main() {
  const candidates = [
    PreviewCandidate(path: '/ws/docs/a/adr.md', label: 'docs/a/adr.md'),
    PreviewCandidate(path: '/ws/docs/b/adr.md', label: 'docs/b/adr.md'),
  ];

  testWidgets('renders one tappable tile per candidate with its relative path',
      (tester) async {
    String? picked;
    await tester.pumpWidget(_wrap(Builder(
      builder: (context) => Center(
        child: FilledButton(
          onPressed: () async {
            picked = await showPreviewCandidateSheet(
              context,
              candidates: candidates,
            );
          },
          child: const Text('open'),
        ),
      ),
    )));

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('找到多个同名文件'), findsOneWidget);
    expect(find.text('docs/a/adr.md'), findsOneWidget);
    expect(find.text('docs/b/adr.md'), findsOneWidget);

    await tester.tap(find.text('docs/b/adr.md'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(picked, '/ws/docs/b/adr.md');
  });

  testWidgets('en locale renders the English heading', (tester) async {
    await tester.pumpWidget(_wrap(
      PreviewCandidateSheet(candidates: candidates),
      locale: 'en-US',
    ));

    expect(find.text('Several files match that name'), findsOneWidget);
    expect(find.text('docs/a/adr.md'), findsOneWidget);
  });

  testWidgets('a single candidate still renders (defensive: the caller '
      'auto-opens, but the sheet must not crash)', (tester) async {
    await tester.pumpWidget(_wrap(const PreviewCandidateSheet(
      candidates: [PreviewCandidate(path: '/ws/x.md', label: 'x.md')],
    )));

    expect(find.text('x.md'), findsOneWidget);
  });

  testWidgets('candidate tiles keep a touch target of at least 44x48 '
      '(interaction-patterns §2)', (tester) async {
    await tester.pumpWidget(_wrap(const PreviewCandidateSheet(
      candidates: candidates,
    )));

    final tiles = find.byType(InkWell).evaluate().toList();
    expect(tiles, isNotEmpty);
    for (final tile in tiles) {
      final size = (tile.findRenderObject() as RenderBox).size;
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });
}
