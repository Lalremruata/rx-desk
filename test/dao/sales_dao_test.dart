import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/fy/fy.dart';
import 'package:rx_desk/core/money/gst.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';

import '../helpers/test_db.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = memoryDb());
  tearDown(() => db.close());

  SaveBillRequest req(List<BillLineRequest> lines, {String? doctor, int disc = 0, String pay = 'UPI'}) =>
      SaveBillRequest(lines: lines, customerName: 'Esther', customerPhone: '9800000001', doctorName: doctor, discount: PercentDiscount(disc), paymentMode: pay);

  group('saveBill — one transaction (CLAUDE.md rule 3)', () {
    test('writes invoice, snapshot items, stock, movements, summary and sequence', () async {
      final (p1, b1) = await addMed(db);
      final (p2, b2) = await addMed(db, name: 'Amoxicillin 500 mg Capsule', salt: 'Amoxicillin 500 mg', schedule: 'H', mrp: 9850, batch: 'AMX0942', qty: 18, category: 'Capsule');

      final saved = await db.salesDao.saveBill(
        req([
          BillLineRequest(productId: p1, batchId: b1, qty: 2),
          BillLineRequest(productId: p2, batchId: b2, qty: 1),
        ], doctor: 'Dr. J. Lalrinsanga', disc: 5),
        rules: const BillRules(),
        at: t0,
      );

      expect(saved.number, 'INV/26-27/00001');
      final inv = (await db.salesDao.invoiceWithItems(saved.invoiceId))!;
      expect(inv.invoice.fy, '26-27');
      expect(inv.invoice.saleDate, '2026-11-09');
      expect(inv.invoice.status, 'paid');
      expect(inv.invoice.customerPhone, '9800000001');
      expect(inv.invoice.customerId, isNotNull);
      expect(inv.items, hasLength(2));
      // Snapshots.
      final amx = inv.items[1];
      expect(amx.productName, 'Amoxicillin 500 mg Capsule');
      expect(amx.salt, 'Amoxicillin 500 mg');
      expect(amx.manufacturer, 'Northline Pharma');
      expect(amx.schedule, 'H');
      expect(amx.batchNo, 'AMX0942');
      expect(amx.expiry, '2027-08');
      expect(amx.mrpPaise, 9850);
      expect(amx.gstRate, 12);
      expect(amx.doctorName, 'Dr. J. Lalrinsanga');
      // Totals = sums of lines.
      final net = inv.items.fold<int>(0, (a, i) => a + i.netPaise);
      final tax = inv.items.fold<int>(0, (a, i) => a + i.taxPaise);
      expect(inv.invoice.cgstPaise + inv.invoice.sgstPaise, tax);
      expect(inv.invoice.totalPaise - inv.invoice.roundOffPaise, net);
      expect(inv.invoice.totalPaise % 100, 0); // round-off on by default
      expect(saved.totals.total.value, inv.invoice.totalPaise);

      // Stock + movements.
      expect(await qtyOf(db, b1), 98);
      expect(await qtyOf(db, b2), 17);
      final mv = await db.catalogDao.movementsOf(b1);
      expect(mv.map((m) => (m.reason, m.delta)), [('opening', 100), ('sale', -2)]);
      expect(mv.last.refId, saved.invoiceId);

      // Summary.
      final sum = await db.select(db.dailySalesSummary).get();
      expect(sum, hasLength(2));
      final s1 = sum.firstWhere((s) => s.productId == p1);
      expect((s1.saleDate, s1.units, s1.bills), ('2026-11-09', 2, 1));
      expect(sum.fold<int>(0, (a, s) => a + s.netPaise), net);

      // Sequence + last sold.
      final seq = await db.select(db.invoiceSeq).getSingle();
      expect((seq.fy, seq.lastSeq), ('26-27', 1));
      final prod = await (db.select(db.products)..where((p) => p.id.equals(p1))).getSingle();
      expect(prod.lastSoldAt, t0.toUtc().millisecondsSinceEpoch);
    });

    test('a failing bill writes nothing (all or nothing)', () async {
      final (p1, b1) = await addMed(db, qty: 3);
      final before = (await countOf(db, 'stock_movements'), await countOf(db, 'invoices'));
      await expectLater(
        db.salesDao.saveBill(req([BillLineRequest(productId: p1, batchId: b1, qty: 5)]), rules: const BillRules(), at: t0),
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.insufficientStock)),
      );
      expect(await qtyOf(db, b1), 3);
      expect((await countOf(db, 'stock_movements'), await countOf(db, 'invoices')), before);
      expect(await countOf(db, 'invoice_seq'), 0);
      expect(await countOf(db, 'daily_sales_summary'), 0);
    });

    test('negative stock only when allowed', () async {
      final (p1, b1) = await addMed(db, qty: 1);
      await db.salesDao.saveBill(
        req([BillLineRequest(productId: p1, batchId: b1, qty: 3)]),
        rules: const BillRules(allowNegativeStock: true),
        at: t0,
      );
      expect(await qtyOf(db, b1), -2);
    });

    test('expired batch is rejected even with negative stock allowed', () async {
      final (p1, b1) = await addMed(db, expiry: '2026-10');
      await expectLater(
        db.salesDao.saveBill(req([BillLineRequest(productId: p1, batchId: b1, qty: 1)]), rules: const BillRules(allowNegativeStock: true), at: t0),
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.expiredBatch)),
      );
    });

    test('Rx item without doctor is blocked', () async {
      final (p1, b1) = await addMed(db, schedule: 'H1');
      await expectLater(
        db.salesDao.saveBill(req([BillLineRequest(productId: p1, batchId: b1, qty: 1)]), rules: const BillRules(), at: t0),
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.doctorRequired)),
      );
      expect(await countOf(db, 'invoices'), 0);
    });
  });

  group('invoice numbering (SPEC §4.2, rule 7)', () {
    test('gapless; restarts on 1 April when FY is in the number', () async {
      final (p1, b1) = await addMed(db, expiry: '2028-01');
      Future<String> sell(DateTime at, {BillRules rules = const BillRules()}) async =>
          (await db.salesDao.saveBill(req([BillLineRequest(productId: p1, batchId: b1, qty: 1)]), rules: rules, at: at)).number;

      expect(await sell(DateTime(2027, 3, 31, 22)), 'INV/26-27/00001');
      expect(await sell(DateTime(2027, 3, 31, 23, 59)), 'INV/26-27/00002');
      expect(await sell(DateTime(2027, 4, 1, 0, 5)), 'INV/27-28/00001');
      expect(await sell(DateTime(2027, 4, 1, 9)), 'INV/27-28/00002');
      // A failed save doesn't consume a number.
      await expectLater(
        db.salesDao.saveBill(req([BillLineRequest(productId: p1, batchId: b1, qty: 10000)]), rules: const BillRules(), at: DateTime(2027, 4, 1, 10)),
        throwsA(isA<BillException>()),
      );
      expect(await sell(DateTime(2027, 4, 1, 11)), 'INV/27-28/00003');
    });

    test('without FY in the number the sequence continues across years', () async {
      final (p1, b1) = await addMed(db, expiry: '2028-01');
      const rules = BillRules(numbering: InvoiceNumberFormat(fyInNumber: false, separator: InvoiceSeparator.none));
      Future<String> sell(DateTime at) async =>
          (await db.salesDao.saveBill(req([BillLineRequest(productId: p1, batchId: b1, qty: 1)]), rules: rules, at: at)).number;
      expect(await sell(DateTime(2027, 3, 31)), 'INV00001');
      expect(await sell(DateTime(2027, 4, 1, 9)), 'INV00002');
    });

    test('format change only affects new bills; collisions skip forward', () async {
      final (p1, b1) = await addMed(db);
      final a = await db.salesDao.saveBill(req([BillLineRequest(productId: p1, batchId: b1, qty: 1)]), rules: const BillRules(), at: t0);
      await db.salesDao.setSequence('26-27', 0); // simulate a reset
      final b = await db.salesDao.saveBill(req([BillLineRequest(productId: p1, batchId: b1, qty: 1)]), rules: const BillRules(), at: t0);
      expect(a.number, 'INV/26-27/00001');
      expect(b.number, 'INV/26-27/00002');
      expect(await db.salesDao.peekNextNumber(const InvoiceNumberFormat(), t0), 'INV/26-27/00003');
    });
  });

  test('cancel restores stock to the same batches and reverses the summary (rule 6)', () async {
    final (p1, b1) = await addMed(db);
    final saved = await db.salesDao.saveBill(req([BillLineRequest(productId: p1, batchId: b1, qty: 4)]), rules: const BillRules(), at: t0);
    await db.salesDao.cancelInvoice(saved.invoiceId, at: t0.add(const Duration(hours: 1)), reason: 'wrong item');
    expect(await qtyOf(db, b1), 100);
    final inv = (await db.salesDao.invoiceWithItems(saved.invoiceId))!.invoice;
    expect(inv.status, 'cancelled');
    expect(inv.note, contains('wrong item'));
    final mv = await db.catalogDao.movementsOf(b1);
    expect(mv.last.reason, 'cancel');
    expect(mv.last.delta, 4);
    final s = await db.select(db.dailySalesSummary).getSingle();
    expect((s.units, s.bills, s.netPaise, s.taxPaise), (0, 0, 0, 0));
    await expectLater(db.salesDao.cancelInvoice(saved.invoiceId, at: t0), throwsA(isA<BillException>()));
    // Invoice rows are never deleted.
    expect(await countOf(db, 'invoices'), 1);
  });

  test('keyset invoice pages + summary', () async {
    final (p1, b1) = await addMed(db, qty: 1000);
    for (var i = 0; i < 7; i++) {
      await db.salesDao.saveBill(
        req([BillLineRequest(productId: p1, batchId: b1, qty: 1)], pay: i.isEven ? 'Cash' : 'UPI'),
        rules: const BillRules(roundOff: false),
        at: t0.add(Duration(minutes: i)),
      );
    }
    const f = InvoiceListFilter(from: '2026-11-01', to: '2026-11-30');
    final p1page = await db.salesDao.invoicePage(f, limit: 3);
    expect(p1page.rows.map((r) => r.seq), [7, 6, 5]);
    expect(p1page.hasOlder, isTrue);
    expect(p1page.hasNewer, isFalse);
    final last = p1page.rows.last;
    final p2page = await db.salesDao.invoicePage(f, limit: 3, olderThan: InvoiceCursor(last.saleDate, last.id));
    expect(p2page.rows.map((r) => r.seq), [4, 3, 2]);
    expect(p2page.hasNewer, isTrue);
    final back = await db.salesDao.invoicePage(f, limit: 3, newerThan: InvoiceCursor(p2page.rows.first.saleDate, p2page.rows.first.id));
    expect(back.rows.map((r) => r.seq), [7, 6, 5]);
    final cash = await db.salesDao.invoiceSummary(const InvoiceListFilter(from: '2026-11-01', to: '2026-11-30', paymentMode: 'Cash'));
    expect(cash.count, 4);
    expect(cash.total, const Paise(4 * 3090));
    final byNo = await db.salesDao.invoiceSummary(const InvoiceListFilter(from: '2026-11-01', to: '2026-11-30', search: '00003'));
    expect(byNo.count, 1);
  });

  test('top sellers come from the daily summary', () async {
    final (p1, b1) = await addMed(db);
    final (p2, b2) = await addMed(db, name: 'Cetirizine 10 mg Tablet', salt: 'Cetirizine 10 mg', batch: 'CTZ1', mrp: 2200);
    await db.salesDao.saveBill(req([BillLineRequest(productId: p1, batchId: b1, qty: 1), BillLineRequest(productId: p2, batchId: b2, qty: 5)]), rules: const BillRules(), at: t0);
    final top = await db.salesDao.topSellers(now: t0);
    expect(top.map((t) => t.name), ['Cetirizine 10 mg Tablet', 'Paracetamol 650 mg Tablet']);
  });

  test('FK + unique constraints are on', () async {
    await expectLater(
      db.customStatement('INSERT INTO batches(product_id, batch_no, expiry, qty, created_at) VALUES (999, "X", "2027-01", 1, 0)'),
      throwsA(isA<Exception>()),
    );
    final (p1, _) = await addMed(db);
    await expectLater(
      db.into(db.batches).insert(BatchesCompanion.insert(productId: p1, batchNo: 'PCM2611', expiry: '2027-01', qty: 1, createdAt: 0)),
      throwsA(isA<Exception>()),
    );
  });

  group('flat ₹ discount (SPEC §4.6)', () {
    test('saves discount_flat_paise; line discounts sum to it; preview = saved', () async {
      final (p1, b1) = await addMed(db, qty: 50); // ₹30.90, 12 %
      final (p2, b2) = await addMed(db, name: 'Cetirizine 10 mg Tablet', salt: 'Cetirizine 10 mg', mrp: 2150, gst: 5, batch: 'CTZ01', qty: 40);
      final lines = [BillLineRequest(productId: p1, batchId: b1, qty: 3), BillLineRequest(productId: p2, batchId: b2, qty: 2)];
      final saved = await db.salesDao.saveBill(
        SaveBillRequest(lines: lines, discount: const FlatDiscount(Paise(1000))),
        rules: const BillRules(),
        at: t0,
      );
      final doc = (await db.salesDao.invoiceWithItems(saved.invoiceId))!;
      expect(doc.invoice.discountFlatPaise, 1000);
      expect(doc.invoice.discountPct, 0);
      expect(doc.invoice.discountPaise, 1000);
      expect(doc.items.map((i) => i.discountPaise), [683, 317]); // 13570 split 9270 : 4300
      expect(doc.items.fold<int>(0, (a, i) => a + i.discountPaise), 1000);
      expect(invoiceDiscount(doc.invoice), const FlatDiscount(Paise(1000)));

      final preview = discountedLines(
        [(mrp: const Paise(3090), qty: 3, gstRate: 12, packSize: 1), (mrp: const Paise(2150), qty: 2, gstRate: 5, packSize: 1)],
        const FlatDiscount(Paise(1000)),
      );
      expect(doc.items.map((i) => (i.netPaise, i.taxablePaise, i.taxPaise)), [for (final a in preview) (a.net.value, a.taxable.value, a.tax.value)]);
      expect(doc.invoice.cgstPaise + doc.invoice.sgstPaise, doc.items.fold<int>(0, (a, i) => a + i.taxPaise));
      expect(saved.totals.total.value, 12600); // 13570 − 1000 = 12570 → ₹126
    });

    test('a percent bill keeps discount_flat_paise null', () async {
      final (p, b) = await addMed(db);
      final saved = await db.salesDao.saveBill(req([BillLineRequest(productId: p, batchId: b, qty: 1)], disc: 5), rules: const BillRules(), at: t0);
      final inv = (await db.salesDao.invoiceWithItems(saved.invoiceId))!.invoice;
      expect((inv.discountPct, inv.discountFlatPaise), (5, null));
      expect(invoiceDiscount(inv), const PercentDiscount(5));
    });

    test('over the cap or over 5 % without permission is refused; nothing is written', () async {
      final (p, b) = await addMed(db); // ₹30.90 × 2 = ₹61.80; 15 % = ₹9.27
      final lines = [BillLineRequest(productId: p, batchId: b, qty: 2)];
      Future<SavedBill> sell(int flat, BillRules rules) =>
          db.salesDao.saveBill(SaveBillRequest(lines: lines, discount: FlatDiscount(Paise(flat))), rules: rules, at: t0);
      await expectLater(sell(928, const BillRules()), throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.discountTooHigh)));
      await expectLater(
        sell(310, const BillRules(canGiveHighDiscount: false)), // 5.02 %
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.discountNotPermitted)),
      );
      expect(await countOf(db, 'invoices'), 0);
      expect(await qtyOf(db, b), 100);
      await sell(927, const BillRules());
      expect(await countOf(db, 'invoices'), 1);
    });
  });
}
