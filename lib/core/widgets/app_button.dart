import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'pressable.dart';

enum AppButtonVariant {
  /// Accent fill, white text ("New bill", "Save changes").
  primary,

  /// White with input-coloured border ("Export", "Cancel").
  secondary,

  /// Amber fill for destructive confirms ("Restore").
  warning,

  /// Red fill for destructive confirms.
  danger,
}

/// Standard button with the prototype's look: radius 10, min height 44,
/// brightness lift on hover, scale 0.97 on press.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = AppButtonVariant.primary,
    this.height = AppSizes.controlMin,
    this.expand = false,
    this.autofocus = false,
    this.focusNode,
  });

  const AppButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = AppSizes.controlMin,
    this.expand = false,
    this.autofocus = false,
    this.focusNode,
  }) : variant = AppButtonVariant.secondary;

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final AppButtonVariant variant;
  final double height;
  final bool expand;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (Color bg, Color fg, BorderSide side) = switch (variant) {
      AppButtonVariant.primary => (palette.accent, AppColors.onAccent, BorderSide.none),
      AppButtonVariant.secondary =>
        (AppColors.surface, AppColors.text, const BorderSide(color: AppColors.inputBorder)),
      AppButtonVariant.warning => (StockColors.low, AppColors.onAccent, BorderSide.none),
      AppButtonVariant.danger => (StatusTone.danger.colors.fg, AppColors.onAccent, BorderSide.none),
    };
    final filled = variant != AppButtonVariant.secondary;
    // Hover: CSS filter brightness(1.07) ≈ a light white overlay on fills,
    // a faint grey on the white button.
    final hover = filled ? AppColors.onAccent.withValues(alpha: 0.08) : AppColors.surfaceAlt;

    final style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, height)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
      shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: AppRadius.controlAll)),
      textStyle: WidgetStatePropertyAll(
        AppType.bodyStrong.copyWith(fontWeight: variant == AppButtonVariant.primary ? FontWeight.w600 : null),
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.disabled) ? bg.withValues(alpha: 0.45) : bg,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.disabled) ? fg.withValues(alpha: 0.6) : fg,
      ),
      overlayColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.pressed)) return hover.withValues(alpha: filled ? 0.14 : 1);
        if (s.contains(WidgetState.hovered) || s.contains(WidgetState.focused)) return hover;
        return null;
      }),
      side: WidgetStatePropertyAll(side),
      elevation: const WidgetStatePropertyAll(0),
      splashFactory: NoSplash.splashFactory,
      mouseCursor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.disabled) ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
      ),
    );

    final child = icon == null
        ? Text(label)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [Icon(icon, size: 16), const SizedBox(width: 8), Flexible(child: Text(label))],
          );

    Widget button = TextButton(
      onPressed: onPressed,
      style: style,
      autofocus: autofocus,
      focusNode: focusNode,
      child: child,
    );
    if (expand) button = SizedBox(width: double.infinity, child: button);
    return Pressable(enabled: onPressed != null, child: button);
  }
}
