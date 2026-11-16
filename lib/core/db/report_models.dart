import 'package:freezed_annotation/freezed_annotation.dart';

import '../money/paise.dart';

part 'report_models.freezed.dart';

/// Group-by options (SPEC §5.5).
enum RegisterGroup {
  none('No grouping (item lines)'),
  day('Day'),
  medicine('Medicine'),
  maker('Maker'),
  category('Category'),
  hsn('HSN + rate'),
  gst('GST rate'),
  payment('Payment'),
  doctor('Doctor');

  const RegisterGroup(this.label);
  final String label;
}

/// Schedule filter: All, H + H1, H, H1, Non-Rx.
enum ScheduleFilter {
  all('All'),
  rx('H + H1'),
  h('H only'),
  h1('H1 only'),
  none('Non-Rx');

  const ScheduleFilter(this.label);
  final String label;

  bool get isRxRegister => this == rx || this == h || this == h1;
}

/// Line sorts: date, qty, net. Group sorts: key, units, net.
enum RegisterSort { date, qty, net, key, units }

@freezed
abstract class RegisterFilter with _$RegisterFilter {
  const factory RegisterFilter({
    /// Inclusive 'YYYY-MM-DD'.
    required String from,
    required String to,
    @Default('') String search,
    String? maker,
    String? category,
    @Default(ScheduleFilter.all) ScheduleFilter schedule,
    String? payment,

    /// '(No prescription)' selects lines without a doctor.
    String? doctor,
    @Default(RegisterGroup.none) RegisterGroup group,
    @Default(RegisterSort.date) RegisterSort sort,
    @Default(true) bool descending,
  }) = _RegisterFilter;

  const RegisterFilter._();

  bool get hasFilters =>
      search.trim().isNotEmpty || maker != null || category != null || schedule != ScheduleFilter.all || payment != null || doctor != null;
}

/// Totals for the whole filtered set (one aggregate query).
@freezed
abstract class RegisterTotals with _$RegisterTotals {
  const factory RegisterTotals({
    @Default(0) int lines,
    @Default(0) int bills,
    @Default(0) int units,
    @Default(Paise.zero) Paise gross,
    @Default(Paise.zero) Paise discount,
    @Default(Paise.zero) Paise taxable,
    @Default(Paise.zero) Paise tax,
    @Default(Paise.zero) Paise net,
  }) = _RegisterTotals;

  const RegisterTotals._();

  /// Same split rule as a bill: CGST gets the floor half.
  Paise get cgst => Paise(tax.value ~/ 2);
  Paise get sgst => tax - cgst;
}

/// One item sold (snapshot fields + bill fields).
@freezed
abstract class RegisterLine with _$RegisterLine {
  const factory RegisterLine({
    required int id,
    required int invoiceId,
    required String saleDate,
    required int createdAt,
    required String billNo,
    required String customer,
    String? doctor,
    required String medicine,
    required String salt,
    required String maker,
    required String schedule,
    required String hsn,
    required String batchNo,

    /// Units; [packSize] is the snapshot when sold (MRP is per pack).
    required int qty,
    @Default(1) int packSize,
    @Default('') String category,
    required Paise mrp,
    required Paise discount,
    required Paise taxable,
    required int gstRate,
    required Paise net,
    required String payment,

    /// Sort value used for keyset paging.
    required Object sortValue,
  }) = _RegisterLine;
}

@freezed
abstract class RegisterGroupRow with _$RegisterGroupRow {
  const factory RegisterGroupRow({
    required String key,
    required String label,
    required int bills,
    required int units,
    required Paise gross,
    required Paise taxable,
    required Paise tax,
    required Paise net,
  }) = _RegisterGroupRow;
}

/// Keyset cursor for register lines: (sort value, line id).
class RegisterCursor {
  const RegisterCursor(this.value, this.id);
  final Object value;
  final int id;
}

class RegisterLinesPage {
  const RegisterLinesPage({required this.rows, required this.hasMore, required this.ms});
  final List<RegisterLine> rows;
  final bool hasMore;
  final double ms;
}

class RegisterGroupsPage {
  const RegisterGroupsPage({required this.rows, required this.total, required this.ms});
  final List<RegisterGroupRow> rows;
  final int total;
  final double ms;
}
