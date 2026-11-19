import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/fy/fy.dart';
import 'package:rx_desk/core/money/gst.dart';
import 'package:rx_desk/core/money/paise.dart';

LineAmounts line(int mrpPaise, int qty, {int disc = 0, int gst = 12, bool reg = true}) =>
    computeLine(mrp: Paise(mrpPaise), qty: qty, discountPct: disc, gstRate: gst, gstRegistered: reg);

void main() {
  group('computeLine (SPEC §4.1, MRP incl. GST)', () {
    test('12 %: ₹30.90 × 2, no discount', () {
      final a = line(3090, 2);
      expect(a.gross, const Paise(6180));
      expect(a.discount, Paise.zero);
      expect(a.net, const Paise(6180));
      expect(a.taxable, const Paise(5518)); // 6180 × 100/112 = 5517.86 → 5518
      expect(a.tax, const Paise(662));
    });

    test('0 %: taxable = net, tax 0', () {
      final a = line(10000, 3, gst: 0);
      expect(a.taxable, const Paise(30000));
      expect(a.tax, Paise.zero);
    });

    test('5 %: ₹21 sachet × 7', () {
      final a = line(2100, 7, gst: 5);
      expect(a.net, const Paise(14700));
      expect(a.taxable, const Paise(14000)); // exact
      expect(a.tax, const Paise(700));
    });

    test('18 %: ₹249 × 1', () {
      final a = line(24900, 1, gst: 18);
      expect(a.taxable, const Paise(21102)); // 21101.69 → 21102
      expect(a.tax, const Paise(3798));
    });

    for (final d in [0, 5, 10, 15, 20]) {
      test('discount $d % on ₹98.50 × 3 @12 %', () {
        final a = line(9850, 3, disc: d);
        const gross = 29550;
        final disc = (gross * d / 100).round();
        expect(a.gross.value, gross);
        expect(a.discount.value, disc);
        expect(a.net.value, gross - disc);
        expect(a.taxable.value, ((gross - disc) * 100 / 112).round());
        expect(a.tax.value + a.taxable.value, a.net.value);
      });
    }

    test('discount rounds half up: 5 % of ₹0.50 = 2.5 paise → 3', () {
      expect(line(50, 1, disc: 5).discount, const Paise(3));
    });

    test('1-paisa line', () {
      final a = line(1, 1);
      expect(a.net, const Paise(1));
      expect(a.taxable, const Paise(1)); // 0.89 → 1
      expect(a.tax, Paise.zero);
    });

    test('bill of supply (not GST registered) stores tax 0', () {
      final a = line(3090, 2, reg: false);
      expect(a.taxable, a.net);
      expect(a.tax, Paise.zero);
    });

    test('divRound is symmetric for negatives (returns mirror sales)', () {
      expect(divRound(250, 100), 3);
      expect(divRound(-250, 100), -3);
      expect(divRound(249, 100), 2);
      expect(divRound(-249, 100), -2);
    });
  });

  group('computeBill', () {
    test('sums per-line rounded values, odd paisa goes to SGST', () {
      final a = line(3090, 2); // tax 662
      final b = line(2200, 1); // 2200 → taxable 1964 (1964.29), tax 236
      final t = computeBill([(a, 2), (b, 1)], roundOff: false);
      expect(t.items, 2);
      expect(t.units, 3);
      expect(t.subtotal, const Paise(8380));
      expect(t.tax, a.tax + b.tax);
      expect(t.cgst + t.sgst, t.tax);
      expect(t.sgst.value - t.cgst.value, anyOf(0, 1));
      expect(t.total, t.net);
      expect(t.roundOff, Paise.zero);
    });

    test('odd tax: 899 → CGST 449, SGST 450', () {
      expect(splitTax(const Paise(899)), (const Paise(449), const Paise(450)));
      expect(splitTax(const Paise(900)), (const Paise(450), const Paise(450)));
    });

    test('round-off down: ₹123.40 → ₹123.00, round off −₹0.40', () {
      final t = computeBill([(line(12340, 1), 1)], roundOff: true);
      expect(t.total, const Paise(12300));
      expect(t.roundOff, const Paise(-40));
    });

    test('round-off up: ₹123.60 → ₹124.00, round off +₹0.40', () {
      final t = computeBill([(line(12360, 1), 1)], roundOff: true);
      expect(t.total, const Paise(12400));
      expect(t.roundOff, const Paise(40));
    });

    test('round-off at exactly 50 paise rounds up', () {
      expect(computeBill([(line(12350, 1), 1)], roundOff: true).total, const Paise(12400));
    });

    test('empty bill', () {
      final t = computeBill(const [], roundOff: true);
      expect(t.total, Paise.zero);
      expect(t.items, 0);
    });
  });

  group('Paise', () {
    test('tryParse', () {
      expect(Paise.tryParse('30.9'), const Paise(3090));
      expect(Paise.tryParse('₹1,234.50'), const Paise(123450));
      expect(Paise.tryParse('1,00,000'), const Paise(10000000));
      expect(Paise.tryParse('.5'), const Paise(50));
      expect(Paise.tryParse('-2'), const Paise(-200));
      expect(Paise.tryParse('1.234'), isNull);
      expect(Paise.tryParse('abc'), isNull);
      expect(Paise.tryParse(''), isNull);
    });

    test('formatInr uses ₹ and lakh grouping', () {
      expect(formatInr(const Paise(123456789)), '₹12,34,567.89');
      expect(formatInr(const Paise(5)), '₹0.05');
      expect(formatInr(const Paise(-4000)), '−₹40.00');
      expect(formatInr(const Paise(123456), decimals: 0), '₹1,235');
    });

    test('formatInrShort', () {
      expect(formatInrShort(const Paise(95000)), '₹950');
      expect(formatInrShort(const Paise(800000)), '₹8k');
      expect(formatInrShort(const Paise(25000000)), '₹2.5L');
      expect(formatInrShort(const Paise(1200000000)), '₹1.2Cr');
    });

    test('toInputString', () {
      expect(const Paise(3090).toInputString(), '30.90');
      expect(const Paise(5).toInputString(), '0.05');
    });
  });

  group('financial year (SPEC §4.2)', () {
    test('label', () {
      expect(fyLabel(DateTime(2026, 4)), '26-27');
      expect(fyLabel(DateTime(2027, 3, 31, 23, 59)), '26-27');
      expect(fyLabel(DateTime(2027, 4)), '27-28');
      expect(fyLabel(DateTime(2026, 11, 9)), '26-27');
      expect(fyLabel(DateTime(2026, 1, 15)), '25-26');
      expect(fyLabel(DateTime(2099, 6)), '99-00');
    });

    test('number formats from the spec', () {
      expect(const InvoiceNumberFormat().format(fy: '26-27', seq: 412), 'INV/26-27/00412');
      expect(
        const InvoiceNumberFormat(separator: InvoiceSeparator.dash, digits: 4).format(fy: '26-27', seq: 412),
        'INV-26-27-0412',
      );
      expect(
        const InvoiceNumberFormat(separator: InvoiceSeparator.none, fyInNumber: false).format(fy: '26-27', seq: 412),
        'INV00412',
      );
      expect(const InvoiceNumberFormat(prefix: '').format(fy: '26-27', seq: 7), '26-27/00007');
    });

    test('sequence key: per FY only when FY is in the number', () {
      expect(const InvoiceNumberFormat().seqKey('26-27'), '26-27');
      expect(const InvoiceNumberFormat(fyInNumber: false).seqKey('26-27'), 'all');
    });
  });

  group('flat ₹ discount (SPEC §4.6)', () {
    test('allocateFlatDiscount: largest remainder, sums exactly', () {
      // floors 33/54/11 (=98); remainders 18060, 3280, 15020 → +1 to lines 0 and 2.
      expect(allocateFlatDiscount(100, [6180, 9850, 2150]), [34, 54, 12]);
      expect(allocateFlatDiscount(1, [100, 100]), [1, 0]); // tie → earlier line
      expect(allocateFlatDiscount(3, [1, 1, 1]), [1, 1, 1]);
      expect(allocateFlatDiscount(10, [0, 100]), [0, 10]);
      expect(allocateFlatDiscount(300, [100, 200]), [100, 200]); // whole bill
      expect(allocateFlatDiscount(0, [100, 200]), [0, 0]);
      expect(allocateFlatDiscount(5, const []), isEmpty);
    });

    test('allocation never exceeds a line and always sums to the amount', () {
      final grosses = [1, 7, 333, 3090, 12, 99999, 5];
      final total = grosses.fold(0, (a, g) => a + g);
      for (final amt in [1, 2, 17, 999, 50000, total - 1, total]) {
        final s = allocateFlatDiscount(amt, grosses);
        expect(s.fold(0, (a, x) => a + x), amt, reason: '$amt');
        for (var i = 0; i < grosses.length; i++) {
          expect(s[i], inInclusiveRange(0, grosses[i]), reason: '$amt line $i');
        }
      }
    });

    test('discountedLines with a % matches computeLine exactly', () {
      final lines = [
        (mrp: const Paise(3090), qty: 3, gstRate: 12, packSize: 1),
        (mrp: const Paise(9850), qty: 5, gstRate: 5, packSize: 10),
      ];
      final got = discountedLines(lines, const PercentDiscount(10));
      expect(got.map((a) => '$a'), [
        '${computeLine(mrp: const Paise(3090), qty: 3, discountPct: 10, gstRate: 12)}',
        '${computeLine(mrp: const Paise(9850), qty: 5, discountPct: 10, gstRate: 5, packSize: 10)}',
      ]);
    });

    test('flat ₹ across 5 / 12 / 18 % lines: Σdiscount = amount, GST backwards per line', () {
      final lines = [
        (mrp: const Paise(1050), qty: 1, gstRate: 5, packSize: 1),
        (mrp: const Paise(1120), qty: 1, gstRate: 12, packSize: 1),
        (mrp: const Paise(1180), qty: 1, gstRate: 18, packSize: 1),
      ];
      final got = discountedLines(lines, const FlatDiscount(Paise(300)));
      expect(got.fold(0, (a, l) => a + l.discount.value), 300);
      expect(got.map((l) => l.discount.value), [94, 100, 106]); // 3350 split by MRP
      for (final (i, l) in got.indexed) {
        final rate = lines[i].gstRate;
        expect(l.net.value, l.gross.value - l.discount.value);
        expect(l.taxable.value, divRound(l.net.value * 100, 100 + rate));
        expect(l.tax.value, l.net.value - l.taxable.value);
      }
      final t = computeBill([for (final l in got) (l, 1)], roundOff: true);
      expect(t.subtotal.value, 3350);
      expect(t.discount.value, 300);
      expect(t.net.value, 3050);
    });

    test('a flat amount above the bill is held to the bill; bill of supply has no tax', () {
      final lines = [(mrp: const Paise(500), qty: 1, gstRate: 12, packSize: 1)];
      expect(discountedLines(lines, const FlatDiscount(Paise(900))).single.net.value, 0);
      final bos = discountedLines(lines, const FlatDiscount(Paise(50)), gstRegistered: false).single;
      expect((bos.net.value, bos.taxable.value, bos.tax.value), (450, 450, 0));
    });

    test('labels', () {
      expect(const PercentDiscount(7).label, '7%');
      expect(const FlatDiscount(Paise(2500)).label, '₹25.00');
      expect(const FlatDiscount(Paise.zero).isZero, isTrue);
    });
  });
}
