import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/inventory/consumption_rules.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/pack.dart';
import '../../../core/utils/save_file.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/guarded_actions.dart';
import '../../staff/application/session.dart';
import '../../staff/presentation/access_denied.dart';
import '../application/consumption_controller.dart';
import '../application/consumption_export.dart';
import '../application/register_export.dart';
import '../data/register_repository.dart';

/// Monthly consumption register — the store's "Inventory Management
/// Register" sheet, filled from sales (SPEC §5.5, §4.12).
class ConsumptionRegisterScreen extends ConsumerWidget {
  const ConsumptionRegisterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(canProvider(Permission.viewReports))) return const AccessDenied(permission: Permission.viewReports);
    return const PageScroll(gap: AppSpace.gap14, children: [_Toolbar(), _Grid()]);
  }
}

class _Toolbar extends ConsumerStatefulWidget {
  const _Toolbar();

  @override
  ConsumerState<_Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends ConsumerState<_Toolbar> {
  Timer? _debounce;
  bool _busy = false;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final st = ref.read(consumptionControllerProvider);
      final s = ref.read(settingsProvider);
      final rows = await ref.read(registerRepositoryProvider).consumptionAll(st.month, includeAll: st.includeAll);
      final lines = consumptionLines(rows, month: st.month, avgLead: s.avgLeadTimeDays, maxLead: s.maxLeadTimeDays);
      final table = consumptionTable(lines, month: st.month, storeName: s.name, avgLead: s.avgLeadTimeDays, maxLead: s.maxLeadTimeDays);
      final name = 'inventory-register-${st.month}';
      String? path;
      try {
        path = await saveBytesAs('$name.xlsx', await buildXlsxInIsolate(table, sheetName: monthTitle(st.month)));
      } on Object {
        path = await saveTextAs('$name.csv', buildCsv(table));
      }
      if (path != null) ref.read(toastsProvider.notifier).show('${path.split(RegExp(r'[/\\]')).last} saved · ${lines.length} medicines');
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('Export failed: $e', warn: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply(Map<int, int> levels) async {
    final ok = await showAppDialog<bool>(
      context,
      builder: (context) => AppDialogPanel(
        semanticLabel: 'Apply reorder levels',
        children: [
          Text('Apply ${levels.length} suggested reorder ${levels.length == 1 ? 'level' : 'levels'}?', style: AppType.cardTitle),
          Text(
            'The low-stock alerts for these medicines will use the new levels. You can still change any of them in Inventory.',
            style: AppType.body,
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpace.gap10,
            children: [
              AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
              AppButton(key: const ValueKey('apply-confirm'), label: 'Apply', onPressed: () => Navigator.of(context).pop(true)),
            ],
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final n = await ref.read(guardedActionsProvider).setReorderLevels(levels);
      ref.read(consumptionControllerProvider.notifier).clearPicked();
      ref.read(toastsProvider.notifier).show('Reorder level updated for ${formatCount(n)} ${n == 1 ? 'medicine' : 'medicines'}');
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('$e', warn: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(consumptionControllerProvider);
    final ctl = ref.read(consumptionControllerProvider.notifier);
    final s = ref.watch(settingsProvider);
    final lines = ref.watch(consumptionPageProvider).value?.$2 ?? const <ConsumptionLine>[];
    final picked = {for (final l in lines) if (st.picked.contains(l.row.productId)) l.row.productId: l.suggested};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            TextButton.icon(
              key: const ValueKey('consumption-back'),
              onPressed: () => context.go(Routes.register),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('Sales register'),
            ),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Semantics(header: true, child: Text('Inventory Management Register', style: AppType.cardTitle, overflow: TextOverflow.ellipsis)),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        Wrap(
          spacing: AppSpace.md,
          runSpacing: AppSpace.md,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const ValueKey('month-prev'),
                  tooltip: 'Previous month',
                  onPressed: () => ctl.moveMonth(-1),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                SizedBox(
                  width: 150,
                  child: Text(monthTitle(st.month), key: const ValueKey('month-label'), textAlign: TextAlign.center, style: AppType.bodyStrong),
                ),
                IconButton(
                  key: const ValueKey('month-next'),
                  tooltip: 'Next month',
                  onPressed: () => ctl.moveMonth(1),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
              child: AppTextField(
                fieldKey: const ValueKey('consumption-search'),
                label: '',
                hint: 'Find a medicine…',
                prefixIcon: Icons.search_rounded,
                value: st.search,
                onChanged: (v) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 150), () => ctl.setSearch(v));
                },
              ),
            ),
            SegmentedPills<bool>(
              semanticLabel: 'Medicines',
              options: const [PillOption(false, 'Sold this month'), PillOption(true, 'All medicines')],
              selected: st.includeAll,
              onChanged: ctl.setIncludeAll,
            ),
            AppButton.secondary(
              key: const ValueKey('consumption-export'),
              label: _busy ? 'Exporting…' : 'Export Excel',
              icon: Icons.download_rounded,
              onPressed: _busy ? null : _export,
            ),
            if (picked.isNotEmpty)
              AppButton(
                key: const ValueKey('apply-reorder'),
                label: 'Apply ${picked.length} reorder ${picked.length == 1 ? 'level' : 'levels'}',
                icon: Icons.check_rounded,
                onPressed: () => _apply(picked),
              ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          'Lead time ${s.avgLeadTimeDays} day${s.avgLeadTimeDays == 1 ? '' : 's'} average, ${s.maxLeadTimeDays} maximum '
          '(Settings › Inventory). Average = over days with sales. Quantities are tablets for medicines sold loose, else packs.',
          style: AppType.caption,
        ),
      ],
    );
  }
}

/// Medicine names stay put while days and figures scroll sideways.
class _Grid extends ConsumerWidget {
  const _Grid();

  static const double _rowH = AppSizes.controlMin;
  static const double _day = 40;

  static const List<(String, String, double)> _stats = [
    ('Total', 'Total consumption in the month', 72),
    ('Avg/day', 'Average daily consumption (days with sales)', 72),
    ('Max/day', 'Maximum daily consumption', 72),
    ('Reorder', 'Reorder level = max/day × max lead time', 72),
    ('Min stock', 'Minimum stock level = reorder − avg/day × avg lead time', 80),
    ('Buffer', 'Buffer stock = (max/day − avg/day) × avg lead time', 72),
    ('Stock now', 'Saleable stock today', 120),
    ('Reorder now', 'Reorder level set on the medicine', 110),
    ('Suggested', 'Reorder level from this month, in packs', 110),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(consumptionControllerProvider);
    final ctl = ref.read(consumptionControllerProvider.notifier);
    final async = ref.watch(consumptionPageProvider);
    final data = async.value;
    final lines = data?.$2 ?? const <ConsumptionLine>[];
    final n = daysInMonth(st.month);
    final canApply = ref.watch(canProvider(Permission.changeStock));
    bool eligible(ConsumptionLine l) => canApply && l.suggested > 0 && l.suggested != l.row.reorderLevel;
    final eligibleIds = {for (final l in lines) if (eligible(l)) l.row.productId};
    final allPicked = eligibleIds.isNotEmpty && eligibleIds.every(st.picked.contains);

    Widget cell(String text, double w, {bool end = true, TextStyle? style, String? tooltip}) {
      final t = Text(text, overflow: TextOverflow.ellipsis, textAlign: end ? TextAlign.right : TextAlign.left, style: style ?? AppType.small);
      return SizedBox(
        width: w,
        height: _rowH,
        child: Align(
          alignment: end ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: tooltip == null ? t : Tooltip(message: tooltip, child: t)),
        ),
      );
    }

    final header = AppType.label;
    final tab = AppType.small.copyWith(fontFeatures: AppType.tabular);
    final strong = AppType.smallStrong.copyWith(fontFeatures: AppType.tabular);
    BoxDecoration rowDeco(int i) => BoxDecoration(
          color: i < 0 ? AppColors.surfaceAlt : AppColors.surface,
          border: const Border(bottom: BorderSide(color: AppColors.divider)),
        );

    final left = Column(
      children: [
        Container(
          decoration: rowDeco(-1),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                height: _rowH,
                child: eligibleIds.isEmpty
                    ? null
                    : Checkbox(
                        key: const ValueKey('pick-all'),
                        value: allPicked,
                        semanticLabel: 'Tick all suggested on this page',
                        onChanged: (_) => ctl.setPicked(allPicked ? (st.picked.difference(eligibleIds)) : {...st.picked, ...eligibleIds}),
                      ),
              ),
              cell('S.No', 48, style: header),
              cell('Name of medicine', 200, end: false, style: header),
            ],
          ),
        ),
        for (final (i, l) in lines.indexed)
          Container(
            decoration: rowDeco(i),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  height: _rowH,
                  child: eligible(l)
                      ? Checkbox(
                          key: ValueKey('pick-${l.row.productId}'),
                          value: st.picked.contains(l.row.productId),
                          semanticLabel: 'Apply suggested reorder level for ${l.row.name}',
                          onChanged: (_) => ctl.toggle(l.row.productId),
                        )
                      : null,
                ),
                cell('${(st.page - 1) * st.pageSize + i + 1}', 48, style: tab),
                cell(l.row.name, 200, end: false, style: AppType.smallStrong, tooltip: l.row.name),
              ],
            ),
          ),
      ],
    );

    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: rowDeco(-1),
          child: Row(
            children: [
              for (var d = 1; d <= n; d++) cell('$d', _day, style: header),
              for (final (label, help, w) in _stats) cell(label, w, style: header, tooltip: help),
            ],
          ),
        ),
        for (final (i, l) in lines.indexed)
          Container(
            key: ValueKey('crow-${l.row.productId}'),
            decoration: rowDeco(i),
            child: Row(
              children: [
                for (var d = 1; d <= n; d++)
                  cell(
                    (l.row.daily[d] ?? 0) == 0 ? '' : formatCount(l.row.daily[d]!),
                    _day,
                    style: (l.row.daily[d] ?? 0) < 0 ? tab.copyWith(color: StatusTone.danger.colors.fg) : tab,
                  ),
                cell(formatCount(l.stats.total), 72, style: strong),
                cell(formatQty(l.stats.avgDaily), 72, style: tab),
                cell(formatCount(l.stats.maxDaily), 72, style: tab),
                cell(formatQty(l.stats.reorderLevel), 72, style: tab),
                cell(formatQty(l.stats.minStock), 80, style: tab),
                cell(formatQty(l.stats.buffer), 72, style: tab),
                cell(
                  formatPackQty(l.row.saleable, l.row.unitsPerPack, l.row.category),
                  120,
                  style: tab.copyWith(
                    color: l.row.saleable <= l.row.reorderLevel * l.row.unitsPerPack ? StatusTone.warning.colors.fg : null,
                  ),
                ),
                cell(formatCount(l.row.reorderLevel), 110, style: tab),
                cell(
                  l.suggested == 0 ? '—' : formatCount(l.suggested),
                  110,
                  style: l.suggested != 0 && l.suggested != l.row.reorderLevel ? strong.copyWith(color: StatusTone.info.colors.fg) : tab,
                ),
              ],
            ),
          ),
      ],
    );

    return AppCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (async.isLoading && data == null) const LinearProgressIndicator(minHeight: 2),
          if (data != null && lines.isEmpty)
            EmptyState(
              icon: Icons.inventory_outlined,
              title: st.includeAll ? 'No medicines' : 'Nothing sold in ${monthTitle(st.month)}',
              message: st.includeAll ? null : 'Pick another month, or show all medicines.',
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                left,
                const VerticalDivider(width: 1),
                Expanded(child: _HScroll(child: right)),
              ],
            ),
          const Divider(),
          Pager(
            page: st.page,
            pageSize: st.pageSize,
            totalRows: data?.$1.total ?? 0,
            onPage: ctl.setPage,
            onPageSize: ctl.setPageSize,
            trailingNote: data == null ? null : 'computed in ${data.$1.ms.toStringAsFixed(1)} ms',
          ),
        ],
      ),
    );
  }
}

/// Horizontal scroll with its own controller (memory: a Scrollbar must share
/// the scroll view's controller).
class _HScroll extends StatefulWidget {
  const _HScroll({required this.child});

  final Widget child;

  @override
  State<_HScroll> createState() => _HScrollState();
}

class _HScrollState extends State<_HScroll> {
  final ScrollController _c = ScrollController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _c,
      thumbVisibility: true,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(controller: _c, scrollDirection: Axis.horizontal, child: widget.child),
      ),
    );
  }
}
