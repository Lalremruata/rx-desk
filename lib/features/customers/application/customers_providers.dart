import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/customers_dao.dart';
import '../data/customers_repository.dart';

part 'customers_providers.g.dart';

/// Bumps after any customer / ledger / invoice change.
@Riverpod(keepAlive: true)
Stream<int> customersVersion(Ref ref) async* {
  var n = 0;
  yield n;
  await for (final _ in ref.watch(customersRepositoryProvider).changes()) {
    yield ++n;
  }
}

/// Customers list: search, "with dues" toggle, page.
class CustomerListState {
  const CustomerListState({this.search = '', this.withDues = true, this.page = 1, this.pageSize = 50});
  final String search;
  final bool withDues;
  final int page;
  final int pageSize;
}

@Riverpod(keepAlive: true)
class CustomerListController extends _$CustomerListController {
  @override
  CustomerListState build() => const CustomerListState();

  void setSearch(String q) => state = CustomerListState(search: q, withDues: state.withDues, pageSize: state.pageSize);
  void setWithDues(bool v) => state = CustomerListState(search: state.search, withDues: v, pageSize: state.pageSize);
  void setPage(int p) => state = CustomerListState(search: state.search, withDues: state.withDues, page: p, pageSize: state.pageSize);
  void setPageSize(int n) => state = CustomerListState(search: state.search, withDues: state.withDues, pageSize: n);
}

@riverpod
Future<CustomerDuesPage> customerDuesPage(Ref ref) {
  ref.watch(customersVersionProvider);
  final s = ref.watch(customerListControllerProvider);
  return ref
      .watch(customersRepositoryProvider)
      .duesPage(search: s.search, withDues: s.withDues, page: s.page, pageSize: s.pageSize);
}

// Declared by hand: riverpod_generator can't resolve Drift's generated row
// types in the same build pass.

/// Totals + top customers (dashboard card, KPI row).
final customerDuesTotalsProvider = FutureProvider.autoDispose<(CustomerDuesTotals, List<CustomerDues>)>((ref) {
  ref.watch(customersVersionProvider);
  return ref.watch(customersRepositoryProvider).totals();
});

final customerDuesProvider = FutureProvider.autoDispose.family<CustomerDues, int>((ref, id) {
  ref.watch(customersVersionProvider);
  return ref.watch(customersRepositoryProvider).customerDues(id);
});

final customerOpenBillsProvider = FutureProvider.autoDispose.family<List<CustomerOpenBill>, int>((ref, id) {
  ref.watch(customersVersionProvider);
  return ref.watch(customersRepositoryProvider).openBills(id);
});

/// (customerId, cursor date, cursor id) → a statement page.
final customerStatementProvider =
    FutureProvider.autoDispose.family<CustomerStatementPage, (int, String?, int?)>((ref, key) {
  ref.watch(customersVersionProvider);
  final (id, date, rowId) = key;
  return ref
      .watch(customersRepositoryProvider)
      .statement(id, after: date == null || rowId == null ? null : CustomerStatementCursor(date, rowId));
});

/// Bill panel: the customer behind a phone number, and their dues.
final creditInfoProvider = FutureProvider.autoDispose.family<({Customer customer, int dues})?, String>((ref, phone) {
  ref.watch(customersVersionProvider);
  return ref.watch(customersRepositoryProvider).creditInfoByPhone(phone);
});
