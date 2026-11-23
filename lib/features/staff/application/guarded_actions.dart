import 'dart:typed_data';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/customers_dao.dart';
import '../../../core/db/daos/dues_dao.dart';
import '../../../core/db/daos/purchases_dao.dart';
import '../../../core/db/daos/sales_dao.dart';
import '../../../core/db/daos/sources_dao.dart';
import '../../../core/db/models.dart';
import '../../../core/inventory/stock_adjust.dart';
import '../../../core/money/paise.dart';
import '../../../core/sales/return_rules.dart';
import '../../backup/application/backup_format.dart';
import '../../backup/application/backup_service.dart';
import '../../billing/data/sales_repository.dart';
import '../../customers/data/customers_repository.dart';
import '../../inventory/data/inventory_repository.dart';
import '../../purchases/data/purchases_repository.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import 'session.dart';

part 'guarded_actions.g.dart';

/// Permission-checked entry points for actions screens trigger (SPEC §7.6).
/// Each checks the signed-in role before touching data.
class GuardedActions {
  GuardedActions(this._ref);

  final Ref _ref;

  int? get _staffId => _ref.read(sessionProvider)?.staffId;

  Future<int> addMedicine(NewProduct p) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(inventoryRepositoryProvider).addProduct(p, staffId: _staffId);
  }

  Future<ReceiveResult> receiveStock({required int productId, required String batchNo, String? expiry, required int qty, Paise? mrp}) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(inventoryRepositoryProvider).receive(productId: productId, batchNo: batchNo, expiry: expiry, qty: qty, mrp: mrp, staffId: _staffId);
  }

  /// Units per pack (SPEC §4.9) — converts the product's batches.
  /// Consumption register: apply suggested reorder levels (packs).
  Future<int> setReorderLevels(Map<int, int> levels) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(inventoryRepositoryProvider).setReorderLevels(levels);
  }

  /// Edit medicine (SPEC §5.3).
  Future<void> updateMedicine(int productId, ProductEdit e, {bool repriceBatches = false}) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(inventoryRepositoryProvider).updateProduct(productId, e, repriceBatches: repriceBatches);
  }

  /// Hide (take off sale) or unhide a medicine.
  Future<void> setMedicineHidden(int productId, bool hidden) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(inventoryRepositoryProvider).setProductActive(productId, !hidden);
  }

  /// Edit batch: number, expiry, counted quantity with a reason.
  Future<StockBatch> editBatch(
    int batchId, {
    String? batchNo,
    String? expiry,
    int? countedQty,
    Paise? mrp,
    StockAdjustReason? reason,
    String note = '',
  }) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(inventoryRepositoryProvider).editBatch(batchId,
        batchNo: batchNo, expiry: expiry, countedQty: countedQty, mrp: mrp, reason: reason, note: note, staffId: _staffId);
  }

  Future<void> setPackSize(int productId, int size) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(inventoryRepositoryProvider).setPackSize(productId, size, staffId: _staffId);
  }

  // Purchases (SPEC §4.7) — all need changeStock.

  Future<List<int>> placeOrder(String orderDate, List<NewOrderLine> lines) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(purchasesRepositoryProvider).addOrder(orderDate, lines, staffId: _staffId);
  }

  Future<SavedReceipt> receivePurchase(ReceiveRequest req) {
    requirePermission(_ref, Permission.changeStock);
    if (req.paidNow != null) requirePermission(_ref, Permission.supplierPayments);
    return _ref
        .read(purchasesRepositoryProvider)
        .receive(req, expiryWindowMonths: _ref.read(settingsProvider).expiryWindowMonths, staffId: _staffId);
  }

  Future<void> closeOrderLineShort(int orderLineId) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(purchasesRepositoryProvider).closeShort(orderLineId);
  }

  Future<void> cancelOrderLine(int orderLineId) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(purchasesRepositoryProvider).cancel(orderLineId);
  }

  // Stockist dues (SPEC §4.8) — supplierPayments; returns also changeStock.

  Future<int> recordSupplierPayment({required int supplierId, required String date, required PaymentInput payment, Set<int>? pickedBillIds}) {
    requirePermission(_ref, Permission.supplierPayments);
    return _ref
        .read(purchasesRepositoryProvider)
        .recordPayment(supplierId: supplierId, date: date, payment: payment, pickedBillIds: pickedBillIds, staffId: _staffId);
  }

  Future<int> recordCreditNote({required int supplierId, required String date, required Paise amount, required String reference, String note = ''}) {
    requirePermission(_ref, Permission.supplierPayments);
    return _ref
        .read(purchasesRepositoryProvider)
        .recordCreditNote(supplierId: supplierId, date: date, amount: amount, reference: reference, note: note, staffId: _staffId);
  }

  Future<int> recordSupplierReturn({
    required int supplierId,
    required String date,
    required Paise amount,
    required String reference,
    String note = '',
    required List<ReturnLineInput> lines,
  }) {
    requirePermission(_ref, Permission.changeStock);
    requirePermission(_ref, Permission.supplierPayments);
    return _ref.read(purchasesRepositoryProvider).recordReturn(
          supplierId: supplierId,
          date: date,
          amount: amount,
          reference: reference,
          note: note,
          lines: lines,
          staffId: _staffId,
        );
  }

  Future<int> setOpeningBalance({required int supplierId, required String date, required Paise amount}) {
    requirePermission(_ref, Permission.supplierPayments);
    return _ref.read(purchasesRepositoryProvider).setOpeningBalance(supplierId: supplierId, date: date, amount: amount, staffId: _staffId);
  }

  Future<void> voidLedgerEntry(int id, {required String reason}) {
    requirePermission(_ref, Permission.supplierPayments);
    return _ref.read(purchasesRepositoryProvider).voidEntry(id, reason: reason);
  }

  Future<void> updateSupplier(int id, {required int creditDays, String? phone, String? gstin}) {
    requirePermission(_ref, Permission.supplierPayments);
    return _ref.read(purchasesRepositoryProvider).updateSupplier(id, creditDays: creditDays, phone: phone, gstin: gstin);
  }

  // Stockist directory (SPEC §4.11) — changeStock, like purchases.

  Future<int> addSource({required String supplierName, int? productId, String itemName = '', String mrName = '', String mrPhone = '', String note = ''}) {
    requirePermission(_ref, Permission.changeStock);
    return _ref
        .read(purchasesRepositoryProvider)
        .addSource(supplierName: supplierName, productId: productId, itemName: itemName, mrName: mrName, mrPhone: mrPhone, note: note);
  }

  Future<void> updateSource(int id, {int? productId, required String itemName, String mrName = '', String mrPhone = '', String note = ''}) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(purchasesRepositoryProvider).updateSource(id, productId: productId, itemName: itemName, mrName: mrName, mrPhone: mrPhone, note: note);
  }

  Future<void> removeSource(int id) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(purchasesRepositoryProvider).removeSource(id);
  }

  Future<void> setStockistContact(int supplierId, {required String phone, String otherPhones = '', String note = ''}) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(purchasesRepositoryProvider).setStockistContact(supplierId, phone: phone, otherPhones: otherPhones, note: note);
  }

  Future<DirectoryImportResult> importDirectory(List<DirectoryImportRow> rows) {
    requirePermission(_ref, Permission.changeStock);
    return _ref.read(purchasesRepositoryProvider).importDirectory(rows);
  }

  // Customer credit (SPEC §4.10) — collectPayments for money in and customer
  // details; manageCustomerCredit for limits, opening dues and voids.

  CustomersRepository get _customers => _ref.read(customersRepositoryProvider);

  Future<int> recordCustomerPayment({required int customerId, required String date, required CustomerPaymentInput payment, Set<int>? pickedBillIds}) {
    requirePermission(_ref, Permission.collectPayments);
    return _customers.recordPayment(customerId: customerId, date: date, payment: payment, pickedBillIds: pickedBillIds, staffId: _staffId);
  }

  Future<int> addCustomer({required String name, required String phone, int? creditLimit, String address = '', String note = ''}) {
    requirePermission(_ref, Permission.collectPayments);
    if (creditLimit != null) requirePermission(_ref, Permission.manageCustomerCredit);
    return _customers.addCustomer(name: name, phone: phone, creditLimit: creditLimit, address: address, note: note);
  }

  /// Changing the limit needs manageCustomerCredit; other details need
  /// collectPayments.
  Future<void> updateCustomer(int id, {required String name, required String phone, required int? creditLimit, String address = '', String note = ''}) async {
    requirePermission(_ref, Permission.collectPayments);
    final current = await _customers.customer(id);
    if (current.creditLimitPaise != creditLimit) requirePermission(_ref, Permission.manageCustomerCredit);
    return _customers.updateCustomer(id, name: name, phone: phone, creditLimit: creditLimit, address: address, note: note);
  }

  Future<int> setCustomerOpeningBalance({required int customerId, required String date, required Paise amount}) {
    requirePermission(_ref, Permission.manageCustomerCredit);
    return _customers.setOpeningBalance(customerId: customerId, date: date, amount: amount, staffId: _staffId);
  }

  Future<void> voidCustomerEntry(int id, {required String reason}) {
    requirePermission(_ref, Permission.manageCustomerCredit);
    return _customers.voidEntry(id, reason: reason);
  }

  Future<void> cancelInvoice(int id, {String? reason}) {
    requirePermission(_ref, Permission.editBills);
    return _ref.read(salesRepositoryProvider).cancel(id, staffId: _staffId, reason: reason);
  }

  /// Sales return → credit note (SPEC §4.5). Needs `acceptReturns`; the
  /// return window can only be overridden by the Owner.
  Future<SavedCreditNote> acceptReturn({
    required int invoiceId,
    required List<ReturnLineRequest> lines,
    required String refundMode,
    String? reason,
  }) {
    requirePermission(_ref, Permission.acceptReturns);
    final role = _ref.read(sessionProvider)?.role ?? StaffRole.owner;
    return _ref.read(salesRepositoryProvider).saveCreditNote(
          SaveCreditNoteRequest(invoiceId: invoiceId, lines: lines, refundMode: refundMode, reason: reason, staffId: _staffId),
          _ref.read(settingsProvider).returnRules(role: role),
        );
  }

  Future<PreparedBackup> prepareBackup({String? password, void Function(double)? onProgress}) {
    requirePermission(_ref, Permission.backups);
    return _ref.read(backupServiceProvider).prepare(password: password, onProgress: onProgress);
  }

  Future<BackupManifest> restoreBackup(Uint8List bytes, {String? password}) {
    requirePermission(_ref, Permission.backups);
    return _ref.read(backupServiceProvider).restore(bytes, password: password);
  }
}

@riverpod
GuardedActions guardedActions(Ref ref) => GuardedActions(ref);
