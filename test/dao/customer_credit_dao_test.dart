import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/customers_dao.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/sales/credit_rules.dart';
import 'package:rx_desk/core/sales/return_rules.dart';

import '../helpers/test_db.dart';

void main() {
  late AppDatabase db;
  late CustomersDao cust;
  late int pid;
  late int bid;

  setUp(() async {
    db = memoryDb();
    cust = db.customersDao;
    (pid, bid) = await addMed(db, qty: 500);
  });

  // Invariant: the stored open amount always matches the allocations.
  tearDown(() async {
    final bad = await db.customSelect('''
      SELECT id FROM customer_ledger l
      WHERE open_paise <> CASE WHEN status <> 'active' THEN 0 ELSE amount_paise - COALESCE(CASE WHEN kind IN ('opening', 'bill')
        THEN (SELECT SUM(amount_paise) FROM customer_allocations a WHERE a.debit_id = l.id)
        ELSE (SELECT SUM(amount_paise) FROM customer_allocations a WHERE a.credit_id = l.id) END, 0) END
         OR open_paise < 0''').get();
    expect(bad, isEmpty, reason: 'open_paise out of step with allocations');
    await db.close();
  });

  const phone = '9876543210';
  const today = '2026-11-09';

  /// 10 tablets at ₹30.90 = ₹309.00.
  Future<SavedBill> creditBill({
    int qty = 10,
    int paidNow = 0,
    String name = 'Lalremruati',
    String? ph = phone,
    bool override = false,
    BillRules rules = const BillRules(),
    DateTime? at,
    String mode = creditMode,
  }) =>
      db.salesDao.saveBill(
        SaveBillRequest(
          lines: [BillLineRequest(productId: pid, batchId: bid, qty: qty)],
          customerName: name,
          customerPhone: ph,
          paymentMode: mode,
          paidNow: Paise(paidNow),
          paidNowMode: 'UPI',
          overrideCreditLimit: override,
        ),
        rules: rules,
        at: at ?? t0,
      );

  Future<int> customerId([String ph = phone]) async => (await db.salesDao.customerByPhone(ph))!.id;

  Future<List<CustomerLedgerData>> ledger() =>
      (db.select(db.customerLedger)..orderBy([(l) => OrderingTerm.asc(l.id)])).get();

  test('credit bill with part payment: bill debit, paid-now payment, snapshots on the invoice', () async {
    final s = await creditBill(paidNow: 10000);
    expect(s.totals.total, const Paise(30900));
    expect(s.duesAfter, const Paise(20900));
    final inv = (await db.salesDao.invoiceWithItems(s.invoiceId))!.invoice;
    expect((inv.paymentMode, inv.paidNowPaise, inv.duesAfterPaise), ('Credit', 10000, 20900));
    final rows = await ledger();
    expect(rows.map((r) => (r.kind, r.amountPaise, r.openPaise, r.invoiceId)), [
      ('bill', 30900, 20900, s.invoiceId),
      ('payment', 10000, 0, s.invoiceId),
    ]);
    expect(rows[1].mode, 'UPI');
    expect(await cust.currentDues(await customerId()), 20900);
    // Stock and sales move exactly as for a cash bill.
    expect(await qtyOf(db, bid), 490);
  });

  test('credit needs a named customer with a phone, paid now below the total, and the permission', () async {
    await expectLater(creditBill(ph: null), throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.customerRequired)));
    await expectLater(creditBill(name: ''), throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.customerRequired)));
    await expectLater(creditBill(paidNow: 30900), throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.invalidPaidNow)));
    await expectLater(
      creditBill(rules: const BillRules(canSellOnCredit: false)),
      throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.creditNotPermitted)),
    );
    // Nothing was written: no invoice, no ledger, stock and numbering untouched.
    expect(await countOf(db, 'invoices'), 0);
    expect(await countOf(db, 'customer_ledger'), 0);
    expect(await qtyOf(db, bid), 500);
    expect((await creditBill()).number, 'INV/26-27/00001');
  });

  test('credit limit blocks the bill (rolled back) unless the Owner overrides; 0 = no limit', () async {
    const rules = BillRules(defaultCreditLimit: 50000);
    await creditBill(rules: rules);
    final over = creditBill(rules: rules, paidNow: 5000);
    await expectLater(
      over,
      throwsA(isA<CreditLimitException>()
          .having((e) => (e.dues, e.adding, e.limit, e.overBy), 'amounts', (30900, 25900, 50000, 6800))),
    );
    expect(await countOf(db, 'invoices'), 1);
    expect(await countOf(db, 'customer_ledger'), 1);
    expect(await qtyOf(db, bid), 490);

    final ok = await creditBill(rules: rules, paidNow: 5000, override: true);
    expect(ok.duesAfter, const Paise(56800));
    expect(ok.number, 'INV/26-27/00002'); // gapless: the blocked try used no number

    // The customer's own limit wins over the default; 0 = no limit.
    final c = await customerId();
    await cust.updateCustomer(c, name: 'Lalremruati', phone: phone, creditLimit: 0);
    await creditBill(rules: rules);
    await cust.updateCustomer(c, name: 'Lalremruati', phone: phone, creditLimit: 100000);
    await expectLater(creditBill(rules: rules), throwsA(isA<CreditLimitException>()));
  });

  test('cancelling a credit bill voids its debit and paid-now payment; later payments re-apply', () async {
    final a = await creditBill(paidNow: 10000);
    final b = await creditBill(at: t0.add(const Duration(days: 1)));
    final c = await customerId();
    // A payment that FIFO-applies to bill A.
    await cust.recordPayment(
      customerId: c,
      date: '2026-11-10',
      payment: const CustomerPaymentInput(amount: Paise(20900), mode: 'Cash'),
      at: t0,
    );
    expect(await cust.currentDues(c), 30900);
    await db.salesDao.cancelInvoice(a.invoiceId, at: t0, reason: 'wrong customer');
    final rows = await ledger();
    expect(rows.where((r) => r.invoiceId == a.invoiceId).map((r) => r.status), ['void', 'void']);
    // The Cash payment moved to bill B.
    final billB = rows.firstWhere((r) => r.invoiceId == b.invoiceId && r.kind == 'bill');
    expect(billB.openPaise, 30900 - 20900);
    expect(await cust.currentDues(c), 10000);
  });

  test('return adjusted in dues goes to the original bill first; cash refunds leave dues alone', () async {
    final a = await creditBill();
    final b = await creditBill(at: t0.add(const Duration(days: 1)));
    final item = (await db.salesDao.invoiceWithItems(b.invoiceId))!.items.single;
    final cn = await db.salesDao.saveCreditNote(
      SaveCreditNoteRequest(invoiceId: b.invoiceId, lines: [ReturnLineRequest(itemId: item.id, qty: 2)], refundMode: creditMode),
      rules: const ReturnRules(),
      at: t0.add(const Duration(days: 2)),
    );
    expect(cn.totals.total, const Paise(6200)); // 61.80 rounded
    final rows = await ledger();
    final note = rows.singleWhere((r) => r.kind == 'credit_note');
    expect((note.amountPaise, note.invoiceId, note.reference), (6200, cn.creditNoteId, cn.number));
    expect(rows.firstWhere((r) => r.invoiceId == a.invoiceId).openPaise, 30900);
    expect(rows.firstWhere((r) => r.invoiceId == b.invoiceId).openPaise, 30900 - 6200);

    await db.salesDao.saveCreditNote(
      SaveCreditNoteRequest(invoiceId: b.invoiceId, lines: [ReturnLineRequest(itemId: item.id, qty: 1)], refundMode: 'Cash'),
      rules: const ReturnRules(),
      at: t0.add(const Duration(days: 2)),
    );
    expect(await countOf(db, 'customer_ledger'), 3);
    expect(await cust.currentDues(await customerId()), 61800 - 6200);
  });

  test('a walk-in bill can’t be refunded to dues', () async {
    final s = await creditBill(mode: 'Cash', name: '', ph: null);
    final item = (await db.salesDao.invoiceWithItems(s.invoiceId))!.items.single;
    await expectLater(
      db.salesDao.saveCreditNote(
        SaveCreditNoteRequest(invoiceId: s.invoiceId, lines: [ReturnLineRequest(itemId: item.id, qty: 1)], refundMode: creditMode),
        rules: const ReturnRules(),
        at: t0,
      ),
      throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.customerRequired)),
    );
    expect(await countOf(db, 'invoices'), 1);
  });

  test('payments: oldest first or picked bills; overpayment stays as advance and pays the next bill', () async {
    final a = await creditBill();
    final b = await creditBill(at: t0.add(const Duration(days: 1)));
    final c = await customerId();
    final bills = await cust.openBills(c);
    expect(bills.map((x) => x.reference), [a.number, b.number]);

    await cust.recordPayment(
      customerId: c,
      date: today,
      payment: const CustomerPaymentInput(amount: Paise(10000), mode: 'UPI', reference: 'UTR123'),
      pickedDebitIds: {bills[1].ledgerId},
      at: t0,
    );
    var open = await cust.openBills(c);
    expect(open.map((x) => x.outstanding.value), [30900, 20900]);

    await cust.recordPayment(
      customerId: c,
      date: today,
      payment: const CustomerPaymentInput(amount: Paise(60000), mode: 'Cash'),
      at: t0,
    );
    expect(await cust.openBills(c), isEmpty);
    final d = await cust.customerDues(c, today: today);
    expect((d.outstanding, d.advance, d.balance), (Paise.zero, const Paise(8200), const Paise(-8200)));

    final next = await creditBill(at: t0.add(const Duration(days: 2)));
    expect(next.duesAfter, const Paise(30900 - 8200));
    open = await cust.openBills(c);
    expect(open.single.outstanding, const Paise(22700));

    await expectLater(
      cust.recordPayment(customerId: c, date: today, payment: const CustomerPaymentInput(amount: Paise(100), mode: 'Cheque'), at: t0),
      throwsA(isA<CustomerException>()),
    );
  });

  test('voids: payments and opening dues re-settle; bills and bill-linked payments refuse', () async {
    final a = await creditBill(paidNow: 10000);
    final c = await customerId();
    final pay = await cust.recordPayment(
      customerId: c,
      date: today,
      payment: const CustomerPaymentInput(amount: Paise(5000), mode: 'Cash'),
      at: t0,
    );
    expect(await cust.currentDues(c), 15900);
    await cust.voidEntry(pay, reason: 'entered twice');
    expect(await cust.currentDues(c), 20900);
    await expectLater(cust.voidEntry(pay, reason: 'again'), throwsA(isA<CustomerException>()));

    final rows = await ledger();
    final bill = rows.firstWhere((r) => r.kind == 'bill');
    final paidNow = rows.firstWhere((r) => r.kind == 'payment' && r.invoiceId == a.invoiceId);
    await expectLater(cust.voidEntry(bill.id, reason: 'x'), throwsA(isA<CustomerException>()));
    await expectLater(cust.voidEntry(paidNow.id, reason: 'x'), throwsA(isA<CustomerException>()));

    final open = await cust.setOpeningBalance(customerId: c, date: '2026-04-01', amount: const Paise(150000), at: t0);
    await expectLater(
      cust.setOpeningBalance(customerId: c, date: '2026-04-01', amount: const Paise(1), at: t0),
      throwsA(isA<CustomerException>()),
    );
    expect(await cust.currentDues(c), 170900);
    await expectLater(cust.voidEntry(open, reason: ''), throwsA(isA<CustomerException>()));
    await cust.voidEntry(open, reason: 'wrong amount');
    expect(await cust.currentDues(c), 20900);
  });

  test('dues list, totals with 90+ days, statement running balance', () async {
    await creditBill();
    final c1 = await customerId();
    final c2 = await cust.addCustomer(name: 'Zova Traders', phone: '9000000002', at: t0);
    await cust.setOpeningBalance(customerId: c2, date: '2026-06-01', amount: const Paise(500000), at: t0);
    await cust.addCustomer(name: 'Andrea', phone: '9000000003', at: t0);
    await expectLater(cust.addCustomer(name: 'Dup', phone: phone, at: t0), throwsA(isA<CustomerException>()));

    final all = await cust.duesPage(today: today);
    expect(all.total, 3);
    expect(all.rows.map((r) => r.name), ['Andrea', 'Lalremruati', 'Zova Traders']);
    final due = await cust.duesPage(today: today, withDues: true);
    expect(due.rows.map((r) => (r.name, r.balance.value)), [('Zova Traders', 500000), ('Lalremruati', 30900)]);
    expect((await cust.duesPage(today: today, search: '9000000002')).rows.single.customerId, c2);
    expect((await cust.duesPage(today: today, search: 'lal', withDues: true)).rows.single.customerId, c1);

    final (totals, top) = await cust.totals(today: today);
    expect((totals.owed.value, totals.customers, totals.over90.value, totals.over90Customers), (530900, 2, 500000, 1));
    expect(top.first.name, 'Zova Traders');
    expect(top.first.agingOn(today), AgingBucket.over90);

    await cust.recordPayment(customerId: c1, date: today, payment: const CustomerPaymentInput(amount: Paise(900), mode: 'Cash'), at: t0);
    final st = await cust.statement(c1);
    expect(st.rows.map((r) => (r.kind, r.balance.value)), [(CustomerLedgerKind.bill, 30900), (CustomerLedgerKind.payment, 30000)]);
    expect((await cust.customerDues(c1, today: today)).lastPayment, today);
    final page1 = await cust.statement(c1, limit: 1);
    expect(page1.hasMore, isTrue);
    final page2 = await cust.statement(c1, after: CustomerStatementCursor(page1.rows.last.date, page1.rows.last.id));
    expect(page2.rows.single.kind, CustomerLedgerKind.payment);
  });
}
