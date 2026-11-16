import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/daos/reports_dao.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/features/dashboard/application/chart_series.dart';

void main() {
  final now = DateTime(2026, 11, 9, 14);

  test('7D: seven bars ending today, gaps are zero', () {
    final s = buildChartSeries(ChartRange.d7, const [DaySales('2026-11-03', Paise(612000)), DaySales('2026-11-09', Paise(150000))], now);
    expect(s.bars, hasLength(7));
    expect(s.bars.first.label, 'Tue 3 Nov');
    expect(s.bars.first.axis, 'Tue');
    expect(s.bars.last.label, 'Today (so far)');
    expect(s.bars.last.axis, 'Today');
    expect(s.bars[1].value, Paise.zero);
    expect(s.total, const Paise(762000));
    expect(s.peak, const Paise(612000));
    expect(s.average, const Paise(108857));
    expect(s.niceMax, 800000); // 6,120 × 1.08 → ₹8k
    expect(ChartSeries.startKey(ChartRange.d7, now), '2026-11-03');
  });

  test('30D labels every fifth day', () {
    final s = buildChartSeries(ChartRange.d30, const [], now);
    expect(s.bars, hasLength(30));
    expect(s.bars.where((b) => b.axis.isNotEmpty), hasLength(6));
    expect(s.niceMax, 200000); // minimum one step
  });

  test('12M sums days into months, last is "to date"', () {
    final s = buildChartSeries(
      ChartRange.m12,
      const [DaySales('2025-12-01', Paise(100)), DaySales('2025-12-31', Paise(200)), DaySales('2026-11-09', Paise(50))],
      now,
    );
    expect(s.bars, hasLength(12));
    expect(s.bars.first.label, 'Dec 2025');
    expect(s.bars.first.value, const Paise(300));
    expect(s.bars.last.label, 'Nov 2026 (to date)');
    expect(ChartSeries.startKey(ChartRange.m12, now), '2025-12-01');
  });
}
