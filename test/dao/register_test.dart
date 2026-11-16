import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/report_models.dart';
import 'package:rx_desk/core/db/seed/seed.dart';

import '../helpers/test_db.dart';

void main() {
  test('register totals equal the sum of paid invoices; groups and pages add up', () async {
    final db = memoryDb();
    addTearDown(db.close);
    final now = DateTime(2026, 11, 9, 14);
    await seedDemoData(db, now: now);
    // Cancel one bill: it must drop out of the register.
    await db.salesDao.cancelInvoice(1, at: now);

    const f = RegisterFilter(from: '2026-04-01', to: '2026-11-09');
    final t = await db.reportsDao.registerTotals(f);
    final inv = await db.customSelect(
      'SELECT COUNT(*) AS c, SUM(total_paise - round_off_paise) AS n, SUM(cgst_paise + sgst_paise) AS tax '
      "FROM invoices WHERE status = 'paid' AND sale_date BETWEEN '2026-04-01' AND '2026-11-09'",
    ).getSingle();
    expect(t.bills, inv.read<int>('c'));
    expect(t.net.value, inv.read<int>('n'));
    expect(t.tax.value, inv.read<int>('tax'));
    expect(t.cgst + t.sgst, t.tax);

    final days = await db.reportsDao.registerGroups(f.copyWith(group: RegisterGroup.day), limit: null);
    expect(days.rows.fold<int>(0, (a, g) => a + g.net.value), t.net.value);

    // Keyset pages cover every line exactly once.
    var seen = 0;
    RegisterCursor? after;
    final ids = <int>{};
    while (true) {
      final p = await db.reportsDao.registerLines(f, after: after, limit: 5000);
      seen += p.rows.length;
      ids.addAll(p.rows.map((r) => r.id));
      if (!p.hasMore) break;
      after = RegisterCursor(p.rows.last.sortValue, p.rows.last.id);
    }
    expect(seen, t.lines);
    expect(ids.length, t.lines);

    final rx = await db.reportsDao.registerTotals(f.copyWith(schedule: ScheduleFilter.rx));
    final rxLines = await db.reportsDao.registerLines(f.copyWith(schedule: ScheduleFilter.rx), limit: 20);
    expect(rx.lines, greaterThan(0));
    expect(rxLines.rows.every((l) => l.schedule == 'H' || l.schedule == 'H1'), isTrue);
    expect(rxLines.rows.every((l) => l.doctor != null), isTrue);

  }, timeout: const Timeout(Duration(minutes: 2)));
}
