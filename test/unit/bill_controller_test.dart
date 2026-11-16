import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/db_provider.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/billing/application/bill_controller.dart';
import 'package:rx_desk/features/billing/application/bill_state.dart';
import 'package:rx_desk/features/invoices/application/invoice_selection.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';
import 'package:rx_desk/features/settings/application/settings_providers.dart';
import 'package:rx_desk/features/staff/application/session.dart';

import '../helpers/billing_fixture.dart';
import '../helpers/fake_printer.dart';
import '../helpers/test_db.dart';

void main() {
  late ProviderContainer c;
  late BillController bill;
  BillState st() => c.read(billControllerProvider);

  Future<ProviderContainer> make({AppSettings settings = const AppSettings(), SessionUser? user}) async {
    final db = memoryDb();
    addTearDown(db.close);
    await billingFixture(db);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowProvider.overrideWithValue(() => t0),
        initialSettingsProvider.overrideWithValue(settings),
        fakePrinterOverride,
      ],
    );
    addTearDown(container.dispose);
    container.read(sessionProvider.notifier).signIn(user ?? const SessionUser(name: 'Owner', role: StaffRole.owner));
    return container;
  }

  setUp(() async {
    c = await make();
    bill = c.read(billControllerProvider.notifier);
  });

  Future<void> search(String q) async {
    bill.setQuery(q);
    await bill.runSearch();
  }

  test('search → ↓ → Enter opens FEFO batch picker; Enter adds first batch', () async {
    await search('para');
    final r = (st().drop as DropResults).results;
    expect(r.rows.map((x) => x.name), ['Paracetamol 500 mg Tablet', 'Paracetamol 650 mg Tablet', 'Crocin Advance']);
    bill.moveHighlight(1);
    await bill.enter();
    final picker = st().drop as DropBatchPicker;
    expect(picker.options.map((o) => o.batchNo), ['PCM2540', 'PCM2611']);
    expect(picker.expired.map((o) => o.batchNo), ['PCM1111']);
    await bill.enter();
    expect(st().lines.single.batchNo, 'PCM2540');
    expect(st().query, '');
    expect(st().drop, isA<DropClosed>());
  });

  test('single saleable batch is added directly; repeat increments, capped', () async {
    await search('para 500');
    await bill.enter();
    expect(st().lines.single.qty, 1);
    for (var i = 0; i < 4; i++) {
      await search('para 500');
      await bill.enter();
    }
    expect(st().lines.single.qty, 3); // batch has 3
    expect(c.read(toastsTexts), contains('All saleable units of Paracetamol 500 mg Tablet are already in the bill'));
  });

  test('barcode Enter selects immediately, before the debounce fires', () async {
    bill.setQuery('8904021650153');
    await bill.enter();
    expect(st().drop, isA<DropBatchPicker>());
  });

  test('out of stock → substitutes (same salt, in stock); Enter adds one', () async {
    await search('ibuprofen');
    await bill.enter();
    final subs = st().drop as DropSubstitutes;
    expect(subs.substitutes.map((s) => s.name), ['Brufen 400']);
    await bill.enter();
    expect(st().lines.single.name, 'Brufen 400');
  });

  test('Esc closes the picker first, then clears the query', () async {
    await search('para 650');
    await bill.enter();
    expect(st().drop, isA<DropBatchPicker>());
    bill.escape();
    expect(st().drop, isNot(isA<DropBatchPicker>()));
    expect(st().query, 'para 650');
    bill.escape();
    expect(st().query, '');
  });

  test('qty edits clamp to batch stock; totals follow SPEC §4.1', () async {
    await search('crocin');
    await bill.enter();
    final key = st().lines.single.key;
    bill.setQty(key, 999);
    expect(st().lines.single.qty, 40);
    bill.setQty(key, 2);
    bill.setDiscount(10);
    final t = c.read(billTotalsProvider);
    expect(t.subtotal, const Paise(5000));
    expect(t.discount, const Paise(500));
    expect(t.net, const Paise(4500));
    expect(t.total, const Paise(4500));
    expect(t.cgst + t.sgst, t.tax);
  });

  test('F8 cycles payment; F2 clears the bill', () async {
    expect(st().payment, 'Cash');
    bill.cyclePayment();
    expect(st().payment, 'UPI');
    bill.cyclePayment();
    bill.cyclePayment();
    expect(st().payment, 'Credit');
    bill.cyclePayment();
    expect(st().payment, 'Cash');
    await search('crocin');
    await bill.enter();
    bill.setCustomer('Esther');
    bill.newBill();
    expect(st().lines, isEmpty);
    expect(st().customer, '');
  });

  test('Credit (SPEC §4.10): needs a customer; part payment; over the limit asks the Owner', () async {
    c = await make(settings: const AppSettings(defaultCreditLimitPaise: 1000));
    bill = c.read(billControllerProvider.notifier);
    await search('crocin');
    await bill.enter();
    bill.setPayment('Credit');
    expect(st().isCredit, isTrue);
    final missing = await bill.save();
    expect(missing, isA<BillRejected>());
    expect(c.read(toastsProvider).last.text, contains('name and phone'));

    bill
      ..setCustomer('Esther')
      ..setPhone('9811111111')
      ..setPaidNow('5')
      ..setPaidNowMode('UPI');
    final total = c.read(billTotalsProvider).total;
    final blocked = await bill.save();
    expect(blocked, isA<CreditLimitBlocked>());
    expect((blocked as CreditLimitBlocked).error.adding, total.value - 500);
    expect(st().lines, isNotEmpty); // bill kept for the retry

    final r = await bill.save(overrideCreditLimit: true);
    expect(r, isA<BillSavedOutcome>());
    final saved = (r as BillSavedOutcome).saved;
    expect(saved.duesAfter, total - const Paise(500));
    expect(c.read(toastsProvider).last.text, contains('on credit · dues'));
    expect(st().payment, 'Cash'); // fresh bill
    expect(st().paidNow, '');
  });

  test('a Cashier can’t pick Credit; F8 skips it', () async {
    c = await make(user: const SessionUser(name: 'Cash', role: StaffRole.cashier));
    bill = c.read(billControllerProvider.notifier);
    bill.setPayment('Credit');
    expect(st().payment, 'Cash');
    expect(c.read(toastsProvider).last.text, contains('can’t sell on credit'));
    bill
      ..cyclePayment()
      ..cyclePayment()
      ..cyclePayment();
    expect(st().payment, 'Cash');
  });

  test('Rx item without doctor blocks saving; with doctor it saves', () async {
    await search('amoxi');
    await bill.enter();
    var r = await bill.save();
    expect(r, isA<BillRejected>());
    expect((r as BillRejected).message, contains('prescribing doctor'));
    expect(st().lines, hasLength(1));

    bill.setDoctor('Dr. J. Lalrinsanga');
    r = await bill.save();
    expect(r, isA<BillSavedOutcome>());
    final saved = (r as BillSavedOutcome).saved;
    expect(saved.number, 'INV/26-27/00001');
    expect(c.read(selectedInvoiceProvider), saved.invoiceId);
    expect(st().lines, isEmpty); // reset
    expect(c.read(toastsTexts).last, startsWith('INV/26-27/00001 saved · ₹99.00 · printing 1 copy'));
  });

  test('default payment comes from settings after saving', () async {
    final c2 = await make(settings: const AppSettings(defaultPayment: 'UPI'));
    expect(c2.read(billControllerProvider).payment, 'UPI');
  });

  test('cashier cannot add Schedule H or give > 5 %', () async {
    final c2 = await make(user: const SessionUser(staffId: 3, name: 'Cash', role: StaffRole.cashier));
    final b2 = c2.read(billControllerProvider.notifier)..setQuery('amoxi');
    await b2.runSearch();
    await b2.enter();
    expect(c2.read(billControllerProvider).lines, isEmpty);
    b2.setDiscount(10);
    expect(c2.read(billControllerProvider).discountPct, 0);
    b2.setDiscount(5);
    expect(c2.read(billControllerProvider).discountPct, 5);
  });
}

/// Test helper: texts of queued toasts.
final toastsTexts = Provider<List<String>>((ref) => ref.watch(toastsProvider).map((t) => t.text).toList());
