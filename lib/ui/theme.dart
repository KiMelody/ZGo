import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Design tokens extracted verbatim from the official ZCode Web Remote Control
/// bundle (`theme-zai-dark` / `:root` light). The official page uses a Tailwind
/// neutral gray scale with a sky-blue brand accent. Values below are the
/// official oklch scale resolved to sRGB.
class ZColors {
  ZColors._();

  // Tailwind neutral scale (oklch L, chroma 0 → resolved to gray).
  static const neutral50 = Color(0xFFFAFAFA);
  static const neutral100 = Color(0xFFF5F5F5);
  static const neutral200 = Color(0xFFE5E5E5);
  static const neutral300 = Color(0xFFD4D4D4);
  static const neutral400 = Color(0xFFA3A3A3);
  static const neutral500 = Color(0xFF737373);
  static const neutral600 = Color(0xFF525252);
  static const neutral700 = Color(0xFF404040);
  static const neutral800 = Color(0xFF262626);
  static const neutral900 = Color(0xFF171717);
  static const neutral950 = Color(0xFF0A0A0A);

  // Official surfaces.
  static const darkBackground = Color(0xFF161616);
  static const darkCard = Color(0xFF2B2B2B);
  /// Official dual-pane left column (--workspace-sidebar-panel-width area).
  static const darkSidebar = Color(0xFF1E1E1E);
  static const darkSecondary = Color(0xFF363636);
  static const lightBackground = Color(0xFFF8F8F8);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightSidebar = Color(0xFFF0F0F0);
  static const lightSecondary = Color(0xFFE6E6E6);

  // Brand sky accent (official --color-brand / --color-accent).
  static const sky400 = Color(0xFF38BDF8);
  static const sky500 = Color(0xFF0EA5E9);
  static const sky600 = Color(0xFF0284C7);
  static const sky50 = Color(0xFFF0F9FF);
  static const sky950 = Color(0xFF082F49);

  // Status.
  static const danger = Color(0xFFFF5C5C); // dark destructive
  static const dangerLight = Color(0xFFE03131); // light destructive
  static const success = Color(0xFF34D399); // emerald-400
  static const warning = Color(0xFFFBBF24); // amber-400

  // Official mobile status pills (measured on the official 390px list).
  static const pillSuccessBg = Color(0xFF46BF72); // 已完成 pill surface
  static const pillRunningBg = Color(0xFF001D3D); // 运行中 pill surface

  // Usage panel (desktop/remote entitlement panel, pixel-measured
  // 2026-09-15 — research/reference-panel-spec.md). Panel-only accents:
  // the existing brand/status tokens take different values, so they stay
  // untouched and these are additive.
  static const usageBlue = Color(0xFF4099FF); // bar fill + legend dot base
  static const usageOrange = Color(0xFFFF8A30); // high-ratio / >=90% limit
  static const usageGreen = Color(0xFF87D9A4); // reset countdown + pill
}

/// Card-list spacing scale (usage / settings screens).
abstract final class ZSpacing {
  /// Gap between adjacent cards in a list. Cards carry no default margin
  /// ([zCardTheme] sets `margin: EdgeInsets.zero`), so the on-screen
  /// separation between two cards equals [cardGap].
  static const double cardGap = 16;

  /// Page edge padding for card-list screens, and the horizontal content
  /// padding inside a bottom sheet.
  static const double screen = 16;

  /// Inner padding of a page card (`ZCard`).
  static const double card = 16;

  /// Whitespace around a centered empty / error / unavailable state.
  static const double emptyState = 32;
}

/// Corner-radius ladder — the only radius values allowed in `lib/ui/`.
/// Eleven ad-hoc literals (3/4/6/7/8/10/12/14/18/20/22) collapse onto these
/// five tiers; every call site spells the tier it means.
abstract final class ZRadius {
  /// Badges, micro chips, small action buttons (composer send/stop).
  static const double mini = 6;

  /// Inputs, embedded blocks (code / diff / kv), icon containers.
  static const double field = 8;

  /// Cards, chat tiles, dialogs, message bubbles.
  static const double tile = 12;

