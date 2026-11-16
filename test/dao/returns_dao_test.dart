import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/db/report_models.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/sales/return_rules.dart';

import '../helpers/test_db.dart';

const ReturnRules cnRules = ReturnRules();

void main() {
  late AppDatabase db;
  setUp(() => db = memoryDb());
  tearDown(() => db.close());

  final tRet = t0.add(const Duration(days: 2)); // 2026-11-11

  Future<SavedBill> sell(List<BillLineRequest> lines, {int disc = 0, String? doctor, DateTime? at}) => db.salesDao.saveBill(
        SaveBillRequest(lines: lines, customerName: 'Esther', customerPhone: '9800000001', discountPct: disc, doctorName: doctor),
        rules: const BillRules(),
        at: at ?? t0,
      );

  Future<List<InvoiceItem>> itemsOf(int invoiceId) async => (await db.salesDao.invoiceWithItems(invoiceId))!.items;

  Future<SavedCreditNote> giveBack(
    int invoiceId,
    List<ReturnLineRequest> lines, {
    ReturnRules rules = cnRules,
    DateTime? at,
    String mode = 'Cash',
  }) =>
      db.salesDao.saveCreditNote(
        SaveCreditNoteRequest(invoiceId: invoiceId, lines: lines, refundMode: mode, reason: 'Doctor changed the medicine'),
        rules: rules,
        at: at ?? tRet,
      );

  group('saveCreditNote — one transaction', () {
    test('partial return: credit note, restock vs write-off, summary on return day, status', () async {
      final (p1, b1) = await addMed(db);
      final (p2, b2) = await addMed(db, name: 'Cetirizine 10 mg Tablet', salt: 'Cetirizine 10 mg', mrp: 2150, batch: 'CTZ01', qty: 40);
      final bill = await sell([
        BillLineRequest(productId: p1, batchId: b1, qty: 3),
        BillLineRequest(productId: p2, batchId: b2, qty: 2),
      ], disc: 5);
      final orig = await itemsOf(bill.invoiceId);

      final cn = await giveBack(bill.invoiceId, [
        ReturnLineRequest(itemId: orig[0].id, qty: 1),
        ReturnLineRequest(itemId: orig[1].id, qty: 1, restock: false),
      ]);

      expect(cn.number, 'CN/26-27/00001');
      final doc = (await db.salesDao.invoiceWithItems(cn.creditNoteId))!;
      expect(doc.invoice.docType, 'credit_note');
      expect(doc.invoice.refInvoiceId, bill.invoiceId);
      expect(doc.invoice.saleDate, '2026-11-11');
      expect(doc.invoice.paymentMode, 'Cash');
      expect(doc.invoice.customerName, 'Esther');
      expect(doc.invoice.discountPct, 5);
      expect(doc.invoice.note, 'Doctor changed the medicine');
      expect(doc.invoice.totalPaise, -cn.totals.total.value);
      expect(doc.invoice.totalPaise, lessThan(0));
      expect(doc.invoice.cgstPaise + doc.invoice.sgstPaise, doc.items.fold<int>(0, (a, i) => a + i.taxPaise));
      expect(doc.invoice.totalPaise - doc.invoice.roundOffPaise, doc.items.fold<int>(0, (a, i) => a + i.netPaise));

      // Negative lines carry the original snapshot.
      expect(doc.items.map((i) => (i.qty, i.refItemId, i.restocked)), [(-1, orig[0].id, true), (-1, orig[1].id, false)]);
      expect(doc.items[0].batchNo, 'PCM2611');
      expect(doc.items[0].mrpPaise, 3090);
      final one = computeLineFor(3090, 1, 5, 12);
      expect(doc.items[0].netPaise, -one);

      // Stock: restocked line back in the same batch; damaged one written off.
      expect(await qtyOf(db, b1), 98);
      expect(await qtyOf(db, b2), 38);
      final mv = await db.catalogDao.movementsOf(b2);
      expect(mv.map((m) => (m.reason, m.delta)), [('opening', 40), ('sale', -2), ('return', 1), ('write_off', -1)]);
      expect(mv.last.refId, cn.creditNoteId);

      // Daily summary: reduced on the return day, bills untouched.
      final sum = await (db.select(db.dailySalesSummary)..where((s) => s.saleDate.equals('2026-11-11'))).get();
      expect(sum.fold<int>(0, (a, s) => a + s.units), -2);
      expect(sum.fold<int>(0, (a, s) => a + s.bills), 0);
      expect(sum.fold<int>(0, (a, s) => a + s.netPaise), doc.items.fold<int>(0, (a, i) => a + i.netPaise));

      final after = (await db.salesDao.invoiceWithItems(bill.invoiceId))!.invoice;
      expect(after.status, 'part_returned');
      expect(after.totalPaise, bill.totals.total.value); // original never changed
      expect((await db.salesDao.creditNotesFor(bill.invoiceId)).single.id, cn.creditNoteId);

      // Invoice numbering is untouched by the credit-note series.
      final (p3, b3) = await addMed(db, name: 'ORS', batch: 'ORS1');
      final next = await sell([BillLineRequest(productId: p3, batchId: b3, qty: 1)], at: tRet);
      expect(next.number, 'INV/26-27/00002');
    });

    test('returning a line bit by bit reconciles to the paisa; then status is returned', () async {
      final (p1, b1) = await addMed(db, mrp: 3333, gst: 18);
      final bill = await sell([BillLineRequest(productId: p1, batchId: b1, qty: 7)], disc: 15);
      final o = (await itemsOf(bill.invoiceId)).single;

      final a = await giveBack(bill.invoiceId, [ReturnLineRequest(itemId: o.id, qty: 2)]);
      expect((await db.salesDao.invoiceWithItems(bill.invoiceId))!.invoice.status, 'part_returned');
      final b = await giveBack(bill.invoiceId, [ReturnLineRequest(itemId: o.id, qty: 3)]);
      final c = await giveBack(bill.invoiceId, [ReturnLineRequest(itemId: o.id, qty: 2)]);
      expect([a.number, b.number, c.number], ['CN/26-27/00001', 'CN/26-27/00002', 'CN/26-27/00003']);

      final cnLines = [
        for (final id in [a.creditNoteId, b.creditNoteId, c.creditNoteId]) ...await itemsOf(id),
      ];
      int sum(int Function(InvoiceItem) f) => cnLines.fold(0, (s, i) => s + f(i));
      expect(sum((i) => i.qty), -o.qty);
      expect(sum((i) => i.grossPaise), -o.grossPaise);
      expect(sum((i) => i.discountPaise), -o.discountPaise);
      expect(sum((i) => i.taxablePaise), -o.taxablePaise);
      expect(sum((i) => i.taxPaise), -o.taxPaise);
      expect(sum((i) => i.netPaise), -o.netPaise);
      expect((await db.salesDao.invoiceWithItems(bill.invoiceId))!.invoice.status, 'returned');
      expect(await qtyOf(db, b1), 100);

      await expectLater(
        giveBack(bill.invoiceId, [ReturnLineRequest(itemId: o.id, qty: 1)]),
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.notReturnable)),
      );
    });

    test('a failed return writes nothing', () async {
      final (p1, b1) = await addMed(db);
      final bill = await sell([BillLineRequest(productId: p1, batchId: b1, qty: 2)]);
      final o = (await itemsOf(bill.invoiceId)).single;
      final before = await countOf(db, 'invoices');

      await expectLater(
        giveBack(bill.invoiceId, [ReturnLineRequest(itemId: o.id, qty: 3)]),
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.invalidQty)),
      );
      expect(await countOf(db, 'invoices'), before);
      expect(await qtyOf(db, b1), 98);
      expect(await db.customSelect("SELECT * FROM invoice_seq WHERE fy LIKE 'CN:%'").get(), isEmpty);
      expect((await db.salesDao.invoiceWithItems(bill.invoiceId))!.invoice.status, 'paid');
    });

    test('Schedule H / H1 lines can’t be returned', () async {
      final (p1, b1) = await addMed(db, name: 'Amoxicillin 500 mg', schedule: 'H', batch: 'AMX1');
      final bill = await sell([BillLineRequest(productId: p1, batchId: b1, qty: 1)], doctor: 'Dr. Lal');
      final o = (await itemsOf(bill.invoiceId)).single;
      await expectLater(
        giveBack(bill.invoiceId, [ReturnLineRequest(itemId: o.id, qty: 1)]),
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.rxReturn)),
      );
    });

    test('return window: blocked for staff, Owner can override; permission needed', () async {
      final (p1, b1) = await addMed(db);
      final bill = await sell([BillLineRequest(productId: p1, batchId: b1, qty: 2)]);
      final o = (await itemsOf(bill.invoiceId)).single;
      final late = t0.add(const Duration(days: 31));
      const staff = ReturnRules(canOverrideWindow: false);

      await expectLater(
        giveBack(bill.invoiceId, [ReturnLineRequest(itemId: o.id, qty: 1)], rules: staff, at: late),
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.returnWindow)),
      );
      // Day 30 is still inside the window.
      await giveBack(bill.invoiceId, [ReturnLineRequest(itemId: o.id, qty: 1)], rules: staff, at: t0.add(const Duration(days: 30)));
      // Owner overrides.
      await giveBack(bill.invoiceId, [ReturnLineRequest(itemId: o.id, qty: 1)], at: late);

      final (p2, b2) = await addMed(db, name: 'ORS', batch: 'ORS1');
      final bill2 = await sell([BillLineRequest(productId: p2, batchId: b2, qty: 1)]);
      final o2 = (await itemsOf(bill2.invoiceId)).single;
      await expectLater(
        giveBack(bill2.invoiceId, [ReturnLineRequest(itemId: o2.id, qty: 1)], rules: const ReturnRules(canAcceptReturns: false)),
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.returnNotPermitted)),
      );
    });

    test('bills with returns and credit notes can’t be cancelled; cancelled bills can’t be returned', () async {
      final (p1, b1) = await addMed(db);
      final bill = await sell([BillLineRequest(productId: p1, batchId: b1, qty: 2)]);
      final o = (await itemsOf(bill.invoiceId)).single;
      final cn = await giveBack(bill.invoiceId, [ReturnLineRequest(itemId: o.id, qty: 1)]);

      await expectLater(db.salesDao.cancelInvoice(bill.invoiceId, at: tRet), throwsA(isA<BillException>()));
      await expectLater(db.salesDao.cancelInvoice(cn.creditNoteId, at: tRet), throwsA(isA<BillException>()));
      await expectLater(
        giveBack(cn.creditNoteId, [ReturnLineRequest(itemId: (await itemsOf(cn.creditNoteId)).single.id, qty: 1)]),
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.notReturnable)),
      );

      final bill2 = await sell([BillLineRequest(productId: p1, batchId: b1, qty: 1)]);
      await db.salesDao.cancelInvoice(bill2.invoiceId, at: tRet);
      await expectLater(
        giveBack(bill2.invoiceId, [ReturnLineRequest(itemId: (await itemsOf(bill2.invoiceId)).single.id, qty: 1)]),
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.notReturnable)),
      );
    });

    test('credit-note numbers restart each financial year', () async {
      final (p1, b1) = await addMed(db);
      final bill = await sell([BillLineRequest(productId: p1, batchId: b1, qty: 3)]);
      final o = (await itemsOf(bill.invoiceId)).single;
      final a = await giveBack(bill.invoiceId, [ReturnLineRequest(itemId: o.id, qty: 1)], rules: const ReturnRules(windowDays: 0));
      final b = await giveBack(
        bill.invoiceId,
        [ReturnLineRequest(itemId: o.id, qty: 1)],
        rules: const ReturnRules(windowDays: 0),
        at: DateTime(2027, 4, 2, 10),
      );
      expect(a.number, 'CN/26-27/00001');
      expect(b.number, 'CN/27-28/00001');
    });
  });

  group('reports net out returns', () {
    test('register totals, invoice list total and day totals', () async {
      final (p1, b1) = await addMed(db);
      final bill = await sell([BillLineRequest(productId: p1, batchId: b1, qty: 4)], at: tRet);
      final o = (await itemsOf(bill.invoiceId)).single;
      final cn = await giveBack(bill.invoiceId, [ReturnLineRequest(itemId: o.id, qty: 1)]);

      final t = await db.reportsDao.registerTotals(const RegisterFilter(from: '2026-11-01', to: '2026-11-30'));
      expect(t.bills, 1);
      expect(t.units, 3);
      expect(t.lines, 2);
      expect(t.net.value, o.netPaise - cn.totals.net.value);

      final day = await db.reportsDao.dayTotals('2026-11-11');
      expect(day.bills, 1);
      expect(day.total.value, bill.totals.total.value - cn.totals.total.value);

      final s = await db.salesDao.invoiceSummary(const InvoiceListFilter(from: '2026-11-01', to: '2026-11-30'));
      expect(s.total.value, bill.totals.total.value - cn.totals.total.value);
    });
  });
}

/// Net paise of [qty] units at [mrp] with [disc] % off.
int computeLineFor(int mrp, int qty, int disc, int gst) {
  final gross = mrp * qty;
  final d = (2 * gross * disc + 100) ~/ 200;
  return Paise(gross - d).value;
}
