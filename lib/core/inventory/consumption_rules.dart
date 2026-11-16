/// Monthly consumption register (SPEC §4.12) — the store's "Inventory
/// Management Register" sheet, computed from sales. Pure Dart.
///
/// Quantities are units (tablets for loose-sold products, else packs); the
/// derived figures are `double` because they are averages of quantities —
/// never money.
library;

/// One medicine's month, with the sheet's formulas:
///
/// - Total = Σ daily
/// - Average daily = Excel `AVERAGE(days)`, which skips blank days → the
///   average over days that had sales
/// - Max daily = `MAX(days)`
/// - Reorder level = max daily × max lead time
/// - Minimum stock = reorder level − average daily × average lead time
/// - Buffer stock = (max daily − average daily) × average lead time
///
/// A month without sales is all zeros (the sheet shows `#DIV/0!`).
class ConsumptionStats {
  const ConsumptionStats({
    required this.total,
    required this.daysWithSales,
    required this.avgDaily,
    required this.maxDaily,
    required this.reorderLevel,
    required this.minStock,
    required this.buffer,
  });

  factory ConsumptionStats.of(Iterable<int> daily, {required int avgLeadDays, required int maxLeadDays}) {
    var total = 0, days = 0;
    int? max;
    for (final q in daily) {
      if (q == 0) continue; // blank cell in the sheet
      total += q;
      days++;
      if (max == null || q > max) max = q;
    }
    if (days == 0) return empty;
    final avg = total / days;
    final reorder = (max! * maxLeadDays).toDouble();
    return ConsumptionStats(
      total: total,
      daysWithSales: days,
      avgDaily: avg,
      maxDaily: max,
      reorderLevel: reorder,
      minStock: reorder - avg * avgLeadDays,
      buffer: (max - avg) * avgLeadDays,
    );
  }

  static const ConsumptionStats empty =
      ConsumptionStats(total: 0, daysWithSales: 0, avgDaily: 0, maxDaily: 0, reorderLevel: 0, minStock: 0, buffer: 0);

  final int total;
  final int daysWithSales;
  final double avgDaily;
  final int maxDaily;
  final double reorderLevel;
  final double minStock;
  final double buffer;
}

/// `products.reorder_level` is in packs (SPEC §4.9): round the unit level
/// up to whole packs. 0 when nothing was sold.
int suggestedReorderPacks(double reorderUnits, int unitsPerPack) {
  if (reorderUnits <= 0) return 0;
  final size = unitsPerPack < 1 ? 1 : unitsPerPack;
  return (reorderUnits / size).ceil();
}

/// Days in 'YYYY-MM'.
int daysInMonth(String month) {
  final y = int.parse(month.substring(0, 4)), m = int.parse(month.substring(5, 7));
  return DateTime(y, m + 1, 0).day;
}

/// 'YYYY-MM' moved by [delta] months.
String shiftMonth(String month, int delta) {
  final y = int.parse(month.substring(0, 4)), m = int.parse(month.substring(5, 7));
  final d = DateTime(y, m + delta);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
}

/// Shows a derived figure like the sheet: up to 2 decimals, no trailing
/// zeros ("2.4", "7.6", "10").
String formatQty(double v) {
  final s = v.toStringAsFixed(2);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

/// Validates the lead-time settings; null when fine.
String? validateLeadTimes({required int avgDays, required int maxDays}) {
  if (avgDays < 1 || avgDays > 60 || maxDays < 1 || maxDays > 60) return 'Lead times are 1–60 days.';
  if (maxDays < avgDays) return 'Maximum lead time can’t be less than the average.';
  return null;
}
