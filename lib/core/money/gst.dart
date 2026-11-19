import 'paise.dart';

/// Integer division rounding half away from zero (like `Math.round` for
/// positive values; symmetric for negatives so returns mirror sales).
int divRound(int numerator, int denominator) {
  assert(denominator > 0, 'denominator must be positive');
  final neg = numerator < 0;
  final n = numerator.abs();
  final q = (2 * n + denominator) ~/ (2 * denominator);
  return neg ? -q : q;
}

/// One bill line's amounts (SPEC §4.1). MRP includes GST; tax is worked
/// backwards and rounded per line to the paisa.
class LineAmounts {
  const LineAmounts({
    required this.gross,
    required this.discount,
    required this.net,
    required this.taxable,
    required this.tax,
  });

  final Paise gross;
  final Paise discount;
  final Paise net;
  final Paise taxable;
  final Paise tax;

  @override
  String toString() => 'LineAmounts(gross: $gross, disc: $discount, net: $net, taxable: $taxable, tax: $tax)';
}

/// ```
/// gross    = mrp × qty                      (whole packs)
/// gross    = floor(mrp × qty ÷ pack_size)   (loose units, never above MRP)
/// discount = round(gross × discount_pct / 100)   (flat ₹: see [discountedLines])
/// net      = gross − discount
/// taxable  = round(net × 100 / (100 + gst_rate))
/// tax      = net − taxable
/// ```
/// [qty] is in the smallest unit (tablets) and [mrp] is per pack of
/// [packSize] units; with packSize 1 the unit is the pack. When
/// [gstRegistered] is false (bill of supply) tax is 0 and taxable = net.
LineAmounts computeLine({
  required Paise mrp,
  required int qty,
  required int discountPct,
  required int gstRate,
  bool gstRegistered = true,
  int packSize = 1,
}) {
  assert(discountPct >= 0 && discountPct <= 100, 'discount % out of range');
  assert(gstRate >= 0, 'gst rate must be ≥ 0');
  assert(packSize >= 1, 'pack size must be ≥ 1');
  final gross = proRataGross(mrp, qty, packSize).value;
  return lineFromGross(
    gross: Paise(gross),
    discount: Paise(divRound(gross * discountPct, 100)),
    gstRate: gstRate,
    gstRegistered: gstRegistered,
  );
}

/// The rest of SPEC §4.1 once a line's gross and discount are known:
/// net = gross − discount, GST worked backwards from net and rounded per line.
LineAmounts lineFromGross({
  required Paise gross,
  required Paise discount,
  required int gstRate,
  bool gstRegistered = true,
}) {
  final net = gross.value - discount.value;
  final taxable = gstRegistered ? divRound(net * 100, 100 + gstRate) : net;
  return LineAmounts(
    gross: gross,
    discount: discount,
    net: Paise(net),
    taxable: Paise(taxable),
    tax: Paise(net - taxable),
  );
}

// ---------------------------------------------------------------------------
// Bill-level discount (SPEC §4.6)

/// A bill's discount: a whole percentage applied to every line, or a flat
/// rupee amount split across the lines in proportion to their MRP value.
sealed class BillDiscount {
  const BillDiscount();

  bool get isZero;

  /// "10%" / "₹25.00".
  String get label;
}

final class PercentDiscount extends BillDiscount {
  const PercentDiscount(this.pct);

  final int pct;

  @override
  bool get isZero => pct == 0;

  @override
  String get label => '$pct%';

  @override
  bool operator ==(Object other) => other is PercentDiscount && other.pct == pct;

  @override
  int get hashCode => pct.hashCode;

  @override
  String toString() => 'PercentDiscount($pct)';
}

final class FlatDiscount extends BillDiscount {
  const FlatDiscount(this.amount);

  final Paise amount;

  @override
  bool get isZero => amount.value == 0;

  @override
  String get label => formatInr(amount);

  @override
  bool operator ==(Object other) => other is FlatDiscount && other.amount == amount;

  @override
  int get hashCode => amount.hashCode;

  @override
  String toString() => 'FlatDiscount($amount)';
}

/// Splits a flat [amount] (paise) across lines in proportion to [grosses]
/// by largest remainder: each line gets floor(amount × gross ÷ Σgross), then
/// the leftover paise go one each to the largest remainders (earlier line on
/// a tie). The shares sum to [amount] exactly and none exceeds its gross
/// while amount ≤ Σgross.
List<int> allocateFlatDiscount(int amount, List<int> grosses) {
  assert(amount >= 0, 'flat discount must be ≥ 0');
  final total = grosses.fold(0, (a, g) => a + g);
  if (amount == 0 || total <= 0) return List.filled(grosses.length, 0);
  assert(amount <= total, 'flat discount above the subtotal');
  final shares = [for (final g in grosses) g * amount ~/ total];
  var left = amount - shares.fold(0, (a, x) => a + x);
  final order = List.generate(grosses.length, (i) => i)
    ..sort((a, b) {
      final ra = grosses[a] * amount % total, rb = grosses[b] * amount % total;
      return ra != rb ? rb.compareTo(ra) : a.compareTo(b);
    });
  for (final i in order) {
    if (left == 0) break;
    shares[i]++;
    left--;
  }
  return shares;
}

