import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/db/db_provider.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/invoices/application/invoice_document.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';

import '../helpers/billing_fixture.dart';
import '../helpers/pump_app.dart';
import '../helpers/test_db.dart';

Future<void> _run(WidgetTester tester, [int ms = 400]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _settings = AppSettings(autoBackup: false, name: 'Zion Medicos', gstin: '15ABCDE1234F1Z5');

/// B2B bills and GSTR-1 (SPEC §4.15).
void main() {
  setUpAll(setUpFormatting);

  testWidgets('buyer GSTIN: checked as typed, saved on the bill, printed under Billed to', (tester) async {
    final c = await pumpApp(tester, size: const Size(1440, 900), settings: _settings, setUpDb: billingFixture);
    await _run(tester);
    await tester.enterText(find.byKey(const ValueKey('billing-search')), 'crocin');
    await _run(tester, 300);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _run(tester);
    await tester.enterText(find.byKey(const ValueKey('bill-customer')).first, 'Hope Clinic');
    await tester.enterText(find.byKey(const ValueKey('bill-gstin-field')), '27AAPFU0939F1ZV');
    await _run(tester);
    expect(find.text('This GSTIN is from Maharashtra — inter-state (IGST) bills aren’t supported'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('bill-gstin-field')), '15aaacm1234a1zd');
    await _run(tester);
    expect(find.text('B2B tax invoice · place of supply 15-Mizoram'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('save-bill')));
    await tester.tap(find.byKey(const ValueKey('save-bill')));
    await _run(tester, 800);
    expect(c.read(toastsProvider).last.text, startsWith('INV/26-27/00001 saved'));
    final w = (await tester.runAsync(() => c.read(appDatabaseProvider).salesDao.invoiceWithItems(1)))!;
    final doc = buildInvoiceDoc(InvoiceData.fromDb(w), _settings);
    expect(doc.phone, 'GSTIN 15AAACM1234A1ZD · Place of supply 15-Mizoram');
  });

  testWidgets('GSTR-1 (month) opens on last month and totals the bills', (tester) async {
    await pumpApp(
      tester,
      location: '/register',
      settings: _settings,
      setUpDb: (db) async {
        final (p, b) = await addMed(db, qty: 50);
        await db.salesDao.saveBill(
          SaveBillRequest(lines: [BillLineRequest(productId: p, batchId: b, qty: 4)]),
          rules: const BillRules(),
          at: DateTime(2026, 10, 15, 11),
        );
      },
    );
    await _run(tester, 600);
    await tester.tap(find.byKey(const ValueKey('saved-gstr1')));
    await _run(tester, 600);
    expect(find.text('October 2026'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('gstr1-net'))).data, '₹110.36'); // 4 × 30.90 incl. 12 %
    expect(find.byKey(const ValueKey('gstr1-export')), findsOneWidget);
  });
}
