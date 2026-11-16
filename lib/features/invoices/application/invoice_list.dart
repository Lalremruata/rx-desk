import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/sales_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/utils/date_range.dart';
import '../../billing/application/bill_controller.dart';
import '../../billing/data/sales_repository.dart';
import '../../settings/application/settings_providers.dart';
import 'invoice_document.dart';

part 'invoice_list.g.dart';

class InvoiceListState {
  const InvoiceListState({
    this.preset = DatePreset.today,
    this.search = '',
    this.payment,
    this.cursors = const [],
  });

  final DatePreset preset;
  final String search;
  final String? payment;

  /// Keyset stack: page N+1 starts older than `cursors[N]`.
  final List<InvoiceCursor> cursors;

  int get page => cursors.length + 1;

  InvoiceListState copyWith({DatePreset? preset, String? search, String? Function()? payment, List<InvoiceCursor>? cursors}) =>
      InvoiceListState(
        preset: preset ?? this.preset,
        search: search ?? this.search,
        payment: payment != null ? payment() : this.payment,
        cursors: cursors ?? this.cursors,
      );
}

/// Invoices list filters + keyset paging (SPEC §5.4). Kept alive so the
/// list stays put when you come back.
@Riverpod(keepAlive: true)
class InvoiceListController extends _$InvoiceListController {
  @override
  InvoiceListState build() => const InvoiceListState();

  void setPreset(DatePreset p) => state = state.copyWith(preset: p, cursors: const []);
  void setSearch(String q) => state = state.copyWith(search: q, cursors: const []);
  void setPayment(String? m) => state = state.copyWith(payment: () => m, cursors: const []);
  void older(InvoiceCursor last) => state = state.copyWith(cursors: [...state.cursors, last]);
  void newer() {
    if (state.cursors.isEmpty) return;
    state = state.copyWith(cursors: state.cursors.sublist(0, state.cursors.length - 1));
  }

  /// After a sale: show today, first page.
  void showToday() => state = const InvoiceListState();
}

InvoiceListFilter filterFor(InvoiceListState s, DateTime now) {
  final r = rangeFor(s.preset, now);
  return InvoiceListFilter(from: r.from, to: r.to, search: s.search, paymentMode: s.payment);
}

final invoicePageProvider = FutureProvider.autoDispose<InvoiceListPage>((ref) {
  ref.watch(salesVersionProvider);
  final s = ref.watch(invoiceListControllerProvider);
  final f = filterFor(s, ref.watch(nowProvider)());
  return ref.watch(salesRepositoryProvider).invoicePage(f, olderThan: s.cursors.isEmpty ? null : s.cursors.last);
});

final invoiceSummaryProvider = FutureProvider.autoDispose<InvoiceListSummary>((ref) {
  ref.watch(salesVersionProvider);
  final s = ref.watch(invoiceListControllerProvider);
  return ref.watch(salesRepositoryProvider).invoiceSummary(filterFor(s, ref.watch(nowProvider)()));
});

/// Full invoice with items.
final invoiceDetailProvider = FutureProvider.autoDispose.family<InvoiceWithItems?, int>((ref, id) {
  ref.watch(salesVersionProvider);
  return ref.watch(salesRepositoryProvider).invoice(id);
});

/// Invoice document for the preview, with current layout settings.
final invoiceDocProvider = FutureProvider.autoDispose.family<InvoiceDoc?, int>((ref, id) async {
  final w = await ref.watch(invoiceDetailProvider(id).future);
  if (w == null) return null;
  return buildInvoiceDoc(InvoiceData.fromDb(w), ref.watch(settingsProvider));
});

/// What can still be returned from an invoice (SPEC §4.5).
final returnContextProvider = FutureProvider.autoDispose.family<ReturnContext?, int>((ref, id) {
  ref.watch(salesVersionProvider);
  return ref.watch(salesRepositoryProvider).returnContext(id);
});

/// Credit notes issued against an invoice, oldest first.
final creditNotesProvider = FutureProvider.autoDispose.family<List<Invoice>, int>((ref, id) {
  ref.watch(salesVersionProvider);
  return ref.watch(salesRepositoryProvider).creditNotesFor(id);
});
