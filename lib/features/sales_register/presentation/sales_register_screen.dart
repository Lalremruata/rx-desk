import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/db/db_provider.dart';
import '../../../core/db/models.dart';
import '../../../core/db/report_models.dart';
import '../../../core/money/paise.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/date_range.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/pack.dart';
import '../../../core/utils/save_file.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/session.dart';
import '../../staff/presentation/access_denied.dart';
import '../application/register_controller.dart';
import '../application/register_export.dart';
import '../data/register_repository.dart';

/// Sales register (SPEC §5.5): one row per item sold.
class SalesRegisterScreen extends ConsumerWidget {
  const SalesRegisterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(canProvider(Permission.viewReports))) return const AccessDenied(permission: Permission.viewReports);
    return const PageScroll(
      gap: AppSpace.gap14,
      children: [_SavedReports(), _Filters(), _TotalsBar(), _Table()],
    );
  }
}

class _SavedReports extends ConsumerWidget {
  const _SavedReports();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: [
        for (final r in savedReports)
          ActionChip(
            key: ValueKey('saved-${r.label}'),
            avatar: Container(width: 8, height: 8, decoration: BoxDecoration(color: r.dot, shape: BoxShape.circle)),
            label: Text(r.label),
            labelStyle: AppType.smallStrong,
            backgroundColor: AppColors.surface,
            side: const BorderSide(color: AppColors.border),
            shape: const StadiumBorder(),
            onPressed: () => ref.read(registerControllerProvider.notifier).applySaved(r),
          ),
        ActionChip(
          key: const ValueKey('saved-consumption'),
          avatar: const Icon(Icons.calendar_view_month_rounded, size: 16),
          label: const Text('Inventory Management Register (monthly)'),
          labelStyle: AppType.smallStrong,
          backgroundColor: AppColors.surface,
          side: const BorderSide(color: AppColors.border),
          shape: const StadiumBorder(),
          onPressed: () => context.go(Routes.consumption),
        ),
      ],
    );
  }
}

class _Filters extends ConsumerStatefulWidget {
  const _Filters();

  @override
  ConsumerState<_Filters> createState() => _FiltersState();
}

