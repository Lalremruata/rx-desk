import '../fy/fy.dart';
import '../money/gst.dart';
import '../money/paise.dart';
import '../utils/expiry.dart';

/// Settings + permissions that govern saving a bill. Built from
/// `AppSettings` and the signed-in staff member's role.
class BillRules {
  const BillRules({
    this.numbering = const InvoiceNumberFormat(),
    this.roundOff = true,
    this.gstRegistered = true,
    this.allowNegativeStock = false,
    this.requireDoctorForRx = true,
    this.maxDiscountPct = 15,
    this.canSellRx = true,
    this.canGiveHighDiscount = true,
    this.canSellOnCredit = true,
    this.defaultCreditLimit = 0,
  });

  final InvoiceNumberFormat numbering;
  final bool roundOff;
  final bool gstRegistered;
  final bool allowNegativeStock;
  final bool requireDoctorForRx;
  final int maxDiscountPct;

  /// Staff permission: sell Schedule H / H1.
  final bool canSellRx;

  /// Staff permission: give more than [highDiscountThreshold] % discount.
  final bool canGiveHighDiscount;

  /// Staff permission: put a bill on the customer's dues (SPEC §4.10).
  final bool canSellOnCredit;

  /// Paise; applies to customers without their own limit. 0 = no limit.
  final int defaultCreditLimit;

  /// Discounts above this need `giveHighDiscount` (SPEC §4.6).
  static const int highDiscountThreshold = 5;

  /// Bill-level discount chips (SPEC §4.6), filtered to ≤ max.
  List<int> get discountChips => [0, 5, 10, 15, 20].where((d) => d <= maxDiscountPct).toList();
}

enum BillError {
  empty,
  invalidQty,
  scheduleX,
  doctorRequired,
  rxNotPermitted,
  expiredBatch,
  insufficientStock,
  discountTooHigh,
  discountNotPermitted,
  inactiveProduct,
  notFound,
  invalidPayment,
  // Sales returns (SPEC §4.5)
  returnNotPermitted,
  rxReturn,
  returnWindow,
  notReturnable,
  // Customer credit (SPEC §4.10)
  creditNotPermitted,
  customerRequired,
  invalidPaidNow,
  overCreditLimit,
  // Editable inventory (SPEC §5.3): MRP / GST changed while the bill was open.
  priceChanged,
}

class BillException implements Exception {
  const BillException(this.code, this.message);

  final BillError code;
  final String message;

  @override
  String toString() => 'BillException($code): $message';
}

/// The MRP or GST rate of items in the bill was edited after they were
/// added: what the counter showed is not what would be saved.
class PriceChangedException extends BillException {
  const PriceChangedException(this.changes, String message) : super(BillError.priceChanged, message);

  /// productId → the current (MRP, GST rate).
  final Map<int, ({Paise mrp, int gstRate})> changes;
}

/// Money changing hands at the counter: refunds, "paid now", dues payments.
const List<String> paymentModes = ['Cash', 'UPI', 'Card'];

/// The payment mode that puts a bill (or a refund) on the customer's dues
/// (SPEC §4.10).
const String creditMode = 'Credit';

/// Payment modes on a bill (SPEC §5.2); F8 cycles them.
const List<String> billPaymentModes = [...paymentModes, creditMode];

/// One requested line: [qty] units from batch [batchId] of [productId].
/// [expectedMrp] / [expectedGstRate] are what the counter showed; when set
/// they must still match the product (else [PriceChangedException]).
class BillLineRequest {
  const BillLineRequest({
    required this.productId,
    required this.batchId,
    required this.qty,
    this.expectedMrp,
    this.expectedGstRate,
  });

  final int productId;
  final int batchId;
  final int qty;
  final Paise? expectedMrp;
  final int? expectedGstRate;
}

/// What a bill needs to know about a line's product + batch, loaded inside
/// the save transaction.
class LineFacts {
  const LineFacts({
    required this.productName,
    required this.schedule,
    required this.isActive,
    required this.batchNo,
    required this.expiry,
    required this.batchQty,
    required this.mrp,
    required this.gstRate,
    this.packSize = 1,
  });

  /// Units per pack; [batchQty] and line qty are in units, [mrp] per pack.
  final int packSize;
  final String productName;
  final String schedule;
  final bool isActive;
  final String batchNo;
  final String expiry;
  final int batchQty;
  final Paise mrp;
  final int gstRate;
}

bool isRxSchedule(String schedule) => schedule == 'H' || schedule == 'H1';

