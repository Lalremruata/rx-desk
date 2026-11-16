/// The six Settings tabs (SPEC §5.7), in prototype order. [slug] is the
/// `:tab` path segment of `/settings/:tab`.
enum SettingsTab {
  store('store', 'Store profile', 'Name, address, licences'),
  invoice('invoice', 'Invoice', 'Numbering, layout, printing'),
  billing('billing', 'Billing & tax', 'GST, discounts, Rx rules'),
  inventory('inventory', 'Inventory', 'Expiry and stock alerts'),
  staff('staff', 'Staff & roles', 'Accounts and permissions'),
  appearance('appearance', 'Appearance', 'Colour and counter screen');

  const SettingsTab(this.slug, this.label, this.help);

  final String slug;
  final String label;
  final String help;

  static SettingsTab? fromSlug(String? slug) {
    for (final t in values) {
      if (t.slug == slug) return t;
    }
    return null;
  }
}
