import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../application/app_settings.dart';
import '../application/settings_providers.dart';

/// Draft-or-saved settings being edited.
AppSettings watchEditing(WidgetRef ref) => ref.watch(settingsDraftProvider) ?? ref.watch(settingsProvider);

void editSettings(WidgetRef ref, AppSettings Function(AppSettings s) change) =>
    ref.read(settingsDraftProvider.notifier).edit(change);

/// A titled settings card.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title, this.subtitle, required this.children, this.trailing});

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      title: title,
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: trailing,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(height: AppSpace.md), c],
        ],
      ),
    );
  }
}

/// "Label / help" on the left, a control (pills) on the right; stacks on
/// narrow widths.
class SettingRow extends StatelessWidget {
  const SettingRow({super.key, required this.label, this.help, required this.child});

  final String label;
  final String? help;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppType.smallStrong),
        if (help != null) ...[const SizedBox(height: 2), Text(help!, style: AppType.caption)],
      ],
    );
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 520) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [text, const SizedBox(height: AppSpace.sm), child],
          );
        }
        return Row(children: [Expanded(child: text), const SizedBox(width: AppSpace.md), child]);
      },
    );
  }
}

/// Settings toggle bound to the draft.
class SettingToggle extends ConsumerWidget {
  const SettingToggle({
    super.key,
    required this.label,
    this.help,
    required this.value,
    required this.onChanged,
    this.locked = false,
  });

  final String label;
  final String? help;
  final bool Function(AppSettings s) value;
  final AppSettings Function(AppSettings s, bool v) onChanged;
  final bool locked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = watchEditing(ref);
    return ToggleRow(
      label: label,
      help: help,
      value: value(s),
      locked: locked,
      onChanged: (v) => editSettings(ref, (x) => onChanged(x, v)),
    );
  }
}

/// Dark sticky bar: "N unsaved changes — the rest of the app updates when
/// you save" · Discard · Save changes.
class UnsavedBar extends StatelessWidget {
  const UnsavedBar({super.key, required this.count, required this.onDiscard, required this.onSave});

  final int count;
  final VoidCallback onDiscard;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;
    return Semantics(
      container: true,
      label: 'Unsaved changes',
      child: Container(
        key: const ValueKey('unsaved-bar'),
        padding: const EdgeInsets.fromLTRB(18, 12, 14, 12),
        decoration: const BoxDecoration(
          color: AppColors.toastBg,
          borderRadius: BorderRadius.all(Radius.circular(14)),
          boxShadow: [AppShadows.toast],
        ),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpace.md,
          runSpacing: AppSpace.sm,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const PulseDot(size: 8),
                const SizedBox(width: AppSpace.gap10),
                Flexible(
                  child: Text(
                    '$count ${count == 1 ? 'unsaved change' : 'unsaved changes'} — the rest of the app updates when you save',
                    style: AppType.small.copyWith(color: AppColors.toastFg, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const ValueKey('settings-discard'),
                  onPressed: onDiscard,
                  style: TextButton.styleFrom(foregroundColor: AppColors.toastFg, minimumSize: const Size(0, AppSizes.controlMin)),
                  child: const Text('Discard'),
                ),
                const SizedBox(width: AppSpace.sm),
                Pressable(
                  child: FilledButton(
                    key: const ValueKey('settings-save'),
                    onPressed: onSave,
                    style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: AppColors.onAccent),
                    child: const Text('Save changes'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Slides [child] up from the bottom when [visible].
class SlideUp extends StatelessWidget {
  const SlideUp({super.key, required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: context.motion(AppMotion.toast),
      switchInCurve: AppMotion.emphasised,
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(position: Tween(begin: const Offset(0, 0.6), end: Offset.zero).animate(a), child: c),
      ),
      child: visible ? child : const SizedBox.shrink(key: ValueKey('hidden')),
    );
  }
}
