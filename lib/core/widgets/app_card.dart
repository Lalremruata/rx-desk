import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'pressable.dart';

/// White card: radius 16, 1 px border.
///
/// Tappable cards (and those with [hoverLift]) lift −2 px with a soft shadow
/// on mouse hover (SPEC §9) and scale on press. Large content cards (grids,
/// charts) don't lift, matching the prototype.
class AppCard extends StatefulWidget {
  const AppCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.all(AppSpace.cardPad),
    this.gap = AppSpace.lg,
    this.onTap,
    this.hoverLift,
    this.clip = false,
    this.semanticLabel,
  });

  final Widget child;

  /// Optional card header: title (17/600 display) + subtitle (13 secondary).
  final String? title;
  final Widget? subtitle;
  final Widget? trailing;

  final EdgeInsetsGeometry padding;

  /// Gap between header and [child].
  final double gap;
  final VoidCallback? onTap;

  /// Defaults to `onTap != null`.
  final bool? hoverLift;

  /// Clip children to the rounded corners (for edge-to-edge grids).
  final bool clip;
  final String? semanticLabel;

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final lift = (widget.hoverLift ?? widget.onTap != null) && _hover;
    final duration = context.motion(AppMotion.hoverLift);

    Widget content = widget.child;
    if (widget.title != null || widget.trailing != null) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.title != null)
                      Semantics(header: true, child: Text(widget.title!, style: AppType.cardTitle)),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: AppSpace.xs),
                      DefaultTextStyle.merge(
                        style: AppType.small.copyWith(color: AppColors.textSecondary),
                        child: widget.subtitle!,
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null) ...[const SizedBox(width: AppSpace.md), widget.trailing!],
            ],
          ),
          SizedBox(height: widget.gap),
          widget.child,
        ],
      );
    }
    content = Padding(padding: widget.padding, child: content);

    if (widget.onTap != null) {
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: AppRadius.cardAll,
          splashFactory: NoSplash.splashFactory,
          hoverColor: AppColors.transparent,
          child: content,
        ),
      );
    }

    Widget card = AnimatedContainer(
      duration: duration,
      curve: Curves.ease,
      transform: Matrix4.translationValues(0, lift ? AppMotion.hoverLiftDy : 0, 0),
      clipBehavior: widget.clip ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardAll,
        border: Border.all(color: AppColors.border),
        boxShadow: lift ? const [AppShadows.cardHover] : const [],
      ),
      child: content,
    );

    if (widget.hoverLift ?? widget.onTap != null) {
      card = MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: card,
      );
    }
    if (widget.onTap != null) card = Pressable(child: card);
    if (widget.semanticLabel != null) {
      card = Semantics(container: true, label: widget.semanticLabel, child: card);
    }
    return card;
  }
}
