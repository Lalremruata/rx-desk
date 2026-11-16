import 'package:drift/drift.dart';

import '../../money/paise.dart';
import '../../sales/credit_rules.dart';
import '../../utils/expiry.dart';
import '../app_database.dart';

part 'customers_dao.g.dart';

// ---------------------------------------------------------------------------
// Inputs and rows (SPEC §4.10).

class CustomerException implements Exception {
  const CustomerException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CustomerPaymentInput {
  const CustomerPaymentInput({required this.amount, required this.mode, this.reference = '', this.note = ''});
  final Paise amount;
  final String mode;
  final String reference;
  final String note;
}

/// A customer's position.
class CustomerDues {
  const CustomerDues({
    required this.customerId,
    required this.name,
    required this.phone,
    required this.address,
    required this.note,
    required this.creditLimit,
    required this.outstanding,
    required this.advance,
    required this.openBills,
    required this.oldestOpen,
    required this.lastPayment,
    required this.hasOpening,
  });

  final int customerId;
  final String name;
  final String phone;
  final String address;
  final String note;

  /// The customer's own limit (paise); null = Settings default, 0 = none.
  final int? creditLimit;

  /// Σ outstanding on debits.
  final Paise outstanding;

  /// Credit not yet applied to any bill.
  final Paise advance;
  final int openBills;

  /// Date of the oldest debit with something still owed.
  final String? oldestOpen;
  final String? lastPayment;
  final bool hasOpening;

  /// Net dues (negative = advance with the store).
  Paise get balance => outstanding - advance;

  AgingBucket agingOn(String today) => agingBucket(oldestOpen, today);
}

class CustomerDuesPage {
  const CustomerDuesPage({required this.rows, required this.total, required this.ms});
  final List<CustomerDues> rows;
  final int total;
  final double ms;
}

class CustomerDuesTotals {
  const CustomerDuesTotals({this.owed = Paise.zero, this.customers = 0, this.over90 = Paise.zero, this.over90Customers = 0});

  /// Σ positive balances.
  final Paise owed;

  /// Customers with dues.
  final int customers;

  /// Outstanding on debits more than 90 days old.
  final Paise over90;
  final int over90Customers;
}

/// A debit (bill or opening dues) with what's still owed on it.
class CustomerOpenBill {
  const CustomerOpenBill({
    required this.ledgerId,
    required this.kind,
    required this.date,
    required this.reference,
    required this.invoiceId,
    required this.amount,
    required this.outstanding,
  });

  final int ledgerId;
  final CustomerLedgerKind kind;
  final String date;

  /// Invoice number, or 'Opening dues'.
  final String reference;
  final int? invoiceId;
  final Paise amount;
  final Paise outstanding;

  bool get partPaid => outstanding.value < amount.value;
}

class CustomerStatementRow {
  const CustomerStatementRow({
    required this.id,
    required this.date,
    required this.kind,
    required this.reference,
    required this.invoiceId,
    required this.mode,
    required this.note,
    required this.amount,
    required this.active,
    required this.voidReason,
    required this.balance,
  });

  final int id;
  final String date;
  final CustomerLedgerKind kind;
  final String reference;
  final int? invoiceId;
  final String? mode;
  final String note;
  final Paise amount;
  final bool active;
  final String? voidReason;

  /// Running balance after this row (void rows don't move it).
  final Paise balance;

  Paise get debit => kind.debit && active ? amount : Paise.zero;
  Paise get credit => !kind.debit && active ? amount : Paise.zero;
}

class CustomerStatementCursor {
  const CustomerStatementCursor(this.date, this.id);
  final String date;
  final int id;
}

class CustomerStatementPage {
  const CustomerStatementPage({required this.rows, required this.hasMore});
  final List<CustomerStatementRow> rows;
  final bool hasMore;
}

// ---------------------------------------------------------------------------

/// Customer ledger (udhaar): bills on credit, payments, credit notes,
/// opening dues and their allocations. Every write is one transaction (a
/// savepoint when called from a bill save).
@DriftAccessor(tables: [Customers, CustomerLedger, CustomerAllocations, Invoices])
class CustomersDao extends DatabaseAccessor<AppDatabase> with _$CustomersDaoMixin {
  CustomersDao(super.attachedDatabase);

