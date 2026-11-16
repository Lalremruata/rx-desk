import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/inventory/consumption_rules.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/sales/return_rules.dart';

import '../helpers/test_db.dart';

void main() {
  late AppDatabase db;
  late int para, paraBatch, cough, coughBatch, idle;
  final now = DateTime(2026, 11, 20, 10);

  Future<SavedBill> sell(int p, int b, int qty, int day, {int month = 11}) =>
      db.salesDao.saveBill(SaveBillRequest(lines: [BillLineRequest(productId: p, batchId: b, qty: qty)]), rules: const BillRules(), at: DateTime(2026, month, day, 11));

  setUp(() async {
    db = memoryDb();
    (para, paraBatch) = await addMed(db, qty: 1000, packSize: 10);
    (cough, coughBatch) = await addMed(db, name: 'Ascoril LS Syrup', salt: 'Ambroxol', batch: 'ASC1', category: 'Syrup');
    (idle, _) = await addMed(db, name: 'Zinc Tablet', salt: 'Zinc', batch: 'ZN1', qty: 50);
  });
  tearDown(() => db.close());

  test('day-wise units for the month, net of returns; other months ignored', () async {
    await sell(para, paraBatch, 30, 3);
    await sell(para, paraBatch, 20, 3); // same day adds up
    final b = await sell(para, paraBatch, 15, 17);
    await sell(cough, coughBatch, 2, 17);
    await sell(cough, coughBatch, 4, 30, month: 10); // October
    // Return 5 tabs on the 18th (counts on the return day).
    final item = (await db.salesDao.invoiceWithItems(b.invoiceId))!.items.single;
    await db.salesDao.saveCreditNote(
      SaveCreditNoteRequest(invoiceId: b.invoiceId, lines: [ReturnLineRequest(itemId: item.id, qty: 5)], refundMode: 'Cash'),
      rules: const ReturnRules(),
      at: DateTime(2026, 11, 18, 9),
    );

    final p = await db.reportsDao.consumptionPage('2026-11', now: now);
    expect(p.total, 2);
    expect(p.rows.map((r) => r.name), ['Ascoril LS Syrup', 'Paracetamol 650 mg Tablet']);
    final pr = p.rows[1];
    expect(pr.daily, {3: 50, 17: 15, 18: -5});
    expect((pr.unitsPerPack, pr.saleable, pr.reorderLevel), (10, 1000 - 65 + 5, 20));
    final s = ConsumptionStats.of(pr.days(daysInMonth('2026-11')), avgLeadDays: 1, maxLeadDays: 2);
    expect((s.total, s.maxDaily, s.reorderLevel), (60, 50, 100.0));
    expect(suggestedReorderPacks(s.reorderLevel, pr.unitsPerPack), 10);

    final oct = await db.reportsDao.consumptionPage('2026-10', now: now);
    expect(oct.rows.single.daily, {30: 4});

    // All medicines: the idle one shows with no days; search narrows.
    final all = await db.reportsDao.consumptionPage('2026-11', now: now, includeAll: true);
    expect(all.rows.map((r) => r.productId), [cough, para, idle]);
    expect(all.rows.last.daily, isEmpty);
    expect((await db.reportsDao.consumptionPage('2026-11', now: now, search: 'asco')).rows.single.productId, cough);
    expect(await db.reportsDao.consumptionAll('2026-11', now: now), hasLength(2));
    final paged = await db.reportsDao.consumptionPage('2026-11', now: now, includeAll: true, pageSize: 2, page: 2);
    expect((paged.total, paged.rows.single.productId), (3, idle));
  });

  test('setReorderLevels updates several products at once', () async {
    expect(await db.catalogDao.setReorderLevels({para: 10, cough: 4}, at: now), 2);
    final rows = await db.reportsDao.consumptionPage('2026-11', now: now, includeAll: true);
    expect({for (final r in rows.rows) r.productId: r.reorderLevel}, {para: 10, cough: 4, idle: 20});
  });
}