  /// Bottom-sheet top corners, large avatars, hero empty-state icon.
  static const double large = 20;

  /// Capsules (status pills, timeline markers).
  static const double pill = 999;
}

/// Geometry contract for a row inside a card (`ZListRow`): device rows, task
/// rows and other card lists share one inset, one height floor and one gap so
/// the pages stop carrying three different row shapes.
abstract final class ZListRow {
  /// Row inset — the card itself adds no padding around rows.
  static const EdgeInsets padding =
      EdgeInsets.symmetric(horizontal: 12, vertical: 10);

  /// Height floor for a row with a secondary line (title + meta).
  static const double twoLineHeight = 60;

  /// Height floor for a single-line row.
  static const double singleLineHeight = 44;

  /// Gap between two adjacent rows / around the row's highlight block.
  static const double gap = 4;

  /// Leading icon container (square) and the icon inside it.
  static const double leadingSize = 36;
  static const double leadingIcon = 20;

  /// Unread / status dot diameter.
  static const double dot = 8;
}

/// Geometry contract for chat turn blocks (`_ReasoningTile`,
/// `_ToolCallTile`, `_SubagentTile`): one header height, icon size and
/// horizontal inset, one seam between neighbours, one expanded-body inset.
/// Type sizes stay semantic (12 label / 13 summary) — only the box is shared.
abstract final class ZTile {
  /// Gap below each block, so neighbouring blocks never read as glued.
  static const double seam = 12;

  /// Header row height floor (header is taller when its content is).
  static const double headHeight = 38;

  /// Header row horizontal inset.
  static const double headPadding = 12;

  /// Header leading icon.
  static const double iconSize = 16;

  /// Header row inset — see [headPadding].
  static const EdgeInsets head =
      EdgeInsets.symmetric(horizontal: headPadding);

  /// Expanded body inset (same horizontal inset as the header, no top gap —
  /// the header row already carries it).
  static const EdgeInsets body =
      EdgeInsets.fromLTRB(headPadding, 0, headPadding, seam);
}

/// Font family bundled with the app. The three static weights come from the
/// Noto Sans SC variable font, subset to the app character set by
/// `tool/font_subset.py`.
const String zFontFamily = 'NotoSansSC';

/// Fallback chain: the bundled family first (for styles used outside a themed
/// `Text`), then emoji faces, then the platform CJK faces. Without an explicit
/// CJK family the engine picks whatever the host offers — Windows lands on
/// traditional-Chinese / Yu Gothic faces, and ROM CJK fonts fake every
/// intermediate weight.
const List<String> zFontFallback = [
  'NotoSansSC',
  'Segoe UI Emoji',
  'Apple Color Emoji',
  'PingFang SC',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
  'sans-serif',
];

/// Typography scale. Seven tiers replace the twelve ad-hoc sizes that were
/// hardcoded at 300+ call sites; each tier carries the bundled family and the
/// shared [zFontFallback] chain so stray inline styles stay covered.
///
/// Sizes 6 / 9 / 10 map to [caption], 18 to [display], and 16 to [heading] or
/// [title] by context — the per-site decisions live in `implement.jsonl`.
abstract final class ZType {
  /// Screen-level hero numbers and markdown h1.
  static const TextStyle display = TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      height: 1.3,
      fontFamily: zFontFamily,
      fontFamilyFallback: zFontFallback);

  /// Page titles, app bar titles, markdown h2, list-row primary text.
  static const TextStyle title = TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      height: 1.3,
      fontFamily: zFontFamily,
      fontFamilyFallback: zFontFallback);

  /// Card headers and section headings.
  static const TextStyle heading = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      height: 1.4,
      fontFamily: zFontFamily,
      fontFamilyFallback: zFontFallback);

  /// Emphasised body text (buttons, key/value pairs, inline labels).
  static const TextStyle bodyStrong = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.4,
      fontFamily: zFontFamily,
      fontFamilyFallback: zFontFallback);

  /// Default body text.
  static const TextStyle body = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.5,
      fontFamily: zFontFamily,
      fontFamilyFallback: zFontFallback);

  /// Secondary text (list subtitles, metadata).
  static const TextStyle sub = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      height: 1.5,
      fontFamily: zFontFamily,
      fontFamilyFallback: zFontFallback);

  /// Timestamps, badges and other supporting text.
  static const TextStyle caption = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w400,
      height: 1.4,
      fontFamily: zFontFamily,
      fontFamilyFallback: zFontFallback);
}

