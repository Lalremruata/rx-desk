import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/catalog_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/db/models.dart';
import '../../../core/inventory/stock_adjust.dart';
import '../../../core/money/paise.dart';

part 'inventory_repository.g.dart';

/// Inventory data access for the app (wraps [CatalogDao]).
class InventoryRepository {
  InventoryRepository(this._db, this._now);

  final AppDatabase _db;
  final DateTime Function() _now;

  CatalogDao get _dao => _db.catalogDao;

  Stream<int> watchProductCount() => _dao.watchProductCount();

  Stream<InventoryCounts> watchCounts({required int expiryWindowMonths, required int deadStockDays}) =>
      _dao.watchInventoryCounts(now: _now(), expiryWindowMonths: expiryWindowMonths, deadStockDays: deadStockDays);

  Future<InventoryCounts> counts({required int expiryWindowMonths, required int deadStockDays}) =>
      _dao.inventoryCounts(now: _now(), expiryWindowMonths: expiryWindowMonths, deadStockDays: deadStockDays);

  Future<InventoryPage> page(InventoryQuery q, {required int expiryWindowMonths, required int deadStockDays}) =>
      _dao.inventoryPage(q, now: _now(), expiryWindowMonths: expiryWindowMonths, deadStockDays: deadStockDays);

  Future<List<StockBatch>> batchesOf(int productId) => _dao.batchesOf(productId);

  Future<List<Manufacturer>> makers() => _dao.allManufacturers();

  Stream<List<Manufacturer>> watchMakers() => _dao.watchManufacturers();

  Future<List<SameNameProduct>> productsNamed(String name, {int? exceptProductId}) =>
      _dao.productsNamed(name, exceptProductId: exceptProductId);

  Future<int> addProduct(NewProduct p, {int? staffId}) => _dao.addProduct(p, at: _now(), staffId: staffId);

  Future<ReceiveResult> receive({
    required int productId,
    required String batchNo,
    String? expiry,
    required int qty,
    int? staffId,
  }) =>
      _dao.receiveStock(productId: productId, batchNo: batchNo, expiry: expiry, qty: qty, at: _now(), staffId: staffId);

  /// Packs per product (consumption register "Apply suggested").
  Future<int> setReorderLevels(Map<int, int> levels) => _dao.setReorderLevels(levels, at: _now());

  Future<void> updateProduct(int productId, ProductEdit e) => _dao.updateProduct(productId, e, at: _now());

  Future<void> setProductActive(int productId, bool active) => _dao.setProductActive(productId, active, at: _now());

  Future<StockBatch> editBatch(
    int batchId, {
    String? batchNo,
    String? expiry,
    int? countedQty,
    StockAdjustReason? reason,
    String note = '',
    int? staffId,
  }) =>
      _dao.editBatch(batchId,
          batchNo: batchNo, expiry: expiry, countedQty: countedQty, reason: reason, note: note, at: _now(), staffId: staffId);

  Stream<List<StockMovement>> watchRecentMovements(int batchId, {int limit = 5}) =>
      _dao.watchRecentMovements(batchId, limit: limit);

  Future<void> setPackSize(int productId, int size, {int? staffId}) =>
      _dao.setPackSize(productId, size, at: _now(), staffId: staffId);

  Future<StockRow?> stockRow(int productId, {int expiryWindowMonths = 3}) =>
      _dao.stockRow(productId, now: _now(), expiryWindowMonths: expiryWindowMonths);

  Future<Paise> stockValue() => _dao.stockValue(now: _now());

  /// FTS product search (name, salt, batch, barcode, HSN).
  Future<SearchResults> search(String q, {int limit = 8}) => _dao.search(q, now: _now(), limit: limit);

  Future<List<StockRow>> reorderSoon({int limit = 4}) => _dao.reorderSoon(now: _now(), limit: limit);

  Future<List<ExpiringBatch>> expiringBatches({required int expiryWindowMonths, int limit = 4}) =>
      _dao.expiringBatches(now: _now(), expiryWindowMonths: expiryWindowMonths, limit: limit);

  /// Every write to stock or products, for refreshing dependent views.
  Stream<void> changes() => _db
      .tableUpdates(TableUpdateQuery.onAllTables([_db.products, _db.batches, _db.manufacturers]))
      .map((_) {});
}

@Riverpod(keepAlive: true)
InventoryRepository inventoryRepository(Ref ref) =>
    InventoryRepository(ref.watch(appDatabaseProvider), ref.watch(nowProvider));
