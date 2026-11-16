import 'package:drift/drift.dart';

import '../../money/paise.dart';
import '../../purchases/dues_rules.dart';
import '../../purchases/purchase_rules.dart';
import '../app_database.dart';

part 'dues_dao.g.dart';

// ---------------------------------------------------------------------------
// Inputs and rows (SPEC §4.8).

class PaymentInput {
  const PaymentInput({required this.amount, required this.mode, this.reference = '', this.note = ''});
  final Paise amount;
  final String mode;
  final String reference;
  final String note;
}

class ReturnLineInput {
  const ReturnLineInput({required this.productId, required this.batchId, required this.qty});
  final int productId;
  final int batchId;
  final int qty;
}

/// A stockist's position.
class SupplierDues {
  const SupplierDues({
    required this.supplierId,
    required this.name,
    required this.creditDays,
    required this.phone,
    required this.gstin,
    required this.outstanding,
    required this.overdue,
    required this.advance,
    required this.openBills,
    required this.oldestDue,
    required this.hasOpening,
  });

  final int supplierId;
  final String name;
  final int creditDays;
  final String phone;
  final String gstin;

  /// Σ outstanding on debits.
  final Paise outstanding;

  /// Part of [outstanding] past its due date.
  final Paise overdue;

  /// Credit not yet applied to any bill.
  final Paise advance;
  final int openBills;
  final String? oldestDue;
  final bool hasOpening;

  /// Net: what the store owes (negative = advance with the stockist).
  Paise get balance => outstanding - advance;
}

class DuesPage {
  const DuesPage({required this.rows, required this.total, required this.ms});
  final List<SupplierDues> rows;
  final int total;
  final double ms;
}

class DuesTotals {
  const DuesTotals({this.owed = Paise.zero, this.overdue = Paise.zero, this.stockists = 0, this.overdueStockists = 0});

  /// Σ positive balances.
  final Paise owed;
  final Paise overdue;

  /// Stockists with a positive balance.
  final int stockists;
  final int overdueStockists;
}

/// A debit (bill or opening balance) with what's still owed on it.
class OpenBill {
  const OpenBill({
    required this.ledgerId,
    required this.kind,
    required this.date,
    required this.reference,
    required this.amount,
    required this.outstanding,
    required this.dueDate,
  });

  final int ledgerId;
  final LedgerKind kind;
  final String date;
  final String reference;
  final Paise amount;
  final Paise outstanding;
  final String dueDate;

  BillStatus get status => billStatus(amount: amount.value, outstanding: outstanding.value);
  bool overdueOn(String today) => isOverdue(dueDate: dueDate, outstanding: outstanding.value, today: today);
}

class StatementRow {
  const StatementRow({
    required this.id,
    required this.date,
    required this.kind,
    required this.reference,
    required this.mode,
    required this.note,
    required this.amount,
    required this.active,
    required this.voidReason,
    required this.balance,
    required this.dueDate,
  });

  final int id;
  final String date;
  final LedgerKind kind;
  final String reference;
  final String? mode;
  final String note;
  final Paise amount;
  final bool active;
  final String? voidReason;

  /// Running balance after this row (void rows don't move it).
  final Paise balance;
  final String? dueDate;

  Paise get debit => kind.debit && active ? amount : Paise.zero;
  Paise get credit => !kind.debit && active ? amount : Paise.zero;
}

class StatementCursor {
  const StatementCursor(this.date, this.id);
  final String date;
  final int id;
}

class StatementPage {
  const StatementPage({required this.rows, required this.hasMore});
  final List<StatementRow> rows;
  final bool hasMore;
}

// ---------------------------------------------------------------------------

/// Stockist ledger: bills, payments, credit notes, returns, allocations.
@DriftAccessor(tables: [Suppliers, PurchaseReceipts, SupplierLedger, LedgerAllocations, ReturnLines, Products, Batches])
class DuesDao extends DatabaseAccessor<AppDatabase> with _$DuesDaoMixin {
  DuesDao(super.attachedDatabase);

  Set<ResultSetImplementation<dynamic, dynamic>> get _reads => {suppliers, supplierLedger, ledgerAllocations, purchaseReceipts};

  static int _ts(DateTime at) => at.toUtc().millisecondsSinceEpoch;

