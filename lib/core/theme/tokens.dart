// Design tokens, ported by hand from design/tokens.json.
//
// This file and app_theme.dart are the ONLY places allowed to contain colour
// literals. Feature code and shared widgets read from here (enforced by
// test/unit/no_hardcoded_colors_test.dart).
import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

/// Raw colour palette (`color.*` in tokens.json).
abstract final class AppColors {
  static const Color background = Color(0xFFF3F5F8);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceAlt = Color(0xFFF8FAFC);
  static const Color border = Color(0xFFE5EAF0);
  static const Color divider = Color(0xFFF1F4F8);
  static const Color inputBorder = Color(0xFFD7DEE6);
  static const Color track = Color(0xFFF1F4F8);
  static const Color switchOff = Color(0xFFCBD5E1);
  static const Color text = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF5B6472);
  static const Color textMuted = Color(0xFF64748B);
  static const Color label = Color(0xFF475569);
  static const Color body = Color(0xFF334155);

  /// Text/icons drawn on top of the accent colour.
  static const Color onAccent = Color(0xFFFFFFFF);

  /// Transparent, for animated backgrounds that fade in/out.
  static const Color transparent = Color(0x00FFFFFF);

  // Prototype-only greys not named in tokens.json.
  static const Color navHover = Color(0xFFEEF2F5); // .nav:hover
  static const Color rowHover = surfaceAlt; // .row:hover
  static const Color chipBorder = Color(0xFFE2E8F0); // pills, pager, grid header rule
  static const Color kbdBorder = Color(0xFFCBD5E1); // .kbd
  static const Color tableHeadAlt = Color(0xFFFBFCFD); // nested batch table head
  static const Color chartGrid = Color(0xFFE2E8F0);
  static const Color chartAxis = Color(0xFFCBD5E1);

  /// Modal barrier: rgba(15,23,42,.45).
  static const Color barrier = Color(0x730F172A);

  static const Color accentDefault = Color(0xFF0F766E);

  /// Accent choices offered in Settings › Appearance (SPEC §7.5).
  static const Map<String, Color> accentOptions = {
    'Teal': Color(0xFF0F766E),
    'Blue': Color(0xFF2563EB),
    'Violet': Color(0xFF7C3AED),
    'Cyan': Color(0xFF0E7490),
    'Rose': Color(0xFFBE123C),
    'Slate': Color(0xFF334155),
  };

  /// accentSoft = accent mixed 12 % over white.
  static const double accentSoftMix = 0.12;

  /// Non-current chart bars = accent mixed 42 % over white.
  static const double chartBarMuteMix = 0.42;

  static const Color toastBg = Color(0xFF0F172A);
  static const Color toastFg = Color(0xFFFFFFFF);
  static const Color flashNewRow = Color(0xFFFEF3C7);

  /// Pulsing dot (offline / unsaved): amber.
  static const Color pulse = Color(0xFFD97706);

  /// Category chart colours (SPEC §8).
  static const Map<String, Color> category = {
    'Tablet': Color(0xFF0F766E),
    'Capsule': Color(0xFF5EEAD4),
    'Syrup': Color(0xFFD97706),
    'Injection': Color(0xFF4338CA),
    'OTC': Color(0xFFF9A8D4),
    'Topical': Color(0xFF94A3B8),
  };

  /// Staff role chip colours.
  static const Map<String, StatusColors> role = {
    'Owner': StatusColors(bg: Color(0xFFE0E7FF), fg: Color(0xFF3730A3)),
    'Pharmacist': StatusColors(bg: Color(0xFFD1FAE5), fg: Color(0xFF047857)),
    'Cashier': StatusColors(bg: Color(0xFFFEF3C7), fg: Color(0xFF92400E)),
  };

  /// Mixes [color] over white by [amount] (0–1), like CSS
  /// `color-mix(in srgb, color amount, #fff)`.
  static Color mixOverWhite(Color color, double amount) =>
      Color.lerp(surface, color, amount)!;
}

/// A background/foreground pair (+ optional icon colour) for badges & chips.
class StatusColors {
  const StatusColors({required this.bg, required this.fg, Color? icon})
      : icon = icon ?? fg;

  final Color bg;
  final Color fg;
  final Color icon;
}

