import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'pressable.dart';

class PillOption<T> {
  const PillOption(this.value, this.label, {this.tooltip});

  final T value;
  final String label;
  final String? tooltip;
}

/// Grey track with a white raised "selected" segment (chart range 7D/30D/12M,
/// backup frequency…). Single select.
class SegmentedPills<T> extends StatelessWidget {
  const SegmentedPills({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.semanticLabel,
  });

  final List<PillOption<T>> options;
  final T selected;
  final ValueChanged<T>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final d = context.motion(AppMotion.colour);
    return Semantics(
      container: true,
      label: semanticLabel,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.xs),
        decoration: const BoxDecoration(color: AppColors.track, borderRadius: AppRadius.controlAll),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, o) in options.indexed) ...[
              if (i > 0) const SizedBox(width: 2),
              _Segment(
                label: o.label,
                tooltip: o.tooltip,
                selected: o.value == selected,
                duration: d,
                onTap: onChanged == null ? null : () => onChanged!(o.value),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.duration,
    required this.onTap,
    this.tooltip,
  });

  final String label;
  final bool selected;
  final Duration duration;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    Widget seg = Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Pressable(
        enabled: onTap != null,
        child: AnimatedContainer(
          duration: duration,
          constraints: const BoxConstraints(minHeight: 36),
          decoration: BoxDecoration(
            color: selected ? AppColors.surface : AppColors.transparent,
            borderRadius: AppRadius.smallAll,
            boxShadow: selected ? const [AppShadows.segment] : const [],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: AppRadius.smallAll,
              splashFactory: NoSplash.splashFactory,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                child: AnimatedDefaultTextStyle(
                  duration: duration,
                  style: AppType.smallStrong.copyWith(
                    color: selected ? AppColors.text : AppColors.textSecondary,
                  ),
                  child: Text(label),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) seg = Tooltip(message: tooltip, child: seg);
    return seg;
  }
}
