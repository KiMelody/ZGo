import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/widgets/swipe_actions.dart';

/// A row with one swipe action, plus tap counters for both layers.
(Widget, List<int>) harness() {
  final taps = <int>[0, 0]; // [row taps, action taps]
  final row = SwipeActionsRow(
    actions: [
      SwipeAction(
        icon: Icons.archive_outlined,
        label: '归档',
        color: Colors.blue,
        onTap: () => taps[1]++,
      ),
    ],
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

    await tester.drag(find.text('任务'), const Offset(-120, 0));
    await tester.pumpAndSettle();

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
    await tester.drag(find.text('任务'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    // The close-scrim sits above the row, so the tap lands on it, not the text.
    await tester.tap(find.text('任务'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(taps[0], 1);
    expect(taps[1], 0);

    // Closed again → the row is live once more.
    await tester.tap(find.text('任务'));
    expect(taps[0], 2);
  });
}
