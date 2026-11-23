import 'package:drift/drift.dart';

import '../../fy/fy.dart';
import '../../money/gst.dart';
import '../../money/paise.dart';
import '../../sales/bill_rules.dart';
import '../../utils/expiry.dart';
import '../app_database.dart';
import '../daos/customers_dao.dart';
import '../daos/sales_dao.dart';
import 'catalog_data.dart';

/// Which demo data set to generate.
enum SeedSize {
  /// ~1,600 products, ~11 months of sales (~12k bills / ~25k lines).
  demo(1),

  /// Same catalogue, ~4× the bills: ~100k invoice lines (perf budgets).
  perf100k(4);

  const SeedSize(this.billFactor);
  final int billFactor;
}

class SeedReport {
  const SeedReport({required this.products, required this.batches, required this.bills, required this.lines, required this.elapsed});

  final int products;
  final int batches;
  final int bills;
  final int lines;
  final Duration elapsed;

  @override
  String toString() => 'Seeded $products products, $batches batches, $bills bills, $lines lines in ${elapsed.inMilliseconds} ms';
}

class _PlannedBill {
  _PlannedBill(this.at, this.customer, this.phone, this.doctor, this.pay, this.disc);

  final DateTime at;
  final String customer;
  final String? phone;
  final String? doctor;
  final String pay;
  final int disc;
  final List<(SeedProduct, SeedBatch, int)> items = [];
}

