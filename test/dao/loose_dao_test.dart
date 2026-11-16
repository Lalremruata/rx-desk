import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/catalog_dao.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/sales/return_rules.dart';

import '../helpers/test_db.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = memoryDb());
  tearDown(() => db.close());

  Future<SavedBill> sell(List<BillLineRequest> lines, {int disc = 0}) => db.salesDao.saveBill(
        SaveBillRequest(lines: lines, discountPct: disc),
        rules: const BillRules(),
        at: t0,
      );

  group('selling loose (SPEC §4.9)', () {
    test('5 tabs of a ₹30.90 strip of 10: pro-rata amount, stock in tabs, pack size snapshot', () async {
      final (p, b) = await addMed(db, packSize: 10); // 10 strips
      final bill = await sell([BillLineRequest(productId: p, batchId: b, qty: 5)]);
      final it = (await db.salesDao.invoiceWithItems(bill.invoiceId))!.items.single;
      expect((it.qty, it.packSize, it.grossPaise), (5, 10, 1545));
      expect(await qtyOf(db, b), 95);
      expect(bill.totals.subtotal, const Paise(1545));
      expect(bill.totals.total, const Paise(1500)); // ₹15.45 → ₹15

      // 2 whole strips cost exactly 2 × MRP.
      final two = await sell([BillLineRequest(productId: p, batchId: b, qty: 20)]);
      expect(two.totals.subtotal, const Paise(6180));
      expect(await qtyOf(db, b), 75);
    });

    test('can’t sell more tabs than the batch holds', () async {
      final (p, b) = await addMed(db, qty: 7, packSize: 10);
      await expectLater(
        sell([BillLineRequest(productId: p, batchId: b, qty: 8)]),
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.insufficientStock)),
      );
    });

    test('returning loose tabs uses the snapshot pack size and reconciles', () async {
      final (p, b) = await addMed(db, mrp: 2200, qty: 150, packSize: 15);
      final bill = await sell([BillLineRequest(productId: p, batchId: b, qty: 7)], disc: 5);
      final o = (await db.salesDao.invoiceWithItems(bill.invoiceId))!.items.single;
      // Change the size afterwards (top up to whole strips first): the return
      // still prices from the 15-per-strip snapshot.
      await db.catalogDao.receiveStock(productId: p, batchNo: 'PCM2611', qty: 7, at: t0);
      await db.catalogDao.setPackSize(p, 10, at: t0);
      expect((await db.catalogDao.stockRow(p, now: t0))!.packSize, 10);
      final a = await db.salesDao.saveCreditNote(
        SaveCreditNoteRequest(invoiceId: bill.invoiceId, lines: [ReturnLineRequest(itemId: o.id, qty: 3)], refundMode: 'Cash'),
        rules: const ReturnRules(),
        at: t0,
      );
      final c = await db.salesDao.saveCreditNote(
        SaveCreditNoteRequest(invoiceId: bill.invoiceId, lines: [ReturnLineRequest(itemId: o.id, qty: 4)], refundMode: 'Cash'),
        rules: const ReturnRules(),
        at: t0,
      );
      final cn = [
        ...(await db.salesDao.invoiceWithItems(a.creditNoteId))!.items,
        ...(await db.salesDao.invoiceWithItems(c.creditNoteId))!.items,
      ];
      expect(cn.map((i) => i.packSize).toSet(), {15});
      expect(cn.fold<int>(0, (s, i) => s + i.netPaise), -o.netPaise);
      expect(cn.first.grossPaise, -proRata(2200, 3, 15));
    });
  });

  group('setPackSize', () {
    test('converts whole strips to tabs with a repack movement and rescales the purchase rate', () async {
      final (p, b) = await addMed(db, qty: 12); // 12 strips, size 1
      await db.catalogDao.receiveStock(productId: p, batchNo: 'NEW1', expiry: '2028-01', qty: 3, at: t0, purchaseRate: const Paise(2500));
      await db.catalogDao.setPackSize(p, 10, at: t0);
      expect(await qtyOf(db, b), 120);
      final bs = await db.catalogDao.batchesOf(p);
      final n = bs.firstWhere((x) => x.batchNo == 'NEW1');
      expect((n.qty, n.purchaseRatePaise), (30, 250));
      final mv = await db.catalogDao.movementsOf(b);
      expect(mv.map((m) => (m.reason, m.delta)), [('opening', 12), ('repack', 108)]);
      expect(mv.fold<int>(0, (s, m) => s + m.delta), 120);

      final row = (await db.catalogDao.stockRow(p, now: t0))!;
      expect((row.packSize, row.saleable, row.saleablePacks), (10, 150, 15));

      // Size 10 → 15 keeps whole strips (12 strips = 180 tabs).
      await db.catalogDao.setPackSize(p, 15, at: t0);
      expect(await qtyOf(db, b), 180);
    });

    test('refuses while a batch holds loose tabs', () async {
      final (p, b) = await addMed(db, packSize: 10);
      await sell([BillLineRequest(productId: p, batchId: b, qty: 3)]);
      await expectLater(db.catalogDao.setPackSize(p, 15, at: t0), throwsA(isA<CatalogException>()));
      expect(await qtyOf(db, b), 97);
      await expectLater(db.catalogDao.setPackSize(p, 0, at: t0), throwsA(isA<CatalogException>()));
    });
  });

  test('low stock, reorder and stock value use packs', () async {
    // Reorder level 20 strips; 150 tabs = 15 strips → low.
    final (p, _) = await addMed(db, qty: 150, packSize: 10);
    final (q, _) = await addMed(db, name: 'Cetirizine', batch: 'C1', qty: 250, packSize: 10); // 25 strips → not low
    final row = (await db.catalogDao.stockRow(p, now: t0))!;
    expect(row.isLow, isTrue);
    expect((await db.catalogDao.stockRow(q, now: t0))!.isLow, isFalse);
    final counts = await db.catalogDao.inventoryCounts(now: t0);
    expect(counts.low, 1);
    expect((await db.catalogDao.reorderSoon(now: t0)).map((r) => r.id), [p]);
    // 400 tabs × ₹30.90 per 10.
    expect(await db.catalogDao.stockValue(now: t0), const Paise(3090 * 40));
  });
}

int proRata(int mrp, int qty, int size) => mrp * qty ~/ size;
