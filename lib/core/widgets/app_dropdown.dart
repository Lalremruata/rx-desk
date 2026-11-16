import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class DropdownOption<T> {
  const DropdownOption(this.value, this.label);
  final T value;
  final String label;
}

/// Compact select with an optional inline label ("Category [All ▾]") or a
/// label above (forms).
class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.label,
    this.labelAbove = false,
    this.width,
    this.semanticLabel,
  });

  final List<DropdownOption<T>> options;
  final T value;
  final ValueChanged<T>? onChanged;
  final String? label;
  final bool labelAbove;
  final double? width;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final field = Container(
      width: width,
      constraints: const BoxConstraints(minHeight: AppSizes.controlMin),
      padding: const EdgeInsets.only(left: 12, right: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.controlAll,
        border: Border.all(color: AppColors.inputBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: options.any((o) => o.value == value) ? value : null,
          isExpanded: width != null || labelAbove,
          borderRadius: AppRadius.controlAll,
          style: AppType.body,
          icon: const Icon(Icons.expand_more_rounded, size: 20, color: AppColors.textMuted),
          items: [
            for (final o in options)
              DropdownMenuItem<T>(value: o.value, child: Text(o.label, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged == null
              ? null
              : (v) {
                  if (v is T) onChanged!(v);
                },
        ),
      ),
    );
    final labelled = Semantics(label: semanticLabel ?? label, child: field);
    if (label == null) return labelled;
    if (labelAbove) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [Text(label!, style: AppType.label), const SizedBox(height: 6), labelled],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label!, style: AppType.smallStrong.copyWith(color: AppColors.label)),
        const SizedBox(width: AppSpace.sm),
        Flexible(child: labelled),
      ],
    );
  }
}
