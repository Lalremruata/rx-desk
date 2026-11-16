import '../../../core/db/daos/reports_dao.dart';
import '../../../core/money/paise.dart';
import '../../../core/utils/expiry.dart';

enum ChartRange {
  d7('7D'),
  d30('30D'),
  m12('12M');

  const ChartRange(this.label);
  final String label;
}

class ChartBar {
  const ChartBar({required this.label, required this.axis, required this.value});

  /// Tooltip label: "Mon 3 Nov" / "Today (so far)" / "Nov 2026 (to date)".
  final String label;

  /// Axis label ('' to skip).
  final String axis;
  final Paise value;
}

class ChartSeries {
  const ChartSeries({required this.bars, required this.niceMax, required this.total, required this.average, required this.peak});

  final List<ChartBar> bars;

  /// Rounded-up axis maximum (paise).
  final int niceMax;
  final Paise total;
  final Paise average;
  final Paise peak;

  /// First calendar day the series covers ('YYYY-MM-DD').
  static String startKey(ChartRange r, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return switch (r) {
      ChartRange.d7 => dateKey(today.subtract(const Duration(days: 6))),
      ChartRange.d30 => dateKey(today.subtract(const Duration(days: 29))),
      ChartRange.m12 => dateKey(DateTime(now.year, now.month - 11)),
    };
  }
}

const _dows = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Bars for the Sales overview chart from daily-summary rows (SPEC §5.1;
/// prototype dashboard). The last bar is today / this month.
ChartSeries buildChartSeries(ChartRange range, List<DaySales> days, DateTime now) {
  final byDay = {for (final d in days) d.day: d.net.value};
  final today = DateTime(now.year, now.month, now.day);
  final bars = <ChartBar>[];
  if (range == ChartRange.m12) {
    for (var i = 11; i >= 0; i--) {
      final m = DateTime(now.year, now.month - i);
      final key = monthKey(m);
      final v = byDay.entries.where((e) => e.key.startsWith(key)).fold<int>(0, (a, e) => a + e.value);
      bars.add(ChartBar(label: '${monthName(m.month)} ${m.year}${i == 0 ? ' (to date)' : ''}', axis: monthName(m.month), value: Paise(v)));
    }
  } else {
    final n = range == ChartRange.d7 ? 7 : 30;
    for (var i = n - 1; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      final v = byDay[dateKey(d)] ?? 0;
      final label = i == 0 ? 'Today (so far)' : '${_dows[d.weekday - 1]} ${d.day} ${monthName(d.month)}';
      final axis = n == 7
          ? (i == 0 ? 'Today' : _dows[d.weekday - 1])
          : ((n - 1 - i) % 5 == 0 ? '${d.day} ${monthName(d.month)}' : '');
      bars.add(ChartBar(label: label, axis: axis, value: Paise(v)));
    }
  }
  final total = bars.fold<int>(0, (a, b) => a + b.value.value);
  final peak = bars.fold<int>(0, (a, b) => b.value.value > a ? b.value.value : a);
  // Nice axis max: ₹2,000 steps for days, ₹50,000 for months (prototype).
  final step = range == ChartRange.m12 ? 5000000 : 200000;
  final raw = (peak * 1.08).ceil();
  final niceMax = raw <= step ? step : ((raw + step - 1) ~/ step) * step;
  return ChartSeries(
    bars: bars,
    niceMax: niceMax,
    total: Paise(total),
    average: Paise(bars.isEmpty ? 0 : (total / bars.length).round()),
    peak: Paise(peak),
  );
}
