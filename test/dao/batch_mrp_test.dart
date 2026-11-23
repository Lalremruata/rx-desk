import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/catalog_dao.dart';
import 'package:rx_desk/core/db/daos/purchases_dao.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/db/models.dart';
import 'package:rx_desk/core/inventory/stock_adjust.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/purchases/purchase_rules.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';

import '../helpers/test_db.dart';

/// Batch-wise MRP and purchase rate details (SPEC §4.5, §4.7).
void main() {
  late AppDatabase db;
  setUp(() => db = memoryDb());
  tearDown(() => db.close());

  Future<StockBatch> batch(int id) => (db.select(db.batches)..where((b) => b.id.equals(id))).getSingle();
  Future<StockRow> row(int pid) async => (await db.catalogDao.stockRow(pid, now: t0))!;

  group('batch MRP', () {
    test('opening batch takes the medicine MRP', () async {
      final (_, bid) = await addMed(db);
      expect((await batch(bid)).mrpPaise, 3090);
    });

    test('a new batch at a new MRP: the medicine follows, the old batch keeps its own', () async {
      final (pid, old) = await addMed(db, qty: 10);
      final r = await db.catalogDao.receiveStock(productId: pid, batchNo: 'NEW1', expiry: '2028-06', qty: 20, mrp: const Paise(3360), at: t0);
      expect((await batch(r.batchId)).mrpPaise, 3360);
      expect((await batch(old)).mrpPaise, 3090);
      final p = await row(pid);
      expect(p.mrp, const Paise(3360));
      // FEFO sells the old batch first, at its printed MRP.
      expect((p.saleMrp, p.mrpCount), (const Paise(3090), 2));
    });

    test('a new batch without an MRP takes the medicine MRP; an existing batch must match its own', () async {
      final (pid, bid) = await addMed(db, qty: 10);
      final r = await db.catalogDao.receiveStock(productId: pid, batchNo: 'NEW1', expiry: '2028-06', qty: 5, at: t0);
      expect((await batch(r.batchId)).mrpPaise, 3090);
      await db.catalogDao.receiveStock(productId: pid, batchNo: 'PCM2611', qty: 5, mrp: const Paise(3090), at: t0);
      expect(await qtyOf(db, bid), 15);
      await expectLater(
        db.catalogDao.receiveStock(productId: pid, batchNo: 'PCM2611', qty: 5, mrp: const Paise(3360), at: t0),
        throwsA(isA<CatalogException>().having((e) => e.message, 'message', contains('own batch number'))),
      );
      expect(await qtyOf(db, bid), 15);
    });

    test('edit batch MRP fixes a typo and leaves a movement in the history', () async {
      final (_, bid) = await addMed(db, qty: 10);
      await db.catalogDao.editBatch(bid, mrp: const Paise(3060), at: t0);
      expect((await batch(bid)).mrpPaise, 3060);
      final mv = (await db.catalogDao.movementsOf(bid)).last;
      expect((mv.reason, mv.delta, mv.note), ('mrp', 0, 'MRP ₹30.90 → ₹30.60'));
      expect(await qtyOf(db, bid), 10);
      await expectLater(db.catalogDao.editBatch(bid, mrp: Paise.zero, at: t0), throwsA(isA<CatalogException>()));
    });

    test('edit medicine MRP: reprices batches at the old MRP only when asked', () async {
      final (pid, b1) = await addMed(db, qty: 10);
      final b2 = (await db.catalogDao.receiveStock(productId: pid, batchNo: 'B2', expiry: '2028-01', qty: 5, mrp: const Paise(3200), at: t0)).batchId;
      ProductEdit edit(StockRow r, int mrp) => ProductEdit(
            name: r.name,
            maker: r.maker,
            category: r.category,
            gstRate: r.gstRate,
            mrp: Paise(mrp),
            reorderLevel: r.reorderLevel,
          );
      // The medicine is now at 32.00 (newest batch). Without repricing only new batches change.
      await db.catalogDao.updateProduct(pid, edit(await row(pid), 3300), at: t0);
      expect(((await batch(b1)).mrpPaise, (await batch(b2)).mrpPaise), (3090, 3200));
      // With repricing, batches at the old medicine MRP (32.00) follow; 30.90 stays.
      await db.catalogDao.updateProduct(pid, edit(await row(pid), 3400), at: t0, repriceBatches: true);
      expect(((await batch(b1)).mrpPaise, (await batch(b2)).mrpPaise), (3090, 3200));
      await db.catalogDao.updateProduct(pid, edit(await row(pid), 3200), at: t0);
      await db.catalogDao.updateProduct(pid, edit(await row(pid), 3250), at: t0, repriceBatches: true);
      expect((await batch(b2)).mrpPaise, 3250);
    });

    test('a bill sells each batch at its own MRP; stock value uses batch MRPs', () async {
      final (pid, old) = await addMed(db, qty: 2);
      final nb = (await db.catalogDao.receiveStock(productId: pid, batchNo: 'NEW1', expiry: '2028-06', qty: 3, mrp: const Paise(3360), at: t0)).batchId;
      final saved = await db.salesDao.saveBill(
        SaveBillRequest(lines: [
          BillLineRequest(productId: pid, batchId: old, qty: 2, expectedMrp: const Paise(3090)),
          BillLineRequest(productId: pid, batchId: nb, qty: 1, expectedMrp: const Paise(3360)),
        ]),
        rules: const BillRules(),
        at: t0,
      );
      final items = await (db.select(db.invoiceItems)..where((i) => i.invoiceId.equals(saved.invoiceId))).get();
      expect(items.map((i) => (i.batchNo, i.mrpPaise, i.grossPaise)), [('PCM2611', 3090, 6180), ('NEW1', 3360, 3360)]);
      expect(await db.catalogDao.stockValue(now: t0), const Paise(2 * 3360));
    });

    test('a stale batch MRP on the counter is refused per batch', () async {
      final (pid, bid) = await addMed(db, qty: 5);
      await db.catalogDao.editBatch(bid, mrp: const Paise(3060), at: t0);
      await expectLater(
        db.salesDao.saveBill(
          SaveBillRequest(lines: [BillLineRequest(productId: pid, batchId: bid, qty: 1, expectedMrp: const Paise(3090))]),
          rules: const BillRules(),
          at: t0,
        ),
        throwsA(isA<PriceChangedException>().having((e) => e.changes[bid]?.mrp, 'mrp', const Paise(3060))),
      );
    });

    test('a batch with no MRP can’t be billed', () async {
      final (pid, bid) = await addMed(db, qty: 5);
      await db.customStatement('UPDATE batches SET mrp_paise = 0 WHERE id = $bid');
      await expectLater(
        db.salesDao.saveBill(SaveBillRequest(lines: [BillLineRequest(productId: pid, batchId: bid, qty: 1)]), rules: const BillRules(), at: t0),
        throwsA(isA<BillException>().having((e) => e.message, 'message', contains('has no MRP'))),
      );
    });

    test('editing a batch count still works alongside MRP', () async {
      final (_, bid) = await addMed(db, qty: 10);
      await db.catalogDao.editBatch(bid, countedQty: 8, reason: StockAdjustReason.damaged, mrp: const Paise(3000), at: t0);
      final b = await batch(bid);
      expect((b.qty, b.mrpPaise), (8, 3000));
    });
  });

  group('receive with rate details', () {
    Future<SavedReceipt> receive(List<ReceiveLineInput> lines, {String inv = 'INV1'}) => db.purchasesDao.receive(
          ReceiveRequest(supplierName: 'Life Drugs Centre', invoiceNo: inv, receivedDate: '2026-11-09', lines: lines),
          at: t0,
          now: t0,
        );

    test('10 + 1 free, rate, disc, GST: stock includes free, cost per strip includes free, MRP on the new batch', () async {
      final (pid, _) = await addMed(db, qty: 0);
      await receive([
        ReceiveLineInput(
          productId: pid,
          batchNo: 'NEW1',
          expiry: '2028-06',
          qty: 10,
          freeQty: 1,
          unit: 'Strip',
          stockUnits: 11,
          rate: const Paise(2000),
          discBp: 500,
          gstRate: 12,
          amount: const Paise(21280), // 200 − 10 = 190 + 22.80 GST
          mrp: const Paise(3360),
        ),
      ]);
      final b = (await db.catalogDao.batchesOf(pid)).firstWhere((x) => x.batchNo == 'NEW1');
      expect((b.qty, b.mrpPaise, b.purchaseRatePaise), (11, 3360, 1935)); // 212.80 ÷ 11
      final line = await db.select(db.receiptLines).getSingle();
      expect((line.qty, line.freeQty, line.ratePaise, line.discBp, line.gstRate, line.mrpPaise), (10, 1, 2000, 500, 12, 3360));
      expect((await row(pid)).mrp, const Paise(3360));
    });

    test('bad rate details are refused and nothing is saved', () async {
      final (pid, _) = await addMed(db, qty: 0);
      ReceiveLineInput l({int free = 0, int disc = 0, int? gst, Paise? mrp}) => ReceiveLineInput(
            productId: pid,
            batchNo: 'NEW1',
            expiry: '2028-06',
            qty: 1,
            unit: 'Strip',
            stockUnits: 1,
            amount: Paise.zero,
            freeQty: free,
            discBp: disc,
            gstRate: gst,
            mrp: mrp,
          );
      for (final (i, bad) in [l(free: -1), l(disc: 10001), l(gst: 7), l(mrp: Paise.zero)].indexed) {
        await expectLater(receive([bad], inv: 'BAD$i'), throwsA(isA<PurchaseException>()));
      }
      expect(await countOf(db, 'purchase_receipts'), 0);
    });
  });
}