class _FiltersState extends ConsumerState<_Filters> {
  Timer? _debounce;
  bool _exporting = false;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _pickCustom() async {
    final now = ref.read(nowProvider)();
    final s = ref.read(registerControllerProvider);
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 8),
      lastDate: now,
      initialDateRange: DateTimeRange(start: s.customFrom ?? DateTime(now.year, now.month), end: s.customTo ?? now),
    );
    if (r != null) ref.read(registerControllerProvider.notifier).setCustom(r.start, r.end);
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    final toasts = ref.read(toastsProvider.notifier);
    try {
      final repo = ref.read(registerRepositoryProvider);
      final f = ref.read(registerFilterProvider);
      final st = ref.read(registerControllerProvider);
      final now = ref.read(nowProvider)();
      final settings = ref.read(settingsProvider);
      final totals = await repo.totals(f);
      final grouped = f.group != RegisterGroup.none;
      final lines = grouped ? const <RegisterLine>[] : await repo.allLines(f);
      final groups = grouped ? (await repo.groups(f, limit: null)).rows : const <RegisterGroupRow>[];
      final table = registerExportTable(
        filter: f,
        totals: totals,
        lines: lines,
        groups: groups,
        storeName: settings.name,
        gstin: settings.gstRegistered ? settings.gstin : '',
        rangeLabel: st.range(now).label,
        generatedAt: now,
      );
      final name = 'sales-register-${f.from}-to-${f.to}';
      String? path;
      try {
        path = await saveBytesAs('$name.xlsx', await buildXlsxInIsolate(table));
      } on Object {
        path = await saveTextAs('$name.csv', buildCsv(table)); // CSV fallback
      }
      if (path != null) {
        toasts.show('${path.split(RegExp(r'[/\\]')).last} saved · ${formatCount(table.rows.length)} ${grouped ? 'rows' : 'lines'} with totals');
      }
    } on Object catch (e) {
      toasts.show('Export failed: $e', warn: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(registerControllerProvider);
    final ctl = ref.read(registerControllerProvider.notifier);
    final now = ref.watch(nowProvider)();
    final makers = ref.watch(registerMakersProvider).value ?? const <String>[];
    final doctors = ref.watch(registerDoctorsProvider).value ?? const <String>[];
    final filtered = s.search.trim().isNotEmpty || s.maker != null || s.category != null || s.schedule != ScheduleFilter.all || s.payment != null || s.doctor != null;

    return AppCard(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChipRow<DatePreset>(
                semanticLabel: 'Date range',
                options: [for (final p in DatePreset.values) PillOption(p, p.label)],
                selected: s.preset,
                onChanged: (p) => p == DatePreset.custom ? _pickCustom() : ctl.setPreset(p),
              ),
              Text(s.range(now).label, key: const ValueKey('register-range'), style: AppType.caption),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.gap10,
            runSpacing: AppSpace.gap10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 260, maxWidth: 380),
                child: AppTextField(
                  key: const ValueKey('register-search'),
                  label: '',
                  hint: 'Medicine, salt, batch, bill no. or customer…',
                  prefixIcon: Icons.search_rounded,
                  value: s.search,
                  onChanged: (v) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 200), () => ctl.setSearch(v));
                  },
                ),
              ),
              AppDropdown<String?>(
                label: 'Maker',
                width: 180,
                value: s.maker,
                options: [const DropdownOption(null, 'All'), for (final m in makers) DropdownOption(m, m)],
                onChanged: ctl.setMaker,
              ),
              AppDropdown<String?>(
                label: 'Category',
                value: s.category,
                options: [const DropdownOption(null, 'All'), for (final c in productCategories) DropdownOption(c, c)],
                onChanged: ctl.setCategory,
              ),
              AppDropdown<ScheduleFilter>(
                label: 'Schedule',
                value: s.schedule,
                options: [for (final f in ScheduleFilter.values) DropdownOption(f, f.label)],
                onChanged: ctl.setSchedule,
              ),
              AppDropdown<String?>(
                label: 'Payment',
                value: s.payment,
                options: const [DropdownOption(null, 'All'), DropdownOption('Cash', 'Cash'), DropdownOption('UPI', 'UPI'), DropdownOption('Card', 'Card'), DropdownOption('Credit', 'Credit')],
                onChanged: ctl.setPayment,
              ),
              AppDropdown<String?>(
                label: 'Doctor',
                width: 200,
                value: s.doctor,
                options: [
                  const DropdownOption(null, 'All'),
                  const DropdownOption('(No prescription)', '(No prescription)'),
                  for (final d in doctors) DropdownOption(d, d),
                ],
                onChanged: ctl.setDoctor,
              ),
              if (filtered) TextButton(key: const ValueKey('clear-filters'), onPressed: ctl.clearFilters, child: const Text('Clear filters')),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: AppSpace.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Group by', style: AppType.label),
                  FilterChipRow<RegisterGroup>(
                    semanticLabel: 'Group by',
                    options: [
                      for (final g in RegisterGroup.values) PillOption(g, g == RegisterGroup.none ? 'None' : g.label),
                    ],
                    selected: s.group,
                    onChanged: ctl.setGroup,
                  ),
                ],
              ),
              AppButton.secondary(
                key: const ValueKey('export-excel'),
                label: _exporting ? 'Exporting…' : 'Export Excel',
                icon: Icons.table_view_outlined,
                onPressed: _exporting ? null : _export,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TotalsBar extends ConsumerWidget {
  const _TotalsBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(registerTotalsProvider).value ?? const RegisterTotals();
    Widget cell(String label, String value, {bool strong = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: AppType.overline),
              const SizedBox(height: 4),
              Text(
                value,
                style: (strong ? AppType.cardTitle.copyWith(fontWeight: FontWeight.w700) : AppType.bodyStrong).copyWith(fontFeatures: AppType.tabular),
              ),
            ],
          ),
        );
    return AppCard(
      padding: const EdgeInsets.all(AppSpace.xs),
      semanticLabel: 'Totals for the filtered sales',
      child: Wrap(
        children: [
          cell('BILLS', formatCount(t.bills)),
          cell('UNITS', formatCount(t.units)),
          cell('GROSS', formatInr(t.gross)),
          cell('DISCOUNT', formatInr(t.discount)),
          cell('TAXABLE', formatInr(t.taxable)),
          cell('CGST', formatInr(t.cgst)),
          cell('SGST', formatInr(t.sgst)),
          KeyedSubtree(key: const ValueKey('register-net'), child: cell('NET', formatInr(t.net), strong: true)),
        ],
      ),
    );
  }
}

