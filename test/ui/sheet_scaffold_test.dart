import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/widgets/sheet_scaffold.dart';

/// Landscape sheet surface (logical 844×390, DPR 1.0).
void useLandscape(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(844, 390);
  addTearDown(tester.view.reset);
}

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

/// Opens [child] inside the exact modal skeleton the migrated sheets use
/// (`isScrollControlled: true` — the scaffold's documented requirement).
Future<void> pumpSheet(WidgetTester tester, Widget child) async {
  useLandscape(tester);
  await tester.pumpWidget(wrap(Builder(
    builder: (context) => TextButton(
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => zSheetScaffold(context, child: child),
      ),
      child: const Text('open'),
    ),
  )));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('zContentMaxWidth matches the chat message-column cap',
      (tester) async {
    expect(zContentMaxWidth, 848);
  });

  testWidgets('zScreenPadding: no safe-area inset = the fixed 16px edge',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    EdgeInsets captured = EdgeInsets.zero;
    await tester.pumpWidget(wrap(Builder(
      builder: (context) {
        captured = zScreenPadding(context, bottom: 96);
        return const SizedBox.shrink();
      },
    )));
    expect(captured, const EdgeInsets.fromLTRB(16, 16, 16, 96));
  });

  testWidgets('zScreenPadding: horizontal cutout insets stack onto 16px',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(left: 44, right: 44);
    addTearDown(tester.view.reset);
    EdgeInsets captured = EdgeInsets.zero;
    await tester.pumpWidget(wrap(Builder(
      builder: (context) {
        captured = zScreenPadding(context);
        return const SizedBox.shrink();
      },
    )));
    expect(captured, const EdgeInsets.fromLTRB(60, 16, 60, 0));
  });

  testWidgets(
      'scaffold caps a tall sheet at 0.85 × screen height and '
      'scrolls the rest (844×390)', (tester) async {
    await pumpSheet(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 40; i++) ListTile(title: Text('row $i')),
        ],
      ),
    );
    expect(tester.takeException(), isNull);

    // The sheet body is capped below the full 390px viewport.
    final scrollable = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scrollable, findsOneWidget);
    expect(tester.getSize(scrollable).height, closeTo(0.85 * 390, 1.0));

    // Overflowing content stays reachable through the scroll.
    await tester.scrollUntilVisible(find.text('row 39'), 200,
        scrollable: find.descendant(
            of: find.byType(BottomSheet), matching: find.byType(Scrollable)));
    expect(find.text('row 39'), findsOneWidget);
  });

  testWidgets(
      'scaffold lifts content above a keyboard inset and keeps the '
      'bottom button tappable (844×390 + 250px IME)', (tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    addTearDown(tester.view.reset);
    await pumpSheet(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 20; i++) ListTile(title: Text('field $i')),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: () {},
              child: const Text('save'),
            ),
          ),
        ],
      ),
    );
    expect(tester.takeException(), isNull);

    // The IME shrinks the room to 140px: content scrolls instead of
    // overflowing, and the bottom save button scrolls into the strip
    // above the keyboard and stays tappable there.
    final keyboardTop = 390.0 - 250.0;
    await tester.scrollUntilVisible(find.text('save'), 200);
    final buttonTop = tester.getTopLeft(find.text('save')).dy;
    expect(buttonTop, lessThan(keyboardTop),
        reason: 'the scaffold bottom padding must clear the IME');
    expect(find.text('save').hitTestable(), findsOneWidget);
  });
}
