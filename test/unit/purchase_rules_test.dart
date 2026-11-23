import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/purchases/purchase_rules.dart';

void main() {
  group('order-line status after a receipt (SPEC §4.7)', () {
    OrderStatus after({
      OrderStatus current = OrderStatus.pending,
      int ordered = 30,
      int same = 0,
      int other = 0,
      bool more = false,
    }) =>
        statusAfterReceipt(
          current: current,
          orderedQty: ordered,
          received: ReceivedSoFar(sameUnitQty: same, otherUnitLines: other),
          moreExpected: more,
        );

    test('nothing received stays pending', () => expect(after(), OrderStatus.pending));
    test('full qty → received', () => expect(after(same: 30), OrderStatus.received));
    test('over-supply → received', () => expect(after(ordered: 2, same: 4), OrderStatus.received));
    test('short and more expected → part', () => expect(after(same: 20, more: true), OrderStatus.part));
    test('short and nothing more coming → closed', () => expect(after(same: 20), OrderStatus.closed));
    test('different unit counts as complete', () => expect(after(ordered: 1, other: 1), OrderStatus.received));
    test('different unit but more expected → part', () => expect(after(ordered: 1, other: 1, more: true), OrderStatus.part));
    test('part line completed later → received', () => expect(after(current: OrderStatus.part, same: 30), OrderStatus.received));
    test('closed and cancelled never change', () {
      expect(after(current: OrderStatus.closed, same: 30), OrderStatus.closed);
      expect(after(current: OrderStatus.cancelled, same: 30), OrderStatus.cancelled);
    });
  });

  test('"still expecting more" defaults on only for a short same-unit delivery', () {
    bool d(int already, int qty, String unit) =>
        defaultMoreExpected(orderedQty: 30, orderedUnit: 'Box', alreadyReceivedSameUnit: already, qty: qty, unit: unit);
    expect(d(0, 20, 'Box'), isTrue);
    expect(d(10, 20, 'Box'), isFalse);
    expect(d(0, 40, 'Box'), isFalse);
    expect(d(0, 5, 'Strip'), isFalse);
  });

  test('supply tags', () {
    SupplyTag t(OrderStatus? s, {int ordered = 10, int got = 0}) => supplyTag(status: s, orderedQty: ordered, receivedSameUnit: got);
    expect(t(null), SupplyTag.notOrdered);
    expect(t(OrderStatus.pending), SupplyTag.pending);
    expect(t(OrderStatus.part, got: 4), SupplyTag.short);
    expect(t(OrderStatus.closed, got: 4), SupplyTag.short);
    expect(t(OrderStatus.received, got: 10), SupplyTag.none);
    expect(t(OrderStatus.received, got: 12), SupplyTag.over);
    expect(t(OrderStatus.cancelled), SupplyTag.cancelled);
    expect(dueQty(30, 20), 10);
    expect(dueQty(2, 4), 0);
  });

  test('purchase rate rounds half-up to the paisa', () {
    expect(purchaseRate(const Paise(361200), 200), const Paise(1806));
    expect(purchaseRate(const Paise(1000), 3), const Paise(333));
    expect(purchaseRate(const Paise(2000), 3), const Paise(667));
    expect(purchaseRate(const Paise(5), 2), const Paise(3));
    expect(purchaseRate(Paise.zero, 10), isNull);
    expect(purchaseRate(const Paise(100), 0), isNull);
  });

  test('expiry check: past blocked, inside window warned', () {
    final now = DateTime(2026, 11, 9);
    expect(receiveExpiryCheck('2026-10', now, 3), ExpiryCheck.expired);
    expect(receiveExpiryCheck('2026-11', now, 3), ExpiryCheck.near);
    expect(receiveExpiryCheck('2027-02', now, 3), ExpiryCheck.near);
    expect(receiveExpiryCheck('2027-03', now, 3), ExpiryCheck.ok);
  });

  test('stock packs for a receive line: Box × strips per box, other units 1:1', () {
    expect(unitNeedsPacksPerBox('Box'), isTrue);
    expect(unitNeedsPacksPerBox('Strip'), isFalse);
    expect(defaultStockPacks(qty: 10, unit: 'Box', packsPerBox: 15), 150);
    expect(defaultStockPacks(qty: 10, unit: 'Box'), isNull); // not known yet → ask
    expect(defaultStockPacks(qty: 10, unit: 'Box', packsPerBox: 0), isNull);
    expect(defaultStockPacks(qty: 10, unit: 'Strip', packsPerBox: 15), 10);
    expect(defaultStockPacks(qty: 3, unit: 'Bottle'), 3);
    expect(defaultStockPacks(qty: 0, unit: 'Box', packsPerBox: 15), isNull);
  });

  test('purchase line amount: rate × qty − disc + GST, each step to the paisa', () {
    expect(purchaseLineAmount(qty: 10, rate: const Paise(2000), discBp: 500, gstRate: 12), const Paise(21280));
    expect(purchaseLineAmount(qty: 3, rate: const Paise(1999), discBp: 750, gstRate: 5), const Paise(5824)); // 59.97 − 4.50 = 55.47 + 2.77 GST
    expect(purchaseLineAmount(qty: 1, rate: const Paise(1000)), const Paise(1000));
    expect(purchaseLineAmount(qty: 0, rate: const Paise(1000)), Paise.zero);
  });

  test('percent ↔ basis points', () {
    expect([parsePercentBp(''), parsePercentBp('7.5'), parsePercentBp('10'), parsePercentBp('12.25')], [0, 750, 1000, 1225]);
    expect([parsePercentBp('7.555'), parsePercentBp('x'), parsePercentBp('-1')], [null, null, null]);
    expect([formatPercentBp(750), formatPercentBp(1000), formatPercentBp(1225), formatPercentBp(5)], ['7.5', '10', '12.25', '0.05']);
  });
}
