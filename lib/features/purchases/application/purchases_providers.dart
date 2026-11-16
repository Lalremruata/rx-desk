import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/dues_dao.dart';
import '../../../core/db/daos/purchases_dao.dart';
import '../../../core/db/daos/sources_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/utils/expiry.dart';
import '../data/purchases_repository.dart';

part 'purchases_providers.g.dart';

enum PurchasesTab {
  pending('Pending'),
  book('Order book'),
  receipts('Receipts'),
  dues('Dues'),
  stockists('Stockists');

  const PurchasesTab(this.label);
  final String label;
}

/// Keyset list state: search + a stack of page-start cursors.
class KeysetListState {
  const KeysetListState({this.search = '', this.cursors = const []});

  final String search;
  final List<PurchaseCursor> cursors;

  int get page => cursors.length + 1;
  PurchaseCursor? get cursor => cursors.isEmpty ? null : cursors.last;
}

/// Screen state (kept alive so the screen stays put when you come back).
@Riverpod(keepAlive: true)
class PurchasesTabState extends _$PurchasesTabState {
  @override
  PurchasesTab build() => PurchasesTab.pending;

  void set(PurchasesTab t) => state = t;
}

@Riverpod(keepAlive: true)
class OpenListController extends _$OpenListController {
  @override
  KeysetListState build() => const KeysetListState();

  void setSearch(String q) => state = KeysetListState(search: q);
  void next(PurchaseCursor last) => state = KeysetListState(search: state.search, cursors: [...state.cursors, last]);
  void previous() {
    if (state.cursors.isEmpty) return;
    state = KeysetListState(search: state.search, cursors: state.cursors.sublist(0, state.cursors.length - 1));
  }
}

@Riverpod(keepAlive: true)
class ReceiptListController extends _$ReceiptListController {
  @override
  KeysetListState build() => const KeysetListState();

  void setSearch(String q) => state = KeysetListState(search: q);
  void older(PurchaseCursor last) => state = KeysetListState(search: state.search, cursors: [...state.cursors, last]);
  void newer() {
    if (state.cursors.isEmpty) return;
    state = KeysetListState(search: state.search, cursors: state.cursors.sublist(0, state.cursors.length - 1));
  }
}

/// Dues tab: search + page (offset; a few hundred stockists at most).
class DuesListState {
  const DuesListState({this.search = '', this.page = 1, this.pageSize = 50});
  final String search;
  final int page;
  final int pageSize;
}

@Riverpod(keepAlive: true)
class DuesListController extends _$DuesListController {
  @override
  DuesListState build() => const DuesListState();

  void setSearch(String q) => state = DuesListState(search: q, pageSize: state.pageSize);
  void setPage(int p) => state = DuesListState(search: state.search, page: p, pageSize: state.pageSize);
  void setPageSize(int n) => state = DuesListState(search: state.search, pageSize: n);
}

/// Order lines ticked on the Pending tab ("Receive selected").
@Riverpod(keepAlive: true)
class SelectedOrderLines extends _$SelectedOrderLines {
  @override
  Set<int> build() => const {};

  void toggle(int id) => state = state.contains(id) ? ({...state}..remove(id)) : {...state, id};
  void clear() => state = const {};
}

/// Day shown in the order book ('YYYY-MM-DD'); null = today.
@Riverpod(keepAlive: true)
class BookDay extends _$BookDay {
  @override
  String? build() => null;

  void set(String day) => state = day;
}

/// Receipt whose lines are open on the Receipts tab.
@Riverpod(keepAlive: true)
class ExpandedReceipt extends _$ExpandedReceipt {
  @override
  int? build() => null;

  void toggle(int id) => state = state == id ? null : id;
}

/// Bumps on every purchases / stock write so views refresh.
@Riverpod(keepAlive: true)
Stream<int> purchasesVersion(Ref ref) async* {
  var n = 0;
  yield n;
  await for (final _ in ref.watch(purchasesRepositoryProvider).changes()) {
    yield ++n;
  }
}

/// The order-book day, resolved against today.
@riverpod
String bookDayKey(Ref ref) => ref.watch(bookDayProvider) ?? dateKey(ref.watch(nowProvider)());

@riverpod
Future<OrderPage> openOrderPage(Ref ref) {
  ref.watch(purchasesVersionProvider);
  final s = ref.watch(openListControllerProvider);
  return ref.watch(purchasesRepositoryProvider).openPage(after: s.cursor, search: s.search);
}

@riverpod
Future<List<BookRow>> bookRows(Ref ref) {
  ref.watch(purchasesVersionProvider);
  final day = ref.watch(bookDayKeyProvider);
  return ref.watch(purchasesRepositoryProvider).book(day, day);
}

