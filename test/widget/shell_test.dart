import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/billing/application/new_bill_request.dart';
import 'package:rx_desk/features/shell/presentation/app_shell.dart';

import '../helpers/pump_app.dart';

Finder _title(String text) => find.descendant(of: find.byType(PageHeader), matching: find.text(text));

void main() {
  setUpAll(setUpFormatting);

  group('≥ 1100 px — full sidebar', () {
    testWidgets('shows sidebar with 8 nav items, header and offline card', (tester) async {
      await pumpApp(tester);
      expect(find.byKey(const ValueKey('shell-sidebar')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-rail')), findsNothing);
      for (final label in [
        'Dashboard',
        'Billing',
        'Inventory',
        'Purchases',
        'Invoices',
        'Sales register',
        'Backup & restore',
        'Settings',
      ]) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      // Default start screen is Billing.
      expect(_title('Billing'), findsOneWidget);
      expect(find.text('Search, pick batch, bill — all from the keyboard'), findsOneWidget);
      expect(find.text('Local database'), findsOneWidget);
      expect(find.text('Mon, 9 Nov 2026'), findsOneWidget);
      expect(find.text('Working offline'), findsOneWidget);
      expect(find.text('0 medicines stored on this device. Last backup: Never'), findsOneWidget);
    });

    testWidgets('nav items route to their screens', (tester) async {
      await pumpApp(tester);
      const expected = {
        'dashboard': 'Dashboard',
        'inventory': 'Inventory',
        'purchases': 'Purchases',
        'invoices': 'Invoices',
        'register': 'Sales register',
        'backup': 'Backup & restore',
        'settings': 'Settings',
        'billing': 'Billing',
      };
      for (final e in expected.entries) {
        await tester.tap(find.byKey(ValueKey('nav-${e.key}')));
        await settle(tester);
        expect(_title(e.value), findsOneWidget, reason: e.key);
      }
    });

    testWidgets('"Back up now" opens Backup', (tester) async {
      await pumpApp(tester, location: '/dashboard');
      await tester.tap(find.text('Back up now'));
      await settle(tester);
      expect(_title('Backup & restore'), findsOneWidget);
    });

    testWidgets('"New bill" goes to Billing and raises a focus request', (tester) async {
      final c = await pumpApp(tester, location: '/invoices');
      expect(c.read(newBillRequestProvider), 0);
      await tester.tap(find.byKey(const ValueKey('header-new-bill')));
      await settle(tester);
      expect(_title('Billing'), findsOneWidget);
      expect(c.read(newBillRequestProvider), 1);
    });

    testWidgets('/settings redirects to the Store profile tab; tabs route', (tester) async {
      await pumpApp(tester, location: '/settings');
      expect(_title('Settings'), findsOneWidget);
      expect(find.text('Pharmacy details'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-tab-appearance')));
      await settle(tester);
      expect(find.text('Brand colour'), findsOneWidget);
    });

    testWidgets('unknown settings tab falls back to Store profile', (tester) async {
      await pumpApp(tester, location: '/settings/bogus');
      expect(find.text('Pharmacy details'), findsOneWidget);
    });
  });

  group('760–1099 px — icon rail', () {
    testWidgets('tablet portrait (800 × 1280) uses the rail with tooltips', (tester) async {
      await pumpApp(tester, size: tabletPortrait);
      expect(find.byKey(const ValueKey('shell-rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-sidebar')), findsNothing);
      expect(find.byTooltip('Sales register'), findsOneWidget);
      expect(find.byTooltip('Backup & restore'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nav-register')));
      await settle(tester);
      expect(_title('Sales register'), findsOneWidget);
    });
  });

  group('< 760 px — bottom bar', () {
    testWidgets('NavigationBar with 4 items + More', (tester) async {
      await pumpApp(tester, size: phone);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-rail')), findsNothing);
      expect(find.byKey(const ValueKey('shell-sidebar')), findsNothing);
      for (final l in ['Dashboard', 'Billing', 'Inventory', 'Invoices', 'More']) {
        expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(l)), findsOneWidget, reason: l);
      }

      await tester.tap(find.byKey(const ValueKey('nav-inventory')));
      await settle(tester);
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Inventory')), findsOneWidget);
    });

    testWidgets('More opens a sheet with Purchases, Register, Backup, Settings', (tester) async {
      await pumpApp(tester, size: phone);
      await tester.tap(find.byKey(const ValueKey('nav-more')));
      await settle(tester);
      expect(find.byKey(const ValueKey('more-purchases')), findsOneWidget);
      expect(find.byKey(const ValueKey('more-register')), findsOneWidget);
      expect(find.byKey(const ValueKey('more-backup')), findsOneWidget);
      expect(find.byKey(const ValueKey('more-settings')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('more-settings')));
      await settle(tester);
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Settings')), findsOneWidget);
      // "More" is highlighted for sections that live under it.
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 4);
    });

    testWidgets('app-bar New bill button has a tooltip and goes to Billing', (tester) async {
      await pumpApp(tester, size: phone, location: '/dashboard');
      await tester.tap(find.byTooltip('New bill'));
      await settle(tester);
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Billing')), findsOneWidget);
    });
  });

  // CLAUDE.md: Windows 1280×800, Android tablet 800×1280 and 1280×800.
  for (final size in [desktop, tabletPortrait, phone]) {
    for (final route in ['/dashboard', '/billing', '/settings/invoice', '/_gallery']) {
      testWidgets('$route lays out at ${size.width.toInt()}×${size.height.toInt()} without overflow', (tester) async {
        await pumpApp(tester, size: size, location: route);
        expect(tester.takeException(), isNull);
        expect(find.byType(PageEnter), findsWidgets);
      });
    }
  }
}
