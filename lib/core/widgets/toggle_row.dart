import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// The prototype's switch: 48×28 track (accent / grey), 22 px white knob that
/// slides 20 px in 250 ms (emphasised). Keyboard: Space/Enter toggles.
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged, required this.semanticLabel});

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Screen-reader label, e.g. "Encrypt backup".
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final track = value ? context.palette.accent : AppColors.switchOff;
    final d = context.motion(AppMotion.switchKnob);
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: enabled ? () => onChanged!(!value) : null,
            borderRadius: AppRadius.pillAll,
            splashFactory: NoSplash.splashFactory,
            child: SizedBox(
              // ≥ 44 px tall hit area around the 28 px track.
              height: AppSizes.controlMin,
              width: AppSizes.switchW,
              child: Center(
                child: AnimatedContainer(
                  duration: d,
                  curve: AppMotion.emphasised,
                  width: AppSizes.switchW,
                  height: AppSizes.switchH,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(color: track, borderRadius: AppRadius.pillAll),
                  child: AnimatedAlign(
                    duration: d,
                    curve: AppMotion.emphasised,
                    alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      width: AppSizes.switchKnob,
                      height: AppSizes.switchKnob,
                      decoration: const BoxDecoration(
                        color: AppColors.surface,
                        shape: BoxShape.circle,
                        boxShadow: [AppShadows.knob],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Settings-style row: label + help text on the left, [AppSwitch] on the
/// right. The whole row toggles. [locked] rows show a lock and can't change
/// (e.g. "Block expired batches").
class ToggleRow extends StatelessWidget {
  const ToggleRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
    this.locked = false,
    this.bordered = true,
  });

  final String label;
  final String? help;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool locked;
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    final change = locked ? null : onChanged;
    // One semantics node for the whole row: label, help as hint, toggle state.
    return Semantics(
      container: true,
      toggled: value,
      enabled: change != null,
      label: label,
      hint: help,
      onTap: change == null ? null : () => change(!value),
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: change == null ? null : () => change(!value),
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          canRequestFocus: false,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: bordered
                ? BoxDecoration(
                    border: Border.all(color: AppColors.divider),
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                  )
                : null,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(child: Text(label, style: AppType.smallStrong)),
                            if (locked) ...[
                              const SizedBox(width: 6),
                              const Tooltip(
                                message: 'Locked — this rule can’t be turned off',
                                child: Icon(Icons.lock_outline_rounded, size: 14, color: AppColors.textMuted),
                              ),
                            ],
                          ],
                        ),
                        if (help != null) ...[
                          const SizedBox(height: 2),
                          Text(help!, style: AppType.caption),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                ExcludeFocus(
                  excluding: change == null,
                  child: AppSwitch(value: value, onChanged: change, semanticLabel: label),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
