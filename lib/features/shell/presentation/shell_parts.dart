import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../purchases/application/purchases_providers.dart';
import '../application/app_section.dart';
import '../application/shell_status.dart';

/// Accent tile with the capsule glyph.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 38});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: context.palette.accent,
          borderRadius: BorderRadius.all(Radius.circular(size * 11 / 38)),
        ),
        child: Icon(Icons.medication_outlined, size: size * 20 / 38, color: AppColors.onAccent),
      ),
    );
  }
}

/// Badge widget for a nav item (count pill or pulsing dot), or null.
Widget? navBadgeFor(AppSection s, WidgetRef ref, {bool compact = false}) {
  switch (s) {
    case AppSection.billing:
      final n = ref.watch(billUnitsProvider);
      if (n <= 0) return null;
      return _CountPill(text: formatCount(n), tone: StatusTone.accent, compact: compact, semantic: '$n units in bill');
    case AppSection.inventory:
      final n = ref.watch(inventoryAlertCountProvider).value ?? 0;
      if (n <= 0) return null;
      return _CountPill(
        text: formatCount(n),
        tone: StatusTone.warning,
        compact: compact,
        semantic: '$n low or out of stock',
      );
    case AppSection.purchases:
      final n = ref.watch(openOrderCountProvider).value ?? 0;
      if (n <= 0) return null;
      return _CountPill(text: formatCount(n), tone: StatusTone.info, compact: compact, semantic: '$n order lines still due');
    case AppSection.settings:
      if (!ref.watch(settingsDirtyProvider)) return null;
      return const PulseDot(size: 8, semanticLabel: 'Unsaved changes');
    default:
      return null;
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.text, required this.tone, required this.compact, required this.semantic});

  final String text;
  final StatusTone tone;
  final bool compact;
  final String semantic;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // Billing badge is a solid accent pill; inventory a soft amber one.
    final (Color bg, Color fg) = tone == StatusTone.accent
        ? (p.accent, AppColors.onAccent)
        : (tone.colors.bg, tone.colors.fg);
    return Semantics(
      label: semantic,
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 8, vertical: compact ? 0 : 2),
        decoration: BoxDecoration(color: bg, borderRadius: AppRadius.pillAll),
        child: Text(text, style: AppType.badge.copyWith(color: fg, fontSize: compact ? 10 : 11)),
      ),
    );
  }
}

/// Full sidebar row: icon, label, optional badge. 44 px min height.
class NavTile extends ConsumerStatefulWidget {
  const NavTile({super.key, required this.section, required this.selected, required this.onTap});

  final AppSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  ConsumerState<NavTile> createState() => _NavTileState();
}

class _NavTileState extends ConsumerState<NavTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = widget.section;
    final on = widget.selected;
    final fg = on ? p.accent : AppColors.body;
    final bg = on ? p.accentSoft : (_hover ? AppColors.navHover : AppColors.transparent);
    final badge = navBadgeFor(s, ref);

    return Semantics(
      selected: on,
      button: true,
      label: s.label,
      child: Pressable(
        scale: 0.98,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('nav-${s.name}'),
            onTap: widget.onTap,
            onHover: (h) => setState(() => _hover = h),
            borderRadius: AppRadius.controlAll,
            hoverColor: AppColors.transparent,
            splashFactory: NoSplash.splashFactory,
            child: AnimatedContainer(
              duration: context.motion(AppMotion.colour),
              constraints: const BoxConstraints(minHeight: AppSizes.controlMin),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(color: bg, borderRadius: AppRadius.controlAll),
              child: ExcludeSemantics(
                excluding: badge == null,
                child: Row(
                  children: [
                    Icon(on ? s.selectedIcon : s.icon, size: 18, color: fg),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Text(
                        s.label,
                        style: AppType.bodyStrong.copyWith(color: fg),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ?badge,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sidebar footer: "Working offline" status + Back up now.
class OfflineCard extends ConsumerWidget {
  const OfflineCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(storedMedicineCountProvider).value ?? 0;
    final last = ref.watch(lastBackupLabelProvider).value ?? 'Never';
    return Container(
      padding: const EdgeInsets.all(AppSpace.gap14),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const PulseDot(),
              const SizedBox(width: AppSpace.sm),
              Flexible(
                child: Text(
                  'Working offline',
                  style: AppType.smallStrong.copyWith(fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.gap10),
          Text(
            '${formatCount(count)} medicines stored on this device. Last backup: $last',
            style: AppType.caption.copyWith(height: 1.5),
          ),
          const SizedBox(height: AppSpace.gap10),
          AppButton.secondary(label: 'Back up now', expand: true, onPressed: () => context.go(Routes.backup)),
        ],
      ),
    );
  }
}

/// Header pill chip ("Local database", date).
class HeaderChip extends StatelessWidget {
  const HeaderChip({super.key, required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.gap14, vertical: AppSpace.sm),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.pillAll,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 16, color: AppColors.body), const SizedBox(width: AppSpace.sm)],
          Text(label, style: AppType.small.copyWith(color: AppColors.body)),
        ],
      ),
    );
  }
}
