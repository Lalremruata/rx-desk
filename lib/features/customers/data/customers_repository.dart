import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/customers_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/money/paise.dart';
import '../../../core/utils/expiry.dart';

part 'customers_repository.g.dart';

/// Customer credit / udhaar data access (wraps [CustomersDao], SPEC §4.10).
class CustomersRepository {
  CustomersRepository(this._db, this._now);

  final AppDatabase _db;
  final DateTime Function() _now;

  CustomersDao get _dao => _db.customersDao;
  String get today => dateKey(_now());

  Future<CustomerDuesPage> duesPage({String search = '', bool withDues = false, int page = 1, int pageSize = 50}) =>
      _dao.duesPage(today: today, search: search, withDues: withDues, page: page, pageSize: pageSize);

  Future<CustomerDues> customerDues(int customerId) => _dao.customerDues(customerId, today: today);

  Future<(CustomerDuesTotals, List<CustomerDues>)> totals({int limit = 4}) => _dao.totals(today: today, limit: limit);

  Future<List<CustomerOpenBill>> openBills(int customerId) => _dao.openBills(customerId);

  Future<CustomerStatementPage> statement(int customerId, {CustomerStatementCursor? after, int limit = 50}) =>
      _dao.statement(customerId, after: after, limit: limit);

  /// For the bill panel: who this phone belongs to and their dues.
  Future<({Customer customer, int dues})?> creditInfoByPhone(String phone) => _dao.creditInfoByPhone(phone);

  Future<int> addCustomer({required String name, required String phone, int? creditLimit, String address = '', String note = '', String gstin = ''}) =>
      _dao.addCustomer(name: name, phone: phone, creditLimit: creditLimit, address: address, note: note, gstin: gstin, at: _now());

  Future<void> updateCustomer(int id, {required String name, required String phone, required int? creditLimit, String address = '', String note = '', String gstin = ''}) =>
      _dao.updateCustomer(id, name: name, phone: phone, creditLimit: creditLimit, address: address, note: note, gstin: gstin);

  Future<Customer> customer(int id) => _dao.customer(id);

  Future<int> recordPayment({required int customerId, required String date, required CustomerPaymentInput payment, Set<int>? pickedBillIds, int? staffId}) =>
      _dao.recordPayment(customerId: customerId, date: date, payment: payment, pickedDebitIds: pickedBillIds, at: _now(), staffId: staffId);

  Future<int> setOpeningBalance({required int customerId, required String date, required Paise amount, int? staffId}) =>
      _dao.setOpeningBalance(customerId: customerId, date: date, amount: amount, at: _now(), staffId: staffId);

  Future<void> voidEntry(int id, {required String reason}) => _dao.voidEntry(id, reason: reason);

  /// Fires after any ledger or customer change (bills on credit included).
  Stream<void> changes() =>
      _db.tableUpdates(TableUpdateQuery.onAllTables([_db.customerLedger, _db.customers, _db.invoices])).map((_) {});
}

@Riverpod(keepAlive: true)
CustomersRepository customersRepository(Ref ref) => CustomersRepository(ref.watch(appDatabaseProvider), ref.watch(nowProvider));
