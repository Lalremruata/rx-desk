import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/reports_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/db/models.dart';
import '../../../core/money/paise.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/pack.dart';
import '../../../core/widgets/widgets.dart';
import '../../billing/data/sales_repository.dart';
import '../../customers/application/customers_providers.dart';
import '../../customers/presentation/customer_dialogs.dart';
import '../../inventory/application/inventory_providers.dart';
import '../../invoices/application/invoice_selection.dart';
import '../../purchases/application/purchases_providers.dart';
import '../../settings/application/settings_providers.dart';
import '../application/chart_series.dart';
import '../application/dashboard_providers.dart';

/// Recent invoices (live stream). Declared by hand: Drift row type.
final _recentProvider = StreamProvider.autoDispose<List<Invoice>>((ref) => ref.watch(salesRepositoryProvider).watchRecent());

/// Dashboard (SPEC §5.1).
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PageScroll(
      children: [
        const _Kpis(),
        LayoutBuilder(
          builder: (context, c) => c.maxWidth >= 860
              ? const IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [Expanded(flex: 2, child: _SalesChart()), SizedBox(width: AppSpace.lg), Expanded(child: _CategoryDonut())],
                  ),
                )
              : const Column(children: [_SalesChart(), SizedBox(height: AppSpace.lg), _CategoryDonut()]),
        ),
        const ResponsiveGrid(equalHeight: false, children: [_ReorderSoon(), _ExpiringBatches(), _RecentInvoices(), _StockistDues(), _CustomerDues()]),
      ],
    );
  }
}

class _Kpis extends ConsumerWidget {
  const _Kpis();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final k = ref.watch(dashboardKpisProvider).value;
    final days = ref.watch(settingsProvider.select((s) => s.expiryWindowMonths)) * 30;
    void open(InventoryView v, InventorySort sort) {
      ref.read(inventoryFilterProvider.notifier).open(v, sort: sort);
      context.go(Routes.inventory);
    }

    return ResponsiveGrid(
      children: [
        KpiTile(
          key: const ValueKey('kpi-today'),
          label: 'Today’s sales',
          value: formatInr(k?.todayNet ?? Paise.zero, decimals: 0),
          caption: '${k?.todayBills ?? 0} invoices · avg ${formatInr(k?.todayAverage ?? Paise.zero, decimals: 0)}',
          icon: Icons.trending_up_rounded,
        ),
        KpiTile(
          label: 'Stock value',
          value: formatInr(k?.stockValue ?? Paise.zero, decimals: 0),
          caption: '${formatCount(k?.medicines ?? 0)} medicines at MRP',
          icon: Icons.inventory_2_outlined,
          tone: StatusTone.info,
        ),
        KpiTile(
          key: const ValueKey('kpi-low'),
          label: 'Low / out of stock',
          value: formatCount(k?.lowOrOut ?? 0),
          caption: 'Review and reorder →',
          icon: Icons.warning_amber_rounded,
          tone: StatusTone.warning,
          captionTone: StatusTone.warning,
          onTap: () => open(InventoryView.low, InventorySort.stock),
        ),
        KpiTile(
          key: const ValueKey('kpi-expiring'),
          label: 'Expiring ≤ $days days',
          value: formatCount(k?.expiring ?? 0),
          caption: 'Medicines with near-expiry batches →',
          icon: Icons.schedule_rounded,
          tone: StatusTone.danger,
          captionTone: StatusTone.danger,
          onTap: () => open(InventoryView.expiring, InventorySort.expiry),
        ),
      ],
    );
  }
}

class _SalesChart extends ConsumerStatefulWidget {
  const _SalesChart();

  @override
  ConsumerState<_SalesChart> createState() => _SalesChartState();
}

class _SalesChartState extends ConsumerState<_SalesChart> {
  /// Bars start at 0 and grow on first data (SPEC §9).
  bool _grown = false;

