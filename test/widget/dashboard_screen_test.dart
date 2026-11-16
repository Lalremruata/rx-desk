import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/features/shell/presentation/app_shell.dart';

import '../helpers/billing_fixture.dart';
import '../helpers/pump_app.dart';

Future<void> _run(WidgetTester tester, [int ms = 900]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(setUpFormatting);

  testWidgets('KPIs, chart, lists; live update after a sale; tap-through to inventory', (tester) async {
    late AppDatabase db;
    await pumpApp(tester, size: const Size(1440, 1100), location: '/dashboard', setUpDb: (d) async {
      db = d;
      await billingFixture(d);
    });
    await _run(tester);
    expect(find.text('Today’s sales'), findsOneWidget);
    expect(find.text('0 invoices · avg ₹0'), findsOneWidget);
    expect(find.text('Sales overview'), findsOneWidget);
    expect(find.text('Reorder soon'), findsOneWidget);
    expect(find.text('Ibuprofen 400 mg Tablet'), findsOneWidget); // out of stock → reorder

    await tester.runAsync(() => db.salesDao.saveBill(
          const SaveBillRequest(lines: [BillLineRequest(productId: 3, batchId: 5, qty: 1)], customerName: 'Esther'),
          rules: const BillRules(),
          at: testNow,
        ));
    await _run(tester);
    expect(find.text('1 invoices · avg ₹25'), findsOneWidget);
    expect(find.text('INV/26-27/00001 · Today · 10:30'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('kpi-low')));
    await _run(tester);
    expect(find.descendant(of: find.byType(PageHeader), matching: find.text('Inventory')), findsOneWidget);
  });

  testWidgets('dashboard lays out on tablet portrait', (tester) async {
    await pumpApp(tester, size: tabletPortrait, location: '/dashboard', setUpDb: billingFixture);
    await _run(tester);
    expect(tester.takeException(), isNull);
  });
}
