/// Ledger allocation shared by the stockist (SPEC §4.8) and customer
/// (SPEC §4.10) ledgers. Pure Dart — amounts are integer paise.
library;

/// A debit with something still owed on it.
class OpenDebit {
  const OpenDebit({required this.id, required this.dueDate, required this.outstanding});
  final int id;

  /// 'YYYY-MM-DD'; empty sorts first.
  final String dueDate;
  final int outstanding;
}

/// A credit with something not yet applied to any debit.
class OpenCredit {
  const OpenCredit({required this.id, required this.unallocated});
  final int id;
  final int unallocated;
}

class Allocation {
  const Allocation({required this.creditId, required this.debitId, required this.amount});
  final int creditId;
  final int debitId;
  final int amount;

  @override
  bool operator ==(Object other) =>
      other is Allocation && other.creditId == creditId && other.debitId == debitId && other.amount == amount;

  @override
  int get hashCode => Object.hash(creditId, debitId, amount);

  @override
  String toString() => 'Allocation($creditId → $debitId: $amount)';
}

List<OpenDebit> _byDue(Iterable<OpenDebit> d) => d.toList()
  ..sort((a, b) {
    final c = a.dueDate.compareTo(b.dueDate);
    return c != 0 ? c : a.id.compareTo(b.id);
  });

/// Splits [amount] of credit [creditId] over [debits]: oldest due date first
/// (then id), or only [picked] debits (in due order) when given. Returns the
/// allocations and what stays on account.
(List<Allocation>, int remainder) allocate(int creditId, int amount, Iterable<OpenDebit> debits, {Set<int>? picked}) {
  if (amount < 0) throw ArgumentError.value(amount, 'amount');
  var left = amount;
  final out = <Allocation>[];
  for (final d in _byDue(debits.where((d) => picked == null || picked.contains(d.id)))) {
    if (left == 0) break;
    if (d.outstanding <= 0) continue;
    final a = left < d.outstanding ? left : d.outstanding;
    out.add(Allocation(creditId: creditId, debitId: d.id, amount: a));
    left -= a;
  }
  return (out, left);
}

/// Applies every unallocated credit (oldest [credits] first) to open debits,
/// oldest due first — after a new bill, an opening balance or a void.
List<Allocation> settle(List<OpenCredit> credits, List<OpenDebit> debits) {
  final owed = {for (final d in debits) d.id: d.outstanding};
  final order = _byDue(debits);
  final out = <Allocation>[];
  for (final c in credits) {
    var left = c.unallocated;
    for (final d in order) {
      if (left <= 0) break;
      final o = owed[d.id]!;
      if (o <= 0) continue;
      final a = left < o ? left : o;
      out.add(Allocation(creditId: c.id, debitId: d.id, amount: a));
      owed[d.id] = o - a;
      left -= a;
    }
  }
  return out;
}
