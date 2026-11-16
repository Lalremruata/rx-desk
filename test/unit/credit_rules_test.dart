import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/sales/credit_rules.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';

void main() {
  group('credit limit (SPEC §4.10)', () {
    test('own limit beats the default; 0 or negative = no limit', () {
      expect(effectiveCreditLimit(customerLimit: null, defaultLimit: 50000), 50000);
      expect(effectiveCreditLimit(customerLimit: 0, defaultLimit: 50000), 0);
      expect(effectiveCreditLimit(customerLimit: 200000, defaultLimit: 50000), 200000);
      expect(effectiveCreditLimit(customerLimit: null, defaultLimit: -5), 0);
    });

    test('over by: dues + adding − limit, never below 0', () {
      expect(creditOverBy(dues: 30000, adding: 20000, limit: 50000), 0);
      expect(creditOverBy(dues: 30000, adding: 20001, limit: 50000), 1);
      expect(creditOverBy(dues: 999999, adding: 1, limit: 0), 0);
      // An advance (negative dues) makes room.
      expect(creditOverBy(dues: -10000, adding: 55000, limit: 50000), 0);
      // Nothing added on credit → never over, even when already above.
      expect(creditOverBy(dues: 90000, adding: 0, limit: 50000), 0);
      final e = CreditLimitException(dues: 40000, limit: 50000, adding: 15000);
      expect((e.code, e.overBy), (BillError.overCreditLimit, 5000));
      expect(e.message, contains('₹500'));
    });
  });

  group('validateCreditBill', () {
    void ok({bool can = true, String name = 'Mami', String? phone = '98', int total = 1000, int paid = 0, String mode = 'Cash'}) =>
        validateCreditBill(canSellOnCredit: can, customerName: name, phone: phone, total: total, paidNow: paid, paidNowMode: mode);
    Matcher code(BillError c) => throwsA(isA<BillException>().having((e) => e.code, 'code', c));

    test('accepts a named customer with phone and paid now below the total', () {
      ok();
      ok(paid: 999, mode: 'UPI');
    });

    test('rejects', () {
      expect(() => ok(can: false), code(BillError.creditNotPermitted));
      expect(() => ok(name: '  '), code(BillError.customerRequired));
      expect(() => ok(name: walkInName), code(BillError.customerRequired));
      expect(() => ok(phone: ''), code(BillError.customerRequired));
      expect(() => ok(phone: null), code(BillError.customerRequired));
      expect(() => ok(paid: -1), code(BillError.invalidPaidNow));
      expect(() => ok(paid: 1000), code(BillError.invalidPaidNow));
      expect(() => ok(paid: 10, mode: 'Credit'), code(BillError.invalidPayment));
    });
  });

  test('bill payment modes: F8 order is Cash, UPI, Card, Credit', () {
    expect(billPaymentModes, ['Cash', 'UPI', 'Card', 'Credit']);
    expect(collectModes, ['Cash', 'UPI', 'Card']);
  });

  test('default refund mode: dues for a credit bill with a customer, else the bill’s mode', () {
    expect(defaultRefundMode(billPaymentMode: 'Credit', customerId: 4), 'Credit');
    expect(defaultRefundMode(billPaymentMode: 'Credit', customerId: null), 'Cash');
    expect(defaultRefundMode(billPaymentMode: 'UPI', customerId: 4), 'UPI');
  });

  test('ledger kinds: only payments and opening dues can be voided', () {
    expect(CustomerLedgerKind.values.where((k) => k.voidable), [CustomerLedgerKind.opening, CustomerLedgerKind.payment]);
    expect(CustomerLedgerKind.parse('credit_note'), CustomerLedgerKind.creditNote);
    expect(CustomerLedgerKind.values.where((k) => k.debit), [CustomerLedgerKind.opening, CustomerLedgerKind.bill]);
  });

  test('aging buckets', () {
    const today = '2026-11-09';
    expect(agingBucket(null, today), AgingBucket.none);
    expect(agingBucket('2026-11-09', today), AgingBucket.d30);
    expect(agingBucket('2026-10-10', today), AgingBucket.d30);
    expect(agingBucket('2026-10-09', today), AgingBucket.d60);
    expect(agingBucket('2026-08-11', today), AgingBucket.d90);
    expect(agingBucket('2026-08-10', today), AgingBucket.over90);
    expect(daysBetween('2026-11-10', today), 0);
  });

  test('settings → bill rules carry the credit permission and default limit', () {
    const s = AppSettings(defaultCreditLimitPaise: 250000);
    expect(s.billRules(role: StaffRole.pharmacist).canSellOnCredit, isTrue);
    expect(s.billRules(role: StaffRole.cashier).canSellOnCredit, isFalse);
    expect(s.billRules().defaultCreditLimit, 250000);
    expect(s.roleHas(StaffRole.cashier, Permission.collectPayments), isTrue);
    expect(s.roleHas(StaffRole.pharmacist, Permission.manageCustomerCredit), isFalse);
    expect(settingsErrors(const AppSettings(defaultCreditLimitPaise: -1)), contains('defaultCreditLimitPaise'));
  });
}
