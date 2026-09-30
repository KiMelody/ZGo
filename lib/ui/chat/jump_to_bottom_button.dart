import 'package:flutter/material.dart';

import '../theme.dart';
import '../ui_settings.dart';

/// Floating「jump to the newest message」control, shown only while the reader
/// is scrolled away from the bottom. Circular icon-only button on the card
/// surface (no label, no unread count). Shared by the chat page and the
/// subagent detail page (task 09-23 R1a).
class JumpToBottomButton extends StatelessWidget {
  final bool visible;
  final VoidCallback onPressed;

  const JumpToBottomButton({
    super.key,
    required this.visible,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // Card surface (darkCard / lightCard) + hairline border + a light shadow,
    // so the button reads as floating over the stream.
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      // Stays mounted so the show/hide can cross-fade; taps must never reach
      // it while transparent.
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: IconButton(
          tooltip: tr(context, 'chat.jumpToBottom'),
          onPressed: onPressed,
          icon: const Icon(Icons.arrow_downward, size: 20),
          style: IconButton.styleFrom(
            backgroundColor: scheme.surfaceContainerHighest,
            foregroundColor: ZInk.muted(context),
            minimumSize: const Size(40, 40),
            maximumSize: const Size(40, 40),
            padding: EdgeInsets.zero,
            elevation: 3,
            surfaceTintColor: Colors.transparent,
            shape: CircleBorder(
              side: BorderSide(color: ZInk.hairline(context)),
            ),
          ),
        ),
      ),
    );
  }
}
