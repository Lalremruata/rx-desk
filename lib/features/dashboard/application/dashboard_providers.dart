import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/daos/catalog_dao.dart';
import '../../../core/db/daos/reports_dao.dart';
import '../../../core/db/models.dart';
import '../../../core/money/paise.dart';
import '../../../core/utils/expiry.dart';
import '../../billing/application/bill_controller.dart';
import '../../inventory/application/inventory_providers.dart';
import '../../settings/application/settings_providers.dart';
import '../data/dashboard_repository.dart';
import 'chart_series.dart';

part 'dashboard_providers.g.dart';

@Riverpod(keepAlive: true)
class ChartRangeSel extends _$ChartRangeSel {
  @override
  ChartRange build() => ChartRange.d7;

  // ignore: use_setters_to_change_properties
  void set(ChartRange r) => state = r;
}

/// The four KPI tiles.
class DashboardKpis {
  const DashboardKpis({
    required this.todayNet,
    required this.todayBills,
    required this.stockValue,
    required this.medicines,
    required this.lowOrOut,
    required this.expiring,
  });

  final Paise todayNet;
  final int todayBills;
  final Paise stockValue;
  final int medicines;
  final int lowOrOut;
  final int expiring;

  Paise get todayAverage => Paise(todayBills == 0 ? 0 : (todayNet.value / todayBills).round());
}

/// Live: re-reads after any sale (salesVersion) or stock change.
final dashboardKpisProvider = FutureProvider.autoDispose<DashboardKpis>((ref) async {
  ref
    ..watch(salesVersionProvider)
    ..watch(inventoryVersionProvider);
  final repo = ref.watch(dashboardRepositoryProvider);
  final s = ref.watch(settingsProvider);
  final today = dateKey(repo.now);
  final results = await Future.wait([
    repo.dailyNet(today, today),
    repo.dayTotals(today),
    repo.stockValue(),
    repo.productCount(),
    repo.counts(expiryWindowMonths: s.expiryWindowMonths, deadStockDays: s.deadStockDays),
  ]);
  final day = results[0] as List<DaySales>;
  final totals = results[1] as ({int bills, Paise total});
  final counts = results[4] as InventoryCounts;
  return DashboardKpis(
    todayNet: day.isEmpty ? Paise.zero : day.first.net,
    todayBills: totals.bills,
    stockValue: results[2] as Paise,
    medicines: results[3] as int,
    lowOrOut: counts.low,
    expiring: counts.expiring,
  );
});

@riverpod
Future<ChartSeries> chartSeries(Ref ref) async {
  ref.watch(salesVersionProvider);
  final range = ref.watch(chartRangeSelProvider);
  final repo = ref.watch(dashboardRepositoryProvider);
  final now = repo.now;
  final days = await repo.dailyNet(ChartSeries.startKey(range, now), dateKey(now));
  return buildChartSeries(range, days, now);
}

/// This month's net by category (from the summary).
final categoryMonthProvider = FutureProvider.autoDispose<List<CategorySales>>((ref) {
  ref.watch(salesVersionProvider);
  final repo = ref.watch(dashboardRepositoryProvider);
  final now = repo.now;
  return repo.categoryNet(dateKey(DateTime(now.year, now.month)), dateKey(now));
});

final reorderSoonProvider = FutureProvider.autoDispose<List<StockRow>>((ref) {
  ref.watch(inventoryVersionProvider);
  return ref.watch(dashboardRepositoryProvider).reorderSoon();
});

final expiringBatchesProvider = FutureProvider.autoDispose<List<ExpiringBatch>>((ref) {
  ref.watch(inventoryVersionProvider);
  return ref.watch(dashboardRepositoryProvider).expiringBatches(ref.watch(settingsProvider.select((s) => s.expiryWindowMonths)));
});
