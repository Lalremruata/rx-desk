/// Day-end cash closing (SPEC §4.14). Pure Dart.
///
/// Expected cash in the drawer = opening + cash sales − cash refunds
/// + dues collected in cash − stockists paid in cash − paid-outs.
library;

import '../money/paise.dart';

/// Thrown for invalid cash operations; [message] is shown to the user.
class CashException implements Exception {
  const CashException(this.message);
  final String message;
  @override
  String toString() => 'CashException: $message';
}

/// The day's cash movements RxDesk knows about (all ≥ 0).
class CashFigures {
  const CashFigures({
    this.cashSales = Paise.zero,
    this.cashRefunds = Paise.zero,
    this.duesCollected = Paise.zero,
    this.stockistsPaid = Paise.zero,
    this.paidOuts = Paise.zero,
  });

  /// Cash bills of the day (not cancelled), at their total.
  final Paise cashSales;

  /// Credit notes of the day refunded in cash.
  final Paise cashRefunds;

  /// Customer payments in cash, including "paid now" on credit bills.
  final Paise duesCollected;

  /// Stockist payments in cash, including paid on delivery.
  final Paise stockistsPaid;

  /// Shop expenses paid from the drawer.
  final Paise paidOuts;

  /// Cash in minus cash out, before the opening amount.
  Paise get net => Paise(cashSales.value - cashRefunds.value + duesCollected.value - stockistsPaid.value - paidOuts.value);

  Paise expected(Paise opening) => Paise(opening.value + net.value);

  @override
  bool operator ==(Object other) =>
      other is CashFigures &&
      other.cashSales == cashSales &&
      other.cashRefunds == cashRefunds &&
      other.duesCollected == duesCollected &&
      other.stockistsPaid == stockistsPaid &&
      other.paidOuts == paidOuts;

  @override
  int get hashCode => Object.hash(cashSales, cashRefunds, duesCollected, stockistsPaid, paidOuts);
}

/// Notes and coins for counting the drawer (₹). Coins are typed as an amount.
const List<int> noteDenominations = [500, 200, 100, 50, 20, 10];

/// Σ count × note value, plus loose [coins], in paise. Null when a count is
/// negative.
Paise? countedFromNotes(Map<int, int> counts, {Paise coins = Paise.zero}) {
  var total = coins.value;
  for (final e in counts.entries) {
    if (e.value < 0) return null;
    total += e.key * 100 * e.value;
  }
  return Paise(total);
}

/// Opening cash for a day = the previous closing's counted cash less what
/// was taken out of the drawer (banked / handed to the Owner).
Paise openingFrom({required Paise counted, required Paise handedOver}) => Paise(counted.value - handedOver.value);