/// Semantic tones for [StatusBadge] and friends (`color.status.*`).
enum StatusTone {
  warning(StatusColors(bg: Color(0xFFFEF3C7), fg: Color(0xFF92400E), icon: Color(0xFFD97706))),
  danger(StatusColors(bg: Color(0xFFFEE2E2), fg: Color(0xFFB91C1C), icon: Color(0xFFDC2626))),
  success(StatusColors(bg: Color(0xFFD1FAE5), fg: Color(0xFF047857), icon: Color(0xFF10B981))),
  info(StatusColors(bg: Color(0xFFE0E7FF), fg: Color(0xFF4338CA))),
  rx(StatusColors(bg: Color(0xFFFFE4E6), fg: Color(0xFF9F1239))),
  neutral(StatusColors(bg: Color(0xFFF1F4F8), fg: Color(0xFF475569))),
  dead(StatusColors(bg: Color(0xFFE2E8F0), fg: Color(0xFF334155))),

  /// Resolved at runtime from the accent (accentSoft / accent).
  accent(StatusColors(bg: Color(0xFFE2EEEE), fg: Color(0xFF0F766E)));

  const StatusTone(this.colors);

  final StatusColors colors;
}

/// Stock-level text colours used in result rows ("12", "4 left", "Out").
abstract final class StockColors {
  static const Color ok = Color(0xFF047857);
  static const Color low = Color(0xFFB45309);
  static const Color out = Color(0xFFB91C1C);
  static const Color barLow = Color(0xFFD97706);
  static const Color barOut = Color(0xFFDC2626);
}

abstract final class AppRadius {
  static const double card = 16;
  static const double panel = 18;
  static const double control = 10;
  static const double small = 8;
  static const double tiny = 6;
  static const double pill = 999;

  static const BorderRadius cardAll = BorderRadius.all(Radius.circular(card));
  static const BorderRadius panelAll = BorderRadius.all(Radius.circular(panel));
  static const BorderRadius controlAll = BorderRadius.all(Radius.circular(control));
  static const BorderRadius smallAll = BorderRadius.all(Radius.circular(small));
  static const BorderRadius tinyAll = BorderRadius.all(Radius.circular(tiny));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double gap10 = 10;
  static const double md = 12;
  static const double gap14 = 14;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;
  static const double pageX = 28;
  static const double pageY = 22;
  static const double cardPad = 20;
}

abstract final class AppSizes {
  static const double sidebar = 236;
  static const double rail = 72;
  static const double controlMin = 44;
  static const double searchHeight = 56;
  static const double primaryCta = 52;
  static const double switchW = 48;
  static const double switchH = 28;
  static const double switchKnob = 22;

  /// Width ≥ this → icon rail (below → compact bottom bar).
  static const double breakpointRail = 760;

  /// Width ≥ this → full sidebar.
  static const double breakpointFull = 1100;

  /// Minimum KPI / card tile width in grids (`minmax(220px, 1fr)`).
  static const double minTile = 220;
}

abstract final class AppShadows {
  /// 0 14 34 -16 rgba(15,23,42,.22)
  static const BoxShadow cardHover = BoxShadow(
    offset: Offset(0, 14),
    blurRadius: 34,
    spreadRadius: -16,
    color: Color(0x380F172A),
  );

  /// 0 24 50 -20 rgba(15,23,42,.35)
  static const BoxShadow dropdown = BoxShadow(
    offset: Offset(0, 24),
    blurRadius: 50,
    spreadRadius: -20,
    color: Color(0x590F172A),
  );

  /// 0 30 60 -20 rgba(15,23,42,.45)
  static const BoxShadow dialog = BoxShadow(
    offset: Offset(0, 30),
    blurRadius: 60,
    spreadRadius: -20,
    color: Color(0x730F172A),
  );

  /// 0 20 40 -16 rgba(15,23,42,.55)
  static const BoxShadow toast = BoxShadow(
    offset: Offset(0, 20),
    blurRadius: 40,
    spreadRadius: -16,
    color: Color(0x8C0F172A),
  );

  /// Selected segment: 0 1 3 rgba(15,23,42,.14)
  static const BoxShadow segment = BoxShadow(
    offset: Offset(0, 1),
    blurRadius: 3,
    color: Color(0x240F172A),
  );

  /// Switch knob: 0 1 3 rgba(0,0,0,.25)
  static const BoxShadow knob = BoxShadow(
    offset: Offset(0, 1),
    blurRadius: 3,
    color: Color(0x40000000),
  );
}

/// Motion tokens (SPEC §9).
abstract final class AppMotion {
  /// cubic-bezier(0.2, 0.8, 0.2, 1) — "emphasised".
  static const Curve emphasised = Cubic(0.2, 0.8, 0.2, 1);