class _Table extends ConsumerWidget {
  const _Table();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(registerControllerProvider);
    final grouped = s.group != RegisterGroup.none;
    final totals = ref.watch(registerTotalsProvider).value;
    return AppCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: grouped ? _Groups(s: s, totals: totals) : _Lines(s: s, totals: totals),
    );
  }
}

String _when(RegisterLine l) {
  final at = DateTime.fromMillisecondsSinceEpoch(l.createdAt, isUtc: true).toLocal();
  return '${dayLabel(l.saleDate).substring(4)} · ${formatTime(at)}';
}

class _Lines extends ConsumerWidget {
  const _Lines({required this.s, required this.totals});

  final RegisterState s;
  final RegisterTotals? totals;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(registerLinesProvider).value;
    final rows = page?.rows ?? const <RegisterLine>[];
    final ctl = ref.read(registerControllerProvider.notifier);
    final rx = s.schedule.isRxRegister;
    final mono = AppType.mono.copyWith(fontWeight: FontWeight.w500);
    final columns = rx
        ? const [
            GridColumn.fixed('Date · time', 138, sortKey: 'date'),
            GridColumn.fixed('Bill no', 138),
            GridColumn('Patient', flex: 1.2, minWidth: 140),
            GridColumn('Doctor', flex: 1.2, minWidth: 150),
            GridColumn('Medicine', flex: 2, minWidth: 200),
            GridColumn.fixed('Batch', 92),
            GridColumn.fixed('Qty', 84, alignEnd: true, sortKey: 'qty'),
          ]
        : const [
            GridColumn.fixed('Date · time', 118, sortKey: 'date'),
            GridColumn.fixed('Bill no', 138),
            GridColumn('Medicine', flex: 2, minWidth: 220),
            GridColumn('Maker', minWidth: 130),
            GridColumn.fixed('Batch', 92),
            GridColumn.fixed('Qty', 84, alignEnd: true, sortKey: 'qty'),
            GridColumn.fixed('MRP', 80, alignEnd: true),
            GridColumn.fixed('Disc', 72, alignEnd: true),
            GridColumn.fixed('Taxable', 92, alignEnd: true),
            GridColumn.fixed('GST%', 48, alignEnd: true),
            GridColumn.fixed('Net', 96, alignEnd: true, sortKey: 'net'),
          ];
    final from = (s.linePage - 1) * 50 + 1;
    final total = totals?.lines ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DataGrid(
          semanticLabel: rx ? 'Schedule H / H1 register' : 'Sales register lines',
          columns: columns,
          rowCount: rows.length,
          sortKey: s.sort.name,
          sortAscending: !s.descending,
          onSort: (k) => ctl.sortBy(RegisterSort.values.byName(k)),
          empty: page == null
              ? const SizedBox(height: 120)
              : const EmptyState(title: 'No sales match', message: 'Widen the dates or clear the filters.'),
          cells: (context, i) {
            final l = rows[i];
            final med = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(l.medicine, style: AppType.smallStrong, overflow: TextOverflow.ellipsis)),
                    if (l.schedule.isNotEmpty) ...[const SizedBox(width: 6), RxBadge(l.schedule)],
                  ],
                ),
                if (!rx) Text(l.salt, style: AppType.caption, overflow: TextOverflow.ellipsis),
              ],
            );
            if (rx) {
              return [
                Text(_when(l), style: AppType.small),
                Text(l.billNo, style: mono),
                Text(l.customer, style: AppType.small, overflow: TextOverflow.ellipsis),
                Text(l.doctor ?? '—', style: AppType.small, overflow: TextOverflow.ellipsis),
                med,
                Text(l.batchNo, style: mono),
                Text(compactPackQty(l.qty, l.packSize, l.category), style: AppType.bodyStrong),
              ];
            }
            return [
              Text(_when(l), style: AppType.small),
              Text(l.billNo, style: mono),
              med,
              Text(l.maker, style: AppType.small.copyWith(color: AppColors.body), overflow: TextOverflow.ellipsis),
              Text(l.batchNo, style: mono),
              Text(compactPackQty(l.qty, l.packSize, l.category), style: AppType.bodyStrong),
              Text(formatInr(l.mrp), style: AppType.small),
              Text(l.discount.isZero ? '—' : formatInr(l.discount), style: AppType.small),
              Text(formatInr(l.taxable), style: AppType.small),
              Text('${l.gstRate}', style: AppType.small),
              Text(formatInr(l.net), style: AppType.bodyStrong),
            ];
          },
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  total == 0
                      ? '0 item lines'
                      : '${formatCount(from)}–${formatCount(from + rows.length - 1)} of ${formatCount(total)} item lines'
                          '${page == null ? '' : ' · computed in ${page.ms.toStringAsFixed(1)} ms'}',
                  key: const ValueKey('register-footer'),
                  style: AppType.small.copyWith(color: AppColors.textSecondary),
                ),
              ),
              PagerButton(label: '‹ Prev', semanticLabel: 'Previous page', onTap: s.cursors.isEmpty ? null : ctl.prevLines),
              const SizedBox(width: 4),
              PagerButton(
                label: 'Next ›',
                semanticLabel: 'Next page',
                onTap: page?.hasMore ?? false ? () => ctl.nextLines(RegisterCursor(rows.last.sortValue, rows.last.id)) : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Groups extends ConsumerWidget {
  const _Groups({required this.s, required this.totals});

  final RegisterState s;
  final RegisterTotals? totals;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(registerGroupsProvider).value;
    final rows = page?.rows ?? const <RegisterGroupRow>[];
    final ctl = ref.read(registerControllerProvider.notifier);
    final net = totals?.net.value ?? 0;
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DataGrid(
          semanticLabel: 'Sales by ${s.group.label}',
          columns: [
            GridColumn(s.group.label, flex: 2, minWidth: 240, sortKey: 'key'),
            const GridColumn.fixed('Bills', 70, alignEnd: true),
            const GridColumn.fixed('Units', 80, alignEnd: true, sortKey: 'units'),
            const GridColumn.fixed('Gross', 110, alignEnd: true),
            const GridColumn.fixed('Taxable', 110, alignEnd: true),
            const GridColumn.fixed('GST', 100, alignEnd: true),
            const GridColumn.fixed('Net', 120, alignEnd: true, sortKey: 'net'),
            const GridColumn.fixed('Share', 150),
          ],
          rowCount: rows.length,
          sortKey: s.sort.name,
          sortAscending: !s.descending,
          onSort: (k) => ctl.sortBy(RegisterSort.values.byName(k)),
          empty: page == null ? const SizedBox(height: 120) : const EmptyState(title: 'No sales match', message: 'Widen the dates or clear the filters.'),
          cells: (context, i) {
            final g = rows[i];
            final share = net == 0 ? 0.0 : g.net.value / net;
            return [
              Text(g.label, style: AppType.smallStrong, overflow: TextOverflow.ellipsis),
              Text(formatCount(g.bills), style: AppType.small),
              Text(formatCount(g.units), style: AppType.smallStrong),
              Text(formatInr(g.gross), style: AppType.small),
              Text(formatInr(g.taxable), style: AppType.small),
              Text(formatInr(g.tax), style: AppType.small),
              Text(formatInr(g.net), style: AppType.bodyStrong),
              StockBar(fraction: share, color: p.accent, trailing: '${(share * 100).toStringAsFixed(1)}%'),
            ];
          },
        ),
        const Divider(),
        Pager(
          page: s.groupPage,
          pageSize: registerGroupPageSize,
          totalRows: page?.total ?? 0,
          onPage: ctl.setGroupPage,
          trailingNote: page == null ? null : 'computed in ${page.ms.toStringAsFixed(1)} ms',
        ),
      ],
    );
  }
}

/// Exposed for tests: rupees total text.
String netText(Paise p) => formatInr(p);
