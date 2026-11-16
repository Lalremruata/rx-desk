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
/// discount = round(gross × discount_pct / 100)
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
  final discount = divRound(gross * discountPct, 100);
  final net = gross - discount;
  final taxable = gstRegistered ? divRound(net * 100, 100 + gstRate) : net;
  return LineAmounts(
    gross: Paise(gross),
    discount: Paise(discount),
    net: Paise(net),
    taxable: Paise(taxable),
    tax: Paise(net - taxable),
  );
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
