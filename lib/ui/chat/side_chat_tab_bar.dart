import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/side_chat_registry.dart';
import '../theme.dart';
import '../ui_settings.dart';

/// The two lifecycle actions of the long-press sheet (design 11-11-btw-side-chat
/// §4/§6/§7): close is a restorable collapse, destroy is permanent.
enum SideChatTabAction { close, destroy }

/// Horizontal switch strip of the chat page's side chats (task
/// 11-11-btw-side-chat, step B2). Visual baseline:
/// `.local-archive/mocks/btw-side-chat/11-12-side-chat-tabs-mock.html`.
///
/// The container decides when the strip mounts: with zero side tabs it stays
/// unmounted (mock 对照帧 — no empty band, the page is pixel-identical to the
/// pre-B2 shape). One tab per [tabs] entry plus the fixed main tab, which
/// carries no close button.
///
/// Geometry is copied from the mock's measured frame (360dp canvas). These are
/// dense-strip exceptions, not reusable tokens — the mock fixed them so the
/// strip never competes with the app bar (mock decision 4 records the same
/// deliberate departure from the 44x48 floor; the long-press sheet is the
/// full-size alternative path):
///   * bar 44 = 4 + 36 + 4, one hairline below (mock draws it as a shadow;
///     here it is a 1px rule so the 44dp interior stays exact)
///   * pill 36 high, [ZRadius.pill], 12dp left inset
///   * side pill: 8dp right inset + a 28x36 close hit box (14px glyph)
///   * gap 6, horizontal padding [ZSpacing.screen] (16)
///
/// Interaction: tap switches (selectionClick haptic, interaction-patterns §3);
/// long-press on a side tab opens the two-action sheet (mediumImpact). The
/// strip scrolls horizontally on narrow screens and reveals the active pill
/// after a switch, so an off-screen active tab is never left hidden.
class SideChatTabBar extends StatefulWidget {
  const SideChatTabBar({
    super.key,
    required this.parentSessionId,
    required this.tabs,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
    required this.onDestroy,
  });

  /// Session id of the parent conversation — the identity of the main tab.
  final String parentSessionId;

  /// Side tabs in registry order (ordinal ascending).
  final List<SideChatTab> tabs;

  /// The tab on screen (the parent id selects the main tab).
  final String activeId;

  final ValueChanged<String> onSelect;
  final ValueChanged<SideChatTab> onClose;
  final ValueChanged<SideChatTab> onDestroy;

  static const double barHeight = 44;
  static const double pillHeight = 36;
  static const double barPadY = 4;
  static const double tabGap = 6;
  static const double pillLeftInset = 12;
  static const double pillRightInset = 12;
  static const double sidePillRightInset = 8;
  static const double closeHitWidth = 28;
  static const double closeIconSize = 14;

  @override
  State<SideChatTabBar> createState() => _SideChatTabBarState();
}

class _SideChatTabBarState extends State<SideChatTabBar> {
  final ScrollController _scroller = ScrollController();
  final GlobalKey _mainKey = GlobalKey();
  final Map<String, GlobalKey> _sideKeys = {};

  @override
  void initState() {
    super.initState();
    _revealActive();
  }

  @override
  void didUpdateWidget(SideChatTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Prune keys of tabs that left the bar (close / destroy / self-heal).
    final live = {for (final tab in widget.tabs) tab.sessionId};
    _sideKeys.removeWhere((id, _) => !live.contains(id));
    if (oldWidget.activeId != widget.activeId) _revealActive();
  }

  @override
  void dispose() {
    _scroller.dispose();
    super.dispose();
  }

  GlobalKey _keyOf(String sessionId) {
    if (sessionId == widget.parentSessionId) return _mainKey;
    return _sideKeys.putIfAbsent(sessionId, GlobalKey.new);
  }