/// Validates a bill against SPEC §4.1–4.6 and CLAUDE.md rules 4–5.
/// Throws [BillException] on the first problem.
void validateBill({
  required List<BillLineRequest> lines,
  required Map<int, LineFacts> factsByBatch,
  required BillRules rules,
  required BillDiscount discount,
  required String? doctorName,
  required String paymentMode,
  required DateTime at,
}) {
  if (lines.isEmpty) throw const BillException(BillError.empty, 'Add at least one item to the bill');
  if (!billPaymentModes.contains(paymentMode)) {
    throw BillException(BillError.invalidPayment, 'Unknown payment mode $paymentMode');
  }
  var subtotal = 0;
  for (final l in lines) {
    if (factsByBatch[l.batchId] case final f?) subtotal += proRataGross(f.mrp, l.qty, f.packSize).value;
  }
  if (discountError(discount, Paise(subtotal), rules) case (final code, final msg)) throw BillException(code, msg);

  _checkPrices(lines, factsByBatch);

  final wanted = <int, int>{};
  var hasRx = false;
  for (final l in lines) {
    final f = factsByBatch[l.batchId];
    if (f == null) throw const BillException(BillError.notFound, 'Item or batch no longer exists');
    if (l.qty <= 0) throw BillException(BillError.invalidQty, 'Quantity for ${f.productName} must be at least 1');
    if (!f.isActive) throw BillException(BillError.inactiveProduct, '${f.productName} is no longer sold');
    if (f.schedule == 'X') {
      throw BillException(BillError.scheduleX, '${f.productName} is Schedule X — it can’t be sold from RxDesk');
    }
    // Rule 5: expired batches can never be sold. No setting turns this off.
    if (isExpired(f.expiry, at)) {
      throw BillException(
        BillError.expiredBatch,
        'Batch ${f.batchNo} of ${f.productName} expired ${formatExpiry(f.expiry)} — it can’t be sold',
      );
    }
    if (isRxSchedule(f.schedule)) hasRx = true;
    wanted[l.batchId] = (wanted[l.batchId] ?? 0) + l.qty;
  }

  if (hasRx && !rules.canSellRx) {
    throw const BillException(BillError.rxNotPermitted, 'Your role can’t sell Schedule H / H1 medicines');
  }
  if (hasRx && rules.requireDoctorForRx && (doctorName == null || doctorName.trim().isEmpty)) {
    throw const BillException(BillError.doctorRequired, 'Schedule H item in bill — enter the prescribing doctor');
  }

  // Rule 4: stock never goes negative unless allowed.
  if (!rules.allowNegativeStock) {
    for (final e in wanted.entries) {
      final f = factsByBatch[e.key]!;
      if (e.value > f.batchQty) {
        throw BillException(
          BillError.insufficientStock,
          'Only ${f.batchQty} left in batch ${f.batchNo} of ${f.productName}',
        );
      }
    }
  }
}

void _checkPrices(List<BillLineRequest> lines, Map<int, LineFacts> factsByBatch) {
  final changes = <int, ({Paise mrp, int gstRate})>{};
  final names = <String>[];
  for (final l in lines) {
    final f = factsByBatch[l.batchId];
    if (f == null || changes.containsKey(l.productId)) continue;
    final mrpChanged = l.expectedMrp != null && l.expectedMrp != f.mrp;
    final gstChanged = l.expectedGstRate != null && l.expectedGstRate != f.gstRate;
    if (!mrpChanged && !gstChanged) continue;
    changes[l.productId] = (mrp: f.mrp, gstRate: f.gstRate);
    names.add(mrpChanged ? 'MRP of ${f.productName} is now ${formatInr(f.mrp)}' : 'GST of ${f.productName} is now ${f.gstRate}%');
  }
  if (changes.isEmpty) return;
  throw PriceChangedException(changes, '${names.join('; ')} — bill updated, check the total and save again');
}

/// Line amounts for a bill, in line order.
List<LineAmounts> amountsFor(
  List<BillLineRequest> lines,
  Map<int, LineFacts> facts, {
  required BillDiscount discount,
  required bool gstRegistered,
}) =>
    discountedLines(
      [
        for (final l in lines)
          (mrp: facts[l.batchId]!.mrp, qty: l.qty, gstRate: facts[l.batchId]!.gstRate, packSize: facts[l.batchId]!.packSize),
      ],
      discount,
      gstRegistered: gstRegistered,
    );

