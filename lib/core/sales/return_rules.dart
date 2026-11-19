import '../fy/fy.dart';
import '../money/gst.dart';
import '../money/paise.dart';
import '../utils/expiry.dart';
import 'bill_rules.dart';

/// Settings + permissions that govern accepting a sales return (SPEC §4.5).
class ReturnRules {
  const ReturnRules({
    this.numbering = const InvoiceNumberFormat(prefix: 'CN', series: 'CN'),
    this.roundOff = true,
    this.windowDays = 30,
    this.canAcceptReturns = true,
    this.canOverrideWindow = true,
  });

  /// Credit-note series (its own gapless sequence per FY).
  final InvoiceNumberFormat numbering;
  final bool roundOff;

  /// Returns older than this many days are blocked; 0 = no limit.
  final int windowDays;

  /// Staff permission `acceptReturns`.
  final bool canAcceptReturns;

  /// Owner only: accept a return after the window has passed.
  final bool canOverrideWindow;
}

/// An original invoice line as sold (positive amounts, from the snapshot).
class SoldLine {
  const SoldLine({
    required this.itemId,
    required this.productName,
    required this.schedule,
    required this.qty,
    required this.mrp,
    required this.gstRate,
    required this.amounts,
    this.packSize = 1,
  });

  /// Units per pack when sold (snapshot); [qty] is in units.
  final int packSize;
  final int itemId;
  final String productName;
  final String schedule;
  final int qty;
  final Paise mrp;
  final int gstRate;
  final LineAmounts amounts;

  bool get isRx => isRxSchedule(schedule);
}

/// What earlier credit notes already took back from one original line
/// (positive sums).
class PriorReturn {
  const PriorReturn({
    this.qty = 0,
    this.gross = Paise.zero,
    this.discount = Paise.zero,
    this.taxable = Paise.zero,
    this.tax = Paise.zero,
    this.net = Paise.zero,
  });

  static const none = PriorReturn();

  final int qty;
  final Paise gross;
  final Paise discount;
  final Paise taxable;
  final Paise tax;
  final Paise net;
}

/// One requested return line.
class ReturnLineRequest {
  const ReturnLineRequest({required this.itemId, required this.qty, this.restock = true});

  /// Original invoice item id.
  final int itemId;
  final int qty;

  /// false = damaged, written off instead of going back to stock.
  final bool restock;
}

/// Units of [line] still returnable.
int returnable(SoldLine line, PriorReturn prior) => (line.qty - prior.qty).clamp(0, line.qty);

/// Refund amounts (positive) for returning [qty] units of [line].
///
/// SPEC §4.1 maths on `mrp × qty` with the original bill's discount: its
/// % for a percentage bill; for a flat ₹ bill, the line's own discount
/// pro-rata to the units returned. When the return takes the line's last
/// units, every column is the original minus what earlier returns took, so a
/// fully returned line reconciles to the paisa.
LineAmounts returnAmounts(
  SoldLine line,
  int qty,
  PriorReturn prior, {
  required BillDiscount discount,
  required bool gstRegistered,
}) {
  final left = returnable(line, prior);
  assert(qty > 0 && qty <= left, 'return qty out of range');
  if (qty == left) {
    final o = line.amounts;
    return LineAmounts(
      gross: o.gross - prior.gross,
      discount: o.discount - prior.discount,
      net: o.net - prior.net,
      taxable: o.taxable - prior.taxable,
      tax: o.tax - prior.tax,
    );
  }
  return switch (discount) {
    PercentDiscount(:final pct) => computeLine(
        mrp: line.mrp,
        qty: qty,
        discountPct: pct,
        gstRate: line.gstRate,
        gstRegistered: gstRegistered,
        packSize: line.packSize,
      ),
    FlatDiscount() => lineFromGross(
        gross: proRataGross(line.mrp, qty, line.packSize),
        discount: Paise(divRound(line.amounts.discount.value * qty, line.qty)),
        gstRate: line.gstRate,
        gstRegistered: gstRegistered,
      ),
  };
}

