import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/catalog_dao.dart';
import '../../../core/db/daos/reports_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/db/models.dart';
import '../../../core/money/paise.dart';

part 'dashboard_repository.g.dart';

/// Dashboard reads: daily summary + small indexed look-ups (SPEC §5.1, §10).
class DashboardRepository {
  DashboardRepository(this._db, this._now);

  final AppDatabase _db;
  final DateTime Function() _now;

  DateTime get now => _now();

  Future<List<DaySales>> dailyNet(String from, String to) => _db.reportsDao.dailyNet(from, to);

  Future<List<CategorySales>> categoryNet(String from, String to) => _db.reportsDao.categoryNet(from, to);

  Future<({int bills, Paise total})> dayTotals(String day) => _db.reportsDao.dayTotals(day);

  Future<Paise> stockValue() => _db.catalogDao.stockValue(now: _now());

  Future<int> productCount() => _db.catalogDao.productCount();

  Future<InventoryCounts> counts({required int expiryWindowMonths, required int deadStockDays}) =>
      _db.catalogDao.inventoryCounts(now: _now(), expiryWindowMonths: expiryWindowMonths, deadStockDays: deadStockDays);

  Future<List<StockRow>> reorderSoon() => _db.catalogDao.reorderSoon(now: _now());

  Future<List<ExpiringBatch>> expiringBatches(int windowMonths) =>
      _db.catalogDao.expiringBatches(now: _now(), expiryWindowMonths: windowMonths);
}

@Riverpod(keepAlive: true)
DashboardRepository dashboardRepository(Ref ref) => DashboardRepository(ref.watch(appDatabaseProvider), ref.watch(nowProvider));
