import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'pressable.dart';
import 'segmented_pills.dart' show PillOption;

/// Wrapping row of pill chips (date presets, discount %, saved reports).
/// Selected chip is filled with the accent. Each chip's hit area is at least
/// 44 px tall even though the pill itself is 34 px (prototype size).
class FilterChipRow<T> extends StatelessWidget {
  const FilterChipRow({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.semanticLabel,
    this.spacing = 6,
  });

  final List<PillOption<T>> options;
  final T? selected;
  final ValueChanged<T>? onChanged;
  final String? semanticLabel;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: semanticLabel,
      child: Wrap(
        spacing: spacing,
        children: [
          for (final o in options)
            _Chip(
              label: o.label,
              tooltip: o.tooltip,
              selected: o.value == selected,
              onTap: onChanged == null ? null : () => onChanged!(o.value),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatefulWidget {
  const _Chip({required this.label, required this.selected, required this.onTap, this.tooltip});

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final on = widget.selected;
    final bg = on ? p.accent : (_hover ? AppColors.surfaceAlt : AppColors.surface);
    final fg = on ? AppColors.onAccent : AppColors.body;
    final bd = on ? p.accent : AppColors.chipBorder;

    Widget chip = Semantics(
      button: true,
      selected: on,
      enabled: widget.onTap != null,
      child: Pressable(
        enabled: widget.onTap != null,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (h) => setState(() => _hover = h),
            borderRadius: AppRadius.pillAll,
            splashFactory: NoSplash.splashFactory,
            hoverColor: AppColors.transparent,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AppSizes.controlMin),
              child: Center(
                widthFactor: 1,
                child: AnimatedContainer(
                  duration: context.motion(AppMotion.colour),
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: AppRadius.pillAll,
                    border: Border.all(color: bd),
                  ),
                  // Not Container.alignment: that would stretch the pill to the Wrap's width.
                  child: Center(widthFactor: 1, child: Text(widget.label, style: AppType.label.copyWith(color: fg))),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) chip = Tooltip(message: widget.tooltip, child: chip);
    return chip;
  }
}
