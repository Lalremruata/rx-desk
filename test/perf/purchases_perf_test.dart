@Tags(['perf'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/purchases_dao.dart';

import '../helpers/test_db.dart';

/// BUILD_PLAN phase 11: Pending / Order book pages < 50 ms with 50k order
/// lines (about 125 a day for 400 days, 80 % received).
void main() {
  late AppDatabase db;

  setUpAll(() async {
    db = memoryDb();
    final (pid, bid) = await addMed(db);
    await db.customStatement('''
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20)
      INSERT INTO suppliers(name, created_at) SELECT 'Stockist ' || i, 0 FROM n''');
    // 50k order lines; every 5th is still open (pending / part).
    await db.customStatement('''
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 50000)
      INSERT INTO order_lines(order_date, product_id, item_name, qty, unit, note, status, created_at, updated_at)
      SELECT date('2025-10-01', '+' || (i / 125) || ' days'), CASE WHEN i % 3 = 0 THEN NULL ELSE $pid END,
             'Item ' || i, 10, 'Box', '',
             CASE i % 5 WHEN 0 THEN 'pending' WHEN 1 THEN 'part' ELSE 'received' END, 0, 0
      FROM n''');
    // One receipt per 10 lines; a receipt line for every non-pending line.
    await db.customStatement('''
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5000)
      INSERT INTO purchase_receipts(supplier_id, invoice_no, received_date, total_paise, created_at)
      SELECT 1 + i % 20, 'INV' || i, date('2025-10-01', '+' || (i * 10 / 125) || ' days'), 100000, 0 FROM n''');
    await db.customStatement('''
      INSERT INTO receipt_lines(receipt_id, line_no, order_line_id, product_id, batch_id, item_name, batch_no, expiry,
                                qty, unit, stock_units, amount_paise)
      SELECT 1 + (id - 1) / 10, 1 + (id - 1) % 10, id, $pid, $bid, item_name, 'PCM2611', '2027-08',
             CASE status WHEN 'part' THEN 5 ELSE 10 END, 'Box', 100, 10000
      FROM order_lines WHERE status <> 'pending' ''');
  });
  tearDownAll(() => db.close());

  Future<double> timed(Future<void> Function() f) async {
    await f(); // warm-up
    final sw = Stopwatch()..start();
    await f();
    return sw.elapsedMicroseconds / 1000;
  }

  test('seeded 50k order lines', () async {
    expect(await countOf(db, 'order_lines'), 50000);
    expect(await countOf(db, 'receipt_lines'), 40000);
  });

  test('Pending first, deep and searched pages < 50 ms', () async {
    final dao = db.purchasesDao;
    final first = await dao.openPage();
    expect(first.rows, hasLength(50));
    expect(first.hasMore, isTrue);
    for (final run in [
      dao.openPage,
      () => dao.openPage(after: const PurchaseCursor('2026-06-01', 0)),
      () => dao.openPage(search: 'item 4999'),
    ]) {
      final ms = await timed(run);
      expect(ms, lessThan(50), reason: '$ms ms');
    }
  });

  test('Order book day (125 lines) and receipts page < 50 ms', () async {
    final dao = db.purchasesDao;
    expect((await dao.book('2026-03-01', '2026-03-01')).length, greaterThanOrEqualTo(125));
    for (final run in [
      () => dao.book('2026-03-01', '2026-03-01'),
      dao.receiptPage,
      () => dao.receiptPage(search: 'stockist 7'),
      () => dao.kpis(now: DateTime(2026, 3, 15)),
    ]) {
      final ms = await timed(run);
      expect(ms, lessThan(50), reason: '$ms ms');
    }
  });
}