  @override
  Widget build(BuildContext context) {
    final range = ref.watch(chartRangeSelProvider);
    final series = ref.watch(chartSeriesProvider).value;
    final p = context.palette;
    if (series != null && !_grown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _grown = true);
      });
    }
    final reduce = context.reduceMotion;
    final show = _grown || reduce;
    final max = (series?.niceMax ?? 200000) / 100;

    return AppCard(
      title: 'Sales overview',
      subtitle: series == null
          ? const Text(' ')
          : Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Total '),
                  TextSpan(text: formatInr(series.total, decimals: 0), style: AppType.smallStrong),
                  TextSpan(text: ' · Avg ${formatInr(series.average, decimals: 0)} · Peak ${formatInr(series.peak, decimals: 0)}'),
                ],
              ),
            ),
      trailing: SegmentedPills<ChartRange>(
        semanticLabel: 'Chart range',
        options: [for (final r in ChartRange.values) PillOption(r, r.label)],
        selected: range,
        onChanged: (r) => ref.read(chartRangeSelProvider.notifier).set(r),
      ),
      child: SizedBox(
        height: 240,
        child: series == null
            ? const SizedBox.shrink()
            : Semantics(
                label: 'Sales bar chart, ${range.label}: total ${formatInr(series.total, decimals: 0)}',
                child: BarChart(
                  BarChartData(
                    maxY: max,
                    minY: 0,
                    alignment: BarChartAlignment.spaceAround,
                    borderData: FlBorderData(show: true, border: const Border(bottom: BorderSide(color: AppColors.chartAxis))),
                    gridData: FlGridData(
                      drawVerticalLine: false,
                      horizontalInterval: max / 4,
                      getDrawingHorizontalLine: (_) => const FlLine(color: AppColors.chartGrid, strokeWidth: 1, dashArray: [4, 4]),
                    ),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 48,
                          interval: max / 4,
                          getTitlesWidget: (v, meta) => SideTitleWidget(
                            meta: meta,
                            child: Text(v == 0 ? '' : formatInrShort(Paise((v * 100).round())), style: AppType.caption.copyWith(fontSize: 11, color: AppColors.textMuted)),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 26,
                          getTitlesWidget: (v, meta) {
                            final i = v.toInt();
                            final t = i >= 0 && i < series.bars.length ? series.bars[i].axis : '';
                            return SideTitleWidget(meta: meta, child: Text(t, style: AppType.caption.copyWith(fontSize: 11, color: AppColors.textMuted)));
                          },
                        ),
                      ),
                    ),
                    barTouchData: BarTouchData(
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (_) => AppColors.toastBg,
                        tooltipBorderRadius: AppRadius.smallAll,
                        getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                          '${series.bars[gi].label} · ${formatInr(series.bars[gi].value, decimals: 0)}',
                          AppType.label.copyWith(color: AppColors.toastFg),
                        ),
                      ),
                    ),
                    barGroups: [
                      for (final (i, b) in series.bars.indexed)
                        BarChartGroupData(
                          x: i,
                          barRods: [
                            BarChartRodData(
                              toY: show ? b.value.value / 100 : 0,
                              color: i == series.bars.length - 1 ? p.accent : p.accentMuted,
                              width: range == ChartRange.d30 ? 8 : 26,
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(6), bottom: Radius.circular(2)),
                            ),
                          ],
                        ),
                    ],
                  ),
                  duration: reduce ? Duration.zero : (_grown ? AppMotion.barsResize : AppMotion.bars),
                  curve: AppMotion.emphasised,
                ),
              ),
      ),
    );
  }
}

/// Category display names and colours (prototype CATC).
const Map<String, String> _catNames = {
  'Tablet': 'Tablets',
  'Capsule': 'Capsules',
  'Syrup': 'Syrups',
  'Injection': 'Injections',
  'OTC': 'OTC',
  'Topical': 'Topical',
};

class _CategoryDonut extends ConsumerStatefulWidget {
  const _CategoryDonut();

  @override
  ConsumerState<_CategoryDonut> createState() => _CategoryDonutState();
}

class _CategoryDonutState extends ConsumerState<_CategoryDonut> {
  String? _hover;

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(categoryMonthProvider).value ?? const <CategorySales>[];
    final total = cats.fold<int>(0, (a, c) => a + c.net.value);
    double pct(CategorySales c) => total == 0 ? 0 : (c.net.value * 1000 / total).round() / 10;
    final hovered = cats.where((c) => c.category == _hover).firstOrNull;
    final d = context.motion(const Duration(milliseconds: 400));

