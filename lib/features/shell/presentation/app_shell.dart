import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/clock.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../billing/application/new_bill_request.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/session.dart';
import '../application/app_section.dart';
import '../application/shell_status.dart';
import 'shell_parts.dart';

/// Debug builds list the widget gallery in the menu. The user-guide
/// screenshot run turns it off so pictures match a release build.
bool debugShowWidgetGallery = kDebugMode;

/// Which chrome the shell is using at the current width (SPEC §2).
enum ShellLayout {
  /// ≥ 1100: 236 px sidebar.
  full,

  /// 760–1099: 72 px icon rail with tooltips.
  rail,

  /// < 760: top app bar + bottom NavigationBar with "More".
  compact;

  static ShellLayout forWidth(double w) => w >= AppSizes.breakpointFull
      ? full
      : w >= AppSizes.breakpointRail
          ? rail
          : compact;
}

/// Responsive app frame around every routed screen.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = AppSection.fromPath(location);
    void go(AppSection s) => context.go(s.path);

    return LayoutBuilder(
      builder: (context, c) {
        final layout = ShellLayout.forWidth(c.maxWidth);
        switch (layout) {
          case ShellLayout.full:
            return Scaffold(
              body: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Sidebar(current: section, onSelect: go),
                  Expanded(child: _Content(section: section, child: child)),
                ],
              ),
            );
          case ShellLayout.rail:
            return Scaffold(
              body: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Rail(current: section, onSelect: go),
                  Expanded(child: _Content(section: section, child: child)),
                ],
              ),
            );
          case ShellLayout.compact:
            return _CompactScaffold(current: section, onSelect: go, child: child);
        }
      },
    );
  }
}

void _newBill(BuildContext context, WidgetRef ref) {
  ref.read(newBillRequestProvider.notifier).request();
  context.go(Routes.billing);
}

