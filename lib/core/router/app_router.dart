import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/backup/presentation/backup_screen.dart';
import '../../features/billing/presentation/billing_screen.dart';
import '../../features/customers/presentation/customers_screen.dart';
import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../../features/inventory/presentation/inventory_screen.dart';
import '../../features/invoices/presentation/invoices_screen.dart';
import '../../features/purchases/presentation/purchases_screen.dart';
import '../../features/sales_register/presentation/consumption_register_screen.dart';
import '../../features/sales_register/presentation/sales_register_screen.dart';
import '../../features/settings/application/settings_tabs.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/shell/presentation/app_shell.dart';
import '../../features/shell/presentation/widget_gallery_screen.dart';
import 'routes.dart';

part 'app_router.g.dart';

/// Screens swap without a route transition; each screen runs its own
/// enter animation (PageEnter).
Page<void> _page(GoRouterState state, Widget child) => NoTransitionPage<void>(key: state.pageKey, child: child);

GoRoute _screen(String path, Widget child) =>
    GoRoute(path: path, pageBuilder: (context, state) => _page(state, child));

GoRouter createRouter({String initialLocation = Routes.start, bool includeGallery = kDebugMode}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', redirect: (context, state) => Routes.start),
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
        routes: [
          _screen(Routes.dashboard, const DashboardScreen()),
          _screen(Routes.billing, const BillingScreen()),
          _screen(Routes.inventory, const InventoryScreen()),
          _screen(Routes.purchases, const PurchasesScreen()),
          _screen(Routes.invoices, const InvoicesScreen()),
          _screen(Routes.customers, const CustomersScreen()),
          _screen(Routes.register, const SalesRegisterScreen()),
          _screen(Routes.consumption, const ConsumptionRegisterScreen()),
          _screen(Routes.backup, const BackupScreen()),
          GoRoute(
            path: Routes.settings,
            redirect: (context, state) =>
                state.uri.path == Routes.settings ? Routes.settingsTab(SettingsTab.store.slug) : null,
            routes: [
              GoRoute(
                path: ':tab',
                redirect: (context, state) => SettingsTab.fromSlug(state.pathParameters['tab']) == null
                    ? Routes.settingsTab(SettingsTab.store.slug)
                    : null,
                pageBuilder: (context, state) => _page(
                  state,
                  SettingsScreen(tab: SettingsTab.fromSlug(state.pathParameters['tab'])!),
                ),
              ),
            ],
          ),
          if (includeGallery) _screen(Routes.gallery, const WidgetGalleryScreen()),
        ],
      ),
    ],
    // Unknown paths fall back to the start screen rather than an error page.
    onException: (context, state, router) => router.go(Routes.start),
  );
}

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  final router = createRouter();
  ref.onDispose(router.dispose);
  return router;
}
