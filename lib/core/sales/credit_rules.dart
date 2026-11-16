/// Customer credit / udhaar (SPEC §4.10). Pure Dart — amounts are integer
/// paise.
library;

import '../money/paise.dart';
import '../utils/expiry.dart';
import 'bill_rules.dart';

export '../ledger/allocation.dart';

/// How the "paid now" part of a Credit bill, or a dues payment, comes in.
const List<String> collectModes = paymentModes;

const String walkInName = 'Walk-in customer';

/// Customer ledger entry kinds, stored by [code].
enum CustomerLedgerKind {
  opening('opening', 'Opening dues', debit: true),
  bill('bill', 'Bill', debit: true),
  payment('payment', 'Payment', debit: false),
  creditNote('credit_note', 'Credit note', debit: false);

  const CustomerLedgerKind(this.code, this.label, {required this.debit});
  final String code;
  final String label;

  /// Debits add to what the customer owes; credits reduce it.
  final bool debit;

  /// Payments and opening dues can be voided. Bills are cancelled and
  /// credit notes stand — both are GST documents.
  bool get voidable => this == opening || this == payment;

  static CustomerLedgerKind parse(String code) => values.firstWhere((k) => k.code == code);
}

/// The limit that applies: the customer's own, else the Settings default.
/// 0 = no limit.
int effectiveCreditLimit({required int? customerLimit, required int defaultLimit}) {
  final l = customerLimit ?? defaultLimit;
  return l < 0 ? 0 : l;
}

/// How far [dues] + [adding] goes past [limit] (0 = within it, or no limit).
int creditOverBy({required int dues, required int adding, required int limit}) {
  if (limit <= 0 || adding <= 0) return 0;
  final over = dues + adding - limit;
  return over > 0 ? over : 0;
}

/// Raised when a Credit bill would take the customer past their limit. The
/// Owner can allow it (SPEC §4.10).
class CreditLimitException extends BillException {
  CreditLimitException({required this.dues, required this.limit, required this.adding})
      : super(
          BillError.overCreditLimit,
          'Over the credit limit — dues ${formatInr(Paise(dues))} + this bill ${formatInr(Paise(adding))} '
          'is above the limit of ${formatInr(Paise(limit))}',
        );

  final int dues;
  final int limit;
  final int adding;

  int get overBy => creditOverBy(dues: dues, adding: adding, limit: limit);
}

/// Checks the parts of a Credit bill that don't need the database: who it
/// is for and the amount paid now. Throws [BillException].
void validateCreditBill({
  required bool canSellOnCredit,
  required String customerName,
  required String? phone,
  required int total,
  required int paidNow,
  required String paidNowMode,
}) {
  if (!canSellOnCredit) {
    throw const BillException(BillError.creditNotPermitted, 'Your role can’t sell on credit');
  }
  final name = customerName.trim();
  if (name.isEmpty || name == walkInName || (phone ?? '').trim().isEmpty) {
    throw const BillException(BillError.customerRequired, 'Credit bill — enter the customer’s name and phone');
  }
  if (paidNow < 0) throw const BillException(BillError.invalidPaidNow, 'Paid now can’t be negative');
  if (paidNow >= total) {
    throw const BillException(BillError.invalidPaidNow, 'Paid now covers the whole bill — pick Cash, UPI or Card instead');
  }
  if (paidNow > 0 && !collectModes.contains(paidNowMode)) {
    throw BillException(BillError.invalidPayment, 'Unknown payment mode $paidNowMode');
  }
}

/// Refund to dues needs a known customer on the original bill.
bool canRefundToDues({required int? customerId}) => customerId != null;

/// The refund mode a return dialog starts on: back to dues when the bill
/// was on credit (SPEC §4.10).
String defaultRefundMode({required String billPaymentMode, required int? customerId}) {
  if (billPaymentMode == creditMode && canRefundToDues(customerId: customerId)) return creditMode;
  return billPaymentMode == creditMode ? paymentModes.first : billPaymentMode;
}

enum AgingBucket {
  none('—'),
  d30('0–30 days'),
  d60('31–60 days'),
  d90('61–90 days'),
  over90('90+ days');

  const AgingBucket(this.label);
  final String label;
}

/// How old the oldest unpaid entry is ('YYYY-MM-DD' dates).
AgingBucket agingBucket(String? oldestOpen, String today) {
  if (oldestOpen == null || oldestOpen.isEmpty) return AgingBucket.none;
  final days = daysBetween(oldestOpen, today);
  if (days <= 30) return AgingBucket.d30;
  if (days <= 60) return AgingBucket.d60;
  if (days <= 90) return AgingBucket.d90;
  return AgingBucket.over90;
}

int daysBetween(String from, String to) {
  final d = parseDateKey(to).difference(parseDateKey(from)).inDays;
  return d < 0 ? 0 : d;
}
