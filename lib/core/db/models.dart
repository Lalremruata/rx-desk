import 'package:freezed_annotation/freezed_annotation.dart';

import '../money/paise.dart';

part 'models.freezed.dart';

/// Product categories (SPEC §3.1).
const List<String> productCategories = ['Tablet', 'Capsule', 'Syrup', 'Injection', 'Topical', 'OTC'];

/// Drug schedules. '' = none.
const List<String> drugSchedules = ['', 'H', 'H1', 'X'];

const List<int> gstRates = [0, 5, 12, 18];

/// An existing medicine that shares a name with one being added or renamed.
/// Same names are allowed (different compositions exist); the form warns.
class SameNameProduct {
  const SameNameProduct({
    required this.id,
    required this.name,
    required this.salt,
    required this.maker,
    required this.pack,
    required this.isActive,
  });

  final int id;
  final String name;
  final String salt;
  final String maker;
  final String pack;
  final bool isActive;
}

/// A product with its derived stock (SPEC §3.4), computed in SQL.
@freezed
abstract class StockRow with _$StockRow {
  const factory StockRow({
    required int id,
    required String name,
    required String salt,
    required String form,
    required String category,
    required String pack,

    /// Units per pack (1 = not sold loose). [saleable] is in units.
    @Default(1) int packSize,

    /// Packs (strips) in one stockist box; null = not known yet.
    int? packsPerBox,
    required int manufacturerId,
    required String maker,
    required String schedule,
    required String hsn,
    required int gstRate,
    required Paise mrp,

    /// In packs.
    required int reorderLevel,
    required String rack,
    String? barcode,
    int? lastSoldAt,
    required int createdAt,

    /// Σ qty of non-expired batches.
    required int saleable,

    /// Earliest non-expired expiry with qty > 0.
    String? nearestExpiry,

    /// Earliest expiry of any batch (fallback for display).
    String? earliestExpiry,

    /// Any batch with qty > 0 within the expiry window (incl. expired).
    required bool expiring,
    required int batchCount,
  }) = _StockRow;

  const StockRow._();

  /// Reorder level is in packs; stock in units.
  bool get isLow => saleable <= reorderLevel * packSize;

  /// Can be sold by the tablet.
  bool get sellsLoose => packSize > 1;

  /// Whole packs in stock (rounded down).
  int get saleablePacks => packSize <= 1 ? saleable : saleable ~/ packSize;
  bool get isOut => saleable <= 0;
  bool get isRx => schedule == 'H' || schedule == 'H1';

  /// Nearest expiry for display: saleable batch first, else any batch.
  String? get displayExpiry => nearestExpiry ?? earliestExpiry;
}

/// Inventory saved views (SPEC §5.3).
/// Saved inventory views; [hidden] lists medicines taken off sale
/// (`is_active = 0`), every other view lists active ones only.
enum InventoryView { all, low, expiring, out, dead, hidden }

enum InventorySort { name, expiry, stock, mrp }

@freezed
abstract class InventoryQuery with _$InventoryQuery {
  const factory InventoryQuery({
    @Default(InventoryView.all) InventoryView view,
    @Default('') String search,
    String? category,
    int? manufacturerId,
    @Default(InventorySort.name) InventorySort sort,
    @Default(true) bool ascending,
    @Default(1) int page,
    @Default(50) int pageSize,
  }) = _InventoryQuery;
}

@freezed
abstract class InventoryCounts with _$InventoryCounts {
  const factory InventoryCounts({
    @Default(0) int all,
    @Default(0) int low,
    @Default(0) int expiring,
    @Default(0) int out,
    @Default(0) int dead,
    @Default(0) int hidden,
  }) = _InventoryCounts;

  const InventoryCounts._();

  int of(InventoryView v) => switch (v) {
        InventoryView.all => all,
        InventoryView.low => low,
        InventoryView.expiring => expiring,
        InventoryView.out => out,
        InventoryView.dead => dead,
        InventoryView.hidden => hidden,
      };
}

@freezed
abstract class InventoryPage with _$InventoryPage {
  const factory InventoryPage({
    required List<StockRow> rows,
    required int total,
    required double ms,
  }) = _InventoryPage;
}

@freezed
abstract class SearchResults with _$SearchResults {
  const factory SearchResults({
    required List<StockRow> rows,
    required int total,

    /// Query time in milliseconds.
    required double ms,

    /// True when the input matched a barcode exactly.
    @Default(false) bool exactBarcode,
  }) = _SearchResults;

  static const empty = SearchResults(rows: [], total: 0, ms: 0);
}

/// Add-medicine form payload (SPEC §5.3 dialog).
@freezed
abstract class NewProduct with _$NewProduct {
  const factory NewProduct({
    required String name,
    @Default('') String salt,
    @Default('') String form,
    required String maker,
    @Default('') String pack,

    /// Units per pack; [openingQty] is in units.
    @Default(1) int packSize,
    required String category,
    @Default('') String schedule,
    String? barcode,
    @Default('3004') String hsn,
    required int gstRate,
    required Paise mrp,
    @Default(20) int reorderLevel,
    @Default('') String rack,

    /// Packs (strips) in one stockist box; null = not known.
    int? packsPerBox,

    /// Optional first batch with opening stock.
    String? batchNo,
    String? expiry,
    @Default(0) int openingQty,
  }) = _NewProduct;
}

/// Edit-medicine form payload (SPEC §5.3). Units per pack is changed with
/// the "Sell loose" action, not here.
@freezed
abstract class ProductEdit with _$ProductEdit {
  const factory ProductEdit({
    required String name,
    @Default('') String salt,
    required String maker,
    @Default('') String pack,
    required String category,
    @Default('') String schedule,
    String? barcode,
    @Default('') String hsn,
    required int gstRate,
    required Paise mrp,
    required int reorderLevel,
    @Default('') String rack,

    /// Packs (strips) in one stockist box; null = not known.
    int? packsPerBox,
  }) = _ProductEdit;
}

@freezed
abstract class ReceiveResult with _$ReceiveResult {
  const factory ReceiveResult({
    required int batchId,
    required bool newBatch,
    required int newQty,
  }) = _ReceiveResult;
}
