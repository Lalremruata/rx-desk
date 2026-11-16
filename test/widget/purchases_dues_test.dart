import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/purchases_dao.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/widgets/widgets.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_db.dart';

Future<void> _run(WidgetTester tester, [int ms = 600]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey(key)));
  await _run(tester);
}

List<String> _toasts(ProviderContainer c) => [for (final t in c.read(toastsProvider)) t.text];

/// One overdue bill (received 1 Oct, due 31 Oct) of ₹3,612 from Life Drugs Centre.
Future<void> _seedBill(AppDatabase db) async {
  final (pid, _) = await addMed(db);
  await db.purchasesDao.receive(
    ReceiveRequest(
      supplierName: 'Life Drugs Centre',
      invoiceNo: '26000730032563',
      receivedDate: '2026-10-01',
      lines: [ReceiveLineInput(productId: pid, batchNo: 'PCM2611', qty: 2, unit: 'Box', stockUnits: 20, amount: const Paise(361200))],
    ),
    at: t0,
    now: t0,
  );
}

void main() {
  setUpAll(setUpFormatting);

  testWidgets('receive billed total + paid now → Dues → pay all → statement → void', (tester) async {
    final c = await pumpApp(tester, size: const Size(1440, 1000), location: '/purchases', setUpDb: addMed);
    await _run(tester);

    await _tap(tester, 'receive-invoice');
    await _type(tester, 'recv-supplier', 'Life Drugs Centre');
    await _type(tester, 'recv-invoice', 'INV-77');
    await _type(tester, 'recv-add-item', 'para');
    await _run(tester, 300);
    await tester.tap(find.byKey(const ValueKey('pick-1')));
    await _run(tester, 100);
    await _type(tester, 'recv-qty-0', '10');
    await _type(tester, 'recv-batch-0', 'PCM2611');
    await _type(tester, 'recv-amount-0', '9800');
    await _type(tester, 'recv-bill-total', '10000');
    expect(find.textContaining('difference ₹200.00'), findsOneWidget);
    await _type(tester, 'recv-paid', '2000');
    expect(find.text('₹8,000.00 will be owed to the stockist, due Wed 9 Dec 26.'), findsOneWidget);
    await _tap(tester, 'recv-save-invoice');
    expect(_toasts(c).last, 'Invoice INV-77 saved · 1 line · +10 units · ₹10,000.00 · ₹2,000.00 paid');
    expect(tester.widget<KpiTile>(find.byKey(const ValueKey('kpi-owed'))).value, '₹8,000');

    // Dues tab.
    await tester.tap(find.text('Dues'));
    await _run(tester);
    expect(find.text('Life Drugs Centre'), findsOneWidget);
    expect(find.text('₹8,000.00'), findsOneWidget);

    // Pay everything.
    await _tap(tester, 'pay-1');
    expect(find.text('→ clears'), findsNothing);
    await _tap(tester, 'pay-all');
    expect(find.text('→ clears'), findsOneWidget);
    await _tap(tester, 'pay-save');
    expect(_toasts(c).last, '₹8,000.00 paid by Cash');

    // Receipts: paid.
    await tester.tap(find.text('Receipts'));
    await _run(tester);
    expect(find.text('Paid'), findsOneWidget);

    // Statement: bill, two payments, balance 0; void the second payment.
    await tester.tap(find.text('Dues'));
    await _run(tester);
    await _tap(tester, 'statement-1');
    expect(tester.widget<Text>(find.byKey(const ValueKey('stmt-balance'))).data, '₹0.00');
    expect(find.text('Bill'), findsOneWidget);
    expect(find.text('Payment'), findsNWidgets(2));
    await _tap(tester, 'void-3');
    await _type(tester, 'void-reason', 'Cheque bounced');
    await _tap(tester, 'void-confirm');
    expect(_toasts(c).last, 'Payment ₹8,000.00 voided');
    expect(tester.widget<Text>(find.byKey(const ValueKey('stmt-balance'))).data, '₹8,000.00');
    expect(find.text('Void: Cheque bounced'), findsOneWidget);
  });

  testWidgets('tablet portrait: Dues, payment and statement have no overflow', (tester) async {
    await pumpApp(tester, size: tabletPortrait, location: '/purchases', setUpDb: _seedBill);
    await _run(tester);
    await tester.tap(find.text('Dues'));
    await _run(tester);
    expect(find.text('Life Drugs Centre'), findsOneWidget);
    await _tap(tester, 'pay-1');
    expect(find.textContaining('days overdue'), findsOneWidget);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await _run(tester);
    await _tap(tester, 'statement-1');
    expect(find.text('Overdue'), findsWidgets);
    await _tap(tester, 'stmt-return');
    expect(find.text('Return / credit note'), findsWidgets);
  });

  testWidgets('dashboard shows stockist dues and overdue', (tester) async {
    await pumpApp(tester, size: const Size(1440, 1000), location: '/dashboard', setUpDb: _seedBill);
    await _run(tester);
    expect(find.text('Stockist dues'), findsOneWidget);
    final t = tester.widget<Text>(find.byKey(const ValueKey('dash-dues')));
    expect(t.textSpan!.toPlainText(), '₹3,612  owed · ₹3,612 overdue');
  });
}