/// Motion: one shared-axis-style transition for every pushed page — the
/// incoming page slides in horizontally while the outgoing one drifts left,
/// so pushes never mix the platform's default zoom/fade with a native slide.
const Duration zPageTransition = Duration(milliseconds: 260);
const Duration zPageReverseTransition = Duration(milliseconds: 200);

/// Page route with the horizontal slide-in above. Drop-in replacement for
/// `MaterialPageRoute(builder: ...)`.
///
/// iOS/macOS keep the Material route: the platform transition there is
/// already a horizontal slide, and it carries the interactive edge-swipe back
/// gesture (the gesture detector lives inside CupertinoPageTransitionsBuilder,
/// which a bare [PageRouteBuilder] does not provide).
Route<T> zRoute<T>(WidgetBuilder builder) {
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    return MaterialPageRoute<T>(builder: builder);
  }
  return PageRouteBuilder<T>(
    transitionDuration: zPageTransition,
    reverseTransitionDuration: zPageReverseTransition,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final incoming = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic);
      final outgoing = CurvedAnimation(
          parent: secondaryAnimation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic);
      return SlideTransition(
        position: Tween<Offset>(
          begin: Offset.zero,
          end: const Offset(-0.06, 0),
        ).animate(outgoing),
        child: FadeTransition(
          opacity: incoming,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.08, 0),
              end: Offset.zero,
            ).animate(incoming),
            child: child,
          ),
        ),
      );
    },
  );
}

/// Mobile touch-target floor (≥44×48dp) for icon-only targets that are not a
/// Material button (Material buttons carry it via
/// [MaterialTapTargetSize.padded]). Growing only these boxes leaves the
/// painted icon at its size.
const double zTouchWidth = 44;
const double zTouchHeight = 48;

/// Theme-aware text colors mirroring the official foreground tokens.
class ZInk {
  ZInk._();

  static Color solid(BuildContext c) =>
      _dark(c) ? ZColors.neutral200 : ZColors.neutral700;
  static Color soft(BuildContext c) =>
      _dark(c) ? ZColors.neutral300 : ZColors.neutral600;
  static Color muted(BuildContext c) =>
      _dark(c) ? ZColors.neutral400 : ZColors.neutral500;
  static Color faint(BuildContext c) => _dark(c)
      ? ZColors.neutral200.withValues(alpha: 0.60)
      : ZColors.neutral700.withValues(alpha: 0.60);
  static Color ghost(BuildContext c) => _dark(c)
      ? ZColors.neutral200.withValues(alpha: 0.30)
      : ZColors.neutral700.withValues(alpha: 0.40);

  /// Sub-surface tone (tiles inside a card: reasoning, tool calls, queue).
  static Color tile(BuildContext c) =>
      _dark(c) ? ZColors.darkSecondary : ZColors.lightSecondary;

  /// 1px hairline borders around tiles.
  static Color hairline(BuildContext c) => _dark(c)
      ? const Color(0x14FFFFFF)
      : const Color(0x140D0D0D);

  /// Inline-code pill background (assistant markdown `code`).
  static Color codeInlineBg(BuildContext c) =>
      _dark(c) ? ZColors.neutral800 : ZColors.neutral200;

  /// Fenced code-block background.
  static Color codeBlockBg(BuildContext c) =>
      _dark(c) ? ZColors.neutral950 : ZColors.neutral100;

  static Color codeText(BuildContext c) =>
      _dark(c) ? ZColors.neutral200 : ZColors.neutral700;

