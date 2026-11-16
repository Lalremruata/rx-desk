@Tags(['perf'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/report_models.dart';
import 'package:rx_desk/core/db/seed/seed.dart';

import '../helpers/test_db.dart';

/// SPEC §10: Sales register FY totals + first page on ~100k lines < 150 ms.
void main() {
  late AppDatabase db;
  late SeedReport report;
  final now = DateTime(2026, 11, 9, 14);

  setUpAll(() async {
    db = memoryDb();
    report = await seedDemoData(db, now: now, size: SeedSize.perf100k);
  });
  tearDownAll(() => db.close());

  test('100k seed has ~100k lines', () {
    expect(report.lines, greaterThan(80000));
  });

  test('FY totals + first page < 150 ms (lines, grouped, filtered)', () async {
    const fy = RegisterFilter(from: '2026-04-01', to: '2026-11-09');
    for (final f in [
      fy,
      fy.copyWith(group: RegisterGroup.medicine, sort: RegisterSort.units),
      fy.copyWith(group: RegisterGroup.hsn),
      fy.copyWith(schedule: ScheduleFilter.rx),
      fy.copyWith(search: 'para', payment: 'UPI'),
      fy.copyWith(sort: RegisterSort.net),
    ]) {
      await db.reportsDao.registerTotals(f); // warm-up
      final sw = Stopwatch()..start();
      await db.reportsDao.registerTotals(f);
      if (f.group == RegisterGroup.none) {
        await db.reportsDao.registerLines(f);
      } else {
        await db.reportsDao.registerGroups(f);
      }
      expect(sw.elapsedMilliseconds, lessThan(150), reason: '$f');
    }
  });

  test('dashboard reads stay < 100 ms on the large seed', () async {
    final sw = Stopwatch()..start();
    await db.reportsDao.dailyNet('2025-12-01', '2026-11-09');
    await db.reportsDao.categoryNet('2026-11-01', '2026-11-09');
    await db.reportsDao.dayTotals('2026-11-09');
    expect(sw.elapsedMilliseconds, lessThan(100));
  });

  test('monthly consumption register page / all medicines / search < 50 ms; full month < 150 ms', () async {
    for (final run in [
      () => db.reportsDao.consumptionPage('2026-10', now: now),
      () => db.reportsDao.consumptionPage('2026-10', now: now, includeAll: true, page: 20),
      () => db.reportsDao.consumptionPage('2026-10', now: now, search: 'para'),
    ]) {
      await run(); // warm-up
      final sw = Stopwatch()..start();
      final p = await run();
      expect(sw.elapsedMilliseconds, lessThan(50), reason: '${sw.elapsedMilliseconds} ms');
      expect(p.rows, isNotEmpty);
    }
    final sw = Stopwatch()..start();
    final all = await db.reportsDao.consumptionAll('2026-10', now: now);
    expect(sw.elapsedMilliseconds, lessThan(150), reason: '${sw.elapsedMilliseconds} ms for ${all.length} rows');
    expect(all.length, greaterThan(100));
  });
}