  static void _checkDate(String d) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d)) throw const PurchaseException('Pick the date');
  }

  Future<Supplier> _supplier(int id) async {
    final s = await (select(suppliers)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (s == null) throw const PurchaseException('Stockist not found');
    return s;
  }

  Future<int> _insert({
    required int supplierId,
    required String date,
    required LedgerKind kind,
    required Paise amount,
    int? receiptId,
    String? dueDate,
    String? mode,
    String reference = '',
    String note = '',
    required DateTime at,
    int? staffId,
  }) {
    if (amount.value <= 0) throw const PurchaseException('Enter an amount above zero');
    _checkDate(date);
    return into(supplierLedger).insert(
      SupplierLedgerCompanion.insert(
        supplierId: supplierId,
        entryDate: date,
        kind: kind.code,
        amountPaise: amount.value,
        openPaise: Value(amount.value),
        receiptId: Value(receiptId),
        dueDate: Value(dueDate),
        mode: Value(mode),
        reference: Value(reference.trim()),
        note: Value(note.trim()),
        staffId: Value(staffId),
        createdAt: _ts(at),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Allocation state

  Future<List<OpenDebit>> _openDebits(int supplierId) async {
    final rows = await customSelect(
      '''
      SELECT id, COALESCE(due_date, entry_date) AS due, open_paise FROM supplier_ledger
      WHERE supplier_id = ?1 AND status = 'active' AND open_paise > 0 AND kind IN ('opening', 'bill')
      ''',
      variables: [Variable.withInt(supplierId)],
      readsFrom: _reads,
    ).get();
    return [for (final r in rows) OpenDebit(id: r.read<int>('id'), dueDate: r.read<String>('due'), outstanding: r.read<int>('open_paise'))];
  }

  Future<List<OpenCredit>> _openCredits(int supplierId) async {
    final rows = await customSelect(
      '''
      SELECT id, open_paise FROM supplier_ledger
      WHERE supplier_id = ?1 AND status = 'active' AND open_paise > 0 AND kind IN ('payment', 'credit_note', 'return')
      ORDER BY entry_date, id
      ''',
      variables: [Variable.withInt(supplierId)],
      readsFrom: _reads,
    ).get();
    return [for (final r in rows) OpenCredit(id: r.read<int>('id'), unallocated: r.read<int>('open_paise'))];
  }

  Future<void> _addOpen(int ledgerId, int delta) =>
      customUpdate('UPDATE supplier_ledger SET open_paise = open_paise + ?1 WHERE id = ?2',
          variables: [Variable.withInt(delta), Variable.withInt(ledgerId)], updates: {supplierLedger});

  Future<void> _write(List<Allocation> allocations) async {
    for (final a in allocations) {
      await into(ledgerAllocations).insert(
        LedgerAllocationsCompanion.insert(creditId: a.creditId, debitId: a.debitId, amountPaise: a.amount),
      );
      await _addOpen(a.creditId, -a.amount);
      await _addOpen(a.debitId, -a.amount);
    }
  }

  /// Applies all unallocated credit to open debits, oldest first.
  Future<void> _settle(int supplierId) async =>
      _write(settle(await _openCredits(supplierId), await _openDebits(supplierId)));

  // -------------------------------------------------------------------------
  // Writes — each one transaction (savepoint when nested).

  /// The debit for a received stockist invoice; existing advance is applied.
  /// Returns null when nothing is owed (bill total 0).
  Future<int?> addBill({
    required int supplierId,
    required int receiptId,
    required String date,
    required Paise amount,
    required String dueDate,
    required String invoiceNo,
    required DateTime at,
    int? staffId,
  }) {
    return transaction(() async {
      if (amount.value == 0) return null;
      final id = await _insert(
        supplierId: supplierId,
        date: date,
        kind: LedgerKind.bill,
        amount: amount,
        receiptId: receiptId,
        dueDate: dueDate,
        reference: invoiceNo,
        at: at,
        staffId: staffId,
      );
      await _settle(supplierId);
      return id;
    });
  }

  /// A payment to a stockist, applied oldest due first — or only to
  /// [pickedDebitIds]; the rest stays on account.
  Future<int> recordPayment({
    required int supplierId,
    required String date,
    required PaymentInput payment,
    Set<int>? pickedDebitIds,
    required DateTime at,
    int? staffId,
  }) {
    return transaction(() async {
      await _supplier(supplierId);
      if (!paymentModes.contains(payment.mode)) throw const PurchaseException('Pick how it was paid');
      final id = await _insert(
        supplierId: supplierId,
        date: date,
        kind: LedgerKind.payment,
        amount: payment.amount,
        mode: payment.mode,
        reference: payment.reference,
        note: payment.note,
        at: at,
        staffId: staffId,
      );
      final debits = await _openDebits(supplierId);
      if (pickedDebitIds != null && pickedDebitIds.any((d) => !debits.any((x) => x.id == d))) {
        throw const PurchaseException('A picked bill is already paid or isn’t this stockist’s');
      }
      final (allocs, _) = allocate(id, payment.amount.value, debits, picked: pickedDebitIds);
      await _write(allocs);
      return id;
    });
  }

  /// A credit note with no stock movement (rate difference, discount…).
  Future<int> recordCreditNote({
    required int supplierId,
    required String date,
    required Paise amount,
    required String reference,
    String note = '',
    required DateTime at,
    int? staffId,
  }) {
    return transaction(() async {
      await _supplier(supplierId);
      final id = await _insert(
        supplierId: supplierId,
        date: date,
        kind: LedgerKind.creditNote,
        amount: amount,
        reference: reference,
        note: note,
        at: at,
        staffId: staffId,
      );
      await _settle(supplierId);
      return id;
    });
  }

  /// Stock sent back to the stockist against their credit note: batch qty
  /// decreases ('supplier_return' movements) and the credit is applied.
  Future<int> recordReturn({
    required int supplierId,
    required String date,
    required Paise amount,
    required String reference,
    String note = '',
    required List<ReturnLineInput> lines,
    required DateTime at,
    int? staffId,
  }) {
    return transaction(() async {
      await _supplier(supplierId);
      if (lines.isEmpty) throw const PurchaseException('Add the medicines being returned');
      final seen = <int>{};
      for (final l in lines) {
        if (!seen.add(l.batchId)) throw const PurchaseException('The same batch is on this return twice');
      }
      final id = await _insert(
        supplierId: supplierId,
        date: date,
        kind: LedgerKind.stockReturn,
        amount: amount,
        reference: reference,
        note: note,
        at: at,
        staffId: staffId,
      );
      for (final l in lines) {
        final p = await (select(products)..where((x) => x.id.equals(l.productId))).getSingleOrNull();
        final b = await (select(batches)..where((x) => x.id.equals(l.batchId))).getSingleOrNull();
        if (p == null || b == null || b.productId != p.id) throw const PurchaseException('Batch doesn’t belong to that medicine');
        if (l.qty < 1) throw PurchaseException('${p.name} — enter the quantity returned');
        if (l.qty > b.qty) throw PurchaseException('${p.name} batch ${b.batchNo} has only ${b.qty}');
        await attachedDatabase.catalogDao.takeOutStock(
          batchId: b.id,
          qty: l.qty,
          reason: 'supplier_return',
          at: at,
          staffId: staffId,
          refType: 'supplier_ledger',
          refId: id,
        );
        await into(returnLines).insert(
          ReturnLinesCompanion.insert(
            ledgerId: id,
            productId: p.id,
            batchId: b.id,
            itemName: p.name,
            batchNo: b.batchNo,
            expiry: b.expiry,
            qty: l.qty,
          ),
        );
      }
      await _settle(supplierId);
      return id;
    });
  }

  /// What was owed before RxDesk — one active entry per stockist.
  Future<int> setOpeningBalance({required int supplierId, required String date, required Paise amount, required DateTime at, int? staffId}) {
    return transaction(() async {
      await _supplier(supplierId);
      final existing = await (select(supplierLedger)
            ..where((l) => l.supplierId.equals(supplierId) & l.kind.equals(LedgerKind.opening.code) & l.status.equals('active')))
          .get();
      if (existing.isNotEmpty) throw const PurchaseException('Opening balance is already set — void it first to change it');
      final id = await _insert(
        supplierId: supplierId,
        date: date,
        kind: LedgerKind.opening,
        amount: amount,
        dueDate: date,
        reference: 'Opening balance',
        at: at,
        staffId: staffId,
      );
      await _settle(supplierId);
      return id;
    });
  }

  /// Voids a payment, credit note or opening balance. The row stays; its
  /// allocations are released and other credit is re-applied.
  Future<void> voidEntry(int id, {required String reason, required DateTime at}) {
    return transaction(() async {
      final e = await (select(supplierLedger)..where((l) => l.id.equals(id))).getSingleOrNull();
      if (e == null) throw const PurchaseException('Entry not found');
      if (e.status != 'active') throw const PurchaseException('Already void');
      final kind = LedgerKind.parse(e.kind);
      if (!kind.voidable) throw PurchaseException('A ${kind.label.toLowerCase()} can’t be voided');
      if (reason.trim().isEmpty) throw const PurchaseException('Give a reason for voiding');
      final released = await (select(ledgerAllocations)..where((a) => a.creditId.equals(id) | a.debitId.equals(id))).get();
      for (final a in released) {
        await _addOpen(a.creditId == id ? a.debitId : a.creditId, a.amountPaise);
      }
      await (delete(ledgerAllocations)..where((a) => a.creditId.equals(id) | a.debitId.equals(id))).go();
      await (update(supplierLedger)..where((l) => l.id.equals(id))).write(
        SupplierLedgerCompanion(status: const Value('void'), voidReason: Value(reason.trim()), openPaise: const Value(0)),
      );
      await _settle(e.supplierId);
    });
  }

  Future<void> updateSupplier(int id, {required int creditDays, String? phone, String? gstin}) {
    return transaction(() async {
      await _supplier(id);
      if (creditDays < 0 || creditDays > 365) throw const PurchaseException('Credit days must be 0–365');
      final g = (gstin ?? '').trim().toUpperCase();
      if (g.isNotEmpty && !RegExp(r'^[0-9A-Z]{15}$').hasMatch(g)) throw const PurchaseException('GSTIN is 15 letters / digits');
      await (update(suppliers)..where((s) => s.id.equals(id))).write(
        SuppliersCompanion(
          creditDays: Value(creditDays),
          phone: Value((phone ?? '').trim().isEmpty ? null : phone!.trim()),
          gstin: Value(g.isEmpty ? null : g),
        ),
      );
    });
  }

  // -------------------------------------------------------------------------
  // Queries

  /// Per-stockist totals; ?1 = today. Reads only open entries
  /// (idx_ledger_open).
  static const String _duesSql = '''
    SELECT s.id, s.name, s.credit_days, COALESCE(s.phone, '') AS phone, COALESCE(s.gstin, '') AS gstin,
      COALESCE(SUM(CASE WHEN d.debit = 1 THEN d.open ELSE 0 END), 0) AS outstanding,
      COALESCE(SUM(CASE WHEN d.debit = 1 AND d.due < ?1 THEN d.open ELSE 0 END), 0) AS overdue,
      COALESCE(SUM(CASE WHEN d.debit = 0 THEN d.open ELSE 0 END), 0) AS advance,
      COALESCE(SUM(d.debit), 0) AS open_bills,
      MIN(CASE WHEN d.debit = 1 THEN d.due END) AS oldest_due,
      EXISTS (SELECT 1 FROM supplier_ledger o WHERE o.supplier_id = s.id AND o.kind = 'opening' AND o.status = 'active') AS has_opening
    FROM suppliers s
    LEFT JOIN (
      SELECT supplier_id, COALESCE(due_date, entry_date) AS due, open_paise AS open,
             CASE WHEN kind IN ('opening', 'bill') THEN 1 ELSE 0 END AS debit
      FROM supplier_ledger WHERE status = 'active' AND open_paise > 0
    ) d ON d.supplier_id = s.id
  ''';

  static SupplierDues _dues(QueryRow r) => SupplierDues(
        supplierId: r.read<int>('id'),
        name: r.read<String>('name'),
        creditDays: r.read<int>('credit_days'),
        phone: r.read<String>('phone'),
        gstin: r.read<String>('gstin'),
        outstanding: Paise(r.read<int>('outstanding')),
        overdue: Paise(r.read<int>('overdue')),
        advance: Paise(r.read<int>('advance')),
        openBills: r.read<int>('open_bills'),
        oldestDue: r.readNullable<String>('oldest_due'),
        hasOpening: r.read<int>('has_opening') == 1,
      );

  /// Stockists, most overdue first, then by balance; page with offset (the
  /// list is a few hundred stockists at most).
  Future<DuesPage> duesPage({required String today, String search = '', int page = 1, int pageSize = 50}) async {
    final sw = Stopwatch()..start();
    final q = search.trim().toLowerCase();
    final like = Variable.withString('%$q%');
    final total = (await customSelect(
      q.isEmpty ? 'SELECT COUNT(*) AS c FROM suppliers' : 'SELECT COUNT(*) AS c FROM suppliers WHERE lower(name) LIKE ?1',
      variables: [if (q.isNotEmpty) like],
      readsFrom: {suppliers},
    ).getSingle())
        .read<int>('c');
    final size = pageSize.clamp(1, 500);
    final pages = total == 0 ? 1 : (total + size - 1) ~/ size;
    final p = page.clamp(1, pages);
    final rows = await customSelect(
      '''
      $_duesSql
      WHERE ?2 = '' OR lower(s.name) LIKE ?3
      GROUP BY s.id
      ORDER BY overdue DESC, outstanding - advance DESC, lower(s.name)
      LIMIT ?4 OFFSET ?5
      ''',
      variables: [
        Variable.withString(today),
        Variable.withString(q),
        like,
        Variable.withInt(size),
        Variable.withInt((p - 1) * size),
      ],
      readsFrom: _reads,
    ).get();
    return DuesPage(rows: rows.map(_dues).toList(), total: total, ms: sw.elapsedMicroseconds / 1000);
  }

  Future<SupplierDues> supplierDues(int supplierId, {required String today}) async {
    final r = await customSelect(
      '$_duesSql WHERE s.id = ?2 GROUP BY s.id',
      variables: [Variable.withString(today), Variable.withInt(supplierId)],
      readsFrom: _reads,
    ).getSingleOrNull();
    if (r == null) throw const PurchaseException('Stockist not found');
    return _dues(r);
  }

  /// Totals across stockists, and the top [limit] by overdue then balance.
  Future<(DuesTotals, List<SupplierDues>)> totals({required String today, int limit = 4}) async {
    final rows = await customSelect(
      'SELECT * FROM ($_duesSql GROUP BY s.id) WHERE outstanding - advance > 0 ORDER BY overdue DESC, outstanding - advance DESC, lower(name)',
      variables: [Variable.withString(today)],
      readsFrom: _reads,
    ).get();
    final all = rows.map(_dues).toList();
    return (
      DuesTotals(
        owed: all.map((d) => d.balance).sum(),
        overdue: all.map((d) => d.overdue).sum(),
        stockists: all.length,
        overdueStockists: all.where((d) => d.overdue.value > 0).length,
      ),
      all.take(limit).toList(),
    );
  }

  /// Debits with something still owed, oldest due first.
  Future<List<OpenBill>> openBills(int supplierId) async {
    final rows = await customSelect(
      '''
      SELECT id, kind, entry_date, reference, amount_paise, COALESCE(due_date, entry_date) AS due, open_paise AS open
      FROM supplier_ledger
      WHERE supplier_id = ?1 AND status = 'active' AND open_paise > 0 AND kind IN ('opening', 'bill')
      ORDER BY due, id
      ''',
      variables: [Variable.withInt(supplierId)],
      readsFrom: _reads,
    ).get();
    return [
      for (final r in rows)
        OpenBill(
          ledgerId: r.read<int>('id'),
          kind: LedgerKind.parse(r.read<String>('kind')),
          date: r.read<String>('entry_date'),
          reference: r.read<String>('reference'),
          amount: Paise(r.read<int>('amount_paise')),
          outstanding: Paise(r.read<int>('open')),
          dueDate: r.read<String>('due'),
        ),
    ];
  }

  /// Ledger rows oldest first with a running balance; keyset on (date, id).
  Future<StatementPage> statement(int supplierId, {StatementCursor? after, int limit = 50}) async {
    final vars = <Variable<Object>>[Variable.withInt(supplierId)];
    var cursor = '';
    if (after != null) {
      vars
        ..add(Variable.withString(after.date))
        ..add(Variable.withInt(after.id));
      cursor = 'WHERE (entry_date, id) > (?2, ?3)';
    }
    vars.add(Variable.withInt(limit + 1));
    final rows = await customSelect(
      '''
      SELECT * FROM (
        SELECT l.id, l.entry_date, l.kind, l.reference, l.mode, l.note, l.amount_paise, l.status, l.void_reason, l.due_date,
               SUM(CASE WHEN l.status <> 'active' THEN 0
                        WHEN l.kind IN ('opening', 'bill') THEN l.amount_paise ELSE -l.amount_paise END)
                 OVER (ORDER BY l.entry_date, l.id ROWS UNBOUNDED PRECEDING) AS balance
        FROM supplier_ledger l WHERE l.supplier_id = ?1
      ) $cursor
      ORDER BY entry_date, id LIMIT ?${vars.length}
      ''',
      variables: vars,
      readsFrom: _reads,
    ).get();
    return StatementPage(
      rows: [
        for (final r in rows.take(limit))
          StatementRow(
            id: r.read<int>('id'),
            date: r.read<String>('entry_date'),
            kind: LedgerKind.parse(r.read<String>('kind')),
            reference: r.read<String>('reference'),
            mode: r.readNullable<String>('mode'),
            note: r.read<String>('note'),
            amount: Paise(r.read<int>('amount_paise')),
            active: r.read<String>('status') == 'active',
            voidReason: r.readNullable<String>('void_reason'),
            balance: Paise(r.read<int>('balance')),
            dueDate: r.readNullable<String>('due_date'),
          ),
      ],
      hasMore: rows.length > limit,
    );
  }

  Future<List<ReturnLine>> returnLinesOf(int ledgerId) =>
      (select(returnLines)..where((l) => l.ledgerId.equals(ledgerId))).get();

}
