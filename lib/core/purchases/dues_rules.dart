/// Stockist dues (SPEC §4.8). Pure Dart — amounts are integer paise.
library;

import '../utils/expiry.dart';

export '../ledger/allocation.dart';

const List<String> paymentModes = ['Cash', 'UPI', 'Cheque', 'NEFT'];

/// Ledger entry kinds, stored by [code].
enum LedgerKind {
  opening('opening', 'Opening balance', debit: true),
  bill('bill', 'Bill', debit: true),
  payment('payment', 'Payment', debit: false),
  creditNote('credit_note', 'Credit note', debit: false),
  stockReturn('return', 'Return', debit: false);

  const LedgerKind(this.code, this.label, {required this.debit});
  final String code;
  final String label;

  /// Debits add to what the store owes; credits reduce it.
  final bool debit;

  /// Mistakes in these can be voided; bills and returns moved stock.
  bool get voidable => this == opening || this == payment || this == creditNote;

  static LedgerKind parse(String code) => values.firstWhere((k) => k.code == code);
}

/// Received date + credit days.
String dueDateFor(String receivedDate, int creditDays) {
  final d = parseDateKey(receivedDate);
  return dateKey(DateTime(d.year, d.month, d.day + creditDays));
}

enum BillStatus {
  paid('Paid'),
  part('Part paid'),
  unpaid('Unpaid');

  const BillStatus(this.label);
  final String label;
}

BillStatus billStatus({required int amount, required int outstanding}) {
  if (outstanding <= 0) return BillStatus.paid;
  if (outstanding < amount) return BillStatus.part;
  return BillStatus.unpaid;
}

/// Something still owed and the due date is before [today] ('YYYY-MM-DD').
bool isOverdue({required String? dueDate, required int outstanding, required String today}) =>
    outstanding > 0 && dueDate != null && dueDate.isNotEmpty && dueDate.compareTo(today) < 0;

/// Days past due (0 when not overdue).
int daysOverdue(String dueDate, String today) {
  if (dueDate.isEmpty || dueDate.compareTo(today) >= 0) return 0;
  return parseDateKey(today).difference(parseDateKey(dueDate)).inDays;
}
