import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/db_provider.dart';
import '../../../core/db/report_models.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/date_range.dart';
import '../../billing/application/bill_controller.dart';
import '../data/register_repository.dart';

part 'register_controller.g.dart';

/// A one-click report (SPEC §5.5).
class SavedReport {
  const SavedReport(this.label, this.dot, this.preset, this.group, this.sort, {this.schedule = ScheduleFilter.all});

  final String label;
  final Color dot;
  final DatePreset preset;
  final RegisterGroup group;
  final RegisterSort sort;
  final ScheduleFilter schedule;
}

/// Saved reports with the prototype's dot colours (from the token palette).
final List<SavedReport> savedReports = [
  SavedReport('Daily sales', AppColors.category['Tablet']!, DatePreset.thisMonth, RegisterGroup.day, RegisterSort.key),
  SavedReport('Top sellers this month', AppColors.category['Syrup']!, DatePreset.thisMonth, RegisterGroup.medicine, RegisterSort.units),
  SavedReport('GST summary by HSN (last month)', AppColors.category['Injection']!, DatePreset.lastMonth, RegisterGroup.hsn, RegisterSort.net),
  SavedReport('Schedule H / H1 register', AppColors.accentOptions['Rose']!, DatePreset.thisMonth, RegisterGroup.none, RegisterSort.date, schedule: ScheduleFilter.rx),
  SavedReport('Maker-wise sales (FY)', AppColors.accentOptions['Cyan']!, DatePreset.thisFy, RegisterGroup.maker, RegisterSort.net),
];

@immutable
class RegisterState {
  const RegisterState({
    this.preset = DatePreset.thisMonth,
    this.customFrom,
    this.customTo,
    this.search = '',
    this.maker,
    this.category,
    this.schedule = ScheduleFilter.all,
    this.payment,
    this.doctor,
    this.group = RegisterGroup.none,
    this.sort = RegisterSort.date,
    this.descending = true,
    this.cursors = const [],
    this.groupPage = 1,
  });

  final DatePreset preset;
  final DateTime? customFrom;
  final DateTime? customTo;
  final String search;
  final String? maker;
  final String? category;
  final ScheduleFilter schedule;
  final String? payment;
  final String? doctor;
  final RegisterGroup group;
  final RegisterSort sort;
  final bool descending;

  /// Lines keyset stack (page N+1 starts after `cursors[N]`).
  final List<RegisterCursor> cursors;
  final int groupPage;

  int get linePage => cursors.length + 1;

  RegisterState copyWith({
    DatePreset? preset,
    DateTime? customFrom,
    DateTime? customTo,
    String? search,
    ValueGetter<String?>? maker,
    ValueGetter<String?>? category,
    ScheduleFilter? schedule,
    ValueGetter<String?>? payment,
    ValueGetter<String?>? doctor,
    RegisterGroup? group,
    RegisterSort? sort,
    bool? descending,
    List<RegisterCursor>? cursors,
    int? groupPage,
  }) =>
      RegisterState(
        preset: preset ?? this.preset,
        customFrom: customFrom ?? this.customFrom,
        customTo: customTo ?? this.customTo,
        search: search ?? this.search,
        maker: maker != null ? maker() : this.maker,
        category: category != null ? category() : this.category,
        schedule: schedule ?? this.schedule,
        payment: payment != null ? payment() : this.payment,
        doctor: doctor != null ? doctor() : this.doctor,
        group: group ?? this.group,
        sort: sort ?? this.sort,
        descending: descending ?? this.descending,
        cursors: cursors ?? this.cursors,
        groupPage: groupPage ?? this.groupPage,
      );

  DateRangeKeys range(DateTime now) => rangeFor(preset, now, from: customFrom, to: customTo);

