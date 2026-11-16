import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/daos/reports_dao.dart';
import 'package:rx_desk/features/sales_register/application/consumption_controller.dart';
import 'package:rx_desk/features/sales_register/application/consumption_export.dart';
import 'package:rx_desk/features/sales_register/application/register_export.dart';

void main() {
  test('export follows the sheet: S.No, name, days 1–31 (blank = none), totals and the five figures', () {
    const rows = [
      ConsumptionRow(productId: 1, name: 'Syr. Moxcad Forte', category: 'Syrup', unitsPerPack: 1, reorderLevel: 20, saleable: 12, daily: {5: 1, 7: 3, 12: 3, 14: 4, 15: 2, 16: 3, 17: 1, 23: 1, 28: 5, 30: 1}),
      ConsumptionRow(productId: 2, name: 'Tab. Pantop', category: 'Tablet', unitsPerPack: 10, reorderLevel: 5, saleable: 400, daily: {1: 10}),
    ];
    final lines = consumptionLines(rows, month: '2026-01', avgLead: 1, maxLead: 2);
    expect(lines.map((l) => l.suggested), [10, 2]);
    final t = consumptionTable(lines, month: '2026-01', storeName: 'Kulikawn SDH', avgLead: 1, maxLead: 2);
    expect(t.headerBlock, contains('Month and year: January 2026'));
    expect(t.columns.take(4), ['S.No', 'Name of Medicine', '1', '2']);
    expect(t.columns.length, 2 + 31 + 6);
    final moxcad = t.rows.first;
    expect(moxcad.sublist(0, 2), [1, 'Syr. Moxcad Forte']);
    expect(moxcad[2 + 4], 1); // day 5
    expect(moxcad[2 + 5], ''); // day 6 blank
    expect(moxcad.sublist(33), [24, 2.4, 5, 10.0, 7.6, 2.6]);
    expect(t.totals[2], 10); // day 1 total
    expect(t.totals[33], 34);
    expect(buildCsv(t).split('\n')[6], startsWith('S.No,Name of Medicine,1,2,3'));
    // February has no 29–31 columns filled.
    final feb = consumptionTable(consumptionLines(rows, month: '2026-02', avgLead: 1, maxLead: 2), month: '2026-02', storeName: 'S', avgLead: 1, maxLead: 2);
    expect(feb.rows.first.sublist(30, 33), ['', '', '']);
  });
}
