import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/theme/app_theme.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/settings/application/settings_providers.dart';
import 'package:rx_desk/features/shell/presentation/app_shell.dart';

import '../helpers/pump_app.dart';

void main() {
  setUpAll(setUpFormatting);

  Future<void> run(WidgetTester tester, int ms) async {
    for (var t = 0; t <= ms; t += 50) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('draft → save → discard (SPEC §5.7)', (tester) async {
    final c = await pumpApp(tester, location: '/settings/store');
    expect(find.byKey(const ValueKey('unsaved-bar')), findsNothing);

    // Edit → sticky bar + sidebar dot.
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('store-name')), matching: find.byType(TextField)), 'Zion Medicos');
    await run(tester, 450);
    expect(find.byKey(const ValueKey('unsaved-bar')), findsOneWidget);
    expect(find.text('1 unsaved change — the rest of the app updates when you save'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('nav-settings')), matching: find.byType(PulseDot)), findsOneWidget);
    expect(c.read(settingsProvider).name, '[Your Pharmacy Name]');

    // Save → applied app-wide, bar hides, toast.
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await run(tester, 450);
    expect(c.read(settingsProvider).name, 'Zion Medicos');
    expect(find.byKey(const ValueKey('unsaved-bar')), findsNothing);
    expect(find.text('Settings saved'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('shell-sidebar')), matching: find.text('Zion Medicos')), findsOneWidget);

    // Another edit, then Discard → field reverts, nothing saved.
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('store-name')), matching: find.byType(TextField)), 'Wrong Name');
    await run(tester, 450);
    expect(find.text('Wrong Name'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-discard')));
    await run(tester, 450);
    expect(find.byKey(const ValueKey('unsaved-bar')), findsNothing);
    expect(find.text('Wrong Name'), findsNothing);
    expect(c.read(settingsProvider).name, 'Zion Medicos');
  });

  testWidgets('invalid GSTIN shows inline error and blocks save', (tester) async {
    final c = await pumpApp(tester, location: '/settings/store');
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('store-gstin')), matching: find.byType(TextField)), '15ABC');
    await run(tester, 450);
    expect(find.textContaining('GSTIN should be 15 characters'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await run(tester, 450);
    expect(c.read(settingsProvider).gstin, '');
    expect(find.textContaining('Fix this first'), findsOneWidget);
  });

  testWidgets('accent previews live on Settings and applies on save', (tester) async {
    final c = await pumpApp(tester, location: '/settings/appearance');
    await tester.tap(find.byKey(const ValueKey('swatch-Rose')));
    await run(tester, 450);
    final ctx = tester.element(find.byType(PageHeader));
    expect(ctx.palette.accent.toARGB32(), 0xFFBE123C); // preview
    expect(c.read(settingsProvider).accent, '#0F766E'); // not saved yet
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await run(tester, 450);
    expect(c.read(settingsProvider).accent, '#BE123C');
  });

  testWidgets('dirty dot shows on the Settings nav item after leaving', (tester) async {
    await pumpApp(tester, location: '/settings/billing');
    await tester.tap(find.text('20%'));
    await run(tester, 300);
    await tester.tap(find.byKey(const ValueKey('nav-dashboard')));
    await run(tester, 600);
    expect(find.descendant(of: find.byKey(const ValueKey('nav-settings')), matching: find.byType(PulseDot)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('nav-dashboard')), matching: find.byType(PulseDot)), findsNothing);
  });

  for (final size in [desktop, tabletPortrait]) {
    for (final tab in ['store', 'invoice', 'billing', 'inventory', 'staff', 'appearance']) {
      testWidgets('$tab tab renders at ${size.width.toInt()}×${size.height.toInt()}', (tester) async {
        await pumpApp(tester, size: size, location: '/settings/$tab');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