/// Whole days from the bill's sale date to [at] (local calendar days).
int daysSinceSale(String saleDate, DateTime at) {
  final sold = parseDateKey(saleDate);
  final today = DateTime(at.year, at.month, at.day);
  return today.difference(sold).inDays;
}

/// True when [saleDate] is past the return window at [at].
bool pastReturnWindow(String saleDate, DateTime at, int windowDays) =>
    windowDays > 0 && daysSinceSale(saleDate, at) > windowDays;

/// Validates a return against SPEC §4.5. Throws [BillException].
void validateReturn({
  required String docType,
  required String status,
  required String saleDate,
  required List<ReturnLineRequest> lines,
  required Map<int, SoldLine> sold,
  required Map<int, PriorReturn> prior,
  required ReturnRules rules,
  required String paymentMode,
  required DateTime at,
  int? customerId,
}) {
  if (!rules.canAcceptReturns) {
    throw const BillException(BillError.returnNotPermitted, 'Your role can’t accept returns');
  }
  if (docType != 'invoice') {
    throw const BillException(BillError.notReturnable, 'Only a tax invoice can be returned against');
  }
  if (status == 'cancelled') throw const BillException(BillError.notReturnable, 'This bill is cancelled');
  if (status == 'returned') throw const BillException(BillError.notReturnable, 'Everything on this bill is already returned');
  if (paymentMode == creditMode) {
    // Adjust in dues (SPEC §4.10) needs a known customer on the bill.
    if (customerId == null) {
      throw const BillException(BillError.customerRequired, 'No customer on this bill — refund in Cash, UPI or Card');
    }
  } else if (!paymentModes.contains(paymentMode)) {
    throw BillException(BillError.invalidPayment, 'Unknown refund mode $paymentMode');
  }
  if (pastReturnWindow(saleDate, at, rules.windowDays) && !rules.canOverrideWindow) {
    throw BillException(
      BillError.returnWindow,
      'This bill is older than ${rules.windowDays} days — only the Owner can accept the return',
    );
  }
  final req = lines.where((l) => l.qty != 0).toList();
  if (req.isEmpty) throw const BillException(BillError.empty, 'Pick at least one item to return');
  final seen = <int>{};
  for (final l in req) {
    final s = sold[l.itemId];
    if (s == null) throw const BillException(BillError.notFound, 'That item isn’t on this bill');
    if (!seen.add(l.itemId)) throw BillException(BillError.invalidQty, '${s.productName} is listed twice');
    if (s.isRx) {
      throw BillException(BillError.rxReturn, '${s.productName} is Schedule ${s.schedule} — it can’t be returned');
    }
    final left = returnable(s, prior[l.itemId] ?? PriorReturn.none);
    if (l.qty < 0) throw BillException(BillError.invalidQty, 'Return quantity for ${s.productName} can’t be negative');
    if (l.qty > left) {
      throw BillException(
        BillError.invalidQty,
        left == 0 ? '${s.productName} is already fully returned' : 'Only $left of ${s.productName} can be returned',
      );
    }
  }
}

/// Refund preview / totals for [lines] (positive values). Lines with qty 0
/// are skipped.
BillTotals returnTotals({
  required List<ReturnLineRequest> lines,
  required Map<int, SoldLine> sold,
  required Map<int, PriorReturn> prior,
  required BillDiscount discount,
  required bool gstRegistered,
  required bool roundOff,
}) =>
    computeBill(
      [
        for (final l in lines)
          if (l.qty > 0 && sold[l.itemId] != null && l.qty <= returnable(sold[l.itemId]!, prior[l.itemId] ?? PriorReturn.none))
            (
              returnAmounts(
                sold[l.itemId]!,
                l.qty,
                prior[l.itemId] ?? PriorReturn.none,
                discount: discount,
                gstRegistered: gstRegistered,
              ),
              l.qty,
            ),
      ],
      roundOff: roundOff,
    );
