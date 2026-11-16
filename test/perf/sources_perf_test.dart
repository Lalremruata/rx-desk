@Tags(['perf'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/sources_dao.dart';

import '../helpers/test_db.dart';

/// BUILD_PLAN phase 16: stockist directory pages < 50 ms with 300 stockists
/// and 20k lines.
void main() {
  late AppDatabase db;

  setUpAll(() async {
    db = memoryDb();
    await addMed(db);
    await db.customStatement('''
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 300)
      INSERT INTO suppliers(name, phone, created_at, credit_days, other_phones, note)
      SELECT 'Stockist ' || printf('%03d', i), '98' || printf('%08d', i), 0, 30, '', '' FROM n''');
    await db.customStatement('''
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000)
      INSERT INTO product_sources(supplier_id, product_id, item_name, mr_name, mr_phone, note, origin, created_at, updated_at)
      SELECT 1 + i % 300, NULL, 'Medicine ' || printf('%05d', i), CASE WHEN i % 50 = 0 THEN 'MR ' || i ELSE '' END, '', '', 'import', 0, 0
      FROM n''');
    await db.customStatement(
      "INSERT INTO product_sources(supplier_id, product_id, item_name, origin, last_received, created_at, updated_at) VALUES (7, 1, 'Paracetamol 650 mg Tablet', 'receipt', '2026-11-01', 0, 0)",
    );
  });
  tearDownAll(() => db.close());

  test('pages, search, stockist filter, sources for a medicine < 50 ms', () async {
    final dao = db.sourcesDao;
    final first = await dao.page();
    expect(first.total, 20001);
    final last = first.rows.last;
    for (final run in [
      dao.page,
      () => dao.page(after: SourceCursor(last.supplierName, last.itemName, last.id)),
      () => dao.page(search: 'medicine 1234'),
      () => dao.page(search: 'mr 500'),
      () => dao.page(supplierId: 42),
      () => dao.sourcesFor(1),
      () => dao.firstSources([1, 2, 3]),
    ]) {
      await run();
      final sw = Stopwatch()..start();
      await run();
      expect(sw.elapsedMilliseconds, lessThan(50), reason: '${sw.elapsedMilliseconds} ms');
    }
  });
}
