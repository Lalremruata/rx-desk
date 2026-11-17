import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/models.dart';
import 'package:rx_desk/core/inventory/stock_adjust.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/theme/tokens.dart';
import 'package:rx_desk/features/inventory/application/inventory_rules.dart';

final now = DateTime(2026, 11, 9, 12);
final ts = now.toUtc().millisecondsSinceEpoch;

StockRow row({int saleable = 50, int reorder = 20, bool expiring = false, int? lastSold, int? created}) => StockRow(
      id: 1,
      name: 'Med, "Special"',
      salt: 'Salt',
      form: '',
      category: 'Tablet',
      pack: 'Strip',
      manufacturerId: 1,
      maker: 'Maker',
      schedule: '',
      hsn: '3004',
      gstRate: 12,
      mrp: const Paise(3090),
      reorderLevel: reorder,
      rack: 'A1',
      createdAt: created ?? ts,
      lastSoldAt: lastSold,
      saleable: saleable,
      nearestExpiry: '2027-02',
      expiring: expiring,
      batchCount: 1,
    );

StockBatch batch(int id, String exp, int qty) =>
    StockBatch(id: id, productId: 1, batchNo: 'B$id', expiry: exp, qty: qty, createdAt: 0);

void main() {
  group('stockStatus (prototype precedence)', () {
    test('out beats everything', () => expect(stockStatus(row(saleable: 0, expiring: true), now: now, deadStockDays: 90).$1, 'Out of stock'));
    test('expiring before low', () => expect(stockStatus(row(saleable: 5, expiring: true), now: now, deadStockDays: 90).$1, 'Expiring'));
    test('low', () => expect(stockStatus(row(saleable: 20), now: now, deadStockDays: 90), ('Low stock', StatusTone.warning)));
    test('dead after N days without a sale', () {
      final old = now.subtract(const Duration(days: 120)).toUtc().millisecondsSinceEpoch;
      expect(stockStatus(row(lastSold: old), now: now, deadStockDays: 90).$1, 'Dead stock');
      expect(stockStatus(row(lastSold: old), now: now, deadStockDays: 180).$1, 'In stock');
      expect(stockStatus(row(created: old), now: now, deadStockDays: 90).$1, 'Dead stock'); // never sold
    });
    test('in stock', () => expect(stockStatus(row(), now: now, deadStockDays: 90), ('In stock', StatusTone.success)));
  });

  test('batch notes and FEFO', () {
    final bs = [batch(1, '2026-10', 5), batch(2, '2026-12', 0), batch(3, '2027-01', 4), batch(4, '2028-01', 9)];
    final fefo = fefoBatchId(bs, now);
    expect(fefo, 3);
    String note(StockBatch b) => batchNote(b, fefoBatchId: fefo, now: now, expiryWindowMonths: 3).$1;
    expect(bs.map(note), ['Expired · return to supplier', 'Sold out', 'Sell first (FEFO)', 'OK']);
    expect(batchNote(batch(5, '2027-02', 3), fefoBatchId: fefo, now: now, expiryWindowMonths: 3).$1, 'Near expiry');
  });

  test('expiry level colours', () {
    expect(expiryLevel('2026-12', now, 3), ExpiryLevel.critical);
    expect(expiryLevel('2027-02', now, 3), ExpiryLevel.near);
    expect(expiryLevel('2027-06', now, 3), ExpiryLevel.ok);
    expect(expiryLevel(null, now, 3), ExpiryLevel.ok);
  });

  test('parseExpiryInput', () {
    expect(parseExpiryInput('08/2027'), '2027-08');
    expect(parseExpiryInput('8/27'), '2027-08');
    expect(parseExpiryInput('2027-8'), '2027-08');
    expect(parseExpiryInput('12-2030'), '2030-12');
    expect(parseExpiryInput('13/2027'), isNull);
    expect(parseExpiryInput('nope'), isNull);
    expect(expiryToInput('2027-08'), '08/2027');
  });

  test('lastSoldLabel', () {
    expect(lastSoldLabel(null, now), 'never');
    expect(lastSoldLabel(ts, now), 'today');
    expect(lastSoldLabel(now.subtract(const Duration(days: 1)).toUtc().millisecondsSinceEpoch, now), 'yesterday');
    expect(lastSoldLabel(now.subtract(const Duration(days: 12)).toUtc().millisecondsSinceEpoch, now), '12 days ago');
  });

  test('stock bar fraction is stock vs 4 × reorder', () {
    expect(stockFraction(row(saleable: 40)), 0.5);
    expect(stockFraction(row(saleable: 0, reorder: 0)), 0);
  });

  test('CSV escapes quotes and commas, includes status', () {
    final csv = inventoryCsv([row()], now: now, deadStockDays: 90);
    final lines = csv.trim().split('\n');
    expect(lines.first, startsWith('Medicine,Salt,Pack,Maker'));
    expect(lines[1], startsWith('"Med, ""Special""",Salt,Strip,Maker,Tablet,,Feb 2027,50,20,30.90,12,3004,A1,,In stock'));
  });

  test('movement labels and stock-correction notes', () {
    expect(movementLabel('adjust'), 'Corrected');
    expect(movementLabel('supplier_return'), 'Returned to stockist');
    expect(movementLabel('mystery'), 'mystery');
    expect(adjustNote(StockAdjustReason.damaged, '  '), 'Damaged');
    expect(adjustNote(StockAdjustReason.other, ' fell behind rack '), 'Other: fell behind rack');
    expect(StockAdjustReason.other.needsNote, isTrue);
    expect(StockAdjustReason.count.needsNote, isFalse);
  });
}