  static const Duration screenEnter = Duration(milliseconds: 500);
  static const double screenEnterDy = 12;
  static const Duration stagger = Duration(milliseconds: 50);

  static const Duration hoverLift = Duration(milliseconds: 250);
  static const double hoverLiftDy = -2;

  static const Duration press = Duration(milliseconds: 150);
  static const double pressScale = 0.97;

  static const Duration bars = Duration(milliseconds: 700);
  static const Duration barsStagger = Duration(milliseconds: 50);
  static const Duration barsStagger30d = Duration(milliseconds: 15);
  static const Duration barsResize = Duration(milliseconds: 550);

  static const Duration dropdown = Duration(milliseconds: 180);
  static const double dropdownDy = -6;

  static const Duration rowIn = Duration(milliseconds: 320);
  static const double rowInDx = 18;
  static const Duration rowFlash = Duration(milliseconds: 1400);

  static const Duration expand = Duration(milliseconds: 220);
  static const Duration chevron = Duration(milliseconds: 200);

  static const Duration dialogBarrier = Duration(milliseconds: 200);
  static const Duration dialog = Duration(milliseconds: 320);
  static const double dialogScaleFrom = 0.95;
  static const double dialogDy = 10;

  static const Duration toast = Duration(milliseconds: 380);
  static const double toastDy = 24;
  static const double toastScaleFrom = 0.97;
  static const Duration toastDismiss = Duration(milliseconds: 2800);

  static const Duration switchKnob = Duration(milliseconds: 250);
  static const Duration progress = Duration(milliseconds: 180);
  static const Duration pulse = Duration(milliseconds: 2200);
  static const Duration previewResize = Duration(milliseconds: 350);

  /// Hover / selection colour changes (prototype `.btn`, `.nav`: .2s).
  static const Duration colour = Duration(milliseconds: 200);
}

/// Font families bundled in assets/fonts.
abstract final class AppFonts {
  static const String body = 'Inter';
  static const String display = 'SpaceGrotesk';

  /// "platform monospace": Consolas on Windows, Menlo on macOS,
  /// the system mono on Android.
  static const String mono = 'Consolas';
  static const List<String> monoFallback = [
    'Menlo',
    'SF Mono',
    'Roboto Mono',
    'Droid Sans Mono',
    'Courier New',
    'monospace',
  ];
}

/// Type scale (SPEC §8 / `type.*`). Colours default to [AppColors.text].
abstract final class AppType {
  static TextStyle _display(double size, FontWeight w) => TextStyle(
        fontFamily: AppFonts.display,
        fontSize: size,
        fontWeight: w,
        letterSpacing: -0.01 * size,
        color: AppColors.text,
        height: 1.2,
      );

  static TextStyle _body(double size, FontWeight w, {double? spacing, Color? color}) => TextStyle(
        fontFamily: AppFonts.body,
        fontSize: size,
        fontWeight: w,
        letterSpacing: spacing,
        color: color ?? AppColors.text,
        height: 1.4,
      );

  static final TextStyle pageTitle = _display(26, FontWeight.w700);
  static final TextStyle cardTitle = _display(17, FontWeight.w600);
  static final TextStyle kpi = _display(28, FontWeight.w700);
  static final TextStyle total = _display(26, FontWeight.w700);
  static final TextStyle brand = _display(19, FontWeight.w700);
  static final TextStyle dialogTitle = _display(20, FontWeight.w700);
  static final TextStyle emptyTitle = _display(16, FontWeight.w600);

  static final TextStyle body = _body(14, FontWeight.w400);
  static final TextStyle bodyStrong = _body(14, FontWeight.w600);
  static final TextStyle small = _body(13, FontWeight.w400);
  static final TextStyle smallStrong = _body(13, FontWeight.w600);
  static final TextStyle label = _body(12, FontWeight.w600, color: AppColors.label);
  static final TextStyle caption = _body(12, FontWeight.w400, color: AppColors.textSecondary);
  static final TextStyle badge = _body(11, FontWeight.w700);
  static final TextStyle overline = _body(11, FontWeight.w700, spacing: 0.6, color: AppColors.textMuted);

  static const TextStyle mono = TextStyle(
    fontFamily: AppFonts.mono,
    fontFamilyFallback: AppFonts.monoFallback,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: AppColors.text,
  );

  /// Tabular figures, for numbers that line up in columns.
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];
}
