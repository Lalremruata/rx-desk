import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/sales_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/db/models.dart';
import '../../../core/fy/fy.dart';
import '../../../core/money/paise.dart';
import '../../../core/sales/bill_rules.dart';
import '../../../core/sales/held_bill.dart';
import '../../../core/sales/return_rules.dart';

part 'sales_repository.g.dart';

/// Billing + invoice data access (wraps [SalesDao] and the catalogue search).
class SalesRepository {
  SalesRepository(this._db, this._now);

  final AppDatabase _db;
  final DateTime Function() _now;

  DateTime get now => _now();

  // Held bills (SPEC §5.2 "Hold").
  Future<int> holdBill({required String label, required HeldBillData data, required int itemCount, required Paise total, int? staffId}) =>
      _db.heldBillsDao.hold(label: label, data: data, itemCount: itemCount, total: total, at: _now(), staffId: staffId);
  Stream<List<HeldBill>> watchHeldBills() => _db.heldBillsDao.watchAll();
  Future<HeldBill?> takeHeldBill(int id) => _db.heldBillsDao.take(id);
  Future<void> discardHeldBill(int id) => _db.heldBillsDao.discard(id);

  Future<SavedBill> saveBill(SaveBillRequest req, BillRules rules) => _db.salesDao.saveBill(req, rules: rules, at: _now());

  Future<void> cancel(int invoiceId, {int? staffId, String? reason}) =>
      _db.salesDao.cancelInvoice(invoiceId, at: _now(), staffId: staffId, reason: reason);

  // Sales returns (SPEC §4.5)

  Future<ReturnContext?> returnContext(int invoiceId) => _db.salesDao.returnContext(invoiceId);

  Future<SavedCreditNote> saveCreditNote(SaveCreditNoteRequest req, ReturnRules rules) =>
      _db.salesDao.saveCreditNote(req, rules: rules, at: _now());

  Future<List<Invoice>> creditNotesFor(int invoiceId) => _db.salesDao.creditNotesFor(invoiceId);

  Future<String> peekNextNumber(InvoiceNumberFormat fmt) => _db.salesDao.peekNextNumber(fmt, _now());

  Future<SearchResults> search(String q, {int expiryWindowMonths = 3}) =>
      _db.catalogDao.search(q, now: _now(), expiryWindowMonths: expiryWindowMonths);

  Future<List<StockBatch>> batchesOf(int productId) => _db.catalogDao.batchesOf(productId);

  Future<List<StockRow>> substitutes(int productId) => _db.catalogDao.substitutes(productId, now: _now());

  Future<List<StockRow>> stockRows(List<int> ids) => _db.catalogDao.stockRows(ids, now: _now());

  Future<List<QuickAddItem>> topSellers() => _db.salesDao.topSellers(now: _now());

  Future<List<String>> knownDoctors() => _db.salesDao.knownDoctors();

  Future<int> productCount() => _db.catalogDao.productCount();

  Future<InvoiceWithItems?> invoice(int id) => _db.salesDao.invoiceWithItems(id);

  Future<Invoice?> invoiceByNumber(String number) => _db.salesDao.invoiceByNumber(number);

  Future<InvoiceListPage> invoicePage(InvoiceListFilter f, {InvoiceCursor? olderThan, InvoiceCursor? newerThan, int limit = 30}) =>
      _db.salesDao.invoicePage(f, olderThan: olderThan, newerThan: newerThan, limit: limit);

  Future<InvoiceListSummary> invoiceSummary(InvoiceListFilter f) => _db.salesDao.invoiceSummary(f);

  Stream<List<Invoice>> watchRecent({int limit = 5}) => _db.salesDao.watchRecent(limit: limit);

  /// Fires after any sale / cancel.
  Stream<void> changes() => _db.tableUpdates(TableUpdateQuery.onAllTables([_db.invoices])).map((_) {});

  Future<Customer?> customerByPhone(String phone) => _db.salesDao.customerByPhone(phone);
}

@Riverpod(keepAlive: true)
SalesRepository salesRepository(Ref ref) => SalesRepository(ref.watch(appDatabaseProvider), ref.watch(nowProvider));
