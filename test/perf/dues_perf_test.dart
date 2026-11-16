@Tags(['perf'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/dues_dao.dart';

import '../helpers/test_db.dart';

/// BUILD_PLAN phase 12: dues and statement pages < 50 ms with 20 stockists,
/// 20k bills and 15k payments.
void main() {
  late AppDatabase db;
  const today = '2026-11-09';

  setUpAll(() async {
    db = memoryDb();
    await db.customStatement('''
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20)
      INSERT INTO suppliers(name, created_at, credit_days) SELECT 'Stockist ' || i, 0, 30 FROM n''');
    // Bills 1..20000, ~50 a day over 400 days.
    await db.customStatement('''
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000)
      INSERT INTO supplier_ledger(supplier_id, entry_date, kind, amount_paise, open_paise, due_date, reference, note, status, created_at)
      SELECT 1 + i % 20, date('2025-10-01', '+' || (i / 50) || ' days'), 'bill', 100000, CASE WHEN i <= 15000 THEN 0 ELSE 100000 END,
             date('2025-10-01', '+' || (i / 50 + 30) || ' days'), 'INV' || i, '', 'active', 0
      FROM n''');
    // Payments 20001..35000, each clearing bill (id - 20000).
    await db.customStatement('''
      INSERT INTO supplier_ledger(supplier_id, entry_date, kind, amount_paise, open_paise, mode, reference, note, status, created_at)
      SELECT supplier_id, date(entry_date, '+20 days'), 'payment', 100000, 0, 'NEFT', 'UTR' || id, '', 'active', 0
      FROM supplier_ledger WHERE id <= 15000 ORDER BY id''');
    await db.customStatement('''
      INSERT INTO ledger_allocations(credit_id, debit_id, amount_paise)
      SELECT id, id - 20000, 100000 FROM supplier_ledger WHERE kind = 'payment' ''');
  });
  tearDownAll(() => db.close());

  Future<double> timed(Future<void> Function() f) async {
    await f(); // warm-up
    final sw = Stopwatch()..start();
    await f();
    return sw.elapsedMicroseconds / 1000;
  }

  test('seeded', () async {
    expect(await countOf(db, 'supplier_ledger'), 35000);
    final (t, _) = await db.duesDao.totals(today: today);
    expect(t.owed.value, 5000 * 100000);
    expect(t.stockists, 20);
  });

  test('dues page, totals, statement pages and open bills < 50 ms', () async {
    final dues = db.duesDao;
    final first = await dues.statement(1);
    for (final run in [
      () => dues.duesPage(today: today),
      () => dues.duesPage(today: today, search: 'stockist 1'),
      () => dues.totals(today: today),
      () => dues.supplierDues(1, today: today),
      () => dues.statement(1),
      () => dues.statement(1, after: StatementCursor(first.rows.last.date, first.rows.last.id)),
      () => dues.openBills(1),
    ]) {
      final ms = await timed(run);
      expect(ms, lessThan(50), reason: '$ms ms');
    }
  });
}
