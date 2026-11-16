@Tags(['perf'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/customers_dao.dart';

import '../helpers/test_db.dart';

/// BUILD_PLAN phase 15: customer list, totals and statement pages < 50 ms
/// with 20k customers, 60k credit bills and 45k payments.
void main() {
  late AppDatabase db;
  const today = '2026-11-09';

  setUpAll(() async {
    db = memoryDb();
    await db.customStatement('''
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000)
      INSERT INTO customers(name, phone, created_at) SELECT 'Customer ' || i, '9' || printf('%09d', i), 0 FROM n''');
    // Bills 1..60000, ~150 a day over 400 days; the last 15k still open.
    await db.customStatement('''
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 60000)
      INSERT INTO customer_ledger(customer_id, entry_date, kind, amount_paise, open_paise, reference, note, status, created_at)
      SELECT 1 + i % 20000, date('2025-10-01', '+' || (i / 150) || ' days'), 'bill', 50000,
             CASE WHEN i <= 45000 THEN 0 ELSE 50000 END, 'INV' || i, '', 'active', 0
      FROM n''');
    // Payments 60001..105000, each clearing bill (id − 60000).
    await db.customStatement('''
      INSERT INTO customer_ledger(customer_id, entry_date, kind, amount_paise, open_paise, mode, reference, note, status, created_at)
      SELECT customer_id, date(entry_date, '+10 days'), 'payment', 50000, 0, 'Cash', '', '', 'active', 0
      FROM customer_ledger WHERE id <= 45000 ORDER BY id''');
    await db.customStatement('''
      INSERT INTO customer_allocations(credit_id, debit_id, amount_paise)
      SELECT id, id - 60000, 50000 FROM customer_ledger WHERE kind = 'payment' ''');
  });
  tearDownAll(() => db.close());

  Future<double> timed(Future<void> Function() f) async {
    await f(); // warm-up
    final sw = Stopwatch()..start();
    await f();
    return sw.elapsedMicroseconds / 1000;
  }

  test('seeded', () async {
    expect(await countOf(db, 'customer_ledger'), 105000);
    final (t, _) = await db.customersDao.totals(today: today);
    expect(t.owed.value, 15000 * 50000);
    expect(t.customers, 15000);
  });

  test('customer list, totals, statement pages, open bills and dues lookup < 50 ms', () async {
    final dao = db.customersDao;
    final first = await dao.statement(7);
    for (final run in [
      () => dao.duesPage(today: today),
      () => dao.duesPage(today: today, withDues: true),
      () => dao.duesPage(today: today, withDues: true, page: 200),
      () => dao.duesPage(today: today, search: 'customer 19'),
      () => dao.duesPage(today: today, search: '9000012345'),
      () => dao.totals(today: today),
      () => dao.customerDues(7, today: today),
      () => dao.statement(7),
      () => dao.statement(7, after: CustomerStatementCursor(first.rows.last.date, first.rows.last.id)),
      () => dao.openBills(7),
      () => dao.creditInfoByPhone('9000000007'),
    ]) {
      final ms = await timed(run);
      expect(ms, lessThan(50), reason: '$ms ms');
    }
  });
}
