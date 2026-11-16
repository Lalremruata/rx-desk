import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/purchases/dues_rules.dart';

void main() {
  const bills = [
    OpenDebit(id: 3, dueDate: '2026-10-20', outstanding: 5000),
    OpenDebit(id: 1, dueDate: '2026-10-01', outstanding: 10000),
    OpenDebit(id: 2, dueDate: '2026-10-01', outstanding: 2500),
  ];

  group('allocate (SPEC §4.8)', () {
    test('oldest due first, then id; exact paise', () {
      final (a, left) = allocate(9, 12600, bills);
      expect(a, const [
        Allocation(creditId: 9, debitId: 1, amount: 10000),
        Allocation(creditId: 9, debitId: 2, amount: 2500),
        Allocation(creditId: 9, debitId: 3, amount: 100),
      ]);
      expect(left, 0);
    });

    test('over-payment leaves the rest on account', () {
      final (a, left) = allocate(9, 20000, bills);
      expect(a.fold<int>(0, (s, x) => s + x.amount), 17500);
      expect(left, 2500);
    });

    test('picked bills only; remainder on account', () {
      final (a, left) = allocate(9, 6000, bills, picked: {3});
      expect(a, const [Allocation(creditId: 9, debitId: 3, amount: 5000)]);
      expect(left, 1000);
    });

    test('never more than a bill’s outstanding; skips settled bills', () {
      final (a, _) = allocate(9, 100, const [OpenDebit(id: 1, dueDate: '', outstanding: 0), OpenDebit(id: 2, dueDate: '', outstanding: 40)]);
      expect(a, const [Allocation(creditId: 9, debitId: 2, amount: 40)]);
    });
  });

  test('settle applies advances oldest credit first to oldest bills', () {
    final a = settle(
      const [OpenCredit(id: 10, unallocated: 3000), OpenCredit(id: 11, unallocated: 9000)],
      bills,
    );
    expect(a, const [
      Allocation(creditId: 10, debitId: 1, amount: 3000),
      Allocation(creditId: 11, debitId: 1, amount: 7000),
      Allocation(creditId: 11, debitId: 2, amount: 2000),
    ]);
    expect(settle(const [OpenCredit(id: 1, unallocated: 500)], const []), isEmpty);
  });

  test('due dates, status and overdue', () {
    expect(dueDateFor('2026-09-02', 30), '2026-10-02');
    expect(dueDateFor('2026-12-15', 30), '2027-01-14');
    expect(dueDateFor('2026-11-09', 0), '2026-11-09');
    expect(billStatus(amount: 1000, outstanding: 0), BillStatus.paid);
    expect(billStatus(amount: 1000, outstanding: 400), BillStatus.part);
    expect(billStatus(amount: 1000, outstanding: 1000), BillStatus.unpaid);
    expect(isOverdue(dueDate: '2026-11-08', outstanding: 1, today: '2026-11-09'), isTrue);
    expect(isOverdue(dueDate: '2026-11-09', outstanding: 1, today: '2026-11-09'), isFalse);
    expect(isOverdue(dueDate: '2026-11-01', outstanding: 0, today: '2026-11-09'), isFalse);
    expect(daysOverdue('2026-10-30', '2026-11-09'), 10);
    expect(daysOverdue('2026-11-30', '2026-11-09'), 0);
  });

  test('kinds: sign and voidability', () {
    expect(LedgerKind.parse('credit_note'), LedgerKind.creditNote);
    expect(LedgerKind.parse('return').debit, isFalse);
    expect(LedgerKind.bill.debit, isTrue);
    expect([for (final k in LedgerKind.values) if (k.voidable) k], [LedgerKind.opening, LedgerKind.payment, LedgerKind.creditNote]);
  });
}
