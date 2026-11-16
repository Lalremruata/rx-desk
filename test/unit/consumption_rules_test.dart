import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/inventory/consumption_rules.dart';

/// Rows copied from the store's "Jan 2026" sheet (docs/Daily Sales.xlsx),
/// lead times 1 / 2 days, with the values Excel computed.
void main() {
  ConsumptionStats of(List<int> d) => ConsumptionStats.of(d, avgLeadDays: 1, maxLeadDays: 2);
  List<int> month(Map<int, int> m) => [for (var d = 1; d <= 31; d++) m[d] ?? 0];

  test('Syr. Moxcad Forte: 24 / 2.4 / 5 / 10 / 7.6 / 2.6', () {
    final s = of(month({5: 1, 7: 3, 12: 3, 14: 4, 15: 2, 16: 3, 17: 1, 23: 1, 28: 5, 30: 1}));
    expect((s.total, s.avgDaily, s.maxDaily, s.reorderLevel), (24, 2.4, 5, 10.0));
    expect(s.minStock, closeTo(7.6, 1e-9));
    expect(s.buffer, closeTo(2.6, 1e-9));
    expect(s.daysWithSales, 10);
  });

  test('Syr. Inclav 625: 260 / 16.25 / 30 / 60', () {
    final s = of(month({4: 20, 6: 10, 8: 20, 9: 20, 12: 20, 13: 30, 14: 10, 20: 30, 21: 10, 22: 10, 23: 20, 24: 10, 28: 10, 29: 10, 30: 20, 31: 10}));
    expect((s.total, s.avgDaily, s.maxDaily, s.reorderLevel), (260, 16.25, 30, 60.0));
    expect(s.minStock, closeTo(43.75, 1e-9));
    expect(s.buffer, closeTo(13.75, 1e-9));
  });

  test('Tab. Flagyl 400 (one big day): 840 / 168 / 750 / 1500 / 1332 / 582', () {
    final s = of(month({17: 30, 20: 15, 24: 15, 28: 30, 30: 750}));
    expect((s.total, s.avgDaily, s.maxDaily, s.reorderLevel, s.minStock, s.buffer), (840, 168.0, 750, 1500.0, 1332.0, 582.0));
  });

  test('no sales → zeros, not #DIV/0!', () {
    final s = of(month({}));
    expect((s.total, s.avgDaily, s.maxDaily, s.reorderLevel, s.minStock, s.buffer), (0, 0.0, 0, 0.0, 0.0, 0.0));
  });

  test('other lead times', () {
    final s = ConsumptionStats.of([4, 0, 2], avgLeadDays: 3, maxLeadDays: 5);
    expect((s.avgDaily, s.reorderLevel, s.minStock, s.buffer), (3.0, 20.0, 11.0, 3.0));
  });

  test('suggested reorder packs round up; months; formatting; validation', () {
    expect(suggestedReorderPacks(10, 1), 10);
    expect(suggestedReorderPacks(140, 10), 14);
    expect(suggestedReorderPacks(141, 10), 15);
    expect(suggestedReorderPacks(0, 10), 0);
    expect(daysInMonth('2026-02'), 28);
    expect(daysInMonth('2028-02'), 29);
    expect(daysInMonth('2026-01'), 31);
    expect(shiftMonth('2026-01', -1), '2025-12');
    expect(shiftMonth('2026-12', 1), '2027-01');
    expect([formatQty(2.4), formatQty(10), formatQty(7.6), formatQty(28.421052631), formatQty(0)], ['2.4', '10', '7.6', '28.42', '0']);
    expect(validateLeadTimes(avgDays: 1, maxDays: 2), isNull);
    expect(validateLeadTimes(avgDays: 3, maxDays: 2), isNotNull);
    expect(validateLeadTimes(avgDays: 0, maxDays: 2), isNotNull);
  });
}
