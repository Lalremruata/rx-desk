import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/report_models.dart';
import 'package:rx_desk/core/db/seed/seed.dart';
import 'package:rx_desk/core/utils/expiry.dart';
import 'package:rx_desk/features/dashboard/application/chart_series.dart';

import '../helpers/test_db.dart';

void main() {
  test('dashboard numbers match the register for the same ranges', () async {
    final db = memoryDb();
    addTearDown(db.close);
    final now = DateTime(2026, 11, 9, 14);
    await seedDemoData(db, now: now);
    await db.salesDao.cancelInvoice(5, at: now); // cancelled bills drop out of both

    for (final r in ChartRange.values) {
      final from = ChartSeries.startKey(r, now);
      final to = dateKey(now);
      final s = buildChartSeries(r, await db.reportsDao.dailyNet(from, to), now);
      final reg = await db.reportsDao.registerTotals(RegisterFilter(from: from, to: to));
      expect(s.total, reg.net, reason: r.label);
    }

    const monthFrom = '2026-11-01', today = '2026-11-09';
    final cats = await db.reportsDao.categoryNet(monthFrom, today);
    final reg = await db.reportsDao.registerTotals(const RegisterFilter(from: monthFrom, to: today));
    expect(cats.fold<int>(0, (a, c) => a + c.net.value), reg.net.value);
    final regTablets = await db.reportsDao.registerTotals(const RegisterFilter(from: monthFrom, to: today, category: 'Tablet'));
    expect(cats.firstWhere((c) => c.category == 'Tablet').net, regTablets.net);

    final day = await db.reportsDao.dayTotals(today);
    final regToday = await db.reportsDao.registerTotals(const RegisterFilter(from: today, to: today));
    expect(day.bills, regToday.bills);

    // Load-time budget: test/perf/register_perf_test.dart.
  }, timeout: const Timeout(Duration(minutes: 2)));
}
