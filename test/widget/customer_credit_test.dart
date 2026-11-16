import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/billing/application/bill_controller.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';
import 'package:rx_desk/features/staff/application/session.dart';
import 'package:rx_desk/features/staff/data/staff_repository.dart';

import '../helpers/billing_fixture.dart';
import '../helpers/pump_app.dart';
import '../helpers/test_db.dart';

Future<void> _run(WidgetTester tester, [int ms = 500]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await _run(tester, 150);
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  final f = find.byKey(ValueKey(key));
  final field = find.descendant(of: f, matching: find.byType(TextField));
  await tester.ensureVisible(f);
  await tester.enterText(field.evaluate().isEmpty ? f : field, text);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key, [int ms = 500]) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey(key)));
  await _run(tester, ms);
}

List<String> _toasts(ProviderContainer c) => [for (final t in c.read(toastsProvider)) t.text];

/// Two credit bills for Mami: 10 tabs (₹309) yesterday, 3 tabs (₹92.70 → ₹93) today.
Future<void> _creditBills(AppDatabase db) async {
  final (p, b) = await addMed(db);
  for (final (qty, at) in [(10, testNow.subtract(const Duration(days: 1))), (3, testNow.subtract(const Duration(minutes: 5)))]) {
    await db.salesDao.saveBill(
      SaveBillRequest(
        lines: [BillLineRequest(productId: p, batchId: b, qty: qty)],
        customerName: 'Mami',
        customerPhone: '9800000001',
        paymentMode: 'Credit',
      ),
      rules: const BillRules(),
      at: at,
    );
  }
}

