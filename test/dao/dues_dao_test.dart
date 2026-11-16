import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/dues_dao.dart';
import 'package:rx_desk/core/db/daos/purchases_dao.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/purchases/dues_rules.dart';
import 'package:rx_desk/core/purchases/purchase_rules.dart';

import '../helpers/test_db.dart';

void main() {
  late AppDatabase db;
  late DuesDao dues;
  late int pid;
  var inv = 0;
  setUp(() async {
    inv = 0;
    db = memoryDb();
    dues = db.duesDao;
    (pid, _) = await addMed(db);
  });
  // Invariant: the stored open amount always matches the allocations.
  tearDown(() async {
    final bad = await db.customSelect('''
      SELECT id FROM supplier_ledger l
      WHERE open_paise <> CASE WHEN status <> 'active' THEN 0 ELSE amount_paise - COALESCE(CASE WHEN kind IN ('opening', 'bill')
        THEN (SELECT SUM(amount_paise) FROM ledger_allocations a WHERE a.debit_id = l.id)
        ELSE (SELECT SUM(amount_paise) FROM ledger_allocations a WHERE a.credit_id = l.id) END, 0) END
         OR open_paise < 0''').get();
    expect(bad, isEmpty, reason: 'open_paise out of step with allocations');
    await db.close();
  });

  const today = '2026-11-09';

  /// Receives one line and returns (receiptId, supplierId).
  Future<(SavedReceipt, int)> bill(
    int rupees, {
    String supplier = 'Life Drugs Centre',
    String date = '2026-10-01',
    int? billed,
    PaymentInput? paidNow,
    String? dueDate,
  }) async {
    final r = await db.purchasesDao.receive(
      ReceiveRequest(
        supplierName: supplier,
        invoiceNo: 'INV${++inv}',
        receivedDate: date,
        lines: [ReceiveLineInput(productId: pid, batchNo: 'PCM2611', qty: 1, unit: 'Box', stockUnits: 10, amount: Paise.rupees(rupees))],
        billTotal: billed == null ? null : Paise.rupees(billed),
        paidNow: paidNow,
        dueDate: dueDate,
      ),
      at: t0,
      now: t0,
    );
    final sid = (await db.purchasesDao.allSuppliers()).firstWhere((s) => s.name == supplier).id;
    return (r, sid);
  }

  Future<SupplierDues> of(int sid) => dues.supplierDues(sid, today: today);

  test('bill total as billed + paid on delivery → outstanding, due date, part paid', () async {
    final (r, sid) = await bill(9800, billed: 10000, date: '2026-11-01', paidNow: const PaymentInput(amount: Paise.rupees(2000), mode: 'Cash'));
    expect(r.total, const Paise.rupees(9800));
    expect(r.billTotal, const Paise.rupees(10000));
    expect(r.dueDate, '2026-12-01');
    final d = await of(sid);
    expect(d.outstanding, const Paise.rupees(8000));
    expect(d.balance, const Paise.rupees(8000));
    expect(d.overdue, Paise.zero);
    final receipt = (await db.purchasesDao.receiptPage()).rows.single;
    expect(receipt.status, BillStatus.part);
    expect(receipt.outstanding, const Paise.rupees(8000));
  });

  test('a lump sum pays the oldest bills first; picked bills only when ticked', () async {
    final (_, sid) = await bill(1000, date: '2026-09-01');
    await bill(2000, date: '2026-09-15');
    await bill(3000);
    await dues.recordPayment(supplierId: sid, date: today, payment: const PaymentInput(amount: Paise.rupees(2500), mode: 'UPI', reference: 'UTR1'), at: t0);
    var open = await dues.openBills(sid);
    expect(open.map((b) => (b.reference, b.outstanding.value ~/ 100, b.status)), [('INV2', 500, BillStatus.part), ('INV3', 3000, BillStatus.unpaid)]);

    // Ticked: only the newest bill; the extra stays on account.
    await dues.recordPayment(
      supplierId: sid,
      date: today,
      payment: const PaymentInput(amount: Paise.rupees(3200), mode: 'Cheque', reference: '000123'),
      pickedDebitIds: {open.last.ledgerId},
      at: t0,
    );
    open = await dues.openBills(sid);
    expect(open.map((b) => b.reference), ['INV2']);
    final d = await of(sid);
    expect(d.outstanding, const Paise.rupees(500));
    expect(d.advance, const Paise.rupees(200));
    expect(d.balance, const Paise.rupees(300));

    // The advance goes to the next bill… after the oldest open one.
    await bill(1000, date: '2026-11-05');
    final after = await of(sid);
    expect(after.advance, Paise.zero);
    expect(after.balance, const Paise.rupees(1300));
    expect((await dues.openBills(sid)).first.outstanding, const Paise.rupees(300));
  });

  test('overpayment leaves an advance the next bill absorbs', () async {
    final (_, sid) = await bill(1000);
    await dues.recordPayment(supplierId: sid, date: today, payment: const PaymentInput(amount: Paise.rupees(1500), mode: 'NEFT'), at: t0);
    expect((await of(sid)).balance, const Paise.rupees(-500));
    await bill(800);
    final d = await of(sid);
    expect(d.balance, const Paise.rupees(300));
    expect(d.advance, Paise.zero);
  });

  test('return to stockist takes stock out and credits the ledger; too much is refused', () async {
    final (_, sid) = await bill(3000);
    final bid = (await db.catalogDao.batchesOf(pid)).single.id;
    final before = await qtyOf(db, bid);
    final id = await dues.recordReturn(
      supplierId: sid,
      date: today,
      amount: const Paise.rupees(300),
      reference: 'CN-11',
      lines: [ReturnLineInput(productId: pid, batchId: bid, qty: 2)],
      at: t0,
    );
    expect(await qtyOf(db, bid), before - 2);
    final mv = (await db.catalogDao.movementsOf(bid)).last;
    expect((mv.reason, mv.delta, mv.refType, mv.refId), ('supplier_return', -2, 'supplier_ledger', id));
    expect((await dues.returnLinesOf(id)).single.batchNo, 'PCM2611');
    expect((await of(sid)).balance, const Paise.rupees(2700));

    await expectLater(
      dues.recordReturn(
        supplierId: sid,
        date: today,
        amount: const Paise.rupees(100),
        reference: 'CN-12',
        lines: [ReturnLineInput(productId: pid, batchId: bid, qty: 9999)],
        at: t0,
      ),
      throwsA(isA<PurchaseException>()),
    );
    expect(await qtyOf(db, bid), before - 2);
    expect(await countOf(db, 'supplier_ledger'), 2);
  });

  test('credit note, void a payment, opening balance once', () async {
    final (_, sid) = await bill(1000);
    await dues.recordCreditNote(supplierId: sid, date: today, amount: const Paise.rupees(100), reference: 'CN-1', at: t0);
    final pay = await dues.recordPayment(supplierId: sid, date: today, payment: const PaymentInput(amount: Paise.rupees(900), mode: 'Cash'), at: t0);
    expect((await of(sid)).balance, Paise.zero);

    await expectLater(dues.voidEntry(pay, reason: ' ', at: t0), throwsA(isA<PurchaseException>()));
    await dues.voidEntry(pay, reason: 'Entered twice', at: t0);
    expect((await of(sid)).outstanding, const Paise.rupees(900));
    await expectLater(dues.voidEntry(pay, reason: 'again', at: t0), throwsA(isA<PurchaseException>()));
    final billId = (await dues.openBills(sid)).single.ledgerId;
    await expectLater(dues.voidEntry(billId, reason: 'no', at: t0), throwsA(isA<PurchaseException>()));

    await dues.setOpeningBalance(supplierId: sid, date: '2026-04-01', amount: const Paise.rupees(5000), at: t0);
    await expectLater(
      dues.setOpeningBalance(supplierId: sid, date: '2026-04-01', amount: const Paise.rupees(1), at: t0),
      throwsA(isA<PurchaseException>()),
    );
    final d = await of(sid);
    expect(d.hasOpening, isTrue);
    expect(d.balance, const Paise.rupees(5900));
    expect(d.overdue, const Paise.rupees(5900)); // opening is due at once; the Oct bill is past 31 Oct
  });

  test('statement running balance ends at the stockist balance; keyset pages', () async {
    final (_, sid) = await bill(1000, date: '2026-09-01');
    await bill(2000, date: '2026-09-10');
    final p = await dues.recordPayment(supplierId: sid, date: '2026-09-20', payment: const PaymentInput(amount: Paise.rupees(1200), mode: 'UPI'), at: t0);
    await dues.recordCreditNote(supplierId: sid, date: '2026-09-25', amount: const Paise.rupees(50), reference: 'CN', at: t0);
    await dues.voidEntry(p, reason: 'bounced', at: t0);

    final first = await dues.statement(sid, limit: 2);
    expect(first.hasMore, isTrue);
    final rest = await dues.statement(sid, after: StatementCursor(first.rows.last.date, first.rows.last.id), limit: 10);
    final rows = [...first.rows, ...rest.rows];
    expect(rows.map((r) => (r.kind, r.balance.value ~/ 100, r.active)), [
      (LedgerKind.bill, 1000, true),
      (LedgerKind.bill, 3000, true),
      (LedgerKind.payment, 3000, false),
      (LedgerKind.creditNote, 2950, true),
    ]);
    expect(rows.last.balance, (await of(sid)).balance);
  });

  test('dues page sorts most overdue first; totals; supplier terms', () async {
    final (_, a) = await bill(1000, supplier: 'A Pharma', date: '2026-11-01');
    final (_, b) = await bill(500, supplier: 'B Pharma', date: '2026-09-01');
    await dues.updateSupplier(a, creditDays: 7, phone: '98620 00000', gstin: '15abcde1234f1z5');
    final page = await dues.duesPage(today: today);
    expect(page.rows.map((r) => r.name), ['B Pharma', 'A Pharma']);
    expect(page.rows.first.overdue, const Paise.rupees(500));
    expect((await dues.duesPage(today: today, search: 'a ph')).rows.single.supplierId, a);
    final (t, top) = await dues.totals(today: today);
    expect(t.owed, const Paise.rupees(1500));
    expect(t.overdue, const Paise.rupees(500));
    expect(t.overdueStockists, 1);
    expect(top.first.supplierId, b);
    final sa = await of(a);
    expect((sa.creditDays, sa.gstin), (7, '15ABCDE1234F1Z5'));
    await expectLater(dues.updateSupplier(a, creditDays: 400), throwsA(isA<PurchaseException>()));
    // The next bill from A uses 7 days.
    final (r, _) = await bill(100, supplier: 'A Pharma', date: '2026-11-09');
    expect(r.dueDate, '2026-11-16');
  });

  test('payment validation', () async {
    final (_, sid) = await bill(100);
    await expectLater(
      dues.recordPayment(supplierId: sid, date: today, payment: const PaymentInput(amount: Paise.zero, mode: 'Cash'), at: t0),
      throwsA(isA<PurchaseException>()),
    );
    await expectLater(
      dues.recordPayment(supplierId: sid, date: today, payment: const PaymentInput(amount: Paise(100), mode: 'Barter'), at: t0),
      throwsA(isA<PurchaseException>()),
    );
    await expectLater(
      dues.recordPayment(supplierId: sid, date: today, payment: const PaymentInput(amount: Paise(100), mode: 'Cash'), pickedDebitIds: {999}, at: t0),
      throwsA(isA<PurchaseException>()),
    );
    expect(await countOf(db, 'supplier_ledger'), 1);
  });
}