  /// Brings the active pill into view after the frame lays the bar out (the
  /// mock: "点任一 tab 也会自动滚入视口"). Jump, don't animate: a tab switch
  /// is a discrete state change, not a scroll gesture.
  void _revealActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _keyOf(widget.activeId).currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: Duration.zero,
      );
    });
  }

  void _select(String sessionId) {
    if (sessionId == widget.activeId) return;
    HapticFeedback.selectionClick();
    widget.onSelect(sessionId);
  }

  Future<void> _openMenu(SideChatTab tab) async {
    HapticFeedback.mediumImpact();
    final action = await showModalBottomSheet<SideChatTabAction>(
      context: context,
      // Nested / embedded navigators must not send the sheet to the root
      // navigator (interaction-patterns §6).
      useRootNavigator: false,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.close,
                size: 20,
                color: ZInk.iconNeutral(sheetContext),
              ),
              title: Text(tr(sheetContext, 'sideChat.menu.close')),
              onTap: () => Navigator.pop(sheetContext, SideChatTabAction.close),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                size: 20,
                color: Theme.of(sheetContext).colorScheme.error,
              ),
              title: Text(
                tr(sheetContext, 'sideChat.menu.destroy'),
                style: TextStyle(
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
              ),
              onTap: () =>
                  Navigator.pop(sheetContext, SideChatTabAction.destroy),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case SideChatTabAction.close:
        widget.onClose(tab);
      case SideChatTabAction.destroy:
        widget.onDestroy(tab);
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: SideChatTabBar.barHeight,
      // The mock draws the separating rule as an inset box-shadow, i.e. ON
      // TOP of the 44dp band (the interior stays 4+36+4). A foreground
      // decoration paints without taking layout space.
      foregroundDecoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ZInk.hairline(context))),
      ),
      child: SingleChildScrollView(
        controller: _scroller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: ZSpacing.screen,
          vertical: SideChatTabBar.barPadY,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            KeyedSubtree(
              key: _mainKey,
              child: _pill(
                context,
                tabKey: const ValueKey('side-tab-main'),
                label: tr(context, 'sideChat.tabs.main'),
                active: widget.activeId == widget.parentSessionId,
                onTap: () => _select(widget.parentSessionId),
              ),
            ),
            for (final tab in widget.tabs) ...[
              const SizedBox(width: SideChatTabBar.tabGap),
              KeyedSubtree(
                key: _keyOf(tab.sessionId),
                child: _pill(
                  context,
                  tabKey: ValueKey('side-tab-${tab.sessionId}'),
                  label: trP(
                    context,
                    'sideChat.tab.title',
                    ['${tab.ordinal}'],
                  ),
                  active: widget.activeId == tab.sessionId,
                  onTap: () => _select(tab.sessionId),
                  onLongPress: () => _openMenu(tab),
                  trailing: _closeButton(context, tab),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pill(
    BuildContext context, {
    required Key tabKey,
    required String label,
    required bool active,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    Widget? trailing,
  }) {
    final radius = BorderRadius.circular(ZRadius.pill);
    final fg = active ? ZInk.solid(context) : ZInk.muted(context);
    return Semantics(
      button: true,
      selected: active,
      child: SizedBox(
        height: SideChatTabBar.pillHeight,
        child: Material(
          // Active = one step above the page surface (the composer's card
          // family); brand sky stays reserved for links and 更多 (mock
          // decision 5).
          color: active ? ZInk.tile(context) : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            key: tabKey,
            borderRadius: radius,
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: EdgeInsets.only(
                left: SideChatTabBar.pillLeftInset,
                right: trailing == null
                    ? SideChatTabBar.pillRightInset
                    : SideChatTabBar.sidePillRightInset,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    style: ZType.body.copyWith(
                      color: fg,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: SideChatTabBar.tabGap),
                    trailing,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Close target of one side pill: 28x36 hit box with a 14px glyph (mock
  /// decision 4 — the dense-strip exception; discarding needs no confirm and
  /// the long-press sheet is the full-size path).
  Widget _closeButton(BuildContext context, SideChatTab tab) {
    return Semantics(
      button: true,
      label: trP(context, 'sideChat.close.aria', ['${tab.ordinal}']),
      child: SizedBox(
        width: SideChatTabBar.closeHitWidth,
        height: SideChatTabBar.pillHeight,
        child: InkWell(
          key: ValueKey('side-tab-close-${tab.sessionId}'),
          borderRadius: BorderRadius.circular(ZRadius.pill),
          onTap: () => widget.onClose(tab),
          child: Icon(
            Icons.close,
            size: SideChatTabBar.closeIconSize,
            color: ZInk.muted(context),
          ),
        ),
      ),
    );
  }
}
