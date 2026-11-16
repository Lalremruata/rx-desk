import 'package:flutter/material.dart';

import 'tokens.dart';

/// Accent-derived colours. Read with `context.palette`.
@immutable
class RxPalette extends ThemeExtension<RxPalette> {
  const RxPalette({required this.accent, required this.accentSoft, required this.accentMuted});

  factory RxPalette.fromAccent(Color accent) => RxPalette(
        accent: accent,
        accentSoft: AppColors.mixOverWhite(accent, AppColors.accentSoftMix),
        accentMuted: AppColors.mixOverWhite(accent, AppColors.chartBarMuteMix),
      );

  /// User-selected brand colour (Settings › Appearance).
  final Color accent;

  /// 12 % accent over white — selected nav, soft chips, icon tiles.
  final Color accentSoft;

  /// 42 % accent over white — non-current chart bars.
  final Color accentMuted;

  /// Resolves a [StatusTone] to colours, mapping [StatusTone.accent] to the
  /// live accent.
  StatusColors tone(StatusTone tone) => tone == StatusTone.accent
      ? StatusColors(bg: accentSoft, fg: accent)
      : tone.colors;

  @override
  RxPalette copyWith({Color? accent}) => RxPalette.fromAccent(accent ?? this.accent);

  @override
  RxPalette lerp(RxPalette? other, double t) {
    if (other == null) return this;
    return RxPalette(
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      accentMuted: Color.lerp(accentMuted, other.accentMuted, t)!,
    );
  }
}

extension RxPaletteX on BuildContext {
  RxPalette get palette =>
      Theme.of(this).extension<RxPalette>() ?? RxPalette.fromAccent(AppColors.accentDefault);
}

ThemeData buildAppTheme(Color accent) {
  final palette = RxPalette.fromAccent(accent);
  final scheme = ColorScheme.light(
    primary: accent,
    primaryContainer: palette.accentSoft,
    onPrimaryContainer: accent,
    secondary: accent,
    onSecondary: AppColors.onAccent,
    onSurfaceVariant: AppColors.textSecondary,
    surfaceContainerLowest: AppColors.surface,
    surfaceContainerLow: AppColors.surfaceAlt,
    surfaceContainer: AppColors.surface,
    surfaceContainerHigh: AppColors.surface,
    surfaceContainerHighest: AppColors.divider,
    error: StatusTone.danger.colors.fg,
    outline: AppColors.inputBorder,
    outlineVariant: AppColors.border,
  );

  final textTheme = TextTheme(
    headlineMedium: AppType.pageTitle,
    titleLarge: AppType.dialogTitle,
    titleMedium: AppType.cardTitle,
    titleSmall: AppType.bodyStrong,
    bodyLarge: AppType.body,
    bodyMedium: AppType.body,
    bodySmall: AppType.caption,
    labelLarge: AppType.bodyStrong,
    labelMedium: AppType.label,
    labelSmall: AppType.badge,
  );

  const controlShape = RoundedRectangleBorder(borderRadius: AppRadius.controlAll);
  OutlineInputBorder inputBorder(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: AppRadius.controlAll,
        borderSide: BorderSide(color: c, width: w),
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: AppFonts.body,
    textTheme: textTheme,
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.surface,
    dividerColor: AppColors.divider,
    splashFactory: InkRipple.splashFactory,
    hoverColor: AppColors.navHover,
    focusColor: palette.accentSoft,
    highlightColor: AppColors.transparent,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    extensions: [palette],
    dividerTheme: const DividerThemeData(color: AppColors.divider, thickness: 1, space: 1),
    iconTheme: const IconThemeData(color: AppColors.body, size: 18),
    tooltipTheme: TooltipThemeData(
      decoration: const BoxDecoration(color: AppColors.toastBg, borderRadius: AppRadius.smallAll),
      textStyle: AppType.label.copyWith(color: AppColors.toastFg),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      waitDuration: const Duration(milliseconds: 400),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintStyle: AppType.body.copyWith(color: AppColors.textMuted),
      labelStyle: AppType.label,
      border: inputBorder(AppColors.inputBorder),
      enabledBorder: inputBorder(AppColors.inputBorder),
      focusedBorder: inputBorder(accent, 1.5),
      errorBorder: inputBorder(StatusTone.danger.colors.fg),
      focusedErrorBorder: inputBorder(StatusTone.danger.colors.fg, 1.5),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, AppSizes.controlMin),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: controlShape,
        textStyle: AppType.bodyStrong,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, AppSizes.controlMin),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: controlShape,
        foregroundColor: AppColors.text,
        side: const BorderSide(color: AppColors.inputBorder),
        textStyle: AppType.bodyStrong,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, AppSizes.controlMin),
        shape: controlShape,
        foregroundColor: accent,
        textStyle: AppType.bodyStrong,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(AppSizes.controlMin, AppSizes.controlMin),
        shape: controlShape,
        foregroundColor: AppColors.body,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: palette.accentSoft,
      surfaceTintColor: AppColors.transparent,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => AppType.label.copyWith(
          color: s.contains(WidgetState.selected) ? accent : AppColors.body,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          size: 22,
          color: s.contains(WidgetState.selected) ? accent : AppColors.body,
        ),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.text,
      surfaceTintColor: AppColors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: AppType.cardTitle.copyWith(fontSize: 19, fontWeight: FontWeight.w700),
      shape: const Border(bottom: BorderSide(color: AppColors.border)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: AppColors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.panel)),
      ),
    ),
    scrollbarTheme: const ScrollbarThemeData(radius: Radius.circular(AppRadius.pill)),
  );
}

/// '#0F766E' → Color. Falls back to the default accent for bad input.
Color colorFromHex(String hex) {
  final h = hex.replaceFirst('#', '');
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? AppColors.accentDefault : Color(v);
}

/// Color → '#0F766E'.
String hexOf(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
