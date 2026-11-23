import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/catalog_dao.dart';
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
import '../../../core/utils/save_file.dart';
import '../../../core/widgets/widgets.dart';
import '../../purchases/application/purchases_providers.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/guarded_actions.dart';
import '../../staff/application/session.dart';
import '../application/inventory_providers.dart';
import '../application/inventory_rules.dart';
import '../data/inventory_repository.dart';
import 'inventory_dialogs.dart';

/// Inventory (SPEC §5.3).
class InventoryScreen extends ConsumerWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const PageScroll(
      gap: AppSpace.gap14,
      children: [_ViewTabs(), _Toolbar(), _Grid()],
    );
  }
}

// ---------------------------------------------------------------------------

class _ViewTabs extends ConsumerWidget {
  const _ViewTabs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(inventoryFilterProvider);
    final counts = ref.watch(inventoryCountsProvider).value ?? const InventoryCounts();
    final days = ref.watch(settingsProvider.select((s) => s.expiryWindowMonths)) * 30;
    final p = context.palette;
    String label(InventoryView v) => switch (v) {
          InventoryView.all => 'All items',
          InventoryView.low => 'Low stock',
          InventoryView.expiring => 'Expiring ≤ ${days}d',
          InventoryView.out => 'Out of stock',
          InventoryView.dead => 'Dead stock',
          InventoryView.hidden => 'Hidden',
        };
    // Hidden appears once something has been hidden.
    final views = [
      for (final v in InventoryView.values)
        if (v != InventoryView.hidden || counts.hidden > 0 || q.view == InventoryView.hidden) v,
    ];
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.chipBorder))),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Semantics(
          container: true,
          label: 'Saved views',
          child: Row(
            children: [
              for (final v in views)
                Semantics(
                  selected: q.view == v,
                  button: true,
                  child: InkWell(
                    key: ValueKey('view-${v.name}'),
                    onTap: () => ref.read(inventoryFilterProvider.notifier).setView(v),
                    child: AnimatedContainer(
                      duration: context.motion(AppMotion.colour),
                      constraints: const BoxConstraints(minHeight: AppSizes.controlMin),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: q.view == v ? p.accent : AppColors.transparent, width: 2.5)),
                      ),
                      child: Row(
                        children: [
                          Text(label(v), style: AppType.bodyStrong.copyWith(color: q.view == v ? p.accent : AppColors.label)),
                          const SizedBox(width: AppSpace.sm),
                          StatusBadge.count(formatCount(counts.of(v)), tone: q.view == v ? StatusTone.accent : StatusTone.neutral),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _Toolbar extends ConsumerStatefulWidget {
  const _Toolbar();

  @override
  ConsumerState<_Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends ConsumerState<_Toolbar> {
  Timer? _debounce;
  bool _exporting = false;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () => ref.read(inventoryFilterProvider.notifier).setSearch(v));
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final q = ref.read(inventoryFilterProvider);
      final s = ref.read(settingsProvider);
      final repo = ref.read(inventoryRepositoryProvider);
      final all = await repo.page(q.copyWith(page: 1, pageSize: 500), expiryWindowMonths: s.expiryWindowMonths, deadStockDays: s.deadStockDays);
      final rows = [...all.rows];
      for (var page = 2; rows.length < all.total; page++) {
        final next = await repo.page(q.copyWith(page: page, pageSize: 500), expiryWindowMonths: s.expiryWindowMonths, deadStockDays: s.deadStockDays);
        if (next.rows.isEmpty) break;
        rows.addAll(next.rows);
      }
      final now = ref.read(nowProvider)();
      final name = 'inventory-${dateKey(now)}.csv';
      final path = await saveTextAs(name, inventoryCsv(rows, now: now, deadStockDays: s.deadStockDays));
      if (path != null) ref.read(toastsProvider.notifier).show('$name saved (${formatCount(rows.length)} rows)');
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('Export failed: $e', warn: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = ref.watch(inventoryFilterProvider);
    final makers = ref.watch(makersProvider).value ?? const <Manufacturer>[];
    final canEdit = ref.watch(canProvider(Permission.changeStock));
    return Wrap(
      spacing: AppSpace.gap10,
      runSpacing: AppSpace.gap10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 260, maxWidth: 420),
          child: AppTextField(
            key: const ValueKey('inventory-search'),
            label: '',
            hint: 'Name, salt, batch, barcode or HSN…',
            prefixIcon: Icons.search_rounded,
            value: q.search,
            onChanged: _onSearch,
          ),
        ),
        AppDropdown<String?>(
          label: 'Category',
          value: q.category,
          options: [const DropdownOption(null, 'All'), for (final c in productCategories) DropdownOption(c, c)],
          onChanged: (v) => ref.read(inventoryFilterProvider.notifier).setCategory(v),
        ),
        AppDropdown<int?>(
          label: 'Maker',
          value: q.manufacturerId,
          width: 200,
          options: [const DropdownOption(null, 'All makers'), for (final m in makers) DropdownOption(m.id, m.name)],
          onChanged: (v) => ref.read(inventoryFilterProvider.notifier).setMaker(v),
        ),
        AppButton.secondary(label: _exporting ? 'Exporting…' : 'Export', icon: Icons.download_rounded, onPressed: _exporting ? null : _export),
        if (ref.watch(canProvider(Permission.viewReports)))
          AppButton.secondary(
            key: const ValueKey('open-consumption'),
            label: 'Consumption register',
            icon: Icons.calendar_view_month_rounded,
            onPressed: () => context.go(Routes.consumption),
          ),
        AppButton(
          key: const ValueKey('add-medicine'),
          label: 'Add medicine',
          icon: Icons.add_rounded,
          onPressed: canEdit ? () => showAddMedicineDialog(context) : null,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _Grid extends ConsumerWidget {
  const _Grid();

  static const _columns = [
    GridColumn.fixed('', 44),
    GridColumn('Medicine', flex: 2.6, minWidth: 240, sortKey: 'name'),
    GridColumn('Maker', flex: 1.3, minWidth: 150),
    GridColumn.fixed('Category', 84),
    GridColumn.fixed('Nearest expiry', 120, sortKey: 'expiry'),
    GridColumn.fixed('Saleable stock', 170, sortKey: 'stock'),
    GridColumn.fixed('MRP', 92, alignEnd: true, sortKey: 'mrp'),
    GridColumn.fixed('Rack', 64),
    GridColumn.fixed('Status', 116),
    GridColumn.fixed('Action', 104, alignEnd: true),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(inventoryFilterProvider);
    final pageAsync = ref.watch(inventoryPageProvider);
    final page = pageAsync.value;
    final expanded = ref.watch(expandedProductsProvider);
    final s = ref.watch(settingsProvider);
    final now = ref.watch(nowProvider)();
    final canEdit = ref.watch(canProvider(Permission.changeStock));
    final rows = page?.rows ?? const <StockRow>[];
    final hiddenView = q.view == InventoryView.hidden;

    return AppCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pageAsync.isLoading && page == null) const LinearProgressIndicator(minHeight: 2),
          DataGrid(
            semanticLabel: 'Inventory',
            columns: _columns,
            rowCount: rows.length,
            sortKey: q.sort.name,
            sortAscending: q.ascending,
            onSort: (k) => ref.read(inventoryFilterProvider.notifier).sortBy(InventorySort.values.byName(k)),
            empty: page == null
                ? const SizedBox(height: 120)
                : const EmptyState(title: 'No medicines match', message: 'Try a salt name or barcode, or clear the filters.'),
            belowRow: (context, i) => expanded.contains(rows[i].id) ? _BatchPanel(row: rows[i]) : null,
            cells: (context, i) =>
                _cells(context, ref, rows[i], expanded.contains(rows[i].id), now, s.expiryWindowMonths, s.deadStockDays, canEdit, hiddenView),
          ),
          const Divider(),
          Pager(
            page: q.page,
            pageSize: q.pageSize,
            totalRows: page?.total ?? 0,
            onPage: (p) => ref.read(inventoryFilterProvider.notifier).setPage(p),
            onPageSize: (n) => ref.read(inventoryFilterProvider.notifier).setPageSize(n),
            trailingNote: page == null ? null : '${page.ms.toStringAsFixed(1)} ms',
          ),
        ],
      ),
    );
  }

  List<Widget> _cells(
    BuildContext context,
    WidgetRef ref,
    StockRow r,
    bool open,
    DateTime now,
    int window,
    int deadDays,
    bool canEdit,
    bool hiddenView,
  ) {
    final p = context.palette;
    final exp = r.displayExpiry;
    final level = expiryLevel(exp, now, window);
    final (status, tone) = stockStatus(r, now: now, deadStockDays: deadDays);
    final stockLevel = r.isOut
        ? StockLevel.out
        : r.isLow
            ? StockLevel.low
            : StockLevel.ok;
    return [
      _ExpandButton(open: open, onTap: () => ref.read(expandedProductsProvider.notifier).toggle(r.id)),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Flexible(child: Text(r.name, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis)),
              if (r.schedule.isNotEmpty) ...[const SizedBox(width: 6), RxBadge(r.schedule)],
            ],
          ),
          Text(
            '${r.salt} · ${r.pack}${r.sellsLoose ? ' (${r.packSize}/${PackNouns.of(r.category).pack}, sold loose)' : ''}'
            ' · ${r.batchCount} ${r.batchCount == 1 ? 'batch' : 'batches'}',
            style: AppType.caption,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      Text(r.maker, style: AppType.small.copyWith(color: AppColors.body), overflow: TextOverflow.ellipsis),
      Text(r.category, style: AppType.small.copyWith(color: AppColors.body)),
      Text(
        exp == null ? '—' : formatExpiry(exp),
        style: AppType.smallStrong.copyWith(
          color: switch (level) {
            ExpiryLevel.critical => StockColors.out,
            ExpiryLevel.near => StockColors.low,
            ExpiryLevel.ok => AppColors.body,
          },
        ),
      ),
      Tooltip(
        message: formatPackQty(r.saleable, r.packSize, r.category),
        child: StockBar(
          fraction: stockFraction(r),
          level: stockLevel,
          trailing: compactPackQty(r.saleable, r.packSize, r.category),
          color: stockLevel == StockLevel.ok ? p.accent : null,
        ),
      ),
      r.mrpCount > 1
          ? Tooltip(
              message: '${r.mrpCount} MRPs on the shelf — each batch sells at its own (see batches)',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(formatInr(r.shownMrp), style: AppType.bodyStrong.copyWith(fontFeatures: AppType.tabular)),
                  Text('${r.mrpCount} MRPs', style: AppType.caption.copyWith(color: StockColors.low)),
                ],
              ),
            )
          : Text(formatInr(r.shownMrp), style: AppType.bodyStrong.copyWith(fontFeatures: AppType.tabular)),
      Text(r.rack.isEmpty ? '—' : r.rack, style: AppType.small.copyWith(color: AppColors.body)),
      hiddenView ? const StatusBadge('Hidden') : StatusBadge(status, tone: tone),
      hiddenView
          ? AppButton.secondary(
              key: ValueKey('unhide-${r.id}'),
              label: 'Unhide',
              height: 36,
              onPressed: canEdit ? () => setMedicineHidden(context, ref, r, hidden: false) : null,
            )
          : AppButton.secondary(
              key: ValueKey('receive-${r.id}'),
              label: 'Receive',
              height: 36,
              onPressed: canEdit ? () => showReceiveDialog(context, product: r) : null,
            ),
    ];
  }
}