/// Why [discount] can't be given on a bill whose MRP subtotal is
/// [subtotal], or null when it can (SPEC §4.6). A flat ₹ amount is held to
/// the same limits as a percentage via its share of the subtotal.
(BillError, String)? discountError(BillDiscount discount, Paise subtotal, BillRules rules) {
  const high = BillRules.highDiscountThreshold;
  final max = rules.maxDiscountPct;
  switch (discount) {
    case PercentDiscount(:final pct):
      if (pct < 0 || pct > max) return (BillError.discountTooHigh, 'Discount can be at most $max%');
      if (pct > high && !rules.canGiveHighDiscount) {
        return (BillError.discountNotPermitted, 'Your role can’t give more than $high% discount');
      }
    case FlatDiscount(:final amount):
      final a = amount.value, sub = subtotal.value;
      if (a < 0) return (BillError.discountTooHigh, 'Discount can’t be negative');
      if (a == 0) return null;
      // Integer comparisons: a ÷ sub ≤ max % ⇔ a × 100 ≤ max × sub.
      if (a * 100 > max * sub) {
        return (BillError.discountTooHigh, 'Discount can be at most $max% of the MRP (${formatInr(maxFlatDiscount(subtotal, max))})');
      }
      if (a * 100 > high * sub && !rules.canGiveHighDiscount) {
        return (
          BillError.discountNotPermitted,
          'Your role can’t give more than $high% discount (${formatInr(maxFlatDiscount(subtotal, high))} on this bill)',
        );
      }
  }
  return null;
}

/// Message form of [discountError] for the billing screen.
String? discountProblem(BillDiscount discount, Paise subtotal, BillRules rules) => discountError(discount, subtotal, rules)?.$2;

/// Largest flat ₹ (paise) that stays within [pct] % of [subtotal].
Paise maxFlatDiscount(Paise subtotal, int pct) => Paise(subtotal.value <= 0 ? 0 : subtotal.value * pct ~/ 100);

// ---------------------------------------------------------------------------
// FEFO + substitutes (SPEC §4.3)

/// A batch as seen by the batch picker.
class BatchOption {
  const BatchOption({required this.batchId, required this.batchNo, required this.expiry, required this.qty});

  final int batchId;
  final String batchNo;
  final String expiry;
  final int qty;
}

/// Result of picking a product at the counter.
sealed class BatchPick {
  const BatchPick();
}

/// Exactly one saleable batch → add it directly.
class AddDirect extends BatchPick {
  const AddDirect(this.batch);
  final BatchOption batch;
}

/// Several → batch picker; [saleable] sorted FEFO (first = "sell first"),
/// [expired] listed greyed and blocked.
class ShowPicker extends BatchPick {
  const ShowPicker(this.saleable, this.expired);
  final List<BatchOption> saleable;
  final List<BatchOption> expired;
}

/// No saleable stock at all → show substitutes.
class ShowSubstitutes extends BatchPick {
  const ShowSubstitutes();
}

/// Some stock exists but every unit is already in the bill.
class AllInBill extends BatchPick {
  const AllInBill();
}

/// SPEC §4.3: saleable = (qty − already in bill) > 0 and not expired, FEFO.
BatchPick pickBatches(
  List<BatchOption> batches,
  DateTime now, {
  Map<int, int> inBill = const {},
}) {
  final valid = <BatchOption>[];
  final expired = <BatchOption>[];
  var anyStock = false;
  for (final b in batches) {
    if (isExpired(b.expiry, now)) {
      if (b.qty > 0) expired.add(b);
      continue;
    }
    if (b.qty > 0) anyStock = true;
    final left = b.qty - (inBill[b.batchId] ?? 0);
    if (left > 0) valid.add(BatchOption(batchId: b.batchId, batchNo: b.batchNo, expiry: b.expiry, qty: left));
  }
  int byExpiry(BatchOption a, BatchOption b) {
    final c = a.expiry.compareTo(b.expiry);
    return c != 0 ? c : a.batchNo.compareTo(b.batchNo);
  }

  valid.sort(byExpiry);
  expired.sort(byExpiry);
  if (valid.isEmpty) return anyStock ? const AllInBill() : const ShowSubstitutes();
  if (valid.length == 1) return AddDirect(valid.first);
  return ShowPicker(valid, expired);
}

/// Normalised salt + strength for substitute matching:
/// "Paracetamol  650 MG" → "paracetamol 650 mg".
String normaliseSalt(String salt) => salt.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
