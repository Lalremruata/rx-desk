import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'app_button.dart';

/// Opens [builder] in the app's dialog route: barrier fades in over 200 ms,
/// the panel scales 0.95→1 and rises 10 px over 320 ms (emphasised).
/// Esc and a barrier tap close it when [barrierDismissible].
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double maxWidth = 440,
  double topPadding = 120,
  bool barrierDismissible = true,
}) {
  return Navigator.of(context).push<T>(
    AppDialogRoute<T>(
      builder: builder,
      maxWidth: maxWidth,
      topPadding: topPadding,
      dismissible: barrierDismissible,
      duration: context.motion(AppMotion.dialog),
    ),
  );
}

class AppDialogRoute<T> extends PopupRoute<T> {
  AppDialogRoute({
    required this.builder,
    required this.maxWidth,
    required this.topPadding,
    required this.dismissible,
    required this.duration,
  });

  final WidgetBuilder builder;
  final double maxWidth;
  final double topPadding;
  final bool dismissible;
  final Duration duration;

  @override
  Color get barrierColor => AppColors.barrier;

  @override
  bool get barrierDismissible => dismissible;

  @override
  String get barrierLabel => 'Close dialog';

  /// Barrier finishes fading at 200 ms of the 320 ms panel animation.
  @override
  Curve get barrierCurve => Interval(
        0,
        AppMotion.dialogBarrier.inMilliseconds / AppMotion.dialog.inMilliseconds,
        curve: Curves.ease,
      );

  @override
  Duration get transitionDuration => duration;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final h = MediaQuery.sizeOf(context).height;
    // Pull the panel up on short screens so it isn't pushed off the bottom.
    final top = h < 700 ? topPadding / 3 : topPadding;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16, top, 16, 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Builder(builder: builder),
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final t = CurvedAnimation(parent: animation, curve: AppMotion.emphasised, reverseCurve: Curves.easeIn);
    return AnimatedBuilder(
      animation: t,
      child: child,
      builder: (context, child) {
        final v = t.value;
        return Opacity(
          opacity: v.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, AppMotion.dialogDy * (1 - v)),
            child: Transform.scale(scale: AppMotion.dialogScaleFrom + (1 - AppMotion.dialogScaleFrom) * v, child: child),
          ),
        );
      },
    );
  }
}

/// White dialog panel: radius 18, padding 24, gap 16, big shadow.
class AppDialogPanel extends StatelessWidget {
  const AppDialogPanel({super.key, required this.children, this.semanticLabel, this.gap = AppSpace.lg});

  final List<Widget> children;
  final String? semanticLabel;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: semanticLabel,
      // The shadow sits behind the Material: inside it, a box with no colour
      // would show its own shadow through the panel as a grey veil.
      child: DecoratedBox(
        decoration: const BoxDecoration(borderRadius: AppRadius.panelAll, boxShadow: [AppShadows.dialog]),
        child: Material(
          color: AppColors.surface,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.panelAll),
          shadowColor: AppColors.transparent,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, c) in children.indexed) ...[if (i > 0) SizedBox(height: gap), c],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum ConfirmTone { warning, danger, accent }

/// "Are you sure?" dialog. Resolves `true` when confirmed, `false` on
/// Cancel / Esc / barrier tap. Cancel has initial focus (safer default for
/// destructive actions like Restore).
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  ConfirmTone tone = ConfirmTone.warning,
  IconData icon = Icons.warning_amber_rounded,
}) async {
  final ok = await showAppDialog<bool>(
    context,
    builder: (context) => ConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      tone: tone,
      icon: icon,
    ),
  );
  return ok ?? false;
}

class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.cancelLabel = 'Cancel',
    this.tone = ConfirmTone.warning,
    this.icon = Icons.warning_amber_rounded,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final ConfirmTone tone;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final (StatusColors chip, AppButtonVariant variant) = switch (tone) {
      ConfirmTone.warning => (StatusColors(bg: StatusTone.warning.colors.bg, fg: StockColors.low), AppButtonVariant.warning),
      ConfirmTone.danger => (StatusTone.danger.colors, AppButtonVariant.danger),
      ConfirmTone.accent => (StatusTone.info.colors, AppButtonVariant.primary),
    };
    return AppDialogPanel(
      semanticLabel: title,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(color: chip.bg, borderRadius: const BorderRadius.all(Radius.circular(12))),
            child: Icon(icon, size: 22, color: chip.fg),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppType.dialogTitle),
            const SizedBox(height: 6),
            Text(message, style: AppType.small.copyWith(color: AppColors.textSecondary, height: 1.55)),
          ],
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          runSpacing: AppSpace.sm,
          children: [
            AppButton.secondary(label: cancelLabel, autofocus: true, onPressed: () => Navigator.of(context).pop(false)),
            AppButton(label: confirmLabel, variant: variant, onPressed: () => Navigator.of(context).pop(true)),
          ],
        ),
      ],
    );
  }
}
