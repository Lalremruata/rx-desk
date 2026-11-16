@Tags(['perf'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/models.dart';
import 'package:rx_desk/core/db/seed/seed.dart';

import '../helpers/test_db.dart';

/// SPEC §10 budgets on the demo seed.
void main() {
  late AppDatabase db;
  final now = DateTime(2026, 11, 9, 14);

  setUpAll(() async {
    db = memoryDb();
    await seedDemoData(db, now: now);
  });
  tearDownAll(() => db.close());

  Future<double> timeMs(Future<void> Function() f) async {
    await f(); // warm-up
    final sw = Stopwatch()..start();
    await f();
    return sw.elapsedMicroseconds / 1000;
  }

  test('inventory page (50 rows, any filter/sort) < 50 ms', () async {
    final queries = [
      const InventoryQuery(),
      const InventoryQuery(view: InventoryView.low, sort: InventorySort.stock),
      const InventoryQuery(view: InventoryView.expiring, sort: InventorySort.expiry),
      const InventoryQuery(view: InventoryView.dead),
      const InventoryQuery(view: InventoryView.out, ascending: false),
      const InventoryQuery(search: 'para', sort: InventorySort.mrp),
      const InventoryQuery(category: 'Syrup', page: 2),
      const InventoryQuery(manufacturerId: 3, pageSize: 100),
      const InventoryQuery(page: 20, sort: InventorySort.stock, ascending: false),
    ];
    for (final q in queries) {
      final ms = await timeMs(() => db.catalogDao.inventoryPage(q, now: now));
      expect(ms, lessThan(50), reason: '$q took $ms ms');
    }
    final counts = await timeMs(() => db.catalogDao.inventoryCounts(now: now));
    expect(counts, lessThan(50));
  });

  test('billing search keystroke < 30 ms', () async {
    for (final q in ['p', 'pa', 'para', 'para 6', 'para 650', 'amoxi', 'metf 500', '8904021650153', 'pcm2611', 'kestrel cet']) {
      final ms = await timeMs(() => db.catalogDao.search(q, now: now));
      expect(ms, lessThan(30), reason: '"$q" took $ms ms');
    }
  });
}