class _ExpandButton extends StatelessWidget {
  const _ExpandButton({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: open ? 'Hide batches' : 'Show batches',
      child: Semantics(
        button: true,
        expanded: open,
        label: 'Show batches',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.smallAll,
          child: SizedBox(
            width: AppSizes.controlMin,
            height: AppSizes.controlMin,
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.chipBorder),
                  borderRadius: AppRadius.smallAll,
                ),
                child: AnimatedRotation(
                  turns: open ? 0.25 : 0,
                  duration: context.motion(AppMotion.chevron),
                  child: const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.label),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BatchPanel extends ConsumerWidget {
  const _BatchPanel({required this.row});

  final StockRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batches = ref.watch(productBatchesProvider(row.id)).value;
    final now = ref.watch(nowProvider)();
    final window = ref.watch(settingsProvider.select((s) => s.expiryWindowMonths));
    final fefo = batches == null ? null : fefoBatchId(batches, now);
    final canEdit = ref.watch(canProvider(Permission.changeStock));
    final hidden = ref.watch(inventoryFilterProvider.select((q) => q.view == InventoryView.hidden));

    Widget head(String t, {bool end = false}) =>
        Text(t, textAlign: end ? TextAlign.right : TextAlign.left, style: AppType.overline.copyWith(letterSpacing: 0.4));

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: context.motion(AppMotion.expand),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, AppMotion.dropdownDy * (1 - t)), child: child),
      ),
      child: Container(
        color: AppColors.surfaceAlt,
        padding: const EdgeInsets.fromLTRB(70, 4, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.border),
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    Container(
                      color: AppColors.tableHeadAlt,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      child: Row(
                        children: [
                          SizedBox(width: 110, child: head('BATCH')),
                          SizedBox(width: 96, child: head('EXPIRY')),
                          SizedBox(width: 80, child: head('QTY', end: true)),
                          SizedBox(width: 90, child: head('MRP', end: true)),
                          const SizedBox(width: 12),
                          Expanded(child: head('NOTE')),
                          if (canEdit) const SizedBox(width: _editButtonWidth),
                        ],
                      ),
                    ),
                    if (batches == null)
                      const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator(minHeight: 2))
                    else
                      for (final b in batches) _batchRow(context, b, now, window, fefo, canEdit),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.lg,
              runSpacing: 4,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'Barcode '),
                      TextSpan(text: row.barcode ?? '—', style: AppType.mono.copyWith(fontWeight: FontWeight.w400, color: AppColors.textSecondary)),
                    ],
                  ),
                  style: AppType.caption,
                ),
                Text('HSN ${row.hsn.isEmpty ? '—' : row.hsn}', style: AppType.caption),
                Text('GST ${row.gstRate}%', style: AppType.caption),
                Text(
                  'Reorder at ${row.reorderLevel}${row.sellsLoose ? ' ${PackNouns.of(row.category).packWord(row.reorderLevel)}' : ''}',
                  style: AppType.caption,
                ),
                _PackSizeLink(row: row),
                Text('Last sold ${lastSoldLabel(row.lastSoldAt, now)}', style: AppType.caption),
              ],
            ),
            if (canEdit)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    AppButton.secondary(
                      key: ValueKey('edit-medicine-${row.id}'),
                      label: 'Edit medicine',
                      icon: Icons.edit_outlined,
                      height: 36,
                      onPressed: () => showEditMedicineDialog(context, product: row),
                    ),
                    AppButton.secondary(
                      key: ValueKey('${hidden ? 'unhide' : 'hide'}-medicine-${row.id}'),
                      label: hidden ? 'Unhide medicine' : 'Hide medicine',
                      icon: hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      height: 36,
                      onPressed: () => setMedicineHidden(context, ref, row, hidden: !hidden),
                    ),
                  ],
                ),
              ),
            _GetFrom(productId: row.id),
          ],
        ),
      ),
    );
  }

  static const double _editButtonWidth = 48;

  Widget _batchRow(BuildContext context, StockBatch b, DateTime now, int window, int? fefo, bool canEdit) {
    final (note, tone) = batchNote(b, fefoBatchId: fefo, now: now, expiryWindowMonths: window);
    final level = expiryLevel(b.expiry, now, window);
    return Container(
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.divider))),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          SizedBox(width: 110, child: Text(b.batchNo, style: AppType.mono)),
          SizedBox(
            width: 96,
            child: Text(
              formatExpiry(b.expiry),
              style: AppType.smallStrong.copyWith(
                color: switch (level) {
                  ExpiryLevel.critical => StockColors.out,
                  ExpiryLevel.near => StockColors.low,
                  ExpiryLevel.ok => AppColors.body,
                },
              ),
            ),
          ),
          SizedBox(
            width: row.sellsLoose ? 150 : 80,
            child: Text(
              formatPackQty(b.qty, row.packSize, row.category),
              key: ValueKey('batch-qty-${b.batchNo}'),
              textAlign: TextAlign.right,
              style: AppType.bodyStrong.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          SizedBox(width: 90, child: Text(formatInr(Paise(b.mrpPaise)), textAlign: TextAlign.right, style: AppType.small)),
          const SizedBox(width: 12),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: StatusBadge.tag(note, tone: tone))),
          if (canEdit)
            SizedBox(
              width: _editButtonWidth,
              child: IconButton(
                key: ValueKey('edit-batch-${b.batchNo}'),
                tooltip: 'Edit batch ${b.batchNo} — number, expiry, counted stock',
                onPressed: () => showEditBatchDialog(context, product: row, batch: b),
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Get from" — stockists for this medicine, newest supplier first
/// (SPEC §4.11).
class _GetFrom extends ConsumerWidget {
  const _GetFrom({required this.productId});

  final int productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(productSourcesProvider(productId)).value ?? const [];
    if (sources.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.sm),
      child: Column(
        key: ValueKey('get-from-$productId'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('GET FROM', style: AppType.overline.copyWith(letterSpacing: 0.4)),
          for (final s in sources.take(3))
            Text(
              [
                s.supplierName,
                if (s.phones.isNotEmpty) s.phones,
                if (s.mr.isNotEmpty) 'MR ${s.mr}',
                if (s.lastReceived != null) 'last ${dayLabel(s.lastReceived!)}',
              ].join(' · '),
              style: AppType.caption.copyWith(color: AppColors.body),
            ),
          if (sources.length > 3) Text('+ ${sources.length - 3} more in Purchases › Stockists', style: AppType.caption),
        ],
      ),
    );
  }
}

