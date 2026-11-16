import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/money/gst.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/sales/return_rules.dart';

SoldLine line({int id = 1, int mrp = 3090, int qty = 5, int disc = 0, int gst = 12, String schedule = '', bool registered = true}) =>
    SoldLine(
      itemId: id,
      productName: 'Med $id',
      schedule: schedule,
      qty: qty,
      mrp: Paise(mrp),
      gstRate: gst,
      amounts: computeLine(mrp: Paise(mrp), qty: qty, discountPct: disc, gstRate: gst, gstRegistered: registered),
    );

PriorReturn add(PriorReturn p, int qty, LineAmounts a) => PriorReturn(
      qty: p.qty + qty,
      gross: p.gross + a.gross,
      discount: p.discount + a.discount,
      taxable: p.taxable + a.taxable,
      tax: p.tax + a.tax,
      net: p.net + a.net,
    );

void main() {
  group('returnAmounts', () {
    for (final gst in [0, 5, 12, 18]) {
      for (final disc in [0, 5, 10, 15, 20]) {
        test('one-by-one returns reconcile to the original line (GST $gst %, disc $disc %)', () {
          final l = line(mrp: 3333, qty: 7, disc: disc, gst: gst);
          var prior = PriorReturn.none;
          for (var i = 0; i < 7; i++) {
            final a = returnAmounts(l, 1, prior, discountPct: disc, gstRegistered: true);
            expect(a.net.value, a.gross.value - a.discount.value);
            expect(a.tax.value, a.net.value - a.taxable.value);
            prior = add(prior, 1, a);
          }
          expect(prior.qty, 7);
          expect(prior.gross, l.amounts.gross);
          expect(prior.discount, l.amounts.discount);
          expect(prior.taxable, l.amounts.taxable);
          expect(prior.tax, l.amounts.tax);
          expect(prior.net, l.amounts.net);
        });
      }
    }

    test('a partial return uses the §4.1 maths on the returned qty', () {
      final l = line(disc: 10);
      final a = returnAmounts(l, 2, PriorReturn.none, discountPct: 10, gstRegistered: true);
      final want = computeLine(mrp: const Paise(3090), qty: 2, discountPct: 10, gstRate: 12);
      expect((a.gross, a.discount, a.net, a.taxable, a.tax), (want.gross, want.discount, want.net, want.taxable, want.tax));
    });

    test('returning the whole line in one go equals the original exactly', () {
      final l = line(mrp: 1, qty: 3, disc: 15, gst: 18);
      final a = returnAmounts(l, 3, PriorReturn.none, discountPct: 15, gstRegistered: true);
      expect(a.net, l.amounts.net);
      expect(a.tax, l.amounts.tax);
    });

    test('bill of supply: tax stays 0', () {
      final l = line(registered: false, qty: 4, disc: 5);
      final a = returnAmounts(l, 1, PriorReturn.none, discountPct: 5, gstRegistered: false);
      expect(a.tax, Paise.zero);
      expect(a.taxable, a.net);
    });
  });

  group('returnTotals', () {
    test('odd-paisa tax goes to SGST and round-off works both ways', () {
      final sold = {1: line(mrp: 1121, qty: 3), 2: line(id: 2, mrp: 1060, qty: 2, gst: 5)};
      final t = returnTotals(
        lines: const [ReturnLineRequest(itemId: 1, qty: 1), ReturnLineRequest(itemId: 2, qty: 1)],
        sold: sold,
        prior: const {},
        discountPct: 0,
        gstRegistered: true,
        roundOff: true,
      );
      expect(t.cgst.value + t.sgst.value, t.tax.value);
      expect(t.sgst.value - t.cgst.value, t.tax.value.isOdd ? 1 : 0);
      expect(t.total.value % 100, 0);
      expect(t.total - t.net, t.roundOff);

      final up = returnTotals(
        lines: const [ReturnLineRequest(itemId: 1, qty: 1)],
        sold: {1: line(mrp: 1060, qty: 1)},
        prior: const {},
        discountPct: 0,
        gstRegistered: true,
        roundOff: true,
      );
      expect((up.total.value, up.roundOff.value), (1100, 40));
      final down = returnTotals(
        lines: const [ReturnLineRequest(itemId: 1, qty: 1)],
        sold: {1: line(mrp: 1040, qty: 1)},
        prior: const {},
        discountPct: 0,
        gstRegistered: true,
        roundOff: true,
      );
      expect((down.total.value, down.roundOff.value), (1000, -40));
    });

    test('lines with qty 0 or over the limit are left out of the preview', () {
      final t = returnTotals(
        lines: const [ReturnLineRequest(itemId: 1, qty: 0), ReturnLineRequest(itemId: 2, qty: 9)],
        sold: {1: line(), 2: line(id: 2, qty: 2)},
        prior: const {},
        discountPct: 0,
        gstRegistered: true,
        roundOff: false,
      );
      expect(t.items, 0);
      expect(t.total, Paise.zero);
    });
  });

  group('validateReturn', () {
    final sold = {1: line(qty: 3), 2: line(id: 2, qty: 1, schedule: 'H1')};
    final at = DateTime(2026, 11, 20, 12);

    void check(
      List<ReturnLineRequest> lines, {
      ReturnRules rules = const ReturnRules(),
      String docType = 'invoice',
      String status = 'paid',
      String saleDate = '2026-11-10',
      Map<int, PriorReturn> prior = const {},
      String mode = 'Cash',
    }) =>
        validateReturn(
          docType: docType,
          status: status,
          saleDate: saleDate,
          lines: lines,
          sold: sold,
          prior: prior,
          rules: rules,
          paymentMode: mode,
          at: at,
        );

    Matcher code(BillError e) => throwsA(isA<BillException>().having((x) => x.code, 'code', e));

    test('accepts a normal return', () {
      expect(() => check(const [ReturnLineRequest(itemId: 1, qty: 2)]), returnsNormally);
    });

    test('rejects', () {
      expect(() => check(const []), code(BillError.empty));
      expect(() => check(const [ReturnLineRequest(itemId: 1, qty: 0)]), code(BillError.empty));
      expect(() => check(const [ReturnLineRequest(itemId: 1, qty: 4)]), code(BillError.invalidQty));
      expect(() => check(const [ReturnLineRequest(itemId: 1, qty: -1)]), code(BillError.invalidQty));
      expect(
        () => check(const [ReturnLineRequest(itemId: 1, qty: 1), ReturnLineRequest(itemId: 1, qty: 1)]),
        code(BillError.invalidQty),
      );
      expect(
        () => check(const [ReturnLineRequest(itemId: 1, qty: 2)], prior: const {1: PriorReturn(qty: 2)}),
        code(BillError.invalidQty),
      );
      expect(() => check(const [ReturnLineRequest(itemId: 9, qty: 1)]), code(BillError.notFound));
      expect(() => check(const [ReturnLineRequest(itemId: 2, qty: 1)]), code(BillError.rxReturn));
      expect(() => check(const [ReturnLineRequest(itemId: 1, qty: 1)], docType: 'credit_note'), code(BillError.notReturnable));
      expect(() => check(const [ReturnLineRequest(itemId: 1, qty: 1)], status: 'cancelled'), code(BillError.notReturnable));
      expect(() => check(const [ReturnLineRequest(itemId: 1, qty: 1)], status: 'returned'), code(BillError.notReturnable));
      expect(() => check(const [ReturnLineRequest(itemId: 1, qty: 1)], mode: 'Gold'), code(BillError.invalidPayment));
      expect(
        () => check(const [ReturnLineRequest(itemId: 1, qty: 1)], rules: const ReturnRules(canAcceptReturns: false)),
        code(BillError.returnNotPermitted),
      );
    });

    test('return window: staff blocked after N days, Owner overrides, 0 = no limit', () {
      const staff = ReturnRules(windowDays: 7, canOverrideWindow: false);
      expect(() => check(const [ReturnLineRequest(itemId: 1, qty: 1)], rules: staff, saleDate: '2026-11-13'), returnsNormally);
      expect(
        () => check(const [ReturnLineRequest(itemId: 1, qty: 1)], rules: staff, saleDate: '2026-11-12'),
        code(BillError.returnWindow),
      );
      expect(
        () => check(const [ReturnLineRequest(itemId: 1, qty: 1)], rules: const ReturnRules(windowDays: 7), saleDate: '2026-01-01'),
        returnsNormally,
      );
      expect(
        () => check(
          const [ReturnLineRequest(itemId: 1, qty: 1)],
          rules: const ReturnRules(windowDays: 0, canOverrideWindow: false),
          saleDate: '2025-01-01',
        ),
        returnsNormally,
      );
    });

    test('daysSinceSale / pastReturnWindow', () {
      expect(daysSinceSale('2026-11-20', at), 0);
      expect(daysSinceSale('2026-10-21', at), 30);
      expect(pastReturnWindow('2026-10-21', at, 30), isFalse);
      expect(pastReturnWindow('2026-10-20', at, 30), isTrue);
      expect(pastReturnWindow('2020-01-01', at, 0), isFalse);
    });
  });
}