  static bool _dark(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark;
}

/// Light/dark mode, persisted. Defaults to dark like the official page.
class ThemeController extends ChangeNotifier {
  static const _key = 'zlinker_theme_mode';
  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    switch (prefs.getString(_key)) {
      case 'light':
        _mode = ThemeMode.light;
        break;
      case 'system':
        _mode = ThemeMode.system;
        break;
      default:
        _mode = ThemeMode.dark;
    }
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      _ => 'dark',
    });
  }

  void cycle() {
    setMode(switch (_mode) {
      ThemeMode.dark => ThemeMode.light,
      ThemeMode.light => ThemeMode.system,
      ThemeMode.system => ThemeMode.dark,
    });
  }
}

ThemeData buildDarkTheme() {
  const scheme = ColorScheme.dark(
    primary: ZColors.neutral50,
    onPrimary: ZColors.neutral950,
    secondary: ZColors.darkSecondary,
    onSecondary: ZColors.neutral50,
    surface: ZColors.darkBackground,
    onSurface: ZColors.neutral200,
    error: ZColors.danger,
    onError: ZColors.neutral950,
    surfaceContainerHighest: ZColors.darkCard,
    outline: Color(0x1AFFFFFF),
  );
  return _base(scheme, ZColors.darkBackground, ZColors.darkCard,
      const Color(0x1AFFFFFF), ZColors.neutral200);
}

ThemeData buildLightTheme() {
  const scheme = ColorScheme.light(
    primary: ZColors.neutral950,
    onPrimary: ZColors.neutral50,
    secondary: ZColors.lightSecondary,
    onSecondary: ZColors.neutral950,
    surface: ZColors.lightBackground,
    onSurface: ZColors.neutral700,
    error: ZColors.dangerLight,
    onError: ZColors.neutral50,
    surfaceContainerHighest: ZColors.lightCard,
    outline: Color(0x1A0D0D0D),
  );
  return _base(scheme, ZColors.lightBackground, ZColors.lightCard,
      const Color(0x1A0D0D0D), ZColors.neutral700);
}

ThemeData _base(ColorScheme scheme, Color background, Color card,
    Color border, Color foreground) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    fontFamily: zFontFamily,
    fontFamilyFallback: zFontFallback,
    // iOS/macOS default to shrinkWrap, which would leave Material buttons
    // below the ≥44×48dp touch-target floor; padded keeps every button at
    // kMinInteractiveDimension on all platforms.
    materialTapTargetSize: MaterialTapTargetSize.padded,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: ZType.title.copyWith(color: foreground),
      iconTheme: IconThemeData(color: foreground),
    ),
    // card/dialog visuals ride the CardTheme/DialogTheme widgets in
    // ZLinkerApp.builder — the ThemeData param type differs across SDKs
    // (CardTheme vs CardThemeData), the widget form does not.
    dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: card,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(ZRadius.large)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.primary,
      contentTextStyle: TextStyle(color: scheme.onPrimary),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZRadius.field)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZRadius.field),
        side: BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: card,
      hintStyle: TextStyle(color: foreground.withValues(alpha: 0.4)),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZRadius.field),
          borderSide: BorderSide(color: border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZRadius.field),
          borderSide: BorderSide(color: border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZRadius.field),
          borderSide: const BorderSide(color: ZColors.sky500)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZRadius.field)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: ZType.bodyStrong.copyWith(fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        textStyle: ZType.bodyStrong.copyWith(fontWeight: FontWeight.w500),
      ),
    ),
    listTileTheme: ListTileThemeData(
      textColor: foreground,
      iconColor: foreground,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZRadius.field)),
    ),
  );
}


/// Card visuals for [ZLinkerApp]'s builder-wrapped CardTheme widget
/// (stable across SDKs, unlike ThemeData.cardTheme's param type).
CardThemeData zCardTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return CardThemeData(
    color: dark ? ZColors.darkCard : ZColors.lightCard,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(ZRadius.tile), // official --radius-xl
      side: BorderSide(
          color: dark ? const Color(0x14FFFFFF) : const Color(0x140D0D0D)),
    ),
  );
}

/// Dialog visuals for the builder-wrapped DialogTheme widget.
DialogThemeData zDialogTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return DialogThemeData(
    backgroundColor: dark ? ZColors.darkCard : ZColors.lightCard,
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZRadius.tile)),
  );
}
