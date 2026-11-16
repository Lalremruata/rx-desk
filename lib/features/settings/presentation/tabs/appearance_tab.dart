import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../application/settings_providers.dart';
import '../settings_widgets.dart';

class AppearanceTab extends ConsumerWidget {
  const AppearanceTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = watchEditing(ref);
    final current = colorFromHex(s.accent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'Brand colour',
          subtitle: 'Used for buttons, charts and the invoice header. Changes preview straight away.',
          children: [
            Wrap(
              spacing: AppSpace.md,
              runSpacing: AppSpace.md,
              children: [
                for (final e in AppColors.accentOptions.entries)
                  _Swatch(
                    name: e.key,
                    color: e.value,
                    selected: e.value.toARGB32() == current.toARGB32(),
                    onTap: () => editSettings(ref, (x) => x.copyWith(accent: hexOf(e.value))),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        SettingsSection(
          title: 'Counter screen',
          children: [
            SettingToggle(
              label: 'Show keyboard shortcut hints',
              help: 'The F2 / F3 / F10 bar under the bill.',
              value: (x) => x.showKeyHints,
              onChanged: (x, v) => x.copyWith(showKeyHints: v),
            ),
            SettingRow(
              label: 'Lock the counter after',
              help: 'Minutes without use before the PIN screen comes back.',
              child: SegmentedPills<int>(
                semanticLabel: 'Auto-lock',
                options: const [PillOption(5, '5 min'), PillOption(15, '15 min'), PillOption(30, '30 min'), PillOption(0, 'Never')],
                selected: s.autoLockMinutes,
                onChanged: (v) => editSettings(ref, (x) => x.copyWith(autoLockMinutes: v)),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        AppCard(
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSpace.md,
            runSpacing: AppSpace.md,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Reset all settings', style: AppType.smallStrong),
                    Text(
                      'Puts every setting back to its default. Medicines, stock, bills, staff and your store details are not touched.',
                      style: AppType.caption,
                    ),
                  ],
                ),
              ),
              AppButton.secondary(
                key: const ValueKey('reset-defaults'),
                label: 'Reset to defaults',
                onPressed: () {
                  ref.read(settingsDraftProvider.notifier).resetToDefaults();
                  ref.read(toastsProvider.notifier).show('Defaults loaded — press Save changes to apply', warn: true);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.name, required this.color, required this.selected, required this.onTap});

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Brand colour $name',
      excludeSemantics: true,
      child: Pressable(
        child: InkWell(
          key: ValueKey('swatch-$name'),
          onTap: onTap,
          borderRadius: AppRadius.controlAll,
          child: Container(
            width: 104,
            padding: const EdgeInsets.all(AppSpace.gap10),
            decoration: BoxDecoration(
              borderRadius: AppRadius.controlAll,
              border: Border.all(color: selected ? color : AppColors.chipBorder, width: selected ? 2 : 1),
            ),
            child: Column(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: selected ? const Icon(Icons.check_rounded, color: AppColors.onAccent, size: 20) : null,
                ),
                const SizedBox(height: 6),
                Text(name, style: AppType.smallStrong),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