/// Debug seed (`--dart-define=SEED=true`, `--dart-define=PERF_SEED=100k`).
///
/// Generates the prototype's catalogue and ~11 months of sales, and writes
/// every bill through [SalesDao.saveBill] so stock, movements, daily
/// summaries and invoice sequences are exactly what real use would produce.
/// Opening stock = target stock + everything the history sells.
Future<SeedReport> seedDemoData(
  AppDatabase db, {
  DateTime? now,
  SeedSize size = SeedSize.demo,
  void Function(double progress, String stage)? onProgress,
}) async {
  final sw = Stopwatch()..start();
  final today = now ?? DateTime.now();
  final barcodes = <String>{};
  final curated = curatedProducts(today);
  barcodes.addAll(curated.map((p) => p.barcode));
  final all = [...curated, ...generatedProducts(today, usedBarcodes: barcodes)];

  // ---- plan history (prototype genHistory) ----
  onProgress?.call(0, 'Planning sales history');
  final rnd = Mulberry32(4242);
  // Credit (udhaar) uses its own stream so the rest of the history stays
  // exactly as before.
  final creditRnd = Mulberry32(7777);
  final regulars = [
    for (final (i, n) in seedCustomers.indexed) (n, '97${(1000001 + i * 7919).toString().padLeft(8, '0')}'),
  ];
  final popular = [...all.take(15), for (var i = 15; i < all.length; i += 7) all[i]];
  final notSlow = all.where((p) => !p.slow).toList();
  final start = DateTime(today.year, today.month, today.day).subtract(const Duration(days: 343));
  final yesterday = DateTime(today.year, today.month, today.day).subtract(const Duration(days: 1));
  final slowCutoff = DateTime(today.year, today.month, today.day).subtract(const Duration(days: 120));
  final plans = <_PlannedBill>[];

  SeedBatch? fefo(SeedProduct p, DateTime at) {
    final valid = p.batches.where((b) => !isExpired(b.expiry, at)).toList()..sort((a, b) => a.expiry.compareTo(b.expiry));
    return valid.isEmpty ? null : valid.first;
  }

  void plan(DateTime day, int n, {int maxMinute = 1260}) {
    final mins = [for (var i = 0; i < n; i++) 480 + rnd.nextInt(maxMinute - 480)]..sort();
    for (final m in mins) {
      final at = day.add(Duration(minutes: m, seconds: rnd.nextInt(60)));
      final k = 1 + (rnd.next() * rnd.next() * 6).floor();
      final items = <(SeedProduct, SeedBatch, int)>[];
      var rx = false;
      for (var j = 0; j < k; j++) {
        final pool = day.isAfter(slowCutoff) ? notSlow : all;
        final p = rnd.next() < 0.6 ? popular[rnd.nextInt(popular.length)] : pool[rnd.nextInt(pool.length)];
        if (p.schedule == 'X') continue;
        if (items.any((x) => identical(x.$1, p))) continue;
        final b = fefo(p, at);
        if (b == null) continue;
        if (isRxSchedule(p.schedule)) rx = true;
        final qty = 1 + (rnd.next() * rnd.next() * 4).floor();
        items.add((p, b, qty));
      }
      if (items.isEmpty) continue;
      final named = rx || rnd.next() < 0.3;
      final r = rnd.next();
      final name = named ? seedCustomers[rnd.nextInt(seedCustomers.length)] : '';
      final phone = named ? '98${(10000000 + rnd.nextInt(89999999)).toString()}' : null;
      final doctor = rx ? seedDoctors[rnd.nextInt(seedDoctors.length)] : null;
      final pay = r < 0.45 ? 'UPI' : r < 0.85 ? 'Cash' : 'Card';
      final disc = rnd.next() < 0.12 ? 5 : rnd.next() < 0.04 ? 10 : 0;
      // About one named bill in five goes on a regular's khata.
      final regular = named && creditRnd.next() < 0.2 ? regulars[creditRnd.nextInt(regulars.length)] : null;
      final bill = _PlannedBill(
        at,
        regular?.$1 ?? name,
        regular?.$2 ?? phone,
        doctor,
        regular == null ? pay : creditMode,
        disc,
      )..items.addAll(items);
      for (final it in items) {
        it.$2.sold += it.$3;
      }
      plans.add(bill);
    }
  }

  for (var d = start; !d.isAfter(yesterday); d = DateTime(d.year, d.month, d.day + 1)) {
    final age = d.difference(start).inDays;
    final dow = d.weekday; // 7 = Sunday
    final factor = dow == DateTime.sunday ? 0.6 : dow == DateTime.saturday ? 1.15 : 1.0;
    final n = ((30 + age * 0.03) * factor * (0.85 + rnd.next() * 0.3) * size.billFactor).round();
    plan(d, n);
  }
  // A few bills earlier today (prototype has three).
  final minutesNow = today.hour * 60 + today.minute;
  if (minutesNow > 540) plan(DateTime(today.year, today.month, today.day), 3 * size.billFactor, maxMinute: minutesNow);

  // ---- write catalogue with opening stock ----
  onProgress?.call(0.02, 'Writing catalogue');
  final openingAt = start.subtract(const Duration(days: 1));
  final openTs = openingAt.toUtc().millisecondsSinceEpoch;
  var batchCount = 0;
  await db.transaction(() async {
    final makerIds = <String, int>{};
    for (final p in all) {
      final mid = makerIds[p.maker] ??= await db.catalogDao.manufacturerIdFor(p.maker);
      p.id = await db.into(db.products).insert(
            ProductsCompanion.insert(
              name: p.name,
              salt: Value(p.salt),
              form: Value(p.form),
              category: p.category,
              pack: Value(p.pack),
              manufacturerId: mid,
              schedule: Value(p.schedule),
              hsn: Value(p.hsn),
              gstRate: p.gst,
              mrpPaise: p.mrpPaise,
              reorderLevel: Value(p.reorder),
              rack: Value(p.rack),
              barcode: Value(p.barcode),
              createdAt: openTs,
              updatedAt: openTs,
            ),
          );
      for (final b in p.batches) {
        final opening = b.targetQty + b.sold;
        b.id = await db.into(db.batches).insert(
              BatchesCompanion.insert(productId: p.id!, batchNo: b.batchNo, expiry: b.expiry, qty: opening, mrpPaise: Value(p.mrpPaise), createdAt: openTs),
            );
        batchCount++;
        if (opening != 0) {
          await db.into(db.stockMovements).insert(
                StockMovementsCompanion.insert(
                  batchId: b.id!,
                  delta: opening,
                  reason: 'opening',
                  refType: const Value('seed'),
                  at: openTs,
                ),
              );
        }
      }
    }
    // Bills before this FY started continue an earlier series, like the
    // prototype (INV/25-26/02141…).
    await db.salesDao.setSequence(fyLabel(start), 2140);
  });

  // ---- replay history through the real save path ----
  const rules = BillRules(maxDiscountPct: 20);
  var lines = 0;
  const chunk = 400;
  for (var i = 0; i < plans.length; i += chunk) {
    final end = (i + chunk).clamp(0, plans.length);
    await db.transaction(() async {
      for (final b in plans.sublist(i, end)) {
        await db.salesDao.saveBill(
          SaveBillRequest(
            lines: [for (final it in b.items) BillLineRequest(productId: it.$1.id!, batchId: it.$2.id!, qty: it.$3)],
            customerName: b.customer,
            customerPhone: b.phone,
            doctorName: b.doctor,
            paymentMode: b.pay,
            discount: PercentDiscount(b.disc),
          ),
          rules: rules,
          at: b.at,
        );
        lines += b.items.length;
      }
    });
    onProgress?.call(0.05 + 0.95 * end / plans.length, 'Writing sales history');
  }

  // ---- regulars paid most of their khata; recent bills stay open ----
  onProgress?.call(1, 'Customer payments');
  final payDay = dateKey(yesterday);
  await db.transaction(() async {
    for (final (_, phone) in regulars) {
      final info = await db.customersDao.creditInfoByPhone(phone);
      if (info == null || info.dues <= 0) continue;
      final keepDays = [7, 20, 45, 75, 120][creditRnd.nextInt(5)];
      final from = dateKey(today.subtract(Duration(days: keepDays)));
      final open = await db.customSelect(
        "SELECT COALESCE(SUM(amount_paise), 0) AS s FROM customer_ledger WHERE customer_id = ?1 AND kind = 'bill' AND entry_date >= ?2",
        variables: [Variable.withInt(info.customer.id), Variable.withString(from)],
      ).getSingle();
      final pay = info.dues - open.read<int>('s');
      if (pay <= 0) continue;
      await db.customersDao.recordPayment(
        customerId: info.customer.id,
        date: payDay,
        payment: CustomerPaymentInput(amount: Paise(pay), mode: creditRnd.next() < 0.5 ? 'Cash' : 'UPI'),
        at: yesterday.add(const Duration(hours: 18)),
      );
    }
  });

  return SeedReport(
    products: all.length,
    batches: batchCount,
    bills: plans.length,
    lines: lines,
    elapsed: sw.elapsed,
  );
}

/// Whether the database has no products yet.
Future<bool> isEmptyDatabase(AppDatabase db) async => await db.catalogDao.productCount() == 0;