    return AppCard(
      title: 'Sales by category',
      subtitle: const Text('This month · hover a row'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 168,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  PieChartData(
                    sectionsSpace: 0,
                    centerSpaceRadius: 54,
                    startDegreeOffset: -90,
                    sections: [
                      if (total == 0) PieChartSectionData(value: 1, color: AppColors.track, radius: 30, showTitle: false),
                      for (final c in cats)
                        PieChartSectionData(
                          value: c.net.value.toDouble(),
                          color: _hover != null && _hover != c.category
                              ? AppColors.mixOverWhite(AppColors.category[c.category] ?? AppColors.textMuted, 0.25)
                              : AppColors.category[c.category] ?? AppColors.textMuted,
                          radius: 30,
                          showTitle: false,
                        ),
                    ],
                  ),
                  duration: d,
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      hovered != null ? '${pct(hovered)}%' : formatInrShort(Paise(total)),
                      key: const ValueKey('donut-center'),
                      style: AppType.cardTitle.copyWith(fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                    Text(hovered != null ? _catNames[hovered.category] ?? hovered.category : 'Sales this month', style: AppType.caption.copyWith(fontSize: 11)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.md),
          for (final c in cats)
            MouseRegion(
              onEnter: (_) => setState(() => _hover = c.category),
              onExit: (_) => setState(() => _hover = null),
              child: GestureDetector(
                onTap: () => setState(() => _hover = _hover == c.category ? null : c.category),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                  decoration: BoxDecoration(
                    color: _hover == c.category ? AppColors.rowHover : AppColors.transparent,
                    borderRadius: AppRadius.smallAll,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: AppColors.category[c.category] ?? AppColors.textMuted, borderRadius: BorderRadius.circular(3)),
                      ),
                      const SizedBox(width: AppSpace.gap10),
                      Expanded(child: Text(_catNames[c.category] ?? c.category, style: AppType.small)),
                      Text('${pct(c)}%', style: AppType.smallStrong),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard({required this.title, required this.onViewAll, required this.children, this.empty});

  final String title;
  final VoidCallback onViewAll;
  final List<Widget> children;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      title: title,
      trailing: TextButton(onPressed: onViewAll, child: const Text('View all')),
      gap: AppSpace.sm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children.isEmpty
            ? [Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(empty ?? 'Nothing here', style: AppType.small.copyWith(color: AppColors.textSecondary)))]
            : children,
      ),
    );
  }
}

