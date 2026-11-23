import 'package:flutter/material.dart';

import '../../../core/router/routes.dart';

/// The app's top-level sections, in sidebar order (SPEC §2), plus the
/// debug-only widget gallery.
enum AppSection {
  dashboard(
    Routes.dashboard,
    'Dashboard',
    Icons.space_dashboard_outlined,
    Icons.space_dashboard_rounded,
    'How the store is doing today',
  ),
  billing(
    Routes.billing,
    'Billing',
    Icons.shopping_cart_outlined,
    Icons.shopping_cart_rounded,
    'Search, pick batch, bill — all from the keyboard',
  ),
  inventory(
    Routes.inventory,
    'Inventory',
    Icons.inventory_2_outlined,
    Icons.inventory_2_rounded,
    // Prefixed with the medicine count by the header.
    'batch-wise stock and expiry',
  ),
  purchases(
    Routes.purchases,
    'Purchases',
    Icons.local_shipping_outlined,
    Icons.local_shipping_rounded,
    'Order book — what you ordered and what came in',
  ),
  invoices(
    Routes.invoices,
    'Invoices',
    Icons.description_outlined,
    Icons.description_rounded,
    'One row per bill — find, reprint or return',
  ),
  customers(
    Routes.customers,
    'Customers',
    Icons.people_alt_outlined,
    Icons.people_alt_rounded,
    'Who owes what — credit bills, payments and statements',
  ),
  cash(
    Routes.cash,
    'Day close',
    Icons.point_of_sale_outlined,
    Icons.point_of_sale_rounded,
    'Cash in the drawer — paid-outs and closing the day',
  ),
  register(
    Routes.register,
    'Sales register',
    Icons.bar_chart_rounded,
    Icons.bar_chart_rounded,
    'One row per item sold — filter, group, total and export',
  ),
  backup(
    Routes.backup,
    'Backup & restore',
    Icons.storage_rounded,
    Icons.storage_rounded,
    'Your data lives on this device — keep a copy safe',
  ),
  settings(
    Routes.settings,
    'Settings',
    Icons.tune_rounded,
    Icons.tune_rounded,
    'Store details, invoice layout, billing rules and staff',
  ),
  gallery(
    Routes.gallery,
    'Widget gallery',
    Icons.widgets_outlined,
    Icons.widgets_rounded,
    'Debug only — every shared widget from SPEC §8',
  );

  const AppSection(this.path, this.label, this.icon, this.selectedIcon, this.subtitle);

  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String subtitle;

  /// The sidebar items (gallery excluded).
  static const List<AppSection> nav = [
    dashboard,
    billing,
    inventory,
    purchases,
    invoices,
    customers,
    cash,
    register,
    backup,
    settings,
  ];

  /// Bottom-bar items on compact widths; the rest live under "More".
  static const List<AppSection> compactPrimary = [dashboard, billing, inventory, invoices];
  static const List<AppSection> compactMore = [purchases, customers, cash, register, backup, settings];

  /// Section owning [path] ("/settings/invoice" → settings). Unknown → billing.
  static AppSection fromPath(String path) {
    for (final s in values) {
      if (path == s.path || path.startsWith('${s.path}/')) return s;
    }
    return billing;
  }
}
