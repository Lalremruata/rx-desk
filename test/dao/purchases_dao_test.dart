import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/purchases_dao.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/purchases/purchase_rules.dart';
import 'package:rx_desk/core/utils/pack.dart';

import '../helpers/test_db.dart';

void main() {
  late AppDatabase db;
  late PurchasesDao dao;
  setUp(() {
    db = memoryDb();
    dao = db.purchasesDao;
  });
  tearDown(() => db.close());

  const day = '2026-09-01';

  Future<SavedReceipt> receive(List<ReceiveLineInput> lines, {String supplier = 'Life Drugs Centre', String inv = '26000730032563'}) =>
      dao.receive(
        ReceiveRequest(supplierName: supplier, invoiceNo: inv, receivedDate: '2026-09-02', lines: lines),
        at: t0,
        now: t0,
      );

  Future<OrderRow> rowOf(int id) async => (await dao.orderRows([id])).single;

  test('adds order lines with product name snapshot or free text', () async {
    final (pid, _) = await addMed(db, name: 'Dolo 650 Tablet');
    final ids = await dao.addOrderLines(day, [
      NewOrderLine(productId: pid, itemName: 'ignored', qty: 5, unit: 'Box', note: '32x15'),
      const NewOrderLine(itemName: '  Mycospor Cream ', qty: 20, unit: 'Nos'),
    ], at: t0);
    final rows = await dao.orderRows(ids);
    expect(rows.map((r) => (r.itemName, r.qty, r.unit, r.status)), [
      ('Dolo 650 Tablet', 5, 'Box', OrderStatus.pending),
      ('Mycospor Cream', 20, 'Nos', OrderStatus.pending),
    ]);
    expect(rows.first.note, '32x15');
    await expectLater(dao.addOrderLines(day, [const NewOrderLine(itemName: 'X', qty: 0, unit: 'Box')], at: t0), throwsA(isA<PurchaseException>()));
    await expectLater(dao.addOrderLines(day, [const NewOrderLine(itemName: 'X', qty: 1, unit: 'Crate')], at: t0), throwsA(isA<PurchaseException>()));
  });

  test('receive into a new and an existing batch: stock, movements, status', () async {
    final (pid, bid) = await addMed(db, name: 'Etodase TH-4', batch: 'ET01', qty: 10);
    final (pid2, _) = await addMed(db, name: 'Azithral XL 200', batch: 'AZ01', qty: 0);
    final ids = await dao.addOrderLines(day, [
      NewOrderLine(productId: pid, itemName: '', qty: 30, unit: 'Box'),
      NewOrderLine(productId: pid2, itemName: '', qty: 15, unit: 'Nos'),
    ], at: t0);

    final saved = await receive([
      ReceiveLineInput(orderLineId: ids[0], productId: pid, batchNo: 'et01', qty: 20, unit: 'Box', stockUnits: 200, amount: const Paise(361200), moreExpected: true),
      ReceiveLineInput(orderLineId: ids[1], productId: pid2, batchNo: 'AZ99', expiry: '2028-01', qty: 15, unit: 'Nos', stockUnits: 15, amount: const Paise(141200)),
    ]);
    expect(saved.total, const Paise(502400));
    expect(saved.stockUnits, 215);

    expect(await qtyOf(db, bid), 210);
    final batches2 = await db.catalogDao.batchesOf(pid2);
    final az99 = batches2.firstWhere((b) => b.batchNo == 'AZ99');
    expect(az99.qty, 15);
    expect(az99.purchaseRatePaise, 9413);

    final mv = await db.catalogDao.movementsOf(bid);
    expect(mv.last.reason, 'receive');
    expect(mv.last.delta, 200);
    expect(mv.last.refType, 'purchase');
    expect(mv.last.refId, saved.receiptId);

    final r0 = await rowOf(ids[0]);
    expect(r0.status, OrderStatus.part);
    expect(r0.receivedSameUnit, 20);
    expect(r0.due, 10);
    expect(r0.suppliers, 'Life Drugs Centre');
    expect(r0.invoiceNos, '26000730032563');
    expect(r0.lastReceived, '2026-09-02');
    expect((await rowOf(ids[1])).status, OrderStatus.received);

    // The rest arrives later from another stockist.
    await receive(
      [ReceiveLineInput(orderLineId: ids[0], productId: pid, batchNo: 'ET01', qty: 10, unit: 'Box', stockUnits: 100, amount: const Paise(180600))],
      supplier: 'Life Care Pharmacy',
      inv: '1104',
    );
    final done = await rowOf(ids[0]);
    expect(done.status, OrderStatus.received);
    expect(done.receivedLabel, '30 Box');
    expect(done.amount, const Paise(541800));
    expect(done.suppliers, 'Life Drugs Centre, Life Care Pharmacy');
  });

  test('short delivery with nothing more coming closes the line', () async {
    final (pid, _) = await addMed(db);
    final ids = await dao.addOrderLines(day, [NewOrderLine(productId: pid, itemName: '', qty: 10, unit: 'Nos')], at: t0);
    await receive([ReceiveLineInput(orderLineId: ids[0], productId: pid, batchNo: 'PCM2611', qty: 5, unit: 'Nos', stockUnits: 5, amount: const Paise(20000))]);
    expect((await rowOf(ids[0])).status, OrderStatus.closed);
    expect((await rowOf(ids[0])).tag, SupplyTag.short);
  });

  test('a bad line rolls the whole receipt back', () async {
    final (pid, bid) = await addMed(db, qty: 10);
    final ids = await dao.addOrderLines(day, [NewOrderLine(productId: pid, itemName: '', qty: 10, unit: 'Box')], at: t0);
    await expectLater(
      receive([
        ReceiveLineInput(orderLineId: ids[0], productId: pid, batchNo: 'PCM2611', qty: 10, unit: 'Box', stockUnits: 100, amount: const Paise(100)),
        // New batch without expiry.
        ReceiveLineInput(productId: pid, batchNo: 'NEW1', qty: 1, unit: 'Box', stockUnits: 10, amount: const Paise(100)),
      ]),
      throwsA(isA<PurchaseException>()),
    );
    expect(await qtyOf(db, bid), 10);
    expect(await countOf(db, 'purchase_receipts'), 0);
    expect(await countOf(db, 'receipt_lines'), 0);
    expect(await countOf(db, 'suppliers'), 0);
    expect((await rowOf(ids[0])).status, OrderStatus.pending);
    expect((await db.catalogDao.movementsOf(bid)).length, 1);
  });

  test('expired stock cannot be received, into a new or existing batch', () async {
    final (pid, _) = await addMed(db, batch: 'OLD1', expiry: '2026-08');
    await expectLater(
      receive([ReceiveLineInput(productId: pid, batchNo: 'NEW1', expiry: '2026-10', qty: 1, unit: 'Box', stockUnits: 10, amount: Paise.zero)]),
      throwsA(isA<PurchaseException>().having((e) => e.message, 'message', contains('expired'))),
    );
    await expectLater(
      receive([ReceiveLineInput(productId: pid, batchNo: 'OLD1', qty: 1, unit: 'Box', stockUnits: 10, amount: Paise.zero)]),
      throwsA(isA<PurchaseException>()),
    );
    // Near expiry is allowed.
    await receive([ReceiveLineInput(productId: pid, batchNo: 'NEW2', expiry: '2026-12', qty: 1, unit: 'Box', stockUnits: 10, amount: Paise.zero)]);
  });

  test('duplicate stockist invoice is rejected; stockist names match case-insensitively', () async {
    final (pid, _) = await addMed(db);
    ReceiveLineInput line() => ReceiveLineInput(productId: pid, batchNo: 'PCM2611', qty: 1, unit: 'Box', stockUnits: 10, amount: const Paise(500));
    await receive([line()], supplier: 'FMT Pharmacy', inv: 'FP/401/26-27');
    await expectLater(receive([line()], supplier: 'fmt  pharmacy', inv: 'FP/401/26-27'), throwsA(isA<PurchaseException>()));
    await receive([line()], supplier: 'fmt pharmacy', inv: 'FP/402/26-27');
    expect(await countOf(db, 'suppliers'), 1);
    expect(await countOf(db, 'purchase_receipts'), 2);
  });

  test('free-text line takes the received product; mismatched product is refused', () async {
    final (pid, _) = await addMed(db, name: 'Mycospor Cream', category: 'Topical');
    final (other, _) = await addMed(db, name: 'Other', batch: 'OT1');
    final ids = await dao.addOrderLines(day, [
      const NewOrderLine(itemName: 'Mycospor', qty: 20, unit: 'Tube'),
      NewOrderLine(productId: other, itemName: '', qty: 1, unit: 'Box'),
    ], at: t0);
    await receive([ReceiveLineInput(orderLineId: ids[0], productId: pid, batchNo: 'PCM2611', qty: 20, unit: 'Tube', stockUnits: 20, amount: const Paise(100))]);
    expect((await rowOf(ids[0])).productId, pid);
    await expectLater(
      receive([ReceiveLineInput(orderLineId: ids[1], productId: pid, batchNo: 'PCM2611', qty: 1, unit: 'Box', stockUnits: 1, amount: Paise.zero)], inv: 'X2'),
      throwsA(isA<PurchaseException>()),
    );
  });

  test('a Box line remembers strips per box on the medicine, in the same transaction', () async {
    final (pid, bid) = await addMed(db, name: 'Dolo 650 Tablet', qty: 0);
    Future<int?> perBox() async => (await db.catalogDao.stockRow(pid, now: t0))!.packsPerBox;
    expect(await perBox(), isNull);

    // Free text "Dolo 10 Box" linked on receipt: 10 × 15 = 150 strips.
    final ids = await dao.addOrderLines(day, [const NewOrderLine(itemName: 'Dolo', qty: 10, unit: 'Box')], at: t0);
    await receive([
      ReceiveLineInput(orderLineId: ids[0], productId: pid, batchNo: 'PCM2611', qty: 10, unit: 'Box', stockUnits: 150, amount: const Paise(150000), packsPerBox: 15),
    ]);
    expect(await qtyOf(db, bid), 150);
    expect(await perBox(), 15);
    expect((await rowOf(ids[0])).status, OrderStatus.received);

    // A Strip line leaves it alone; a later Box line can change it.
    await receive([ReceiveLineInput(productId: pid, batchNo: 'PCM2611', qty: 5, unit: 'Strip', stockUnits: 5, amount: Paise.zero, packsPerBox: 99)], inv: 'S1');
    expect(await perBox(), 15);
    await receive([ReceiveLineInput(productId: pid, batchNo: 'PCM2611', qty: 1, unit: 'Box', stockUnits: 10, amount: Paise.zero, packsPerBox: 10)], inv: 'B2');
    expect(await perBox(), 10);
    expect(await qtyOf(db, bid), 165);

    // Out of range: nothing saved, medicine unchanged.
    for (final bad in [0, maxPacksPerBox + 1]) {
      await expectLater(
        receive([ReceiveLineInput(productId: pid, batchNo: 'PCM2611', qty: 1, unit: 'Box', stockUnits: 10, amount: Paise.zero, packsPerBox: bad)], inv: 'BAD$bad'),
        throwsA(isA<PurchaseException>()),
      );
    }
    expect(await perBox(), 10);
    expect(await qtyOf(db, bid), 165);
  });

  test('a bad later line rolls back a remembered strips per box', () async {
    final (pid, _) = await addMed(db, qty: 0);
    await expectLater(
      receive([
        ReceiveLineInput(productId: pid, batchNo: 'PCM2611', qty: 2, unit: 'Box', stockUnits: 20, amount: Paise.zero, packsPerBox: 10),
        ReceiveLineInput(productId: pid, batchNo: 'NEW1', qty: 1, unit: 'Box', stockUnits: 10, amount: Paise.zero, packsPerBox: 10),
      ]),
      throwsA(isA<PurchaseException>()),
    );
    expect((await db.catalogDao.stockRow(pid, now: t0))!.packsPerBox, isNull);
  });

  test('close short and cancel only from the right status', () async {
    final (pid, _) = await addMed(db);
    final ids = await dao.addOrderLines(day, [
      NewOrderLine(productId: pid, itemName: '', qty: 10, unit: 'Box'),
      NewOrderLine(productId: pid, itemName: '', qty: 10, unit: 'Box'),
    ], at: t0);
    await expectLater(dao.closeShort(ids[0], at: t0), throwsA(isA<PurchaseException>()));
    await dao.cancelOrderLine(ids[0], at: t0);
    expect((await rowOf(ids[0])).status, OrderStatus.cancelled);
    await expectLater(
      receive([ReceiveLineInput(orderLineId: ids[0], productId: pid, batchNo: 'PCM2611', qty: 1, unit: 'Box', stockUnits: 1, amount: Paise.zero)]),
      throwsA(isA<PurchaseException>()),
    );

    await receive([ReceiveLineInput(orderLineId: ids[1], productId: pid, batchNo: 'PCM2611', qty: 4, unit: 'Box', stockUnits: 40, amount: Paise.zero, moreExpected: true)]);
    await expectLater(dao.cancelOrderLine(ids[1], at: t0), throwsA(isA<PurchaseException>()));
    await dao.closeShort(ids[1], at: t0);
    expect((await rowOf(ids[1])).status, OrderStatus.closed);
  });

  test('open page is keyset paged, oldest first, and searchable', () async {
    final (pid, _) = await addMed(db);
    for (var d = 1; d <= 5; d++) {
      await dao.addOrderLines('2026-09-0$d', [
        for (var i = 0; i < 3; i++) NewOrderLine(productId: i == 0 ? pid : null, itemName: 'Item $d.$i', qty: 1, unit: 'Box'),
      ], at: t0);
    }
    final ids = <int>[];
    PurchaseCursor? after;
    var pages = 0;
    while (true) {
      final p = await dao.openPage(after: after, limit: 4);
      ids.addAll(p.rows.map((r) => r.id));
      pages++;
      if (!p.hasMore) break;
      after = PurchaseCursor(p.rows.last.orderDate, p.rows.last.id);
    }
    expect(pages, 4);
    expect(ids, [...ids]..sort());
    expect(ids.toSet().length, 15);
    final found = await dao.openPage(search: 'item 3.');
    expect(found.rows.map((r) => r.itemName), ['Item 3.1', 'Item 3.2']);
  });

  test('order book: ordered lines then unordered extras; totals add up', () async {
    final (pid, _) = await addMed(db);
    final ids = await dao.addOrderLines('2026-09-02', [
      NewOrderLine(productId: pid, itemName: '', qty: 24, unit: 'Pcs'),
      const NewOrderLine(itemName: 'Nitrocube SR 100', qty: 4, unit: 'Box'),
    ], at: t0);
    await receive([
      ReceiveLineInput(orderLineId: ids[0], productId: pid, batchNo: 'PCM2611', qty: 24, unit: 'Pcs', stockUnits: 24, amount: const Paise(325100)),
      ReceiveLineInput(productId: pid, batchNo: 'PCM2611', qty: 2, unit: 'Box', stockUnits: 20, amount: const Paise(378000)),
    ], supplier: 'Copex Health Care', inv: 'CHP/26-27/0001777');
    final book = await dao.book('2026-09-02', '2026-09-02');
    expect(book.map((b) => (b.item, b.orderedLabel, b.stockist, b.receivedLabel, b.tag)), [
      ('Paracetamol 650 mg Tablet', '24 Pcs', 'Copex Health Care', '24 Pcs', SupplyTag.none),
      ('Nitrocube SR 100', '4 Box', '', '', SupplyTag.pending),
      ('Paracetamol 650 mg Tablet', '', 'Copex Health Care', '2 Box', SupplyTag.notOrdered),
    ]);
    expect(book.map((b) => b.amount).sum(), const Paise(703100));
    expect(await dao.adjacentDay('2026-09-02', forward: false), isNull);
    expect(await dao.adjacentDay('2026-08-20', forward: true), '2026-09-02');

    final receipts = await dao.receiptPage();
    expect(receipts.rows.single.lines, 2);
    expect(receipts.rows.single.total, const Paise(703100));
    expect((await dao.receiptPage(search: 'copex')).rows, hasLength(1));
    expect((await dao.receiptPage(search: 'nope')).rows, isEmpty);
    expect((await dao.linesOf(receipts.rows.single.id)).map((l) => l.stockUnits), [24, 20]);

    final k = await dao.kpis(now: DateTime(2026, 9, 15));
    expect(k.open, 1);
    expect(k.orderedThisMonth, 2);
    expect(k.receivedThisMonth, const Paise(703100));
    expect(k.shortThisMonth, 0);
    expect(await dao.watchOpenCount().first, 1);
  });
}