@riverpod
Future<ReceiptPage> receiptPage(Ref ref) {
  ref.watch(purchasesVersionProvider);
  final s = ref.watch(receiptListControllerProvider);
  return ref.watch(purchasesRepositoryProvider).receiptPage(before: s.cursor, search: s.search);
}

@riverpod
Future<PurchaseKpis> purchaseKpis(Ref ref) {
  ref.watch(purchasesVersionProvider);
  return ref.watch(purchasesRepositoryProvider).kpis();
}

/// Open order lines (Purchases nav badge).
@riverpod
Stream<int> openOrderCount(Ref ref) => ref.watch(purchasesRepositoryProvider).watchOpenCount();

// Declared by hand: riverpod_generator can't resolve Drift's generated row
// types in the same build pass.

final receiptLinesProvider = FutureProvider.autoDispose.family<List<ReceiptLine>, int>((ref, receiptId) {
  ref.watch(purchasesVersionProvider);
  return ref.watch(purchasesRepositoryProvider).linesOf(receiptId);
});

final suppliersProvider = FutureProvider.autoDispose<List<Supplier>>((ref) {
  ref.watch(purchasesVersionProvider);
  return ref.watch(purchasesRepositoryProvider).suppliers();
});

@riverpod
Future<DuesPage> duesPage(Ref ref) {
  ref.watch(purchasesVersionProvider);
  ref.watch(bookDayKeyProvider); // today changes at midnight via the clock
  final s = ref.watch(duesListControllerProvider);
  return ref.watch(purchasesRepositoryProvider).duesPage(search: s.search, page: s.page, pageSize: s.pageSize);
}

/// Totals + top stockists (dashboard card, KPI).
final duesTotalsProvider = FutureProvider.autoDispose<(DuesTotals, List<SupplierDues>)>((ref) {
  ref.watch(purchasesVersionProvider);
  return ref.watch(purchasesRepositoryProvider).duesTotals();
});

final supplierDuesProvider = FutureProvider.autoDispose.family<SupplierDues, int>((ref, supplierId) {
  ref.watch(purchasesVersionProvider);
  return ref.watch(purchasesRepositoryProvider).supplierDues(supplierId);
});

final openBillsProvider = FutureProvider.autoDispose.family<List<OpenBill>, int>((ref, supplierId) {
  ref.watch(purchasesVersionProvider);
  return ref.watch(purchasesRepositoryProvider).openBills(supplierId);
});

/// (supplierId, cursor date, cursor id) → a statement page.
final statementPageProvider = FutureProvider.autoDispose.family<StatementPage, (int, String?, int?)>((ref, key) {
  ref.watch(purchasesVersionProvider);
  final (sid, date, id) = key;
  return ref
      .watch(purchasesRepositoryProvider)
      .statement(sid, after: date == null || id == null ? null : StatementCursor(date, id));
});

// ---------------------------------------------------------------------------
// Stockist directory (SPEC §4.11).

class SourcesListState {
  const SourcesListState({this.search = '', this.supplierId, this.cursors = const []});
  final String search;
  final int? supplierId;
  final List<SourceCursor> cursors;

  int get page => cursors.length + 1;
  SourceCursor? get cursor => cursors.isEmpty ? null : cursors.last;
}

@Riverpod(keepAlive: true)
class SourcesListController extends _$SourcesListController {
  @override
  SourcesListState build() => const SourcesListState();

  void setSearch(String q) => state = SourcesListState(search: q, supplierId: state.supplierId);
  void setSupplier(int? id) => state = SourcesListState(search: state.search, supplierId: id);
  void next(SourceCursor last) =>
      state = SourcesListState(search: state.search, supplierId: state.supplierId, cursors: [...state.cursors, last]);
  void previous() {
    if (state.cursors.isEmpty) return;
    state = SourcesListState(search: state.search, supplierId: state.supplierId, cursors: state.cursors.sublist(0, state.cursors.length - 1));
  }
}

@riverpod
Future<SourcePage> sourcesPage(Ref ref) {
  ref.watch(purchasesVersionProvider);
  final s = ref.watch(sourcesListControllerProvider);
  return ref.watch(purchasesRepositoryProvider).sourcesPage(search: s.search, supplierId: s.supplierId, after: s.cursor);
}

/// "Get from" for a medicine (batches dialog).
final productSourcesProvider = FutureProvider.autoDispose.family<List<SourceRow>, int>((ref, productId) {
  ref.watch(purchasesVersionProvider);
  return ref.watch(purchasesRepositoryProvider).sourcesFor(productId);
});

/// "Get from" for the Pending page's linked lines, by product id.
final pendingSourcesProvider = FutureProvider.autoDispose<Map<int, SourceRow>>((ref) async {
  final page = await ref.watch(openOrderPageProvider.future);
  return ref.watch(purchasesRepositoryProvider).firstSources([for (final r in page.rows) if (r.productId != null) r.productId!]);
});