// ---------------------------------------------------------------------------
// Full sidebar

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.current, required this.onSelect});

  final AppSection current;
  final ValueChanged<AppSection> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      key: const ValueKey('shell-sidebar'),
      width: AppSizes.sidebar,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.pageY),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
            child: Row(
              children: [
                const BrandMark(),
                const SizedBox(width: AppSpace.gap10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('RxDesk', style: AppType.brand),
                      Text(
                        ref.watch(settingsProvider.select((s) => s.name)).trim().isEmpty
                            ? '[Your Pharmacy Name]'
                            : ref.watch(settingsProvider.select((s) => s.name)),
                        style: AppType.caption.copyWith(color: AppColors.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.pageY),
          Expanded(
            child: SingleChildScrollView(
              child: Semantics(
                container: true,
                label: 'Main',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final s in AppSection.nav) ...[
                      NavTile(section: s, selected: s == current, onTap: () => onSelect(s)),
                      const SizedBox(height: AppSpace.xs),
                    ],
                    if (debugShowWidgetGallery) ...[
                      const SizedBox(height: AppSpace.sm),
                      NavTile(
                        section: AppSection.gallery,
                        selected: current == AppSection.gallery,
                        onTap: () => onSelect(AppSection.gallery),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          const OfflineCard(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Icon rail

class _Rail extends ConsumerWidget {
  const _Rail({required this.current, required this.onSelect});

  final AppSection current;
  final ValueChanged<AppSection> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(storedMedicineCountProvider).value ?? 0;
    final last = ref.watch(lastBackupLabelProvider).value ?? 'Never';
    final items = [...AppSection.nav, if (debugShowWidgetGallery) AppSection.gallery];
    return Container(
      key: const ValueKey('shell-rail'),
      width: AppSizes.rail,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.pageY),
      child: Column(
        children: [
          const Tooltip(message: 'RxDesk', child: BrandMark()),
          const SizedBox(height: AppSpace.pageY),
          Expanded(
            child: SingleChildScrollView(
              child: Semantics(
                container: true,
                label: 'Main',
                child: Column(
                  children: [
                    for (final s in items) ...[
                      _RailButton(section: s, selected: s == current, onTap: () => onSelect(s)),
                      const SizedBox(height: AppSpace.xs),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Tooltip(
            message: 'Working offline · ${formatCount(count)} medicines on this device · Last backup: $last',
            child: Semantics(
              button: true,
              label: 'Working offline. Back up now',
              excludeSemantics: true,
              child: InkWell(
                onTap: () => context.go(Routes.backup),
                borderRadius: AppRadius.controlAll,
                child: const SizedBox(width: 48, height: 48, child: Center(child: PulseDot())),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailButton extends ConsumerWidget {
  const _RailButton({required this.section, required this.selected, required this.onTap});

  final AppSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final badge = navBadgeFor(section, ref, compact: true);
    final fg = selected ? p.accent : AppColors.body;
    return Tooltip(
      message: section.label,
      preferBelow: false,
      child: Semantics(
        selected: selected,
        button: true,
        label: section.label,
        excludeSemantics: true,
        child: Pressable(
          scale: 0.98,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: ValueKey('nav-${section.name}'),
              onTap: onTap,
              borderRadius: AppRadius.controlAll,
              hoverColor: AppColors.navHover,
              child: Ink(
                width: 48,
                height: 44,
                decoration: BoxDecoration(
                  color: selected ? p.accentSoft : AppColors.transparent,
                  borderRadius: AppRadius.controlAll,
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Icon(selected ? section.selectedIcon : section.icon, size: 20, color: fg),
                    if (badge != null) Positioned(top: 4, right: 2, child: badge),
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

// ---------------------------------------------------------------------------
// Compact (phone / narrow tablet)

class _CompactScaffold extends ConsumerWidget {
  const _CompactScaffold({required this.current, required this.onSelect, required this.child});

  final AppSection current;
  final ValueChanged<AppSection> onSelect;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const primary = AppSection.compactPrimary;
    final idx = primary.indexOf(current);
    final selected = idx >= 0 ? idx : primary.length; // "More"

    return Scaffold(
      key: const ValueKey('shell-compact'),
      appBar: AppBar(
        titleSpacing: AppSpace.lg,
        title: Row(
          children: [
            const BrandMark(size: 32),
            const SizedBox(width: AppSpace.gap10),
            Expanded(child: Text(current.label, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'New bill',
            onPressed: () => _newBill(context, ref),
            icon: Icon(Icons.add_rounded, color: context.palette.accent),
          ),
          const SizedBox(width: AppSpace.sm),
        ],
      ),
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected,
        onDestinationSelected: (i) {
          if (i < primary.length) {
            onSelect(primary[i]);
          } else {
            _showMore(context, ref);
          }
        },
        destinations: [
          for (final s in primary)
            NavigationDestination(
              key: ValueKey('nav-${s.name}'),
              icon: _withBadge(s, ref, Icon(s.icon)),
              selectedIcon: _withBadge(s, ref, Icon(s.selectedIcon)),
              label: s.label,
              tooltip: s.label,
            ),
          NavigationDestination(
            key: const ValueKey('nav-more'),
            icon: _withBadge(AppSection.settings, ref, const Icon(Icons.more_horiz_rounded)),
            label: 'More',
            tooltip: 'More',
          ),
        ],
      ),
    );
  }

  Widget _withBadge(AppSection s, WidgetRef ref, Widget icon) {
    final b = navBadgeFor(s, ref, compact: true);
    if (b == null) return icon;
    return Stack(clipBehavior: Clip.none, children: [icon, Positioned(top: -4, right: -10, child: b)]);
  }

  Future<void> _showMore(BuildContext context, WidgetRef ref) async {
    final items = [...AppSection.compactMore, if (debugShowWidgetGallery) AppSection.gallery];
    final picked = await showModalBottomSheet<AppSection>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.sm, 0, AppSpace.sm, AppSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in items)
                Consumer(
                  builder: (context, ref, _) => ListTile(
                    key: ValueKey('more-${s.name}'),
                    minTileHeight: 52,
                    shape: const RoundedRectangleBorder(borderRadius: AppRadius.controlAll),
                    selected: s == current,
                    selectedColor: context.palette.accent,
                    selectedTileColor: context.palette.accentSoft,
                    leading: Icon(s.icon, size: 20),
                    titleTextStyle: AppType.bodyStrong,
                    title: Text(s.label),
                    trailing: navBadgeFor(s, ref),
                    onTap: () => Navigator.of(context).pop(s),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && context.mounted) onSelect(picked);
  }
}

// ---------------------------------------------------------------------------
// Header + content (full and rail layouts)

class _Content extends StatelessWidget {
  const _Content({required this.section, required this.child});

  final AppSection section;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.pageX, AppSpace.pageY, AppSpace.pageX, AppSpace.xl),
          child: PageHeader(section: section),
        ),
        Expanded(child: child),
      ],
    );
  }
}

/// Signed-in user + lock.
class _LockButton extends ConsumerWidget {
  const _LockButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider);
    if (user == null) return const SizedBox.shrink();
    return Tooltip(
      message: 'Lock the counter (${user.name}, ${user.role.label})',
      child: Semantics(
        button: true,
        label: 'Lock — signed in as ${user.name}',
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('lock-button'),
          borderRadius: AppRadius.pillAll,
          onTap: () => ref.read(sessionProvider.notifier).lock(),
          child: Container(
            constraints: const BoxConstraints(minHeight: AppSizes.controlMin),
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.gap14),
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: AppRadius.pillAll, border: Border.all(color: AppColors.border)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline_rounded, size: 16, color: AppColors.body),
                const SizedBox(width: AppSpace.sm),
                Text(user.name, style: AppType.small.copyWith(color: AppColors.body)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Page title + subtitle, "Local database" chip, date chip, "New bill".
class PageHeader extends ConsumerWidget {
  const PageHeader({super.key, required this.section});

  final AppSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final subtitle = section == AppSection.inventory
        ? '${formatCount(ref.watch(storedMedicineCountProvider).value ?? 0)} medicines · ${section.subtitle}'
        : section.subtitle;

    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(header: true, child: Text(section.label, style: AppType.pageTitle)),
        const SizedBox(height: 2),
        Text(subtitle, style: AppType.small.copyWith(color: AppColors.textSecondary)),
      ],
    );
    final actions = Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const HeaderChip(label: 'Local database', icon: Icons.dns_outlined),
        const _LockButton(),
        HeaderChip(label: formatHeaderDate(now)),
        AppButton(
          key: const ValueKey('header-new-bill'),
          label: 'New bill',
          icon: Icons.add_rounded,
          onPressed: () => _newBill(context, ref),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 720) {
          return Row(children: [Expanded(child: titleBlock), const SizedBox(width: AppSpace.gap14), actions]);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [titleBlock, const SizedBox(height: AppSpace.gap14), actions],
        );
      },
    );
  }
}
