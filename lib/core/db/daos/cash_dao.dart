import 'package:drift/drift.dart';

import '../../cash/cash_rules.dart';
import '../../money/paise.dart';
import '../app_database.dart';

part 'cash_dao.g.dart';

/// Day-end cash closing (SPEC §4.14): the day's cash movements, paid-outs
/// and closings. Dates are local 'YYYY-MM-DD' keys.
@DriftAccessor(tables: [CashPaidOuts, CashClosings, Invoices, CustomerLedger, SupplierLedger])
class CashDao extends DatabaseAccessor<AppDatabase> with _$CashDaoMixin {
  CashDao(super.attachedDatabase);

  Set<ResultSetImplementation<dynamic, dynamic>> get _reads => {invoices, customerLedger, supplierLedger, cashPaidOuts};

  static bool _isDateKey(String s) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s);

  /// What RxDesk knows about the cash that moved on [date].
  Future<CashFigures> figures(String date) => _figuresQuery(date).getSingle().then(_figures);

  Stream<CashFigures> watchFigures(String date) => _figuresQuery(date).watchSingle().map(_figures);

  Selectable<QueryRow> _figuresQuery(String date) => customSelect(
        '''
        SELECT
          (SELECT COALESCE(SUM(total_paise), 0) FROM invoices
             WHERE sale_date = ?1 AND doc_type = 'invoice' AND payment_mode = 'Cash' AND status <> 'cancelled') AS sales,
          (SELECT COALESCE(SUM(-total_paise), 0) FROM invoices
             WHERE sale_date = ?1 AND doc_type = 'credit_note' AND payment_mode = 'Cash' AND status <> 'cancelled') AS refunds,
          (SELECT COALESCE(SUM(amount_paise), 0) FROM customer_ledger
             WHERE entry_date = ?1 AND kind = 'payment' AND mode = 'Cash' AND status = 'active') AS collected,
          (SELECT COALESCE(SUM(amount_paise), 0) FROM supplier_ledger
             WHERE entry_date = ?1 AND kind = 'payment' AND mode = 'Cash' AND status = 'active') AS stockists,
          (SELECT COALESCE(SUM(amount_paise), 0) FROM cash_paid_out
             WHERE entry_date = ?1 AND status = 'active') AS paid_outs
        ''',
        variables: [Variable.withString(date)],
        readsFrom: _reads,
      );

  static CashFigures _figures(QueryRow r) => CashFigures(
        cashSales: Paise(r.read<int>('sales')),
        cashRefunds: Paise(r.read<int>('refunds')),
        duesCollected: Paise(r.read<int>('collected')),
        stockistsPaid: Paise(r.read<int>('stockists')),
        paidOuts: Paise(r.read<int>('paid_outs')),
      );

  // -------------------------------------------------------------------------
  // Paid-outs

  Future<int> addPaidOut({required String date, required Paise amount, required String note, required DateTime at, int? staffId}) async {
    if (!_isDateKey(date)) throw const CashException('Pick the date');
    if (amount.value <= 0) throw const CashException('Enter the amount paid out');
    if (note.trim().isEmpty) throw const CashException('Say what it was for');
    return into(cashPaidOuts).insert(
      CashPaidOutsCompanion.insert(
        entryDate: date,
        amountPaise: amount.value,
        note: note.trim(),
        staffId: Value(staffId),
        createdAt: at.toUtc().millisecondsSinceEpoch,
      ),
    );
  }

  /// Paid-outs of [date], oldest first (void ones included, marked).
  Stream<List<CashPaidOut>> watchPaidOuts(String date) => (select(cashPaidOuts)
        ..where((p) => p.entryDate.equals(date))
        ..orderBy([(p) => OrderingTerm.asc(p.createdAt), (p) => OrderingTerm.asc(p.id)]))
      .watch();

  Future<void> voidPaidOut(int id, {required String reason}) async {
    if (reason.trim().isEmpty) throw const CashException('Give a reason for voiding');
    final n = await (update(cashPaidOuts)..where((p) => p.id.equals(id) & p.status.equals('active')))
        .write(CashPaidOutsCompanion(status: const Value('void'), voidReason: Value(reason.trim())));
    if (n == 0) throw const CashException('This paid-out is already void');
  }

  // -------------------------------------------------------------------------
  // Closings

  /// The latest closing of [date] (later rows supersede earlier ones).
  Future<CashClosing?> closingOf(String date) => _closingQuery(date).getSingleOrNull();

  Stream<CashClosing?> watchClosing(String date) => _closingQuery(date).watchSingleOrNull();

  SimpleSelectStatement<$CashClosingsTable, CashClosing> _closingQuery(String date) => select(cashClosings)
    ..where((c) => c.closeDate.equals(date))
    ..orderBy([(c) => OrderingTerm.desc(c.id)])
    ..limit(1);

  /// The most recent closing before [date] — its counted cash less what was
  /// handed over is [date]'s opening.
  Stream<CashClosing?> watchPreviousClosing(String date) => (select(cashClosings)
        ..where((c) => c.closeDate.isSmallerThanValue(date))
        ..orderBy([(c) => OrderingTerm.desc(c.closeDate), (c) => OrderingTerm.desc(c.id)])
        ..limit(1))
      .watchSingleOrNull();

  /// Every closing of [date], newest first (history).
  Future<List<CashClosing>> closingsOf(String date) => (select(cashClosings)
        ..where((c) => c.closeDate.equals(date))
        ..orderBy([(c) => OrderingTerm.desc(c.id)]))
      .get();

  /// Closes [date] (SPEC §4.14): snapshots the day's figures as they are
  /// now, with the [opening] used and the cash [counted]. One transaction.
  Future<CashClosing> closeDay({
    required String date,
    required Paise opening,
    required Paise counted,
    Paise handedOver = Paise.zero,
    String note = '',
    required DateTime at,
    int? staffId,
  }) {
    return transaction(() async {
      if (!_isDateKey(date)) throw const CashException('Pick the date');
      if (opening.value < 0) throw const CashException('Opening cash can’t be negative');
      if (counted.value < 0) throw const CashException('Enter the cash counted');
      if (handedOver.value < 0) throw const CashException('Handed over can’t be negative');
      if (handedOver.value > counted.value) throw const CashException('Can’t hand over more than was counted');
      final f = await figures(date);
      final expected = f.expected(opening);
      final id = await into(cashClosings).insert(
        CashClosingsCompanion.insert(
          closeDate: date,
          openingPaise: opening.value,
          cashSalesPaise: f.cashSales.value,
          cashRefundsPaise: f.cashRefunds.value,
          duesCollectedPaise: f.duesCollected.value,
          stockistsPaidPaise: f.stockistsPaid.value,
          paidOutsPaise: f.paidOuts.value,
          expectedPaise: expected.value,
          countedPaise: counted.value,
          differencePaise: counted.value - expected.value,
          handedOverPaise: Value(handedOver.value),
          note: Value(note.trim()),
          staffId: Value(staffId),
          closedAt: at.toUtc().millisecondsSinceEpoch,
        ),
      );
      return (select(cashClosings)..where((c) => c.id.equals(id))).getSingle();
    });
  }
}

/// The figures a closing was made with.
CashFigures closingFigures(CashClosing c) => CashFigures(
      cashSales: Paise(c.cashSalesPaise),
      cashRefunds: Paise(c.cashRefundsPaise),
      duesCollected: Paise(c.duesCollectedPaise),
      stockistsPaid: Paise(c.stockistsPaidPaise),
      paidOuts: Paise(c.paidOutsPaise),
    );
