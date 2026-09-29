import 'package:flutter/material.dart';

/// Shared bottom-sheet skeleton for form / menu sheets: keyboard inset,
/// safe area, a fraction-of-screen height cap and overflow scrolling in one
/// box, so landscape (≈390px tall) can no longer RenderFlex-overflow a
/// fixed `Column`.
///
/// The caller MUST open the sheet with `isScrollControlled: true` — without
/// it the modal caps the sheet at 9/16 screen height and this scaffold
/// never gets the room it is allowed to use. Content keeps its own
/// horizontal padding; this scaffold only owns the four behaviours above.
///
/// Already-compliant sheets with custom structures (AutomationSheet,
/// _FetchModelsSheet, _UsageSheet, _SubagentSheet, mention_sheet) stay on
/// their own skeletons by design.
Widget zSheetScaffold(
  BuildContext context, {
  double maxHeightFactor = 0.85,
  required Widget child,
}) {
  return Padding(
    // Keyboard: lift the content above the IME (the sheet route sits above
    // the Scaffold, so the raw viewInsets apply here).
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * maxHeightFactor,
        ),
        child: SingleChildScrollView(child: child),
      ),
    ),
  );
}
