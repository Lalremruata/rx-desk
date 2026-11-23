import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/catalog_dao.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/db/models.dart';
import 'package:rx_desk/core/inventory/stock_adjust.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/utils/pack.dart';

import '../helpers/test_db.dart';

/// Editable inventory (SPEC §5.3): edit medicine, edit batch, hide.
void main() {
  late AppDatabase db;
  setUp(() => db = memoryDb());
  tearDown(() => db.close());

  ProductEdit edit(StockRow r, {String? name, String? barcode, int? mrp, int? gst, String? maker, int? perBox}) => ProductEdit(
        name: name ?? r.name,
        salt: r.salt,
        maker: maker ?? r.maker,
        pack: r.pack,
        category: r.category,
        schedule: r.schedule,
        barcode: barcode ?? r.barcode,
        hsn: r.hsn,
        gstRate: gst ?? r.gstRate,
        mrp: Paise(mrp ?? r.mrp.value),
        reorderLevel: r.reorderLevel,
        rack: r.rack,
        packsPerBox: perBox ?? r.packsPerBox,
      );

  Future<StockRow> row(int pid) async => (await db.catalogDao.stockRow(pid, now: t0))!;

  group('edit medicine', () {
    test('updates details; search follows; past bills keep their snapshot', () async {
      final (pid, bid) = await addMed(db, qty: 10);
      final sale = await db.salesDao.saveBill(
        SaveBillRequest(lines: [BillLineRequest(productId: pid, batchId: bid, qty: 2)]),
        rules: const BillRules(),
        at: t0,
      );
      await db.catalogDao.updateProduct(pid, edit(await row(pid), name: 'Dolo 650', mrp: 3360, gst: 5, maker: 'Micro Labs'), at: t0);

      final r = await row(pid);
      expect((r.name, r.mrp, r.gstRate, r.maker), ('Dolo 650', const Paise(3360), 5, 'Micro Labs'));
      expect((await db.catalogDao.search('dolo', now: t0)).rows.single.id, pid);
      expect((await db.catalogDao.search('micro', now: t0)).rows.single.id, pid);

      final item = await (db.select(db.invoiceItems)..where((i) => i.invoiceId.equals(sale.invoiceId))).getSingle();
      expect((item.productName, item.mrpPaise, item.gstRate), ('Paracetamol 650 mg Tablet', 3090, 12));
    });

    test('strips per box: set on add, corrected on edit, 1–$maxPacksPerBox', () async {
      final pid = await db.catalogDao.addProduct(
        const NewProduct(name: 'Dolo 650', maker: 'Micro Labs', category: 'Tablet', gstRate: 12, mrp: Paise(3360), packsPerBox: 15),
        at: t0,
      );
      expect((await row(pid)).packsPerBox, 15);
      await db.catalogDao.updateProduct(pid, edit(await row(pid), perBox: 10), at: t0);
      expect((await row(pid)).packsPerBox, 10);
      await db.catalogDao.updateProduct(pid, edit(await row(pid), name: 'Dolo 650 Tab'), at: t0);
      expect((await row(pid)).packsPerBox, 10);
      await expectLater(db.catalogDao.updateProduct(pid, edit(await row(pid), perBox: 0), at: t0), throwsA(isA<CatalogException>()));
      await expectLater(
        db.catalogDao.addProduct(const NewProduct(name: 'X', maker: 'Y', category: 'Tablet', gstRate: 12, mrp: Paise(100), packsPerBox: maxPacksPerBox + 1), at: t0),
        throwsA(isA<CatalogException>()),
      );
    });

    test('barcode: own barcode is fine, another product’s is refused', () async {
      final (a, _) = await addMed(db, barcode: '111');
      final (b, _) = await addMed(db, name: 'Other', salt: 'O', batch: 'O1', barcode: '222');
      await db.catalogDao.updateProduct(a, edit(await row(a), name: 'Renamed'), at: t0);
      await expectLater(
        db.catalogDao.updateProduct(b, edit(await row(b), barcode: '111'), at: t0),
        throwsA(isA<CatalogException>().having((e) => e.message, 'message', contains('Renamed'))),
      );
    });

    test('validates like Add medicine', () async {
      final (pid, _) = await addMed(db);
      await expectLater(db.catalogDao.updateProduct(pid, edit(await row(pid), gst: 7), at: t0), throwsA(isA<CatalogException>()));
      await expectLater(db.catalogDao.updateProduct(pid, edit(await row(pid), mrp: 0), at: t0), throwsA(isA<CatalogException>()));
      await expectLater(db.catalogDao.updateProduct(pid, edit(await row(pid), name: ' '), at: t0), throwsA(isA<CatalogException>()));
    });
  });

  group('price changed while a bill was open', () {
    test('a stale MRP or GST is refused with the current prices; matching prices save', () async {
      final (pid, bid) = await addMed(db, qty: 10);
      await db.catalogDao.updateProduct(pid, edit(await row(pid), mrp: 3360), at: t0, repriceBatches: true);
      final stale = SaveBillRequest(
        lines: [BillLineRequest(productId: pid, batchId: bid, qty: 1, expectedMrp: const Paise(3090), expectedGstRate: 12)],
      );
      await expectLater(
        db.salesDao.saveBill(stale, rules: const BillRules(), at: t0),
        throwsA(isA<PriceChangedException>().having((e) => e.changes[bid], 'change', (mrp: const Paise(3360), gstRate: 12))),
      );
      expect(await qtyOf(db, bid), 10);
      expect(await countOf(db, 'invoices'), 0);

      final ok = await db.salesDao.saveBill(
        SaveBillRequest(
          lines: [BillLineRequest(productId: pid, batchId: bid, qty: 1, expectedMrp: const Paise(3360), expectedGstRate: 12)],
        ),
        rules: const BillRules(),
        at: t0,
      );
      expect(ok.totals.total, const Paise(3400)); // 33.60 rounded off to the rupee
    });
  });

  group('edit batch', () {
    test('counted quantity writes an adjust movement with the reason note', () async {
      final (_, bid) = await addMed(db, qty: 40);
      final b = await db.catalogDao.editBatch(bid, countedQty: 36, reason: StockAdjustReason.damaged, note: '4 crushed', at: t0, staffId: 1);
      expect(b.qty, 36);
      final mv = (await db.catalogDao.movementsOf(bid)).last;
      expect((mv.reason, mv.delta, mv.note, mv.staffId), ('adjust', -4, 'Damaged: 4 crushed', 1));
    });

    test('quantity rules: reason needed, Other needs a note, never negative, no-op refused', () async {
      final (_, bid) = await addMed(db, qty: 40);
      await expectLater(db.catalogDao.editBatch(bid, countedQty: 30, at: t0), throwsA(isA<CatalogException>()));
      await expectLater(
        db.catalogDao.editBatch(bid, countedQty: 30, reason: StockAdjustReason.other, at: t0),
        throwsA(isA<CatalogException>()),
      );
      await expectLater(
        db.catalogDao.editBatch(bid, countedQty: -1, reason: StockAdjustReason.count, at: t0),
        throwsA(isA<CatalogException>()),
      );
      await expectLater(db.catalogDao.editBatch(bid, countedQty: 40, batchNo: 'pcm2611', at: t0), throwsA(isA<CatalogException>()));
      expect(await qtyOf(db, bid), 40);
      expect((await db.catalogDao.movementsOf(bid)).length, 1); // opening only
    });

    test('batch number: upper-cased, unique per product; searchable', () async {
      final (pid, bid) = await addMed(db);
      await db.catalogDao.receiveStock(productId: pid, batchNo: 'B2', expiry: '2028-01', qty: 5, at: t0);
      await expectLater(db.catalogDao.editBatch(bid, batchNo: 'b2', at: t0), throwsA(isA<CatalogException>()));
      final b = await db.catalogDao.editBatch(bid, batchNo: ' pcm2612 ', at: t0);
      expect(b.batchNo, 'PCM2612');
      expect((await db.catalogDao.search('pcm2612', now: t0)).rows.single.id, pid);
    });

    test('expiry can be fixed on a live batch but is locked once expired (rule 5)', () async {
      final (pid, bid) = await addMed(db);
      expect((await db.catalogDao.editBatch(bid, expiry: '2027-09', at: t0)).expiry, '2027-09');
      await expectLater(db.catalogDao.editBatch(bid, expiry: '2027-13', at: t0), throwsA(isA<CatalogException>()));

      final old = await db.catalogDao.receiveStock(productId: pid, batchNo: 'OLD', expiry: '2026-09', qty: 7, at: t0);
      await expectLater(
        db.catalogDao.editBatch(old.batchId, expiry: '2027-09', at: t0),
        throwsA(isA<CatalogException>().having((e) => e.message, 'message', contains('expired'))),
      );
      // Writing off expired stock is still allowed.
      final b = await db.catalogDao.editBatch(old.batchId, countedQty: 0, reason: StockAdjustReason.count, at: t0);
      expect((b.qty, b.expiry), (0, '2026-09'));
    });
  });

  group('hide medicine', () {
    test('hidden medicines leave search, views and counts, show under Hidden, and come back', () async {
      final (pid, bid) = await addMed(db);
      await addMed(db, name: 'Other', salt: 'O', batch: 'O1');
      await db.catalogDao.setProductActive(pid, false, at: t0);

      expect((await db.catalogDao.search('para', now: t0)).rows, isEmpty);
      final c = await db.catalogDao.inventoryCounts(now: t0);
      expect((c.all, c.hidden), (1, 1));
      expect((await db.catalogDao.inventoryPage(const InventoryQuery(), now: t0)).rows.single.name, 'Other');
      final hidden = await db.catalogDao.inventoryPage(const InventoryQuery(view: InventoryView.hidden), now: t0);
      expect(hidden.rows.single.id, pid);
      await expectLater(
        db.salesDao.saveBill(SaveBillRequest(lines: [BillLineRequest(productId: pid, batchId: bid, qty: 1)]), rules: const BillRules(), at: t0),
        throwsA(isA<BillException>().having((e) => e.code, 'code', BillError.inactiveProduct)),
      );

      await db.catalogDao.setProductActive(pid, true, at: t0);
      expect((await db.catalogDao.inventoryCounts(now: t0)).hidden, 0);
      expect((await db.catalogDao.search('para', now: t0)).rows.single.id, pid);
    });
  });
}