  Set<ResultSetImplementation<dynamic, dynamic>> get _reads => {customers, customerLedger, customerAllocations, invoices};

  static int _ts(DateTime at) => at.toUtc().millisecondsSinceEpoch;

  static void _checkDate(String d) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d)) throw const CustomerException('Pick the date');
  }

  /// Same as billing stores it (SalesDao trims only).
  static String _cleanPhone(String? p) => (p ?? '').trim();

  Future<Customer> customer(int id) async {
    final c = await (select(customers)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (c == null) throw const CustomerException('Customer not found');
    return c;
  }

  Future<int> _insert({
    required int customerId,
    required String date,
    required CustomerLedgerKind kind,
    required Paise amount,
    int? invoiceId,
    String? mode,
    String reference = '',
    String note = '',
    required DateTime at,
    int? staffId,
  }) {
    if (amount.value <= 0) throw const CustomerException('Enter an amount above zero');
    _checkDate(date);
    return into(customerLedger).insert(
      CustomerLedgerCompanion.insert(
        customerId: customerId,
        entryDate: date,
        kind: kind.code,
        amountPaise: amount.value,
        openPaise: Value(amount.value),
        invoiceId: Value(invoiceId),
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

  Future<List<OpenDebit>> _openDebits(int customerId) async {
    final rows = await customSelect(
      '''
      SELECT id, entry_date, open_paise FROM customer_ledger
      WHERE customer_id = ?1 AND status = 'active' AND open_paise > 0 AND kind IN ('opening', 'bill')
      ''',
      variables: [Variable.withInt(customerId)],
      readsFrom: _reads,
    ).get();
    return [
      for (final r in rows)
        OpenDebit(id: r.read<int>('id'), dueDate: r.read<String>('entry_date'), outstanding: r.read<int>('open_paise')),
    ];
  }

  Future<List<OpenCredit>> _openCredits(int customerId) async {
    final rows = await customSelect(
      '''
      SELECT id, open_paise FROM customer_ledger
      WHERE customer_id = ?1 AND status = 'active' AND open_paise > 0 AND kind IN ('payment', 'credit_note')
      ORDER BY entry_date, id
      ''',
      variables: [Variable.withInt(customerId)],
      readsFrom: _reads,
    ).get();
    return [for (final r in rows) OpenCredit(id: r.read<int>('id'), unallocated: r.read<int>('open_paise'))];
  }

  Future<void> _addOpen(int ledgerId, int delta) =>
      customUpdate('UPDATE customer_ledger SET open_paise = open_paise + ?1 WHERE id = ?2',
          variables: [Variable.withInt(delta), Variable.withInt(ledgerId)], updates: {customerLedger});

  Future<void> _write(List<Allocation> allocations) async {
    for (final a in allocations) {
      await into(customerAllocations).insert(
        CustomerAllocationsCompanion.insert(creditId: a.creditId, debitId: a.debitId, amountPaise: a.amount),
      );
      await _addOpen(a.creditId, -a.amount);
      await _addOpen(a.debitId, -a.amount);
    }
  }

  /// Applies all unallocated credit to open debits, oldest first.
  Future<void> _settle(int customerId) async =>
      _write(settle(await _openCredits(customerId), await _openDebits(customerId)));

  /// Releases a row's allocations and voids it; the caller re-settles.
  Future<void> _void(CustomerLedgerData e, String reason) async {
    final released = await (select(customerAllocations)..where((a) => a.creditId.equals(e.id) | a.debitId.equals(e.id))).get();
    for (final a in released) {
      await _addOpen(a.creditId == e.id ? a.debitId : a.creditId, a.amountPaise);
    }
    await (delete(customerAllocations)..where((a) => a.creditId.equals(e.id) | a.debitId.equals(e.id))).go();
    await (update(customerLedger)..where((l) => l.id.equals(e.id))).write(
      CustomerLedgerCompanion(status: const Value('void'), voidReason: Value(reason), openPaise: const Value(0)),
    );
  }

  /// Net dues: Σ open debits − Σ open credits (negative = advance).
  Future<int> currentDues(int customerId) async {
    final r = await customSelect(
      '''
      SELECT COALESCE(SUM(CASE WHEN kind IN ('opening', 'bill') THEN open_paise ELSE -open_paise END), 0) AS dues
      FROM customer_ledger WHERE customer_id = ?1 AND status = 'active' AND open_paise > 0
      ''',
      variables: [Variable.withInt(customerId)],
      readsFrom: _reads,
    ).getSingle();
    return r.read<int>('dues');
  }

  // -------------------------------------------------------------------------
  // Writes from billing (called inside SalesDao's transactions)

  /// Puts a Credit bill on the customer's dues. [paidNow] taken at the
  /// counter is a payment applied to this bill first. Returns the dues
  /// after the bill.
  Future<int> addBill({
    required int customerId,
    required int invoiceId,
    required String invoiceNo,
    required String date,
    required Paise total,
    required Paise paidNow,
    required String paidNowMode,
    required DateTime at,
    int? staffId,
  }) {
    return transaction(() async {
      final billId = await _insert(
        customerId: customerId,
        date: date,
        kind: CustomerLedgerKind.bill,
        amount: total,
        invoiceId: invoiceId,
        reference: invoiceNo,
        at: at,
        staffId: staffId,
      );
      if (paidNow.value > 0) {
        final payId = await _insert(
          customerId: customerId,
          date: date,
          kind: CustomerLedgerKind.payment,
          amount: paidNow,
          invoiceId: invoiceId,
          mode: paidNowMode,
          reference: 'Paid with $invoiceNo',
          at: at,
          staffId: staffId,
        );
        await _write([Allocation(creditId: payId, debitId: billId, amount: paidNow.value)]);
      }
      await _settle(customerId);
      return currentDues(customerId);
    });
  }

  /// A Credit bill was cancelled: its debit and the payment taken with it
  /// are voided (that money goes back, as with a cash bill); other credit is
  /// re-applied.
  Future<void> voidForInvoice(int invoiceId, {required String reason}) {
    return transaction(() async {
      final rows = await (select(customerLedger)
            ..where((l) =>
                l.invoiceId.equals(invoiceId) &
                l.status.equals('active') &
                l.kind.isIn([CustomerLedgerKind.bill.code, CustomerLedgerKind.payment.code])))
          .get();
      for (final e in rows) {
        await _void(e, reason);
      }
      for (final c in rows.map((e) => e.customerId).toSet()) {
        await _settle(c);
      }
    });
  }

  /// A sales return adjusted in dues: the credit goes to the original bill
  /// first, then the oldest dues; anything left stays as an advance.
  Future<int> addCreditNote({
    required int customerId,
    required int creditNoteId,
    required String number,
    required int againstInvoiceId,
    required String date,
    required Paise amount,
    required DateTime at,
    int? staffId,
  }) {
    return transaction(() async {
      final id = await _insert(
        customerId: customerId,
        date: date,
        kind: CustomerLedgerKind.creditNote,
        amount: amount,
        invoiceId: creditNoteId,
        reference: number,
        at: at,
        staffId: staffId,
      );
      final bill = await (select(customerLedger)
            ..where((l) =>
                l.invoiceId.equals(againstInvoiceId) &
                l.kind.equals(CustomerLedgerKind.bill.code) &
                l.status.equals('active')))
          .getSingleOrNull();
      if (bill != null) {
        final (allocs, _) = allocate(id, amount.value, await _openDebits(customerId), picked: {bill.id});
        await _write(allocs);
      }
      await _settle(customerId);
      return id;
    });
  }

  // -------------------------------------------------------------------------
  // Writes from the Customers screen — each one transaction.

  /// A new customer (phone must be unused).
  Future<int> addCustomer({required String name, required String phone, int? creditLimit, String address = '', String note = '', required DateTime at}) {
    return transaction(() async {
      final n = name.trim();
      final ph = _cleanPhone(phone);
      if (n.isEmpty || n == walkInName) throw const CustomerException('Enter the customer’s name');
      if (ph.isEmpty) throw const CustomerException('Enter the customer’s phone');
      if (creditLimit != null && creditLimit < 0) throw const CustomerException('Credit limit can’t be negative');
      final clash = await (select(customers)..where((c) => c.phone.equals(ph))).getSingleOrNull();
      if (clash != null) throw CustomerException('${clash.name} already has phone $ph');
      return into(customers).insert(
        CustomersCompanion.insert(
          name: n,
          phone: Value(ph),
          createdAt: _ts(at),
          creditLimitPaise: Value(creditLimit),
          address: Value(address.trim()),
          note: Value(note.trim()),
        ),
      );
    });
  }

  /// Edits a customer. [creditLimit] null = use the Settings default.
  Future<void> updateCustomer(int id, {required String name, required String phone, required int? creditLimit, String address = '', String note = ''}) {
    return transaction(() async {
      await customer(id);
      final n = name.trim();
      final ph = _cleanPhone(phone);
      if (n.isEmpty || n == walkInName) throw const CustomerException('Enter the customer’s name');
      if (ph.isEmpty) throw const CustomerException('Enter the customer’s phone');
      if (creditLimit != null && creditLimit < 0) throw const CustomerException('Credit limit can’t be negative');
      final clash = await (select(customers)..where((c) => c.phone.equals(ph) & c.id.equals(id).not())).getSingleOrNull();
      if (clash != null) throw CustomerException('${clash.name} already has phone $ph');
      await (update(customers)..where((c) => c.id.equals(id))).write(
        CustomersCompanion(
          name: Value(n),
          phone: Value(ph),
          creditLimitPaise: Value(creditLimit),
          address: Value(address.trim()),
          note: Value(note.trim()),
        ),
      );
    });
  }

  /// Money received against dues, applied oldest first — or only to
  /// [pickedDebitIds]; the rest stays on account.
  Future<int> recordPayment({
    required int customerId,
    required String date,
    required CustomerPaymentInput payment,
    Set<int>? pickedDebitIds,
    required DateTime at,
    int? staffId,
  }) {
    return transaction(() async {
      await customer(customerId);
      if (!collectModes.contains(payment.mode)) throw const CustomerException('Pick how it was paid');
      final id = await _insert(
        customerId: customerId,
        date: date,
        kind: CustomerLedgerKind.payment,
        amount: payment.amount,
        mode: payment.mode,
        reference: payment.reference,
        note: payment.note,
        at: at,
        staffId: staffId,
      );
      final debits = await _openDebits(customerId);
      if (pickedDebitIds != null && pickedDebitIds.any((d) => !debits.any((x) => x.id == d))) {
        throw const CustomerException('A picked bill is already paid or isn’t this customer’s');
      }
      final (allocs, _) = allocate(id, payment.amount.value, debits, picked: pickedDebitIds);
      await _write(allocs);
      return id;
    });
  }

  /// What the customer owed before RxDesk — one active entry per customer.
  Future<int> setOpeningBalance({required int customerId, required String date, required Paise amount, required DateTime at, int? staffId}) {
    return transaction(() async {
      await customer(customerId);
      final existing = await (select(customerLedger)
            ..where((l) => l.customerId.equals(customerId) & l.kind.equals(CustomerLedgerKind.opening.code) & l.status.equals('active')))
          .get();
      if (existing.isNotEmpty) throw const CustomerException('Opening dues are already set — void them first to change them');
      final id = await _insert(
        customerId: customerId,
        date: date,
        kind: CustomerLedgerKind.opening,
        amount: amount,
        reference: 'Opening dues',
        at: at,
        staffId: staffId,
      );
      await _settle(customerId);
      return id;
    });
  }

  /// Voids a payment or opening dues. The row stays; its allocations are
  /// released and other credit is re-applied.
  Future<void> voidEntry(int id, {required String reason}) {
    return transaction(() async {
      final e = await (select(customerLedger)..where((l) => l.id.equals(id))).getSingleOrNull();
      if (e == null) throw const CustomerException('Entry not found');
      if (e.status != 'active') throw const CustomerException('Already void');
      final kind = CustomerLedgerKind.parse(e.kind);
      if (!kind.voidable) {
        throw CustomerException(
          kind == CustomerLedgerKind.bill ? 'Cancel the bill from Invoices instead' : 'A credit note can’t be voided',
        );
      }
      if (e.kind == CustomerLedgerKind.payment.code && e.invoiceId != null) {
        throw const CustomerException('This was paid with the bill — cancel the bill instead');
      }
      if (reason.trim().isEmpty) throw const CustomerException('Give a reason for voiding');
      await _void(e, reason.trim());
      await _settle(e.customerId);
    });
  }

  // -------------------------------------------------------------------------
  // Queries

  /// Open ledger rows per customer (idx_cledger_open).
  static const String _openSql = '''
    SELECT customer_id,
      SUM(CASE WHEN kind IN ('opening', 'bill') THEN open_paise ELSE 0 END) AS outstanding,
      SUM(CASE WHEN kind IN ('opening', 'bill') THEN 0 ELSE open_paise END) AS advance,
      SUM(CASE WHEN kind IN ('opening', 'bill') THEN 1 ELSE 0 END) AS open_bills,
      MIN(CASE WHEN kind IN ('opening', 'bill') THEN entry_date END) AS oldest_open,
      SUM(CASE WHEN kind IN ('opening', 'bill') AND entry_date < ?1 THEN open_paise ELSE 0 END) AS over90
    FROM customer_ledger WHERE status = 'active' AND open_paise > 0
    GROUP BY customer_id
  ''';

  static const String _cols = '''
    c.id, c.name, COALESCE(c.phone, '') AS phone, c.address, c.note, c.credit_limit_paise,
    COALESCE(d.outstanding, 0) AS outstanding, COALESCE(d.advance, 0) AS advance,
    COALESCE(d.open_bills, 0) AS open_bills, d.oldest_open,
    (SELECT MAX(p.entry_date) FROM customer_ledger p
       WHERE p.customer_id = c.id AND p.kind = 'payment' AND p.status = 'active') AS last_payment,
    EXISTS (SELECT 1 FROM customer_ledger o
       WHERE o.customer_id = c.id AND o.kind = 'opening' AND o.status = 'active') AS has_opening
  ''';

  static CustomerDues _dues(QueryRow r) => CustomerDues(
        customerId: r.read<int>('id'),
        name: r.read<String>('name'),
        phone: r.read<String>('phone'),
        address: r.read<String>('address'),
        note: r.read<String>('note'),
        creditLimit: r.readNullable<int>('credit_limit_paise'),
        outstanding: Paise(r.read<int>('outstanding')),
        advance: Paise(r.read<int>('advance')),
        openBills: r.read<int>('open_bills'),
        oldestOpen: r.readNullable<String>('oldest_open'),
        lastPayment: r.readNullable<String>('last_payment'),
        hasOpening: r.read<int>('has_opening') == 1,
      );

  static String _ninetyDaysBefore(String today) {
    final d = parseDateKey(today);
    return dateKey(DateTime(d.year, d.month, d.day - 90));
  }

  /// Customers by name, or only those with dues (largest first). Search by
  /// name or phone. Offset paging over 50-row pages.
  Future<CustomerDuesPage> duesPage({
    required String today,
    String search = '',
    bool withDues = false,
    int page = 1,
    int pageSize = 50,
  }) async {
    final sw = Stopwatch()..start();
    final q = search.trim().toLowerCase();
    final like = Variable.withString('%$q%');
    const match = "(?2 = '' OR lower(c.name) LIKE ?3 OR COALESCE(c.phone, '') LIKE ?3)";
    final cut = Variable.withString(_ninetyDaysBefore(today));
    final base = [cut, Variable.withString(q), like];
    final size = pageSize.clamp(1, 500);

    final String countSql;
    final String rowsSql;
    if (withDues) {
      countSql = '''
        SELECT COUNT(*) AS c FROM ($_openSql) d JOIN customers c ON c.id = d.customer_id
        WHERE d.outstanding - d.advance > 0 AND $match''';
      rowsSql = '''
        SELECT $_cols FROM ($_openSql) d JOIN customers c ON c.id = d.customer_id
        WHERE d.outstanding - d.advance > 0 AND $match
        ORDER BY d.outstanding - d.advance DESC, c.name COLLATE NOCASE, c.id
        LIMIT ?4 OFFSET ?5''';
    } else {
      countSql = 'SELECT COUNT(*) AS c FROM customers c WHERE ?1 IS NOT NULL AND $match';
      rowsSql = '''
        SELECT $_cols FROM (
          SELECT * FROM customers c WHERE $match ORDER BY c.name COLLATE NOCASE, c.id LIMIT ?4 OFFSET ?5
        ) c
        LEFT JOIN ($_openSql) d ON d.customer_id = c.id
        ORDER BY c.name COLLATE NOCASE, c.id''';
    }
    final total = (await customSelect(countSql, variables: base, readsFrom: _reads).getSingle()).read<int>('c');
    final pages = total == 0 ? 1 : (total + size - 1) ~/ size;
    final p = page.clamp(1, pages);
    final rows = await customSelect(
      rowsSql,
      variables: [...base, Variable.withInt(size), Variable.withInt((p - 1) * size)],
      readsFrom: _reads,
    ).get();
    return CustomerDuesPage(rows: rows.map(_dues).toList(), total: total, ms: sw.elapsedMicroseconds / 1000);
  }

  Future<CustomerDues> customerDues(int customerId, {required String today}) async {
    final r = await customSelect(
      '''
      SELECT $_cols FROM customers c
      LEFT JOIN ($_openSql) d ON d.customer_id = c.id
      WHERE c.id = ?2
      ''',
      variables: [Variable.withString(_ninetyDaysBefore(today)), Variable.withInt(customerId)],
      readsFrom: _reads,
    ).getSingleOrNull();
    if (r == null) throw const CustomerException('Customer not found');
    return _dues(r);
  }

  /// Totals across customers with dues, and the top [limit] by dues.
  Future<(CustomerDuesTotals, List<CustomerDues>)> totals({required String today, int limit = 4}) async {
    final cut = Variable.withString(_ninetyDaysBefore(today));
    final agg = await customSelect(
      '''
      SELECT COALESCE(SUM(outstanding - advance), 0) AS owed, COUNT(*) AS n,
             COALESCE(SUM(over90), 0) AS over90, COALESCE(SUM(CASE WHEN over90 > 0 THEN 1 ELSE 0 END), 0) AS n90
      FROM ($_openSql) WHERE outstanding - advance > 0
      ''',
      variables: [cut],
      readsFrom: _reads,
    ).getSingle();
    final top = await customSelect(
      '''
      SELECT $_cols FROM ($_openSql) d JOIN customers c ON c.id = d.customer_id
      WHERE d.outstanding - d.advance > 0
      ORDER BY d.outstanding - d.advance DESC, c.name COLLATE NOCASE LIMIT ?2
      ''',
      variables: [cut, Variable.withInt(limit)],
      readsFrom: _reads,
    ).get();
    return (
      CustomerDuesTotals(
        owed: Paise(agg.read<int>('owed')),
        customers: agg.read<int>('n'),
        over90: Paise(agg.read<int>('over90')),
        over90Customers: agg.read<int>('n90'),
      ),
      top.map(_dues).toList(),
    );
  }

  /// Debits with something still owed, oldest first.
  Future<List<CustomerOpenBill>> openBills(int customerId) async {
    final rows = await customSelect(
      '''
      SELECT id, kind, entry_date, reference, invoice_id, amount_paise, open_paise FROM customer_ledger
      WHERE customer_id = ?1 AND status = 'active' AND open_paise > 0 AND kind IN ('opening', 'bill')
      ORDER BY entry_date, id
      ''',
      variables: [Variable.withInt(customerId)],
      readsFrom: _reads,
    ).get();
    return [
      for (final r in rows)
        CustomerOpenBill(
          ledgerId: r.read<int>('id'),
          kind: CustomerLedgerKind.parse(r.read<String>('kind')),
          date: r.read<String>('entry_date'),
          reference: r.read<String>('reference'),
          invoiceId: r.readNullable<int>('invoice_id'),
          amount: Paise(r.read<int>('amount_paise')),
          outstanding: Paise(r.read<int>('open_paise')),
        ),
    ];
  }

  /// Ledger rows oldest first with a running balance; keyset on (date, id).
  Future<CustomerStatementPage> statement(int customerId, {CustomerStatementCursor? after, int limit = 50}) async {
    final vars = <Variable<Object>>[Variable.withInt(customerId)];
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
        SELECT l.id, l.entry_date, l.kind, l.reference, l.invoice_id, l.mode, l.note, l.amount_paise, l.status, l.void_reason,
               SUM(CASE WHEN l.status <> 'active' THEN 0
                        WHEN l.kind IN ('opening', 'bill') THEN l.amount_paise ELSE -l.amount_paise END)
                 OVER (ORDER BY l.entry_date, l.id ROWS UNBOUNDED PRECEDING) AS balance
        FROM customer_ledger l WHERE l.customer_id = ?1
      ) $cursor
      ORDER BY entry_date, id LIMIT ?${vars.length}
      ''',
      variables: vars,
      readsFrom: _reads,
    ).get();
    return CustomerStatementPage(
      rows: [
        for (final r in rows.take(limit))
          CustomerStatementRow(
            id: r.read<int>('id'),
            date: r.read<String>('entry_date'),
            kind: CustomerLedgerKind.parse(r.read<String>('kind')),
            reference: r.read<String>('reference'),
            invoiceId: r.readNullable<int>('invoice_id'),
            mode: r.readNullable<String>('mode'),
            note: r.read<String>('note'),
            amount: Paise(r.read<int>('amount_paise')),
            active: r.read<String>('status') == 'active',
            voidReason: r.readNullable<String>('void_reason'),
            balance: Paise(r.read<int>('balance')),
          ),
      ],
      hasMore: rows.length > limit,
    );
  }

  /// For the bill panel: the customer with this phone, their dues and the
  /// limit that applies.
  Future<({Customer customer, int dues})?> creditInfoByPhone(String phone) async {
    final ph = _cleanPhone(phone);
    if (ph.isEmpty) return null;
    final c = await (select(customers)..where((x) => x.phone.equals(ph))).getSingleOrNull();
    if (c == null) return null;
    return (customer: c, dues: await currentDues(c.id));
  }

  /// Checks a Credit bill against the customer's limit (SPEC §4.10).
  /// Throws [CreditLimitException] unless [override].
  Future<void> checkLimit({required int customerId, required int adding, required int defaultLimit, required bool override}) async {
    if (override) return;
    final c = await customer(customerId);
    final limit = effectiveCreditLimit(customerLimit: c.creditLimitPaise, defaultLimit: defaultLimit);
    final dues = await currentDues(customerId);
    if (creditOverBy(dues: dues, adding: adding, limit: limit) > 0) {
      throw CreditLimitException(dues: dues, limit: limit, adding: adding);
    }
  }
}