/// Hides a medicine (after confirming) or brings it back (SPEC §5.3).
Future<void> setMedicineHidden(BuildContext context, WidgetRef ref, StockRow row, {required bool hidden}) async {
  if (hidden) {
    final stock = row.saleable > 0 ? ' It still has ${formatPackQty(row.saleable, row.packSize, row.category)} in stock.' : '';
    final ok = await showConfirmDialog(
      context,
      title: 'Hide ${row.name}?',
      message: 'It leaves search, billing and the stock views.$stock Nothing is deleted — '
          'bring it back from Inventory › Hidden.',
      confirmLabel: 'Hide',
      icon: Icons.visibility_off_outlined,
    );
    if (!ok) return;
  }
  final toasts = ref.read(toastsProvider.notifier);
  try {
    await ref.read(guardedActionsProvider).setMedicineHidden(row.id, hidden);
    if (hidden) ref.read(expandedProductsProvider.notifier).close(row.id);
    toasts.show(hidden ? '${row.name} hidden — find it under Hidden' : '${row.name} is back on sale');
  } on CatalogException catch (e) {
    toasts.show(e.message, warn: true);
  } on PermissionDenied catch (e) {
    toasts.show('$e', warn: true);
  }
}

/// "10 tabs per strip · Change" in the batch panel (SPEC §4.9).
class _PackSizeLink extends ConsumerWidget {
  const _PackSizeLink({required this.row});

  final StockRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = PackNouns.of(row.category);
    final canEdit = ref.watch(canProvider(Permission.changeStock));
    final text = row.sellsLoose ? '${row.packSize} ${w.units} per ${w.pack} · sold loose' : 'Sold whole only';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: AppType.caption),
        if (canEdit)
          TextButton(
            key: ValueKey('pack-size-${row.id}'),
            onPressed: () => showPackSizeDialog(context, product: row),
            child: Text(row.sellsLoose ? 'Change' : 'Sell loose…', style: AppType.caption.copyWith(fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}
