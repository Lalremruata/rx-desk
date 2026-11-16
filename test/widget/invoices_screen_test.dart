import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/invoices/application/invoice_printer.dart';
import 'package:rx_desk/features/invoices/presentation/invoice_paper.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';
import 'package:rx_desk/features/staff/application/session.dart';

import '../helpers/fake_printer.dart';
import '../helpers/pump_app.dart';
import '../helpers/test_db.dart';

Future<void> _run(WidgetTester tester, [int ms = 500]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _bills(AppDatabase db) async {
  final (p, b) = await addMed(db);
  for (var i = 0; i < 3; i++) {
    await db.salesDao.saveBill(
      SaveBillRequest(
        lines: [BillLineRequest(productId: p, batchId: b, qty: i + 1)],
        customerName: ['Esther', 'Ruata', 'Mawia'][i],
        paymentMode: i == 1 ? 'Cash' : 'UPI',
        discountPct: i == 2 ? 5 : 0,
      ),
      rules: const BillRules(),
      at: testNow.subtract(Duration(minutes: 30 - i)),
    );
  }
}

void main() {
  setUpAll(setUpFormatting);

  testWidgets('lists today’s bills, previews the selected one, prints', (tester) async {
    final c = await pumpApp(tester, size: const Size(1440, 1000), location: '/invoices', setUpDb: _bills);
    await _run(tester);
    expect(find.text('3'), findsWidgets); // "3 bills"
    expect(find.text('Mawia'), findsWidgets);
    // Newest first is selected by default and previewed.
    expect(find.byType(InvoicePaperView), findsOneWidget);
    expect(find.text('INV/26-27/00003'), findsWidgets);
    expect(find.text('TAX INVOICE'), findsOneWidget);
    expect(find.text('You saved ₹4.64 on MRP'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('invoice-INV/26-27/00001')));
    await _run(tester);
    expect(find.text('Esther'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('print-invoice')));
    await _run(tester);
    final printer = c.read(invoicePrinterProvider) as FakeInvoicePrinter;
    expect(printer.printed.single.$2, 1);

    // Payment filter.
    await tester.tap(find.text('All modes'));
    await _run(tester, 200);
    await tester.tap(find.text('Cash').last);
    await _run(tester);
    expect(find.text('Ruata'), findsOneWidget);
    expect(find.text('Mawia'), findsNothing);
  });

  testWidgets('cancel bill asks first, restores stock and marks it cancelled', (tester) async {
    late AppDatabase db;
    await pumpApp(tester, size: const Size(1440, 1000), location: '/invoices', setUpDb: (d) async {
      db = d;
      await _bills(d);
    });
    await _run(tester);
    await tester.tap(find.byKey(const ValueKey('cancel-invoice')));
    await _run(tester);
    expect(find.text('Cancel INV/26-27/00003?'), findsOneWidget);
    await tester.tap(find.text('Cancel bill').last);
    await _run(tester, 600);
    expect(find.text('CANCELLED'), findsOneWidget);
    expect(find.text('Cancelled'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await qtyOf(db, 1), 100 - 1 - 2); // bill 3 (qty 3) restored
    });
  });

  testWidgets('settings preview follows the draft; paper switch resizes it', (tester) async {
    await pumpApp(tester, size: const Size(1600, 1100), location: '/settings/invoice', settings: const AppSettings(name: 'Zion Medicos'));
    await _run(tester);
    expect(find.text('Zion Medicos'), findsWidgets);
    expect(find.text('LIVE PREVIEW · A4'), findsOneWidget);
    final paper = find.descendant(of: find.byKey(const ValueKey('settings-preview')), matching: find.byType(AnimatedContainer)).first;
    final before = tester.getSize(paper).width;

    await tester.tap(find.byKey(const ValueKey('paper-T58')));
    await _run(tester, 600);
    expect(find.text('LIVE PREVIEW · THERMAL 58 MM'), findsOneWidget);
    final after = tester.getSize(paper).width;
    expect(after, lessThan(before));

    // Toggle "Batch number" off → no Batch header on A4.
    await tester.tap(find.byKey(const ValueKey('paper-A4')));
    await _run(tester, 600);
    expect(find.text('Batch'), findsOneWidget);
    await tester.ensureVisible(find.text('Batch number'));
    await tester.tap(find.text('Batch number'));
    await _run(tester, 300);
    expect(find.text('Batch'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('test-print')));
    await _run(tester);
  });

  testWidgets('return items: one strip back → credit note printed, bill marked part returned, stock restored', (tester) async {
    late AppDatabase db;
    final c = await pumpApp(tester, size: const Size(1440, 1000), location: '/invoices', setUpDb: (d) async {
      db = d;
      await _bills(d);
    });
    await _run(tester);
    await tester.tap(find.byKey(const ValueKey('return-invoice')));
    await _run(tester);
    expect(find.text('Return items'), findsWidgets);
    expect(find.byKey(const ValueKey('return-qty-1')), findsOneWidget);
    expect(find.text('0 / 3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('return-qty-1-plus')));
    await _run(tester, 200);
    expect(find.text('1 / 3'), findsOneWidget);
    // ₹30.90 at 5 % off = ₹29.36 → rounds to ₹29.
    expect(tester.widget<Text>(find.byKey(const ValueKey('return-total'))).data, '₹29.00');

    await tester.ensureVisible(find.byKey(const ValueKey('return-save')));
    await tester.tap(find.byKey(const ValueKey('return-save')));
    await _run(tester, 800);

    expect([for (final t in c.read(toastsProvider)) t.text].join(' | '), contains('CN/26-27/00001 saved · Refund ₹29.00'));
    expect(find.text('CREDIT NOTE'), findsOneWidget);
    expect(find.byKey(const ValueKey('invoice-against')), findsOneWidget);
    expect(find.text('Part returned'), findsOneWidget);
    final printer = c.read(invoicePrinterProvider) as FakeInvoicePrinter;
    expect(printer.printed, isNotEmpty);
    await tester.runAsync(() async {
      expect(await qtyOf(db, 1), 100 - 6 + 1);
    });

    // Jump back to the bill: no Cancel once items were returned.
    await tester.tap(find.byKey(const ValueKey('linked-doc-3')));
    await _run(tester);
    expect(find.text('TAX INVOICE'), findsOneWidget);
    expect(find.byKey(const ValueKey('cancel-invoice')), findsNothing);
    expect(find.byKey(const ValueKey('return-invoice')), findsOneWidget);
  });

  testWidgets('return dialog fits a portrait tablet', (tester) async {
    await pumpApp(tester, size: tabletPortrait, location: '/invoices', setUpDb: _bills);
    await _run(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('return-invoice')));
    await tester.tap(find.byKey(const ValueKey('return-invoice')));
    await _run(tester);
    await tester.tap(find.byKey(const ValueKey('return-qty-1-plus')));
    await _run(tester, 200);
    expect(find.text('Damaged — don’t restock'), findsOneWidget);
  });

  testWidgets('Cashier can’t accept returns', (tester) async {
    await pumpApp(
      tester,
      size: const Size(1440, 1000),
      location: '/invoices',
      setUpDb: _bills,
      session: const SessionUser(name: 'Cashier', role: StaffRole.cashier),
    );
    await _run(tester);
    expect(find.byType(InvoicePaperView), findsOneWidget);
    expect(find.byKey(const ValueKey('return-invoice')), findsNothing);
  });
}
