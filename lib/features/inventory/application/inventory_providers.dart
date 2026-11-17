import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/models.dart';
import '../../settings/application/settings_providers.dart';
import '../data/inventory_repository.dart';

part 'inventory_providers.g.dart';

/// Inventory screen state: view, filters, sort, page and expanded rows.
/// Kept alive so the dashboard can open a pre-filtered view.
@Riverpod(keepAlive: true)
class InventoryFilter extends _$InventoryFilter {
  @override
  InventoryQuery build() => const InventoryQuery();

  void setView(InventoryView v) => state = state.copyWith(view: v, page: 1);
  void setSearch(String q) => state = state.copyWith(search: q, page: 1);
  void setCategory(String? c) => state = state.copyWith(category: c, page: 1);
  void setMaker(int? id) => state = state.copyWith(manufacturerId: id, page: 1);
  void setPage(int p) => state = state.copyWith(page: p);
  void setPageSize(int s) => state = state.copyWith(pageSize: s, page: 1);

  /// Clicking a sortable header: same column toggles direction, a new
  /// column starts ascending.
  void sortBy(InventorySort s) =>
      state = state.copyWith(sort: s, ascending: state.sort == s ? !state.ascending : true, page: 1);

  /// Dashboard tap-through (SPEC §5.1): a saved view with a given sort and
  /// no other filters.
  void open(InventoryView v, {InventorySort sort = InventorySort.name, bool ascending = true}) =>
      state = InventoryQuery(view: v, sort: sort, ascending: ascending, pageSize: state.pageSize);

  void showProduct(String name) => state = InventoryQuery(search: name, pageSize: state.pageSize);
}

/// Product ids whose batch panel is open.
@Riverpod(keepAlive: true)
class ExpandedProducts extends _$ExpandedProducts {
  @override
  Set<int> build() => const {};

  void toggle(int id) => state = state.contains(id) ? ({...state}..remove(id)) : {...state, id};
  void open(int id) => state = {...state, id};
  void close(int id) => state = {...state}..remove(id);
}

/// Bumps whenever products / batches change, so views refresh after a
/// sale, receipt or edit.
@Riverpod(keepAlive: true)
Stream<int> inventoryVersion(Ref ref) async* {
  var n = 0;
  yield n;
  await for (final _ in ref.watch(inventoryRepositoryProvider).changes()) {
    yield ++n;
  }
}

@riverpod
Future<InventoryPage> inventoryPage(Ref ref) {
  ref.watch(inventoryVersionProvider);
  final q = ref.watch(inventoryFilterProvider);
  final s = ref.watch(settingsProvider);
  return ref
      .watch(inventoryRepositoryProvider)
      .page(q, expiryWindowMonths: s.expiryWindowMonths, deadStockDays: s.deadStockDays);
}

@riverpod
Stream<InventoryCounts> inventoryCounts(Ref ref) {
  final s = ref.watch(settingsProvider);
  return ref
      .watch(inventoryRepositoryProvider)
      .watchCounts(expiryWindowMonths: s.expiryWindowMonths, deadStockDays: s.deadStockDays);
}

// Declared by hand: riverpod_generator can't resolve Drift's generated row
// types in the same build pass.

/// Batches of one product, refreshed on stock changes.
final productBatchesProvider = FutureProvider.autoDispose.family<List<StockBatch>, int>((ref, productId) {
  ref.watch(inventoryVersionProvider);
  return ref.watch(inventoryRepositoryProvider).batchesOf(productId);
});

final makersProvider = StreamProvider.autoDispose<List<Manufacturer>>(
  (ref) => ref.watch(inventoryRepositoryProvider).watchMakers(),
);

/// The newest stock movements of one batch (Edit batch history).
final batchMovementsProvider = StreamProvider.autoDispose.family<List<StockMovement>, int>(
  (ref, batchId) => ref.watch(inventoryRepositoryProvider).watchRecentMovements(batchId),
);
