import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/dues_dao.dart';
import '../../../core/db/daos/purchases_dao.dart';
import '../../../core/db/daos/sources_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/money/paise.dart';
import '../../../core/utils/expiry.dart';

part 'purchases_repository.g.dart';

/// Order book and stockist receipts for the app (wraps [PurchasesDao]).
class PurchasesRepository {
  PurchasesRepository(this._db, this._now);

  final AppDatabase _db;
  final DateTime Function() _now;

  PurchasesDao get _dao => _db.purchasesDao;
  DuesDao get _dues => _db.duesDao;
  String get _today => dateKey(_now());

  Future<List<int>> addOrder(String orderDate, List<NewOrderLine> lines, {int? staffId}) =>
      _dao.addOrderLines(orderDate, lines, at: _now(), staffId: staffId);

  Future<SavedReceipt> receive(ReceiveRequest req, {required int expiryWindowMonths, int? staffId}) {
    final now = _now();
    return _dao.receive(req, at: now, now: now, expiryWindowMonths: expiryWindowMonths, staffId: staffId);
  }

  Future<void> closeShort(int orderLineId) => _dao.closeShort(orderLineId, at: _now());

  Future<void> cancel(int orderLineId) => _dao.cancelOrderLine(orderLineId, at: _now());

  Future<void> linkProduct(int orderLineId, int productId) => _dao.linkProduct(orderLineId, productId, at: _now());

  Future<OrderPage> openPage({PurchaseCursor? after, String search = '', int limit = 50}) =>
      _dao.openPage(after: after, search: search, limit: limit);

  Future<List<OrderRow>> orderRows(List<int> ids) => _dao.orderRows(ids);

  Future<List<BookRow>> book(String from, String to) => _dao.book(from, to);

  Future<String?> adjacentDay(String date, {required bool forward}) => _dao.adjacentDay(date, forward: forward);

  Future<ReceiptPage> receiptPage({PurchaseCursor? before, String search = '', int limit = 30}) =>
      _dao.receiptPage(before: before, search: search, limit: limit);

  Future<List<ReceiptLine>> linesOf(int receiptId) => _dao.linesOf(receiptId);

  Future<PurchaseKpis> kpis() => _dao.kpis(now: _now());

  Stream<int> watchOpenCount() => _dao.watchOpenCount();

  Future<List<Supplier>> suppliers() => _dao.allSuppliers();

  // Stockist dues (SPEC §4.8).

  Future<int> recordPayment({required int supplierId, required String date, required PaymentInput payment, Set<int>? pickedBillIds, int? staffId}) =>
      _dues.recordPayment(supplierId: supplierId, date: date, payment: payment, pickedDebitIds: pickedBillIds, at: _now(), staffId: staffId);

  Future<int> recordCreditNote({required int supplierId, required String date, required Paise amount, required String reference, String note = '', int? staffId}) =>
      _dues.recordCreditNote(supplierId: supplierId, date: date, amount: amount, reference: reference, note: note, at: _now(), staffId: staffId);

  Future<int> recordReturn({
    required int supplierId,
    required String date,
    required Paise amount,
    required String reference,
    String note = '',
    required List<ReturnLineInput> lines,
    int? staffId,
  }) =>
      _dues.recordReturn(
        supplierId: supplierId,
        date: date,
        amount: amount,
        reference: reference,
        note: note,
        lines: lines,
        at: _now(),
        staffId: staffId,
      );

  Future<int> setOpeningBalance({required int supplierId, required String date, required Paise amount, int? staffId}) =>
      _dues.setOpeningBalance(supplierId: supplierId, date: date, amount: amount, at: _now(), staffId: staffId);

  Future<void> voidEntry(int id, {required String reason}) => _dues.voidEntry(id, reason: reason, at: _now());

  Future<void> updateSupplier(int id, {required int creditDays, String? phone, String? gstin}) =>
      _dues.updateSupplier(id, creditDays: creditDays, phone: phone, gstin: gstin);

  Future<DuesPage> duesPage({String search = '', int page = 1, int pageSize = 50}) =>
      _dues.duesPage(today: _today, search: search, page: page, pageSize: pageSize);

  Future<SupplierDues> supplierDues(int supplierId) => _dues.supplierDues(supplierId, today: _today);

  Future<(DuesTotals, List<SupplierDues>)> duesTotals({int limit = 4}) => _dues.totals(today: _today, limit: limit);

  Future<List<OpenBill>> openBills(int supplierId) => _dues.openBills(supplierId);

  Future<StatementPage> statement(int supplierId, {StatementCursor? after, int limit = 50}) =>
      _dues.statement(supplierId, after: after, limit: limit);

  // Stockist directory (SPEC §4.11).

  SourcesDao get _sources => _db.sourcesDao;

  Future<SourcePage> sourcesPage({String search = '', int? supplierId, SourceCursor? after, int limit = 50}) =>
      _sources.page(search: search, supplierId: supplierId, after: after, limit: limit);

  Future<List<SourceRow>> sourcesFor(int productId) => _sources.sourcesFor(productId);

  Future<Map<int, SourceRow>> firstSources(Iterable<int> productIds) => _sources.firstSources(productIds);

  Future<int> addSource({required String supplierName, int? productId, String itemName = '', String mrName = '', String mrPhone = '', String note = ''}) =>
      _sources.add(supplierName: supplierName, productId: productId, itemName: itemName, mrName: mrName, mrPhone: mrPhone, note: note, at: _now());

  Future<void> updateSource(int id, {int? productId, required String itemName, String mrName = '', String mrPhone = '', String note = ''}) =>
      _sources.updateSource(id, productId: productId, itemName: itemName, mrName: mrName, mrPhone: mrPhone, note: note, at: _now());

  Future<void> removeSource(int id) => _sources.remove(id);

  Future<void> setStockistContact(int supplierId, {required String phone, String otherPhones = '', String note = ''}) =>
      _sources.setStockistContact(supplierId, phone: phone, otherPhones: otherPhones, note: note);

  Future<DirectoryImportResult> importDirectory(List<DirectoryImportRow> rows) => _sources.importRows(rows, at: _now());

  /// Catalogue search for matching sheet names: (id, name), best first.
  Future<List<(int, String)>> searchCatalogue(String q) async =>
      [for (final r in (await _db.catalogDao.search(q, now: _now())).rows) (r.id, r.name)];

  /// Every write to the order book, receipts or stock.
  Stream<void> changes() => _db
      .tableUpdates(
        TableUpdateQuery.onAllTables([
          _db.orderLines,
          _db.purchaseReceipts,
          _db.receiptLines,
          _db.suppliers,
          _db.batches,
          _db.supplierLedger,
          _db.ledgerAllocations,
          _db.productSources,
        ]),
      )
      .map((_) {});
}

@Riverpod(keepAlive: true)
PurchasesRepository purchasesRepository(Ref ref) =>
    PurchasesRepository(ref.watch(appDatabaseProvider), ref.watch(nowProvider));
