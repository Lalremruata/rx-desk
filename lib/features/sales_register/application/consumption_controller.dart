import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/daos/reports_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/inventory/consumption_rules.dart';
import '../../../core/utils/expiry.dart';
import '../../billing/application/bill_controller.dart';
import '../../inventory/application/inventory_providers.dart';
import '../../settings/application/settings_providers.dart';
import '../data/register_repository.dart';

part 'consumption_controller.g.dart';

/// Monthly consumption register screen state (SPEC §5.5, §4.12).
class ConsumptionState {
  const ConsumptionState({
    required this.month,
    this.search = '',
    this.includeAll = false,
    this.page = 1,
    this.pageSize = 50,
    this.picked = const {},
  });

  /// 'YYYY-MM'.
  final String month;
  final String search;
  final bool includeAll;
  final int page;
  final int pageSize;

  /// Product ids ticked for "Apply suggested reorder levels".
  final Set<int> picked;

  ConsumptionState copyWith({String? month, String? search, bool? includeAll, int? page, int? pageSize, Set<int>? picked}) =>
      ConsumptionState(
        month: month ?? this.month,
        search: search ?? this.search,
        includeAll: includeAll ?? this.includeAll,
        page: page ?? this.page,
        pageSize: pageSize ?? this.pageSize,
        picked: picked ?? this.picked,
      );
}

@Riverpod(keepAlive: true)
class ConsumptionController extends _$ConsumptionController {
  @override
  ConsumptionState build() => ConsumptionState(month: monthKey(ref.read(nowProvider)()));

  void moveMonth(int delta) => state = ConsumptionState(
        month: shiftMonth(state.month, delta),
        search: state.search,
        includeAll: state.includeAll,
        pageSize: state.pageSize,
      );
  void setSearch(String q) => state = state.copyWith(search: q, page: 1);
  void setIncludeAll(bool v) => state = state.copyWith(includeAll: v, page: 1);
  void setPage(int p) => state = state.copyWith(page: p);
  void setPageSize(int n) => state = state.copyWith(pageSize: n, page: 1);
  void toggle(int productId) => state = state.copyWith(
        picked: state.picked.contains(productId) ? ({...state.picked}..remove(productId)) : {...state.picked, productId},
      );
  void setPicked(Set<int> ids) => state = state.copyWith(picked: ids);
  void clearPicked() => state = state.copyWith(picked: const {});

}

/// A row with its sheet figures computed (lead times from Settings).
class ConsumptionLine {
  ConsumptionLine(this.row, this.stats, this.suggested);
  final ConsumptionRow row;
  final ConsumptionStats stats;

  /// Suggested reorder level in packs.
  final int suggested;
}

List<ConsumptionLine> consumptionLines(List<ConsumptionRow> rows, {required String month, required int avgLead, required int maxLead}) {
  final n = daysInMonth(month);
  return [
    for (final r in rows)
      () {
        final s = ConsumptionStats.of(r.days(n), avgLeadDays: avgLead, maxLeadDays: maxLead);
        return ConsumptionLine(r, s, suggestedReorderPacks(s.reorderLevel, r.unitsPerPack));
      }(),
  ];
}

final consumptionPageProvider = FutureProvider.autoDispose<(ConsumptionPage, List<ConsumptionLine>)>((ref) async {
  ref.watch(salesVersionProvider);
  ref.watch(inventoryVersionProvider); // reorder levels, stock
  final st = ref.watch(consumptionControllerProvider);
  final s = ref.watch(settingsProvider);
  final page = await ref
      .watch(registerRepositoryProvider)
      .consumptionPage(st.month, search: st.search, includeAll: st.includeAll, page: st.page, pageSize: st.pageSize);
  return (page, consumptionLines(page.rows, month: st.month, avgLead: s.avgLeadTimeDays, maxLead: s.maxLeadTimeDays));
});
