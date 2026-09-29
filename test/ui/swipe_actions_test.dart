import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/widgets/swipe_actions.dart';

const _fg = Color(0xFF0284C7); // ZColors.sky600 — foreground-tone stand-in.

/// A row with one swipe action, plus tap counters for both layers.
(Widget, List<int>) harness() {
  final taps = <int>[0, 0]; // [row taps, action taps]
  final row = SwipeActionsRow(
    actions: [
      SwipeAction(
        icon: Icons.archive_outlined,
        label: '归档',
        fgColor: _fg,
        onTap: () => taps[1]++,
      ),
    ],
    trayRadius: ZRadius.field,
    childRadius: ZRadius.field,
    child: InkWell(
      onTap: () => taps[0]++,
      child: const SizedBox(
        height: 62,
        child: Center(child: Text('任务')),
      ),
    ),
  );
  return (MaterialApp(home: Scaffold(body: row)), taps);
}

/// Drags the row fully open and settles the snap animation.
Future<void> _open(WidgetTester tester) async {
  await tester.drag(find.text('任务'), const Offset(-120, 0));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('closed row keeps its own tap handling', (tester) async {
    final (app, taps) = harness();
    await tester.pumpWidget(app);
    await tester.tap(find.text('任务'));
    expect(taps[0], 1);
    expect(taps[1], 0);
  });

  testWidgets('swiping left opens the tray and runs the exposed action',
      (tester) async {
    final (app, taps) = harness();
    await tester.pumpWidget(app);

    await _open(tester);

    await tester.tap(find.text('归档'));
    await tester.pumpAndSettle();
    expect(taps[1], 1);
    // The row tap never fired: the drag did not turn into a row tap.
    expect(taps[0], 0);
  });

  testWidgets('a short drag snaps back and tapping the open row closes it',
      (tester) async {
    final (app, taps) = harness();
    await tester.pumpWidget(app);

    // Below half of the 64px action width → closed again.
    await tester.drag(find.text('任务'), const Offset(-20, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('任务'));
    expect(taps[0], 1);

    // Fully open, then a row tap closes the tray instead of opening the task.
    await _open(tester);
    // The close-scrim sits above the row, so the tap lands on it, not the text.
    await tester.tap(find.text('任务'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(taps[0], 1);
    expect(taps[1], 0);

    // Closed again → the row is live once more.
    await tester.tap(find.text('任务'));
    expect(taps[0], 2);
  });

  testWidgets('tray is a neutral tile surface with foreground-tone content',
      (tester) async {
    final (app, _) = harness();
    await tester.pumpWidget(app);
    await _open(tester);

    final context = tester.element(find.text('归档'));
    // Nearest Material above the action: the shared neutral tray surface
    // (the app-root canvas Material sits further up).
    final materials = find.ancestor(
      of: find.text('归档'),
      matching: find.byType(Material),
    );
    expect(materials, findsWidgets);
    final tray = tester.widget<Material>(materials.first);
    expect(tray.color, ZInk.tile(context));

    // F1: square seam side (left), rounded outer edge (right) = trayRadius.
    final shape = tray.shape! as RoundedRectangleBorder;
    final trayRadius = shape.borderRadius as BorderRadius;
    expect(trayRadius.topLeft, Radius.zero);
    expect(trayRadius.bottomLeft, Radius.zero);
    expect(trayRadius.topRight, const Radius.circular(ZRadius.field));
    expect(trayRadius.bottomRight, const Radius.circular(ZRadius.field));

    // Icon + label share the action's foreground tone; no white hardcoding.
    expect(tester.widget<Icon>(find.byIcon(Icons.archive_outlined)).color,
        _fg);
    expect(
      tester.widget<Text>(find.text('归档')).style!.color,
      _fg,
    );
  });

  testWidgets('F1 slot pad: tray stays off-canvas at rest and pads '
      'childRadius under the seam side when open', (tester) async {
    final (app, _) = harness();
    await tester.pumpWidget(app);

    Rect trayRect() => tester.getRect(
          find.ancestor(
            of: find.byType(Row),
            matching: find.byType(Positioned),
          ).first,
        );

    // At rest (offset 0) the tray sits fully beyond the right edge — the
    // closed row is pixel-identical to an unwrapped one.
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(trayRect().left, size.width);

    // Dragged open: the tray's left edge runs childRadius under the row's
    // right edge, so the row's rounded notches reveal the slot colour.
    await _open(tester);
    final rect = trayRect();
    expect(rect.left, size.width - SwipeActionsRow.actionWidth - ZRadius.field);
    expect(
        rect.width, SwipeActionsRow.actionWidth + ZRadius.field);

    // No ClipRRect wrapper on the child — the row keeps its own painting.
    expect(find.byType(ClipRRect), findsNothing);
  });
}
