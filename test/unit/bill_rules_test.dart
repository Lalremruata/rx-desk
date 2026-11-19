import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/money/gst.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/utils/expiry.dart';

final now = DateTime(2026, 11, 9);

BatchOption b(int id, String exp, int qty) => BatchOption(batchId: id, batchNo: 'B$id', expiry: exp, qty: qty);

LineFacts facts({String schedule = '', String expiry = '2027-06', int qty = 10, bool active = true}) => LineFacts(
      productName: 'Med',
      schedule: schedule,
      isActive: active,
      batchNo: 'B1',
      expiry: expiry,
      batchQty: qty,
      mrp: const Paise(1000),
      gstRate: 12,
    );

void expectError(void Function() f, BillError code) =>
    expect(f, throwsA(isA<BillException>().having((e) => e.code, 'code', code)));

void main() {
  group('expiry (month-level, last day of month)', () {
    test('same month is still saleable, previous month expired', () {
      expect(isExpired('2026-11', now), isFalse);
      expect(isExpired('2026-10', now), isTrue);
      expect(isExpired('2027-01', now), isFalse);
    });
    test('monthsLeft', () {
      expect(monthsLeft('2026-11', now), 0);
      expect(monthsLeft('2027-02', now), 3);
      expect(monthsLeft('2026-10', now), -1);
    });
    test('helpers', () {
      expect(addMonthsKey(now, 3), '2027-02');
      expect(addMonthsKey(now, -11), '2025-12');
      expect(formatExpiry('2027-02'), 'Feb 2027');
      expect(dayLabel('2026-11-03'), 'Tue 3 Nov 26');
      expect(isValidExpiry('2027-13'), isFalse);
    });
  });

  group('pickBatches — FEFO (SPEC §4.3)', () {
    test('one saleable batch → add directly', () {
      final r = pickBatches([b(1, '2027-01', 5), b(2, '2026-09', 4)], now);
      expect(r, isA<AddDirect>().having((x) => x.batch.batchId, 'id', 1));
    });

    test('several → picker sorted by expiry; expired listed separately', () {
      final r = pickBatches([b(3, '2028-01', 5), b(1, '2027-01', 5), b(9, '2026-09', 4), b(2, '2027-06', 1)], now);
      expect(r, isA<ShowPicker>());
      final p = r as ShowPicker;
      expect(p.saleable.map((x) => x.batchId), [1, 2, 3]);
      expect(p.expired.map((x) => x.batchId), [9]);
    });

    test('quantity already in the bill is not available again', () {
      final r = pickBatches([b(1, '2027-01', 2), b(2, '2027-06', 3)], now, inBill: {1: 2});
      expect(r, isA<AddDirect>().having((x) => x.batch.batchId, 'id', 2));
      final all = pickBatches([b(1, '2027-01', 2)], now, inBill: {1: 2});
      expect(all, isA<AllInBill>());
    });

    test('no saleable stock → substitutes (expired stock does not count)', () {
      expect(pickBatches([b(1, '2026-09', 50), b(2, '2027-01', 0)], now), isA<ShowSubstitutes>());
      expect(pickBatches(const [], now), isA<ShowSubstitutes>());
    });
  });

  group('validateBill', () {
    void run({
      List<BillLineRequest>? lines,
      LineFacts? f,
      BillRules rules = const BillRules(),
      int disc = 0,
      String? doctor,
      String pay = 'Cash',
    }) =>
        validateBill(
          lines: lines ?? const [BillLineRequest(productId: 1, batchId: 1, qty: 2)],
          factsByBatch: {1: f ?? facts()},
          rules: rules,
          discount: PercentDiscount(disc),
          doctorName: doctor,
          paymentMode: pay,
          at: now,
        );

    test('valid bill passes', run);
    test('MRP / GST edited while the bill was open → priceChanged with the current prices', () {
      run(lines: const [BillLineRequest(productId: 1, batchId: 1, qty: 2, expectedMrp: Paise(1000), expectedGstRate: 12)]);
      expect(
        () => run(lines: const [BillLineRequest(productId: 1, batchId: 1, qty: 2, expectedMrp: Paise(900), expectedGstRate: 12)]),
        throwsA(isA<PriceChangedException>()
            .having((e) => e.changes[1], 'change', (mrp: const Paise(1000), gstRate: 12))
            .having((e) => e.message, 'message', contains('MRP of Med is now ₹10.00'))),
      );
      expectError(
        () => run(lines: const [BillLineRequest(productId: 1, batchId: 1, qty: 2, expectedMrp: Paise(1000), expectedGstRate: 5)]),
        BillError.priceChanged,
      );
    });
    test('empty', () => expectError(() => run(lines: const []), BillError.empty));
    test('zero qty', () => expectError(() => run(lines: const [BillLineRequest(productId: 1, batchId: 1, qty: 0)]), BillError.invalidQty));
    test('expired batch can never be sold — even with negative stock allowed', () {
      expectError(() => run(f: facts(expiry: '2026-10'), rules: const BillRules(allowNegativeStock: true)), BillError.expiredBatch);
    });
    test('schedule X is blocked', () => expectError(() => run(f: facts(schedule: 'X')), BillError.scheduleX));
    test('H / H1 needs a doctor when the setting is on', () {
      expectError(() => run(f: facts(schedule: 'H')), BillError.doctorRequired);
      expectError(() => run(f: facts(schedule: 'H1'), doctor: '  '), BillError.doctorRequired);
      run(f: facts(schedule: 'H'), doctor: 'Dr. A');
      run(f: facts(schedule: 'H'), rules: const BillRules(requireDoctorForRx: false));
    });
    test('role without Rx permission cannot sell H', () {
      expectError(() => run(f: facts(schedule: 'H'), doctor: 'Dr. A', rules: const BillRules(canSellRx: false)), BillError.rxNotPermitted);
    });
    test('stock never goes negative unless allowed (summed per batch)', () {
      const two = [BillLineRequest(productId: 1, batchId: 1, qty: 6), BillLineRequest(productId: 1, batchId: 1, qty: 5)];
      expectError(() => run(lines: two), BillError.insufficientStock);
      run(lines: two, rules: const BillRules(allowNegativeStock: true));
    });
    test('discount limited by setting and by permission', () {
      expectError(() => run(disc: 20), BillError.discountTooHigh);
      run(disc: 15);
      expectError(() => run(disc: 10, rules: const BillRules(canGiveHighDiscount: false)), BillError.discountNotPermitted);
      run(disc: 5, rules: const BillRules(canGiveHighDiscount: false));
    });
    test('inactive product', () => expectError(() => run(f: facts(active: false)), BillError.inactiveProduct));
    test('unknown payment mode', () => expectError(() => run(pay: 'Cheque'), BillError.invalidPayment));
  });

  test('discount chips filtered to ≤ max', () {
    expect(const BillRules(maxDiscountPct: 10).discountChips, [0, 5, 10]);
    expect(const BillRules().discountChips, [0, 5, 10, 15]);
  });

  test('normaliseSalt', () => expect(normaliseSalt('  Paracetamol   650 MG '), 'paracetamol 650 mg'));

  group('discountError (SPEC §4.6)', () {
    const owner = BillRules();
    const cashier = BillRules(canGiveHighDiscount: false);
    const sub = Paise(10000); // ₹100 MRP subtotal
    BillError? code(BillDiscount d, {BillRules r = owner, Paise s = sub}) => discountError(d, s, r)?.$1;

    test('percent: up to the max; above 5 % needs the permission', () {
      expect(code(const PercentDiscount(15)), isNull);
      expect(code(const PercentDiscount(16)), BillError.discountTooHigh);
      expect(code(const PercentDiscount(-1)), BillError.discountTooHigh);
      expect(code(const PercentDiscount(5), r: cashier), isNull);
      expect(code(const PercentDiscount(6), r: cashier), BillError.discountNotPermitted);
    });

    test('flat ₹: held to the same % of the MRP subtotal', () {
      expect(code(const FlatDiscount(Paise(1500))), isNull); // exactly 15 %
      expect(code(const FlatDiscount(Paise(1501))), BillError.discountTooHigh);
      expect(discountProblem(const FlatDiscount(Paise(1501)), sub, owner), 'Discount can be at most 15% of the MRP (₹15.00)');
      expect(code(const FlatDiscount(Paise(500)), r: cashier), isNull); // exactly 5 %
      expect(code(const FlatDiscount(Paise(501)), r: cashier), BillError.discountNotPermitted);
      expect(discountProblem(const FlatDiscount(Paise(501)), sub, cashier), 'Your role can’t give more than 5% discount (₹5.00 on this bill)');
      expect(code(const FlatDiscount(Paise(10001)), r: const BillRules(maxDiscountPct: 100)), BillError.discountTooHigh);
      expect(code(const FlatDiscount(Paise(-1))), BillError.discountTooHigh);
      expect(code(const FlatDiscount(Paise.zero), s: Paise.zero), isNull);
      expect(code(const FlatDiscount(Paise(1)), s: Paise.zero), BillError.discountTooHigh);
    });

    test('validateBill checks a flat ₹ against the bill’s own subtotal', () {
      void run(int flat) => validateBill(
            lines: const [BillLineRequest(productId: 1, batchId: 1, qty: 2)], // 2 × ₹10
            factsByBatch: {1: facts()},
            rules: owner,
            discount: FlatDiscount(Paise(flat)),
            doctorName: null,
            paymentMode: 'Cash',
            at: now,
          );
      run(300);
      expectError(() => run(301), BillError.discountTooHigh);
    });

    test('maxFlatDiscount', () {
      expect(maxFlatDiscount(const Paise(3333), 15), const Paise(499));
      expect(maxFlatDiscount(Paise.zero, 15), Paise.zero);
    });
  });
}
