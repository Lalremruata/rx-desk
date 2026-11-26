import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/money/gst.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/utils/pack.dart';

void main() {
  test('pack summary: box, strip and tablets as one picture', () {
    expect(packSummary(PackNouns.tablet, packSize: 10, packsPerBox: 20), '1 box = 20 strips = 200 tabs');
    expect(packSummary(PackNouns.tablet, packSize: 1, packsPerBox: 1), '1 box = 1 strip');
    expect(packSummary(PackNouns.other, packSize: 1, packsPerBox: 12), '1 box = 12 packs');
    expect(packSummary(PackNouns.capsule, packSize: 15), '1 strip = 15 caps, sold by the strip or the cap');
    expect(packSummary(PackNouns.tablet, packSize: 1), isNull);
    expect(packSummary(PackNouns.tablet, packSize: 1, packsPerBox: 0), isNull);
  });

  group('formatting (SPEC §4.9)', () {
    test('packs and loose units', () {
      expect(formatPackQty(124, 10, 'Tablet'), '12 strips + 4 tabs');
      expect(formatPackQty(10, 10, 'Tablet'), '1 strip');
      expect(formatPackQty(1, 10, 'Tablet'), '1 tab');
      expect(formatPackQty(0, 10, 'Tablet'), '0 strips');
      expect(formatPackQty(37, 15, 'Capsule'), '2 strips + 7 caps');
      expect(formatPackQty(12, 6, 'OTC'), '2 packs');
      expect(formatPackQty(-15, 10, 'Tablet'), '−1 strip + 5 tabs');
      expect(formatPackQty(123456, 1, 'Syrup'), '1,23,456');
    });

    test('compact form for tables', () {
      expect(compactPackQty(20, 10, 'Tablet'), '2');
      expect(compactPackQty(5, 10, 'Tablet'), '5 tab');
      expect(compactPackQty(15, 10, 'Tablet'), '1 + 5 tab');
      expect(compactPackQty(-15, 10, 'Tablet'), '−1 + 5 tab');
      expect(compactPackQty(-3, 1, 'Syrup'), '−3');
      expect(compactPackQty(7, 1, 'Syrup'), '7');
    });

    test('nouns and labels', () {
      expect(PackNouns.of('Tablet').sizeLabel, 'Tablets per strip');
      expect(PackNouns.of('Capsule').sizeLabel, 'Capsules per strip');
      expect(PackNouns.of('Syrup').sizeLabel, 'Units per pack');
    });
  });

  test('splitPack / unitsFrom', () {
    expect(splitPack(124, 10), (12, 4));
    expect(splitPack(-124, 10), (-12, -4));
    expect(splitPack(7, 1), (7, 0));
    expect(unitsFrom(packs: 2, loose: 3, packSize: 10), 23);
    expect(unitsFrom(packs: 2, loose: 10, packSize: 10), isNull);
    expect(unitsFrom(packs: -1, packSize: 10), isNull);
    expect(unitsFrom(packs: 4, packSize: 1), 4);
  });

  test('suggestPackSize reads the pack text for tablets and capsules only', () {
    expect(suggestPackSize('Strip of 10', 'Tablet'), 10);
    expect(suggestPackSize('strip of 15 caps', 'Capsule'), 15);
    expect(suggestPackSize('10 tablets', 'Tablet'), 10);
    expect(suggestPackSize('Box of 10×10', 'Tablet'), 1);
    expect(suggestPackSize('Strip of 10', 'Syrup'), 1);
    expect(suggestPackSize('Bottle', 'Tablet'), 1);
  });

  group('pro-rata price', () {
    test('rounds down to the paisa, never above MRP; whole strips exact', () {
      // ₹30.90 strip of 10 → ₹3.09 a tablet.
      expect(proRataGross(const Paise(3090), 1, 10), const Paise(309));
      expect(proRataGross(const Paise(3090), 10, 10), const Paise(3090));
      expect(proRataGross(const Paise(3090), 25, 10), const Paise(7725));
      // ₹45.00 strip of 15 → 3 tabs = ₹9.00; 1 tab = 300 paise exactly.
      expect(proRataGross(const Paise(4500), 1, 15), const Paise(300));
      // ₹22.00 strip of 15: 1 tab = 146.67 → 146 (down).
      expect(proRataGross(const Paise(2200), 1, 15), const Paise(146));
      expect(proRataGross(const Paise(2200), 15, 15), const Paise(2200));
      // Mirrors for negatives (credit notes).
      expect(proRataGross(const Paise(2200), -1, 15), const Paise(-146));
      for (var n = 1; n <= 45; n++) {
        final g = proRataGross(const Paise(2200), n, 15).value;
        expect(g * 15, lessThanOrEqualTo(2200 * n), reason: '$n tabs');
        expect(2200 * n - g * 15, lessThan(15), reason: '$n tabs');
      }
    });

    test('computeLine uses pro-rata gross, then discount and GST as usual', () {
      final a = computeLine(mrp: const Paise(3090), qty: 5, discountPct: 10, gstRate: 12, packSize: 10);
      expect(a.gross, const Paise(1545));
      expect(a.discount, const Paise(155)); // 154.5 → 155
      expect(a.net, const Paise(1390));
      expect(a.taxable.value + a.tax.value, a.net.value);
      final whole = computeLine(mrp: const Paise(3090), qty: 20, discountPct: 10, gstRate: 12, packSize: 10);
      final strips = computeLine(mrp: const Paise(3090), qty: 2, discountPct: 10, gstRate: 12);
      expect((whole.gross, whole.net, whole.tax), (strips.gross, strips.net, strips.tax));
    });
  });
}
