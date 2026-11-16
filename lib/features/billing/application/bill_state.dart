import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/db/models.dart';
import '../../../core/money/gst.dart';
import '../../../core/money/paise.dart';
import '../../../core/sales/bill_rules.dart';
import '../../../core/utils/pack.dart';

part 'bill_state.freezed.dart';

/// One line in the bill being built.
@freezed
abstract class BillLine with _$BillLine {
  const factory BillLine({
    required int productId,
    required int batchId,
    required String name,
    required String salt,
    required String maker,
    required String schedule,
    required String batchNo,
    required String expiry,
    required Paise mrp,
    required int gstRate,

    /// In units (tablets); a whole number of packs unless [loose].
    required int qty,

    /// Units available in the batch when added (cap for qty).
    required int maxQty,

    /// Units per pack (1 = not sold loose); MRP is per pack.
    @Default(1) int packSize,
    @Default('') String category,

    /// Qty is entered in loose units (Tab) instead of packs (Strip).
    @Default(false) bool loose,
  }) = _BillLine;

  const BillLine._();

  String get key => '$productId|$batchId';
  bool get isRx => isRxSchedule(schedule);
  bool get sellsLoose => packSize > 1;

  /// Units one step of the qty field stands for.
  int get step => loose ? 1 : packSize;

  /// The number in the qty field: packs, or loose units.
  int get shownQty => qty ~/ step;

  /// Things handed over (packs or loose units), for counts.
  int get count => sellsLoose ? shownQty : qty;

  /// Line total at MRP, pro-rata for loose units (SPEC §4.9).
  Paise get amount => proRataGross(mrp, qty, packSize);

  PackNouns get nouns => PackNouns.of(category);
}

/// What the search dropdown is showing.
sealed class DropMode {
  const DropMode();
}

class DropClosed extends DropMode {
  const DropClosed();
}

class DropResults extends DropMode {
  const DropResults(this.results);
  final SearchResults results;
}

class DropBatchPicker extends DropMode {
  const DropBatchPicker(this.product, this.options, this.expired);
  final StockRow product;
  final List<BatchOption> options;
  final List<BatchOption> expired;
}

class DropSubstitutes extends DropMode {
  const DropSubstitutes(this.product, this.substitutes);
  final StockRow product;
  final List<StockRow> substitutes;
}

@freezed
abstract class BillState with _$BillState {
  const factory BillState({
    @Default(<BillLine>[]) List<BillLine> lines,
    @Default('') String query,
    @Default(DropClosed()) DropMode drop,

    /// Highlighted row in the dropdown.
    @Default(0) int highlight,
    @Default('') String customer,
    @Default('') String phone,
    @Default('') String doctor,
    @Default(0) int discountPct,
    @Default('Cash') String payment,

    /// Credit bills (SPEC §4.10): rupees typed in "Paid now", and how.
    @Default('') String paidNow,
    @Default('Cash') String paidNowMode,

    /// Key of the line just added/incremented (flash) and a counter so the
    /// same line can flash again.
    String? lastAddedKey,
    @Default(0) int flashToken,
    @Default(false) bool saving,

    /// Bumped to ask the UI to focus the search box / customer field.
    @Default(0) int focusSearchToken,
    @Default(0) int focusCustomerToken,
  }) = _BillState;

  const BillState._();

  /// Packs + loose units on the bill (the sidebar badge).
  int get units => lines.fold(0, (a, l) => a + l.count);
  bool get hasRx => lines.any((l) => l.isRx);
  bool get isEmpty => lines.isEmpty;
  bool get isCredit => payment == creditMode;

  /// Paid now, in paise (0 when blank or not a Credit bill).
  Paise get paidNowPaise => isCredit ? (Paise.tryParse(paidNow) ?? Paise.zero) : Paise.zero;

  int qtyInBill(int batchId) => lines.where((l) => l.batchId == batchId).fold(0, (a, l) => a + l.qty);
}