void main() {
  setUpAll(setUpFormatting);

  testWidgets('Pharmacist bills on credit with part payment; over the limit needs the Owner’s PIN', (tester) async {
    late AppDatabase db;
    final c = await pumpApp(
      tester,
      size: const Size(1440, 1000),
      settings: const AppSettings(autoBackup: false, autoPrint: false, defaultCreditLimitPaise: 1000),
      session: const SessionUser(name: 'Pharma', role: StaffRole.pharmacist),
      setUpDb: (d) async {
        db = d;
        await billingFixture(d);
        await StaffRepository(d, () => testNow, iterations: 1000).add(name: 'Boss', role: StaffRole.owner, pin: '4321');
      },
    );
    await _run(tester);
    await tester.enterText(find.byKey(const ValueKey('billing-search')), 'crocin');
    await _key(tester, LogicalKeyboardKey.enter);
    expect(c.read(billControllerProvider).lines, hasLength(1));

    // F8 ×3 → Credit: customer fields turn required, credit panel shows.
    for (var i = 0; i < 3; i++) {
      await _key(tester, LogicalKeyboardKey.f8);
    }
    expect(c.read(billControllerProvider).payment, 'Credit');
    expect(find.byKey(const ValueKey('credit-panel')), findsOneWidget);
    expect(find.text('Customer — required for credit'), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.f10);
    expect(_toasts(c).last, 'Credit bill — enter the customer’s name and phone');

    await _type(tester, 'bill-customer', 'Esther');
    await _type(tester, 'bill-phone', '9811111111');
    await _run(tester, 200);
    expect(find.text('New customer — no dues yet'), findsOneWidget);
    await _type(tester, 'bill-paid-now', '5');
    await _run(tester, 200);
    expect(find.byKey(const ValueKey('credit-over')), findsOneWidget);

    // Save → Owner override dialog with a PIN (the Pharmacist isn't the Owner).
    await _tap(tester, 'save-bill');
    expect(find.byKey(const ValueKey('override-pin')), findsOneWidget);
    await _type(tester, 'override-pin', '1111');
    await _tap(tester, 'override-allow');
    expect(find.text('That isn’t an Owner PIN'), findsOneWidget);
    await tester.runAsync(() async => expect(await countOf(db, 'invoices'), 0));

    await _type(tester, 'override-pin', '4321');
    await _tap(tester, 'override-allow', 800);
    expect(_toasts(c).join(' | '), contains('on credit · dues'));
    await tester.runAsync(() async {
      final inv = (await db.select(db.invoices).get()).single;
      expect((inv.paymentMode, inv.paidNowPaise), ('Credit', 500));
      expect(await db.customersDao.currentDues(inv.customerId!), inv.totalPaise - 500);
    });
  });

  testWidgets('Customers screen: dues list → receive payment → statement → void', (tester) async {
    late AppDatabase db;
    final c = await pumpApp(tester, size: const Size(1440, 1000), location: '/customers', setUpDb: (d) async {
      db = d;
      await _creditBills(d);
    });
    await _run(tester);
    expect(tester.widget<KpiTile>(find.byKey(const ValueKey('kpi-cdues'))).value, '₹402');
    expect(find.text('Mami'), findsOneWidget);
    expect(find.text('₹402.00'), findsOneWidget);
    expect(find.text('2 open bills'), findsOneWidget);

    // Receive ₹350 — clears the older bill, part-pays the newer.
    await _tap(tester, 'cpay-1');
    expect(find.text('Receive payment'), findsWidgets);
    await _type(tester, 'cpay-amount', '350');
    await _run(tester, 100);
    expect(find.text('→ clears'), findsOneWidget);
    await _tap(tester, 'cpay-save', 800);
    expect(_toasts(c).last, '₹350.00 received by Cash');
    await tester.runAsync(() async => expect(await db.customersDao.currentDues(1), 5200));
    expect(find.text('₹52.00'), findsOneWidget);

    // Statement shows bills, the payment and the running balance; void it.
    await _tap(tester, 'cstatement-1');
    expect(find.text('INV/26-27/00001'), findsOneWidget);
    expect(find.text('₹52.00'), findsWidgets);
    final pay = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('cvoid-'));
    expect(pay, findsOneWidget);
    await tester.tap(pay);
    await _run(tester);
    await _type(tester, 'cvoid-reason', 'UPI failed');
    await _tap(tester, 'cvoid-confirm', 800);
    await tester.runAsync(() async => expect(await db.customersDao.currentDues(1), 40200));
  });

  testWidgets('returning from a credit bill defaults to “Adjust in dues”', (tester) async {
    late AppDatabase db;
    final c = await pumpApp(tester, size: const Size(1440, 1000), location: '/invoices', setUpDb: (d) async {
      db = d;
      await _creditBills(d);
    });
    await _run(tester);
    expect(find.text('Credit'), findsWidgets); // the selected bill's payment
    await tester.tap(find.byKey(const ValueKey('return-invoice')));
    await _run(tester);
    expect(find.text('Adjust in dues'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('return-qty-1-plus')));
    await _run(tester, 200);
    await _tap(tester, 'return-save', 800);
    expect(_toasts(c).join(' | '), contains('CN/26-27/00001 saved · ₹31.00 off dues'));
    await tester.runAsync(() async {
      expect(await db.customersDao.currentDues(1), 40200 - 3100);
      final note = (await db.select(db.customerLedger).get()).singleWhere((r) => r.kind == 'credit_note');
      expect(note.amountPaise, 3100);
    });
  });

  for (final size in [desktop, tabletPortrait]) {
    testWidgets('credit panel lays out at ${size.width.toInt()}×${size.height.toInt()}', (tester) async {
      final c = await pumpApp(tester, size: size, setUpDb: billingFixture);
      await _run(tester);
      await tester.enterText(find.byKey(const ValueKey('billing-search')), 'crocin');
      await _key(tester, LogicalKeyboardKey.enter);
      c.read(billControllerProvider.notifier)
        ..setPayment('Credit')
        ..setPaidNow('10');
      await _run(tester);
      expect(find.byKey(const ValueKey('credit-panel')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Customers screen fits a portrait tablet', (tester) async {
    await pumpApp(tester, size: tabletPortrait, location: '/customers', setUpDb: _creditBills);
    await _run(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Mami'), findsOneWidget);
  });
}
