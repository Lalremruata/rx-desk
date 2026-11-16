/// Purchases / order book rules (SPEC §4.7). Pure Dart — no Drift, no Flutter.
library;

import '../money/paise.dart';
import '../utils/expiry.dart';

/// Pack units an order or stockist line can be counted in.
const List<String> purchaseUnits = ['Box', 'Strip', 'Nos', 'Bottle', 'Vial', 'Amp', 'Tube', 'Pcs', 'Sachet'];

/// Thrown for invalid purchase operations; [message] is shown to the user.
class PurchaseException implements Exception {
  const PurchaseException(this.message);
  final String message;
  @override
  String toString() => 'PurchaseException: $message';
}

/// Order-line status, stored by [name].
enum OrderStatus {
  /// Nothing received yet.
  pending('Pending'),

  /// Some received, more expected.
  part('Part supplied'),

  /// Fully received (or over-supplied).
  received('Received'),

  /// Received short and no more is coming.
  closed('Closed short'),

  /// Never supplied; withdrawn.
  cancelled('Cancelled');

  const OrderStatus(this.label);
  final String label;

  static OrderStatus parse(String s) => values.byName(s);

  /// Still waiting on the supplier (shown under Pending).
  bool get isOpen => this == pending || this == part;
}

/// What has come in against one order line, split by unit.
class ReceivedSoFar {
  const ReceivedSoFar({this.sameUnitQty = 0, this.otherUnitLines = 0});

  /// Σ qty of receipt lines in the order line's own unit.
  final int sameUnitQty;

  /// Receipt lines in a different unit (can't be compared with the order qty).
  final int otherUnitLines;

  bool get isEmpty => sameUnitQty == 0 && otherUnitLines == 0;
}

/// Status after a receipt (SPEC §4.7).
///
/// * `cancelled` and `closed` never change.
/// * Nothing received → `pending`.
/// * Same-unit total ≥ ordered → `received` (over-supply allowed).
/// * Otherwise [moreExpected] → `part`.
/// * Otherwise a different-unit receipt counts as complete → `received`;
///   a same-unit short delivery with nothing more coming → `closed`.
OrderStatus statusAfterReceipt({
  required OrderStatus current,
  required int orderedQty,
  required ReceivedSoFar received,
  required bool moreExpected,
}) {
  if (current == OrderStatus.cancelled || current == OrderStatus.closed) return current;
  if (received.isEmpty) return OrderStatus.pending;
  if (received.sameUnitQty >= orderedQty) return OrderStatus.received;
  if (moreExpected) return OrderStatus.part;
  if (received.otherUnitLines > 0) return OrderStatus.received;
  return OrderStatus.closed;
}

/// Default for the receive dialog's "Still expecting more" switch: on when
/// this delivery (same unit) leaves the order short.
bool defaultMoreExpected({
  required int orderedQty,
  required String orderedUnit,
  required int alreadyReceivedSameUnit,
  required int qty,
  required String unit,
}) =>
    unit == orderedUnit && alreadyReceivedSameUnit + qty < orderedQty;

/// Short / over tag for a line in the order book.
enum SupplyTag {
  none(''),
  pending('Pending'),
  short('Short'),
  over('Over'),
  cancelled('Cancelled'),
  notOrdered('Not ordered');

  const SupplyTag(this.label);
  final String label;
}

SupplyTag supplyTag({required OrderStatus? status, required int orderedQty, required int receivedSameUnit}) {
  if (status == null) return SupplyTag.notOrdered;
  return switch (status) {
    OrderStatus.cancelled => SupplyTag.cancelled,
    OrderStatus.pending => SupplyTag.pending,
    OrderStatus.part || OrderStatus.closed => SupplyTag.short,
    OrderStatus.received => receivedSameUnit > orderedQty ? SupplyTag.over : SupplyTag.none,
  };
}

/// Units still due on an open line, in its own unit (never negative).
int dueQty(int orderedQty, int receivedSameUnit) => orderedQty - receivedSameUnit < 0 ? 0 : orderedQty - receivedSameUnit;

/// Informational purchase rate per sale unit: amount ÷ units, rounded half-up
/// to the paisa. Null when there are no units or no amount.
Paise? purchaseRate(Paise amount, int stockUnits) {
  if (stockUnits <= 0 || amount.value <= 0) return null;
  return Paise((amount.value * 2 + stockUnits) ~/ (stockUnits * 2));
}

enum ExpiryCheck { ok, near, expired }

/// Expired stock is never sold (CLAUDE.md rule 5), so it can't be received.
/// Inside the expiry window it's allowed with a warning.
ExpiryCheck receiveExpiryCheck(String expiry, DateTime now, int expiryWindowMonths) {
  if (isExpired(expiry, now)) return ExpiryCheck.expired;
  if (monthsLeft(expiry, now) <= expiryWindowMonths) return ExpiryCheck.near;
  return ExpiryCheck.ok;
}

/// "20 Box", "1 Strip".
String qtyLabel(int qty, String unit) => '$qty $unit';

/// Default order unit for a product category.
String defaultUnitFor(String category) => switch (category) {
      'Tablet' || 'Capsule' => 'Strip',
      'Syrup' => 'Bottle',
      'Injection' => 'Vial',
      'Topical' => 'Tube',
      _ => 'Nos',
    };

/// Suggested quantity for a low-stock item: back up to twice the reorder
/// level, at least 1.
int suggestedOrderQty({required int saleable, required int reorderLevel}) {
  final want = reorderLevel * 2 - (saleable < 0 ? 0 : saleable);
  return want < 1 ? 1 : want;
}
