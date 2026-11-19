import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/catalog_dao.dart';
import 'package:rx_desk/core/db/models.dart';
import 'package:rx_desk/core/money/paise.dart';

import '../helpers/test_db.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = memoryDb());
  tearDown(() => db.close());

  group('receive stock (SPEC §4.5)', () {
    test('into an existing batch adds qty and writes a movement', () async {
      final (pid, bid) = await addMed(db, qty: 10);
      final r = await db.catalogDao.receiveStock(productId: pid, batchNo: 'pcm2611', qty: 25, at: t0);
      expect(r.newBatch, isFalse);
      expect(r.batchId, bid);
      expect(await qtyOf(db, bid), 35);
      final mv = await db.catalogDao.movementsOf(bid);
      expect(mv.map((m) => (m.reason, m.delta)), [('opening', 10), ('receive', 25)]);
    });

    test('a new batch needs an expiry, then is created', () async {
      final (pid, _) = await addMed(db);
      await expectLater(
        db.catalogDao.receiveStock(productId: pid, batchNo: 'NEW1', qty: 5, at: t0),
        throwsA(isA<CatalogException>()),
      );
      final r = await db.catalogDao.receiveStock(productId: pid, batchNo: 'NEW1', expiry: '2028-03', qty: 5, at: t0);
      expect(r.newBatch, isTrue);
      expect((await db.catalogDao.batchesOf(pid)).map((b) => b.batchNo), ['PCM2611', 'NEW1']);
      expect((await db.catalogDao.movementsOf(r.batchId)).single.reason, 'receive');
    });

    test('rejects empty batch and zero qty', () async {
      final (pid, _) = await addMed(db);
      await expectLater(db.catalogDao.receiveStock(productId: pid, batchNo: ' ', qty: 5, at: t0), throwsA(isA<CatalogException>()));
      await expectLater(db.catalogDao.receiveStock(productId: pid, batchNo: 'PCM2611', qty: 0, at: t0), throwsA(isA<CatalogException>()));
    });

    test('adjust writes an adjust movement and refuses negatives', () async {
      final (_, bid) = await addMed(db, qty: 3);
      await db.catalogDao.adjustStock(batchId: bid, delta: -2, at: t0);
      expect(await qtyOf(db, bid), 1);
      await expectLater(db.catalogDao.adjustStock(batchId: bid, delta: -2, at: t0), throwsA(isA<CatalogException>()));
    });
  });

  group('FTS search', () {
    setUp(() async {
      await addMed(db, barcode: '8904021650153');
      await addMed(db, name: 'Paracetamol 500 mg Tablet', salt: 'Paracetamol 500 mg', batch: 'PCM1000', qty: 0, barcode: '8904021500016');
      await addMed(db, name: 'Amoxicillin 500 mg Capsule', salt: 'Amoxicillin 500 mg', maker: 'Aurelis Labs', schedule: 'H', batch: 'AMX0942', category: 'Capsule');
      await addMed(db, name: 'Crocin Advance', maker: 'Kestrel Healthcare', batch: 'CRO77', mrp: 2500);
    });

    test('"para 650" matches name and salt words, AND-ed', () async {
      final r = await db.catalogDao.search('para 650', now: t0);
      expect(r.rows.map((x) => x.name), ['Paracetamol 650 mg Tablet', 'Crocin Advance']);
      expect(r.total, 2);
    });

    test('ranking: name prefix, then salt prefix; out of stock after in stock', () async {
      final r = await db.catalogDao.search('para', now: t0);
      expect(r.rows.map((x) => x.name), ['Paracetamol 650 mg Tablet', 'Paracetamol 500 mg Tablet', 'Crocin Advance']);
      expect(r.rows[1].saleable, 0);
    });

    test('"amoxi" prefix', () async {
      final r = await db.catalogDao.search('amoxi', now: t0);
      expect(r.rows.single.name, 'Amoxicillin 500 mg Capsule');
      expect(r.rows.single.isRx, isTrue);
    });

    test('exact barcode', () async {
      final r = await db.catalogDao.search('8904021650153', now: t0);
      expect(r.exactBarcode, isTrue);
      expect(r.rows.single.name, 'Paracetamol 650 mg Tablet');
    });

    test('batch number and maker', () async {
      expect((await db.catalogDao.search('amx0942', now: t0)).rows.single.name, 'Amoxicillin 500 mg Capsule');
      expect((await db.catalogDao.search('kestrel', now: t0)).rows.single.name, 'Crocin Advance');
    });

    test('new batch, renamed product and renamed maker stay searchable (triggers)', () async {
      final amx = (await db.catalogDao.search('amoxi', now: t0)).rows.single;
      await db.catalogDao.receiveStock(productId: amx.id, batchNo: 'ZZ123', expiry: '2028-01', qty: 1, at: t0);
      expect((await db.catalogDao.search('zz123', now: t0)).rows.single.id, amx.id);
      await db.customStatement("UPDATE manufacturers SET name = 'Zephyr Labs' WHERE name = 'Aurelis Labs'");
      expect((await db.catalogDao.search('zephyr', now: t0)).rows.single.id, amx.id);
      await db.customStatement("UPDATE products SET name = 'Moxikind 500' WHERE id = ${amx.id}");
      expect((await db.catalogDao.search('moxik', now: t0)).rows.single.id, amx.id);
      expect((await db.catalogDao.search('amoxi', now: t0)).rows.single.id, amx.id); // salt unchanged
    });

    test('punctuation-only input returns nothing', () async {
      expect((await db.catalogDao.search('  %% ', now: t0)).rows, isEmpty);
    });

    test('substitutes: same salt, in stock, cheapest first', () async {
      final para = (await db.catalogDao.search('8904021650153', now: t0)).rows.single;
      final subs = await db.catalogDao.substitutes(para.id, now: t0);
      expect(subs.map((s) => s.name), ['Crocin Advance']);
    });
  });

  group('derived stock + inventory views (SPEC §3.4)', () {
    test('saleable excludes expired batches; nearest expiry; counts', () async {
      final (pid, _) = await addMed(db, qty: 10);
      await db.catalogDao.receiveStock(productId: pid, batchNo: 'OLD', expiry: '2026-09', qty: 7, at: t0);
      await db.catalogDao.receiveStock(productId: pid, batchNo: 'SOON', expiry: '2026-12', qty: 5, at: t0);
      final row = (await db.catalogDao.stockRow(pid, now: t0))!;
      expect(row.saleable, 15);
      expect(row.nearestExpiry, '2026-12');
      expect(row.earliestExpiry, '2026-09');
      expect(row.expiring, isTrue);
      expect(row.batchCount, 3);

      await addMed(db, name: 'Out Med', salt: 'X', batch: 'O1', qty: 0);
      await addMed(db, name: 'Low Med', salt: 'Y', batch: 'L1', qty: 5); // reorder 20
      final c = await db.catalogDao.inventoryCounts(now: t0);
      expect(c.all, 3);
      expect(c.out, 1);
      expect(c.low, 3); // 15 ≤ 20, 0, 5
      expect(c.expiring, 1);
      // Created 30 days ago, never sold → not dead yet at 90 days.
      expect(c.dead, 0);
      expect((await db.catalogDao.inventoryCounts(now: t0.add(const Duration(days: 100)))).dead, greaterThan(0));
    });

    test('inventory page: filter, sort, paging', () async {
      for (var i = 0; i < 12; i++) {
        await addMed(db, name: 'Med ${String.fromCharCode(65 + i)}', salt: 'S$i', batch: 'B$i', qty: i * 3, mrp: 1000 + i, category: i.isEven ? 'Tablet' : 'Syrup');
      }
      var page = await db.catalogDao.inventoryPage(const InventoryQuery(pageSize: 5), now: t0);
      expect(page.total, 12);
      expect(page.rows.map((r) => r.name), ['Med A', 'Med B', 'Med C', 'Med D', 'Med E']);
      page = await db.catalogDao.inventoryPage(const InventoryQuery(pageSize: 5, page: 3), now: t0);
      expect(page.rows.map((r) => r.name), ['Med K', 'Med L']);
      page = await db.catalogDao.inventoryPage(const InventoryQuery(sort: InventorySort.stock, ascending: false, pageSize: 2), now: t0);
      expect(page.rows.map((r) => r.saleable), [33, 30]);
      page = await db.catalogDao.inventoryPage(const InventoryQuery(category: 'Syrup'), now: t0);
      expect(page.total, 6);
      page = await db.catalogDao.inventoryPage(const InventoryQuery(view: InventoryView.out), now: t0);
      expect(page.rows.single.name, 'Med A');
      page = await db.catalogDao.inventoryPage(const InventoryQuery(search: 'med k'), now: t0);
      expect(page.rows.single.name, 'Med K');
      expect(await db.catalogDao.stockValue(now: t0), Paise([for (var i = 0; i < 12; i++) i * 3 * (1000 + i)].reduce((a, b) => a + b)));
    });
  });

  test('addProduct validates and rejects duplicate barcodes', () async {
    await addMed(db, barcode: '111111');
    await expectLater(addMed(db, name: 'Other', barcode: '111111'), throwsA(isA<CatalogException>()));
    await expectLater(
      db.catalogDao.addProduct(const NewProduct(name: 'x', maker: 'm', category: 'Tablet', gstRate: 7, mrp: Paise(100)), at: t0),
      throwsA(isA<CatalogException>()),
    );
  });

  group('same-name medicines', () {
    test('productsNamed ignores case and outer spaces, flags hidden, skips the one being edited', () async {
      final (a, _) = await addMed(db);
      final (b, _) = await addMed(db, name: 'PARACETAMOL 650 mg tablet ', salt: 'Paracetamol 650 mg + Caffeine 50 mg', maker: 'Aurelis Labs', batch: 'PC2');
      await addMed(db, name: 'Paracetamol 650 mg Tablet SR', batch: 'PC3');
      await db.catalogDao.setProductActive(a, false, at: t0);

      final all = await db.catalogDao.productsNamed('  paracetamol 650 MG Tablet');
      expect(all.map((m) => (m.id, m.isActive)), [(b, true), (a, false)]); // active first
      expect(all.first.maker, 'Aurelis Labs');
      expect(all.first.salt, 'Paracetamol 650 mg + Caffeine 50 mg');

      final others = await db.catalogDao.productsNamed('Paracetamol 650 mg Tablet', exceptProductId: b);
      expect(others.map((m) => m.id), [a]);
      expect(await db.catalogDao.productsNamed('Dolo 650'), isEmpty);
      expect(await db.catalogDao.productsNamed('   '), isEmpty);
    });

    test('the same name with a different salt still saves as a separate medicine', () async {
      final (a, _) = await addMed(db);
      final (b, _) = await addMed(db, salt: 'Paracetamol 650 mg + Caffeine 50 mg', batch: 'PC2');
      expect(b, isNot(a));
      expect((await db.catalogDao.productsNamed('Paracetamol 650 mg Tablet')).length, 2);
    });
  });
}
