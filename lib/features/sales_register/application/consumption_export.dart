import '../../../core/inventory/consumption_rules.dart';
import 'consumption_controller.dart';
import 'register_export.dart';

const List<String> _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/// "November 2026" for 'YYYY-MM'.
String monthTitle(String month) => '${_months[int.parse(month.substring(5, 7)) - 1]} ${month.substring(0, 4)}';

/// The store's "Inventory Management Register" sheet layout: S.No · Name of
/// Medicine · days 1–31 · Total · Average · Maximum · Reorder · Minimum ·
/// Buffer. Blank cells for days without sales (as typed in the sheet).
ExportTable consumptionTable(
  List<ConsumptionLine> lines, {
  required String month,
  required String storeName,
  required int avgLead,
  required int maxLead,
}) {
  final n = daysInMonth(month);
  double r2(double v) => double.parse(v.toStringAsFixed(2));
  final dayTotals = List.filled(31, 0);
  for (final l in lines) {
    for (final e in l.row.daily.entries) {
      dayTotals[e.key - 1] += e.value;
    }
  }
  return ExportTable(
    title: 'Inventory Management Register',
    headerBlock: [
      'Inventory Management Register',
      'Average Lead Time (Days): $avgLead',
      'Maximum Lead Time (Days): $maxLead',
      'Store: $storeName',
      'Month and year: ${monthTitle(month)}',
    ],
    columns: [
      'S.No',
      'Name of Medicine',
      for (var d = 1; d <= 31; d++) '$d',
      'Total Consumption in a Month',
      'Average Daily Consumption',
      'Maximum Daily Consumption',
      'Reorder Level',
      'Minimum Stock Level',
      'Buffer Stock',
    ],
    rows: [
      for (final (i, l) in lines.indexed)
        [
          i + 1,
          l.row.name,
          for (var d = 1; d <= 31; d++)
            if (d > n || (l.row.daily[d] ?? 0) == 0) '' else l.row.daily[d]!,
          l.stats.total,
          r2(l.stats.avgDaily),
          l.stats.maxDaily,
          r2(l.stats.reorderLevel),
          r2(l.stats.minStock),
          r2(l.stats.buffer),
        ],
    ],
    totals: [
      '',
      'Total',
      for (var d = 1; d <= 31; d++)
        if (d > n || dayTotals[d - 1] == 0) '' else dayTotals[d - 1],
      lines.fold<int>(0, (a, l) => a + l.stats.total),
      '', '', '', '', '',
    ],
  );
}