/// One line of a bill before discount.
typedef BillLineInput = ({Paise mrp, int qty, int gstRate, int packSize});

/// Line amounts for a whole bill with [discount] (SPEC §4.1, §4.6).
List<LineAmounts> discountedLines(List<BillLineInput> lines, BillDiscount discount, {bool gstRegistered = true}) {
  switch (discount) {
    case PercentDiscount(:final pct):
      // Held to 0–100 for a live preview; validation reports the problem.
      final p = pct.clamp(0, 100);
      return [
        for (final l in lines)
          computeLine(
            mrp: l.mrp,
            qty: l.qty,
            discountPct: p,
            gstRate: l.gstRate,
            gstRegistered: gstRegistered,
            packSize: l.packSize,
          ),
      ];
    case FlatDiscount(:final amount):
      final grosses = [for (final l in lines) proRataGross(l.mrp, l.qty, l.packSize).value];
      final total = grosses.fold(0, (a, g) => a + g);
      // Never more than the bill; validation reports the problem.
      final shares = allocateFlatDiscount(amount.value.clamp(0, total < 0 ? 0 : total), grosses);
      return [
        for (var i = 0; i < lines.length; i++)
          lineFromGross(
            gross: Paise(grosses[i]),
            discount: Paise(shares[i]),
            gstRate: lines[i].gstRate,
            gstRegistered: gstRegistered,
          ),
      ];
  }
}

/// Price of [qty] units at [mrp] per pack of [packSize] units, rounded down
/// to the paisa so a loose sale never exceeds pro-rata MRP. A whole number
/// of packs is exact.
Paise proRataGross(Paise mrp, int qty, int packSize) {
  final total = mrp.value * qty;
  if (packSize <= 1) return Paise(total);
  // Round the magnitude down so a negative amount mirrors the positive one.
  final q = total >= 0 ? total ~/ packSize : -((-total) ~/ packSize);
  return Paise(q);
}

/// Bill totals = sums of line values (SPEC §4.1).
class BillTotals {
  const BillTotals({
    required this.items,
    required this.units,
    required this.subtotal,
    required this.discount,
    required this.taxable,
    required this.tax,
    required this.cgst,
    required this.sgst,
    required this.net,
    required this.roundOff,
    required this.total,
  });

  static const empty = BillTotals(
    items: 0,
    units: 0,
    subtotal: Paise.zero,
    discount: Paise.zero,
    taxable: Paise.zero,
    tax: Paise.zero,
    cgst: Paise.zero,
    sgst: Paise.zero,
    net: Paise.zero,
    roundOff: Paise.zero,
    total: Paise.zero,
  );

  final int items;
  final int units;

  /// Σ gross (at MRP).
  final Paise subtotal;
  final Paise discount;
  final Paise taxable;
  final Paise tax;

  /// tax ÷ 2, floored.
  final Paise cgst;

  /// tax − cgst (takes the odd paisa).
  final Paise sgst;

  /// Σ net, before round-off.
  final Paise net;

  /// Signed: total − net.
  final Paise roundOff;

  /// Grand total payable.
  final Paise total;
}

/// Splits tax into CGST (floor half) and SGST (the rest).
(Paise cgst, Paise sgst) splitTax(Paise tax) {
  final c = tax.value >= 0 ? tax.value ~/ 2 : -((-tax.value + 1) ~/ 2);
  return (Paise(c), Paise(tax.value - c));
}

/// Nearest whole rupee (half away from zero).
Paise roundToRupee(Paise p) => Paise(divRound(p.value, 100) * 100);

BillTotals computeBill(
  Iterable<(LineAmounts amounts, int qty)> lines, {
  required bool roundOff,
}) {
  var items = 0, units = 0;
  var gross = 0, disc = 0, taxable = 0, tax = 0, net = 0;
  for (final (a, q) in lines) {
    items++;
    units += q;
    gross += a.gross.value;
    disc += a.discount.value;
    taxable += a.taxable.value;
    tax += a.tax.value;
    net += a.net.value;
  }
  final (cgst, sgst) = splitTax(Paise(tax));
  final total = roundOff ? roundToRupee(Paise(net)) : Paise(net);
  return BillTotals(
    items: items,
    units: units,
    subtotal: Paise(gross),
    discount: Paise(disc),
    taxable: Paise(taxable),
    tax: Paise(tax),
    cgst: cgst,
    sgst: sgst,
    net: Paise(net),
    roundOff: total - Paise(net),
    total: total,
  );
}
