import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/migrations.dart';
import 'package:rx_desk/core/db/seed/catalog_data.dart';
import 'package:rx_desk/core/db/seed/seed.dart';

import '../helpers/test_db.dart';

void main() {
  test('fresh schema has FTS, triggers and SPEC §3.3 indexes', () async {
    final db = memoryDb();
    addTearDown(db.close);
    expect(db.schemaVersion, latestSchemaVersion);
    final objs = await db.customSelect("SELECT type, name FROM sqlite_master WHERE type IN ('table','trigger','index')").get();
    final names = objs.map((r) => r.read<String>('name')).toSet();
    expect(names, containsAll(['products_fts', 'products_fts_ai', 'batches_fts_ai', 'manufacturers_fts_au']));
    expect(names, containsAll(['idx_batches_expiry_instock', 'idx_items_schedule_date', 'idx_invoices_date_id', 'idx_movements_batch_at']));
  });

  test('mulberry32 is deterministic', () {
    final a = Mulberry32(42), b = Mulberry32(42);
    for (var i = 0; i < 100; i++) {
      expect(a.next(), b.next());
    }
  });

  test('demo seed: < 30 s, consistent books, acceptance searches', () async {
    final db = memoryDb();
    addTearDown(db.close);
    final now = DateTime(2026, 11, 9, 14);
    final report = await seedDemoData(db, now: now);
    // ignore: avoid_print
    print(report);

    expect(report.elapsed, lessThan(const Duration(seconds: 30)));
    expect(report.products, inInclusiveRange(1400, 1800));
    expect(report.bills, inInclusiveRange(9000, 16000));
    expect(report.lines, greaterThan(report.bills));

    // Books balance: summary = items, sequences = bills, no negative stock.
    final items = await db.customSelect('SELECT SUM(net_paise) AS n, SUM(qty) AS q FROM invoice_items').getSingle();
    final summ = await db.customSelect('SELECT SUM(net_paise) AS n, SUM(units) AS q FROM daily_sales_summary').getSingle();
    expect(summ.read<int>('n'), items.read<int>('n'));
    expect(summ.read<int>('q'), items.read<int>('q'));
    final seqs = (await db.customSelect('SELECT SUM(last_seq) AS s FROM invoice_seq').getSingle()).read<int>('s');
    expect(seqs, report.bills + 2140); // prior-FY series continues from 2140
    expect((await db.customSelect('SELECT COUNT(*) AS c FROM batches WHERE qty < 0').getSingle()).read<int>('c'), 0);
    // Each batch's qty = Σ movements.
    final drift = await db.customSelect(
      'SELECT COUNT(*) AS c FROM batches b WHERE b.qty <> (SELECT COALESCE(SUM(delta),0) FROM stock_movements m WHERE m.batch_id = b.id)',
    ).getSingle();
    expect(drift.read<int>('c'), 0);
    // Gapless numbering in this FY.
    final fy = await db.customSelect("SELECT COUNT(*) AS c, MAX(seq) AS m, MIN(seq) AS lo FROM invoices WHERE fy = '26-27'").getSingle();
    expect(fy.read<int>('lo'), 1);
    expect(fy.read<int>('m'), fy.read<int>('c'));
    // Curated stock after history matches the prototype's targets.
    final para = (await db.catalogDao.search('8904021650153', now: now)).rows.single;
    expect(para.saleable, 142);

    // BUILD_PLAN acceptance: FTS returns results for these.
    for (final q in ['para 650', 'amoxi', '8904021650153', 'PCM2611']) {
      final r = await db.catalogDao.search(q, now: now);
      expect(r.rows, isNotEmpty, reason: q);
    }
    // Regulars' khata (SPEC §4.10): credit bills, part settled, mixed ages.
    final (credit, top) = await db.customersDao.totals(today: '2026-11-09');
    expect(credit.customers, inInclusiveRange(5, 10));
    expect(credit.owed.value, greaterThan(0));
    expect(top, isNotEmpty);
    final ledgerBills = await db.customSelect("SELECT COUNT(*) AS c FROM customer_ledger WHERE kind = 'bill'").getSingle();
    final creditInvoices = await db.customSelect("SELECT COUNT(*) AS c FROM invoices WHERE payment_mode = 'Credit'").getSingle();
    expect(ledgerBills.read<int>('c'), creditInvoices.read<int>('c'));
    expect(creditInvoices.read<int>('c'), greaterThan(100));

    // Timing budgets are checked in test/perf (tag: perf).
  }, timeout: const Timeout(Duration(minutes: 2)));
}
