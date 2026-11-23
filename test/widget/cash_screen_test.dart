import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/db/db_provider.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';
import 'package:rx_desk/features/staff/application/session.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_db.dart';

Future<void> _run(WidgetTester tester, [int ms = 600]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)).first, text);
  await _run(tester, 200);
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await _run(tester, 100);
  await tester.tap(find.byKey(ValueKey(key)));
  await _run(tester);
}

List<String> _toasts(ProviderContainer c) => [for (final t in c.read(toastsProvider)) t.text];

/// Day close (SPEC §4.14).
void main() {
  setUpAll(setUpFormatting);

  testWidgets('cashier: opening, a paid-out, count and close the day', (tester) async {
    final c = await pumpApp(
      tester,
      location: '/cash',
      session: const SessionUser(name: 'Mawii', role: StaffRole.cashier),
      setUpDb: (db) async {
        final (p, b) = await addMed(db);
        await db.salesDao.saveBill(
          SaveBillRequest(lines: [BillLineRequest(productId: p, batchId: b, qty: 2)]),
          rules: const BillRules(),
          at: testNow,
        ); // ₹62.00 cash
      },
    );
    await _run(tester);
    expect(find.text('Not closed yet'), findsOneWidget);
    await _type(tester, 'cash-opening', '2000');
    expect(tester.widget<Text>(find.byKey(const ValueKey('cash-expected'))).data, '₹2,062.00');

    await _tap(tester, 'cash-add-paidout');
    await _type(tester, 'paidout-amount', '12');
    await _type(tester, 'paidout-note', 'Tea');
    await _tap(tester, 'paidout-save');
    expect(tester.widget<Text>(find.byKey(const ValueKey('cash-expected'))).data, '₹2,050.00');

    await _type(tester, 'cash-counted', '2045');
    expect(find.text('₹5.00 short'), findsOneWidget);
    await _tap(tester, 'cash-close');
    expect(_toasts(c).last, 'Day closed · expected ₹2,050.00 · counted ₹2,045.00 · ₹5.00 short');
    expect(find.textContaining('Closed '), findsOneWidget);
    final closing = (await tester.runAsync(() => c.read(appDatabaseProvider).cashDao.closingOf('2026-11-09')))!;
    expect((closing.openingPaise, closing.paidOutsPaise, closing.differencePaise), (200000, 1200, -500));
  });

  testWidgets('a role without cashClose sees access denied', (tester) async {
    await pumpApp(
      tester,
      location: '/cash',
      session: const SessionUser(name: 'Mawii', role: StaffRole.cashier),
      settings: const AppSettings(autoBackup: false, rolePermissions: {'Pharmacist': [], 'Cashier': []}),
    );
    await _run(tester);
    expect(find.byKey(const ValueKey('cash-close')), findsNothing);
  });

  testWidgets('tablet portrait lays out without overflow, counting by notes', (tester) async {
    await pumpApp(tester, size: tabletPortrait, location: '/cash');
    await _run(tester);
    await _tap(tester, 'cash-by-notes');
    await _type(tester, 'cash-note-500', '4');
    await _type(tester, 'cash-coins', '7');
    expect(find.textContaining('Counted ₹2,007.00'), findsOneWidget);
  });
}
