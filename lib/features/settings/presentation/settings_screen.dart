import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../staff/application/session.dart';
import '../../staff/presentation/access_denied.dart';
import '../application/app_settings.dart';
import '../application/settings_providers.dart';
import '../application/settings_tabs.dart';
import 'settings_widgets.dart';
import 'tabs/appearance_tab.dart';
import 'tabs/billing_tab.dart';
import 'tabs/inventory_tab.dart';
import 'tabs/invoice_tab.dart';
import 'tabs/staff_tab.dart';
import 'tabs/store_tab.dart';

/// Settings (SPEC §5.7): six tabs; edits go to a draft with a sticky
/// Discard / Save bar.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, required this.tab});

  final SettingsTab tab;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final SettingsOnScreen _onScreen = ref.read(settingsOnScreenProvider.notifier);

  @override
  void initState() {
    super.initState();
    // The accent previews live only while Settings is open.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScreen.set(true));
  }

  @override
  void dispose() {
    final n = _onScreen;
    WidgetsBinding.instance.addPostFrameCallback((_) => n.set(false));
    super.dispose();
  }

  Future<void> _save() async {
    final r = await ref.read(settingsDraftProvider.notifier).save();
    if (!mounted) return;
    final toasts = ref.read(toastsProvider.notifier);
    switch (r) {
      case DraftSaved():
        toasts.show('Settings saved');
      case DraftInvalid(:final errors):
        toasts.show('Fix this first: ${errors.values.first}', warn: true);
      case DraftDenied():
        toasts.show('Your role can’t change settings. Ask the owner.', warn: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(canProvider(Permission.changeSettings))) return const AccessDenied(permission: Permission.changeSettings);
    final changes = ref.watch(settingsChangesProvider);
    final body = switch (widget.tab) {
      SettingsTab.store => const StoreTab(),
      SettingsTab.invoice => const InvoiceTab(),
      SettingsTab.billing => const BillingTab(),
      SettingsTab.inventory => const InventoryTab(),
      SettingsTab.staff => const StaffTab(),
      SettingsTab.appearance => const AppearanceTab(),
    };

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 860;
        final compact = MediaQuery.sizeOf(context).width < AppSizes.breakpointRail;
        final x = compact ? AppSpace.lg : AppSpace.pageX;
        final content = SingleChildScrollView(
          key: PageStorageKey('settings-${widget.tab.slug}'),
          padding: EdgeInsets.fromLTRB(wide ? 0 : x, compact ? AppSpace.lg : 0, x, changes.isEmpty ? 40 : 120),
          child: PageEnter(key: ValueKey(widget.tab), child: body),
        );
        final Widget main = wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(left: x, right: AppSpace.xl),
                    child: SizedBox(width: 236, child: _TabNav(current: widget.tab)),
                  ),
                  Expanded(child: content),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.fromLTRB(x, compact ? AppSpace.md : 0, x, AppSpace.sm),
                    child: FilterChipRow<SettingsTab>(
                      semanticLabel: 'Settings sections',
                      options: [for (final t in SettingsTab.values) PillOption(t, t.label, tooltip: t.help)],
                      selected: widget.tab,
                      onChanged: (t) => context.go(Routes.settingsTab(t.slug)),
                    ),
                  ),
                  Expanded(child: content),
                ],
              );
        return Stack(
          children: [
            Positioned.fill(child: main),
            Positioned(
              left: wide ? x + 236 + AppSpace.xl : x,
              right: x,
              bottom: AppSpace.lg,
              child: SlideUp(
                visible: changes.isNotEmpty,
                child: UnsavedBar(
                  count: changes.length,
                  onDiscard: () => ref.read(settingsDraftProvider.notifier).discard(),
                  onSave: _save,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TabNav extends StatelessWidget {
  const _TabNav({required this.current});

  final SettingsTab current;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AppCard(
      padding: const EdgeInsets.all(AppSpace.sm),
      child: Semantics(
        container: true,
        label: 'Settings sections',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final t in SettingsTab.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Semantics(
                  selected: t == current,
                  button: true,
                  child: Material(
                    color: t == current ? p.accentSoft : AppColors.transparent,
                    borderRadius: AppRadius.controlAll,
                    child: InkWell(
                      key: ValueKey('settings-tab-${t.slug}'),
                      borderRadius: AppRadius.controlAll,
                      onTap: () => context.go(Routes.settingsTab(t.slug)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.label, style: AppType.bodyStrong.copyWith(color: t == current ? p.accent : AppColors.text)),
                            Text(t.help, style: AppType.caption),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
