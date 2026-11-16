import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';
import 'package:rx_desk/features/staff/application/session.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_db.dart';

Future<void> _run(WidgetTester tester, [int ms = 500]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester tester, String key, [int ms = 500]) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey(key)));
  await _run(tester, ms);
}

/// Paracetamol: 5 on the 2nd, 3 on the 5th (Nov 2026) and 2 on 30 Oct.
Future<void> _sales(AppDatabase db) async {
  final (p, b) = await addMed(db, qty: 200);
  for (final (q, at) in [(5, DateTime(2026, 11, 2, 10)), (3, DateTime(2026, 11, 5, 10)), (2, DateTime(2026, 10, 30, 10))]) {
    await db.salesDao.saveBill(SaveBillRequest(lines: [BillLineRequest(productId: p, batchId: b, qty: q)]), rules: const BillRules(), at: at);
  }
  await addMed(db, name: 'Zinc Tablet', salt: 'Zinc', batch: 'ZN1', qty: 40);
}

void main() {
  setUpAll(setUpFormatting);

  testWidgets('register shows the month grid, moves months, applies the suggested reorder level', (tester) async {
    late AppDatabase db;
    final c = await pumpApp(tester, size: const Size(1440, 1000), location: '/register/consumption', setUpDb: (d) async {
      db = d;
      await _sales(d);
    });
    await _run(tester);
    expect(find.text('Inventory Management Register'), findsOneWidget);
    expect(find.text('November 2026'), findsOneWidget);
    final row = find.byKey(const ValueKey('crow-1'));
    expect(row, findsOneWidget);
    // Days 2 and 5 → total 8, avg 4, max 5, reorder 10, min 6, buffer 1; suggested 10 packs vs 20 now.
    for (final t in ['5', '3', '8', '4', '10', '6', '1']) {
      expect(find.descendant(of: row, matching: find.text(t)), findsWidgets, reason: t);
    }
    expect(find.text('Zinc Tablet'), findsNothing);

    await _tap(tester, 'month-prev');
    expect(find.text('October 2026'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('crow-1')), matching: find.text('2')), findsWidgets);
    await _tap(tester, 'month-next');

    // All medicines shows the idle one too.
    await tester.tap(find.text('All medicines'));
    await _run(tester);
    expect(find.text('Zinc Tablet'), findsOneWidget);

    await _tap(tester, 'pick-1', 200);
    await _tap(tester, 'apply-reorder');
    await _tap(tester, 'apply-confirm', 800);
    expect(c.read(toastsProvider).last.text, 'Reorder level updated for 1 medicine');
    await tester.runAsync(() async {
      final p = await (db.select(db.products)..where((x) => x.id.equals(1))).getSingle();
      expect(p.reorderLevel, 10);
    });
    expect(find.byKey(const ValueKey('pick-1')), findsNothing); // now equal → nothing to apply
  });

  testWidgets('Cashier can’t open the register', (tester) async {
    await pumpApp(tester, location: '/register/consumption', session: const SessionUser(name: 'C', role: StaffRole.cashier), setUpDb: _sales);
    await _run(tester);
    expect(find.text('Inventory Management Register'), findsNothing);
  });

  testWidgets('register lays out on a portrait tablet', (tester) async {
    await pumpApp(tester, size: tabletPortrait, location: '/register/consumption', setUpDb: _sales);
    await _run(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('crow-1')), findsOneWidget);
  });
}