  RegisterFilter filter(DateTime now) {
    final r = range(now);
    return RegisterFilter(
      from: r.from,
      to: r.to,
      search: search,
      maker: maker,
      category: category,
      schedule: schedule,
      payment: payment,
      doctor: doctor,
      group: group,
      sort: sort,
      descending: descending,
    );
  }
}

/// Sales register state. Every change resets paging.
@Riverpod(keepAlive: true)
class RegisterController extends _$RegisterController {
  @override
  RegisterState build() => const RegisterState();

  void _set(RegisterState s) => state = s.copyWith(cursors: const [], groupPage: 1);

  void setPreset(DatePreset p) => _set(state.copyWith(preset: p));
  void setCustom(DateTime from, DateTime to) => _set(state.copyWith(preset: DatePreset.custom, customFrom: from, customTo: to));
  void setSearch(String q) => _set(state.copyWith(search: q));
  void setMaker(String? v) => _set(state.copyWith(maker: () => v));
  void setCategory(String? v) => _set(state.copyWith(category: () => v));
  void setSchedule(ScheduleFilter v) => _set(state.copyWith(schedule: v));
  void setPayment(String? v) => _set(state.copyWith(payment: () => v));
  void setDoctor(String? v) => _set(state.copyWith(doctor: () => v));

  void clearFilters() => _set(
        state.copyWith(search: '', maker: () => null, category: () => null, schedule: ScheduleFilter.all, payment: () => null, doctor: () => null),
      );

  void setGroup(RegisterGroup g) => _set(
        state.copyWith(group: g, sort: g == RegisterGroup.none ? RegisterSort.date : RegisterSort.net, descending: true),
      );

  /// Header click: same column flips direction; a new one starts descending.
  void sortBy(RegisterSort s) => _set(state.copyWith(sort: s, descending: state.sort == s ? !state.descending : true));

  void applySaved(SavedReport r) => state = RegisterState(
        preset: r.preset,
        group: r.group,
        sort: r.sort,
        schedule: r.schedule,
      );

  void nextLines(RegisterCursor last) => state = state.copyWith(cursors: [...state.cursors, last]);
  void prevLines() {
    if (state.cursors.isNotEmpty) state = state.copyWith(cursors: state.cursors.sublist(0, state.cursors.length - 1));
  }

  void setGroupPage(int p) => state = state.copyWith(groupPage: p);
}

final _filter = Provider.autoDispose<RegisterFilter>(
  (ref) => ref.watch(registerControllerProvider).filter(ref.watch(nowProvider)()),
);

/// Totals bar — one aggregate query over the whole filtered set.
final registerTotalsProvider = FutureProvider.autoDispose<RegisterTotals>((ref) {
  ref.watch(salesVersionProvider);
  return ref.watch(registerRepositoryProvider).totals(ref.watch(_filter));
});

final registerLinesProvider = FutureProvider.autoDispose<RegisterLinesPage>((ref) {
  ref.watch(salesVersionProvider);
  final s = ref.watch(registerControllerProvider);
  return ref.watch(registerRepositoryProvider).lines(ref.watch(_filter), after: s.cursors.isEmpty ? null : s.cursors.last);
});

const int registerGroupPageSize = 50;

final registerGroupsProvider = FutureProvider.autoDispose<RegisterGroupsPage>((ref) {
  ref.watch(salesVersionProvider);
  final s = ref.watch(registerControllerProvider);
  return ref
      .watch(registerRepositoryProvider)
      .groups(ref.watch(_filter), offset: (s.groupPage - 1) * registerGroupPageSize);
});

final registerDoctorsProvider = FutureProvider.autoDispose<List<String>>((ref) {
  ref.watch(salesVersionProvider);
  return ref.watch(registerRepositoryProvider).doctors();
});

final registerMakersProvider = FutureProvider.autoDispose<List<String>>((ref) {
  ref.watch(salesVersionProvider);
  return ref.watch(registerRepositoryProvider).makers();
});

/// Current filter (for export).
final registerFilterProvider = _filter;