class _ReorderSoon extends ConsumerWidget {
  const _ReorderSoon();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(reorderSoonProvider).value ?? const <StockRow>[];
    return _ListCard(
      title: 'Reorder soon',
      empty: 'Everything is above its reorder level.',
      onViewAll: () {
        ref.read(inventoryFilterProvider.notifier).open(InventoryView.low, sort: InventorySort.stock);
        context.go(Routes.inventory);
      },
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(r.name, style: AppType.smallStrong, overflow: TextOverflow.ellipsis)),
                    Text('${r.saleablePacks} / ${r.reorderLevel} min', style: AppType.caption),
                  ],
                ),
                const SizedBox(height: 6),
                StockBar(
                  fraction: r.saleable / (r.reorderLevel * r.packSize < 1 ? 1 : r.reorderLevel * r.packSize),
                  level: r.isOut ? StockLevel.out : StockLevel.low,
                  semanticLabel: '${r.name}: ${r.saleablePacks} of ${r.reorderLevel}',
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ExpiringBatches extends ConsumerWidget {
  const _ExpiringBatches();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(expiringBatchesProvider).value ?? const [];
    final now = ref.watch(nowProvider)();
    return _ListCard(
      title: 'Expiring batches',
      empty: 'No batches expire soon.',
      onViewAll: () {
        ref.read(inventoryFilterProvider.notifier).open(InventoryView.expiring, sort: InventorySort.expiry);
        context.go(Routes.inventory);
      },
      children: [
        for (final e in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.productName, style: AppType.smallStrong, overflow: TextOverflow.ellipsis),
                      Text(
                        'Batch ${e.batchNo} · ${e.packSize > 1 ? formatPackQty(e.qty, e.packSize, e.category) : '${e.qty} units'}',
                        style: AppType.caption,
                      ),
                    ],
                  ),
                ),
                StatusBadge.tag(
                  isExpired(e.expiry, now) ? 'Expired' : formatExpiry(e.expiry),
                  tone: monthsLeft(e.expiry, now) <= 1 ? StatusTone.danger : StatusTone.warning,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _RecentInvoices extends ConsumerWidget {
  const _RecentInvoices();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_recentProvider).value ?? const <Invoice>[];
    final now = ref.watch(nowProvider)();
    String when(Invoice i) {
      final at = DateTime.fromMillisecondsSinceEpoch(i.createdAt, isUtc: true).toLocal();
      final day = i.saleDate == dateKey(now)
          ? 'Today'
          : i.saleDate == dateKey(now.subtract(const Duration(days: 1)))
              ? 'Yesterday'
              : dayLabel(i.saleDate).substring(4);
      return '$day · ${formatTime(at)}';
    }

    return _ListCard(
      title: 'Recent invoices',
      empty: 'No bills yet.',
      onViewAll: () => context.go(Routes.invoices),
      children: [
        for (final i in rows)
          InkWell(
            key: ValueKey('recent-${i.number}'),
            borderRadius: AppRadius.smallAll,
            onTap: () {
              ref.read(selectedInvoiceProvider.notifier).select(i.id);
              context.go(Routes.invoices);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(i.customerName, style: AppType.smallStrong, overflow: TextOverflow.ellipsis),
                        Text('${i.number} · ${when(i)}', style: AppType.caption, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  Text(formatInr(Paise(i.totalPaise)), style: AppType.smallStrong),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Stockist dues (SPEC §5.1): total owed, overdue, top stockists.
class _StockistDues extends ConsumerWidget {
  const _StockistDues();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(duesTotalsProvider).value;
    final t = data?.$1;
    final top = data?.$2 ?? const [];
    void open() {
      ref.read(purchasesTabStateProvider.notifier).set(PurchasesTab.dues);
      context.go(Routes.purchases);
    }

    return _ListCard(
      title: 'Stockist dues',
      empty: 'Nothing owed to stockists.',
      onViewAll: open,
      children: [
        if (t != null && t.owed.value > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text.rich(
              key: const ValueKey('dash-dues'),
              TextSpan(
                children: [
                  TextSpan(text: formatInr(t.owed, decimals: 0), style: AppType.cardTitle),
                  TextSpan(text: '  owed', style: AppType.caption),
                  if (t.overdue.value > 0)
                    TextSpan(
                      text: ' · ${formatInr(t.overdue, decimals: 0)} overdue',
                      style: AppType.smallStrong.copyWith(color: StatusTone.danger.colors.fg),
                    ),
                ],
              ),
            ),
          ),
        for (final d in top)
          InkWell(
            borderRadius: AppRadius.smallAll,
            onTap: open,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.name, style: AppType.smallStrong, overflow: TextOverflow.ellipsis),
                        Text(
                          d.overdue.value > 0 ? '${formatInr(d.overdue, decimals: 0)} overdue' : '${d.openBills} open ${d.openBills == 1 ? 'bill' : 'bills'}',
                          style: AppType.caption.copyWith(color: d.overdue.value > 0 ? StatusTone.danger.colors.fg : null),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Text(formatInr(d.balance, decimals: 0), style: AppType.smallStrong),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Customer credit (SPEC §4.10): what customers owe, largest first.
class _CustomerDues extends ConsumerWidget {
  const _CustomerDues();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(customerDuesTotalsProvider).value;
    final t = data?.$1;
    final top = data?.$2 ?? const [];
    final today = dateKey(ref.watch(nowProvider)());

    return _ListCard(
      title: 'Customer dues',
      empty: 'No customer owes anything.',
      onViewAll: () => context.go(Routes.customers),
      children: [
        if (t != null && t.owed.value > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text.rich(
              key: const ValueKey('dash-cdues'),
              TextSpan(
                children: [
                  TextSpan(text: formatInr(t.owed, decimals: 0), style: AppType.cardTitle),
                  TextSpan(text: '  to collect', style: AppType.caption),
                  if (t.over90.value > 0)
                    TextSpan(
                      text: ' · ${formatInr(t.over90, decimals: 0)} 90+ days',
                      style: AppType.smallStrong.copyWith(color: StatusTone.danger.colors.fg),
                    ),
                ],
              ),
            ),
          ),
        for (final d in top)
          InkWell(
            borderRadius: AppRadius.smallAll,
            onTap: () => showCustomerStatement(context, customerId: d.customerId),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.name, style: AppType.smallStrong, overflow: TextOverflow.ellipsis),
                        Text(
                          d.oldestOpen == null ? d.phone : 'Oldest ${d.agingOn(today).label}',
                          style: AppType.caption.copyWith(color: agingTone(d.agingOn(today)) == StatusTone.danger ? StatusTone.danger.colors.fg : null),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Text(formatInr(d.balance, decimals: 0), style: AppType.smallStrong),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
