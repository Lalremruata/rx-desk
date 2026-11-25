import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/daos/dues_dao.dart';
import '../../../core/db/daos/purchases_dao.dart';
import '../../../core/db/daos/sources_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/money/paise.dart';
import '../../../core/purchases/dues_rules.dart';
import '../../../core/purchases/purchase_rules.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/save_file.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/guarded_actions.dart';
import '../../staff/application/session.dart';
import '../application/purchases_export.dart';
import '../application/purchases_providers.dart';
import '../data/purchases_repository.dart';
import 'dues_dialogs.dart';
import 'purchase_dialogs.dart';
import 'stockists_tab.dart';

/// Purchases — order book (SPEC §5.9).
class PurchasesScreen extends ConsumerWidget {
  const PurchasesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(purchasesTabStateProvider);
    return PageScroll(
      gap: AppSpace.gap14,
      children: [
        const _Kpis(),
        const _Toolbar(),
        switch (tab) {
          PurchasesTab.pending => const _PendingTab(),
          PurchasesTab.book => const _BookTab(),
          PurchasesTab.receipts => const _ReceiptsTab(),
          PurchasesTab.dues => const _DuesTab(),
          PurchasesTab.stockists => const StockistsTab(),
        },
      ],
    );
  }
}

StatusTone _statusTone(OrderStatus s) => switch (s) {
      OrderStatus.pending => StatusTone.neutral,
      OrderStatus.part => StatusTone.warning,
      OrderStatus.received => StatusTone.success,
      OrderStatus.closed => StatusTone.dead,
      OrderStatus.cancelled => StatusTone.dead,
    };

StatusTone _tagTone(SupplyTag t) => switch (t) {
      SupplyTag.none => StatusTone.success,
      SupplyTag.pending => StatusTone.neutral,
      SupplyTag.short => StatusTone.warning,
      SupplyTag.over => StatusTone.info,
      SupplyTag.cancelled => StatusTone.dead,
      SupplyTag.notOrdered => StatusTone.info,
    };

void _toastError(WidgetRef ref, Object e) => toastPurchaseError(ref, e);

StatusTone _billTone(BillStatus s, {required bool overdue}) => overdue
    ? StatusTone.danger
    : switch (s) {
        BillStatus.paid => StatusTone.success,
        BillStatus.part => StatusTone.warning,
        BillStatus.unpaid => StatusTone.neutral,
      };

// ---------------------------------------------------------------------------

class _Kpis extends ConsumerWidget {
  const _Kpis();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final k = ref.watch(purchaseKpisProvider).value ?? const PurchaseKpis();
    final dues = ref.watch(duesTotalsProvider).value?.$1 ?? const DuesTotals();
    final month = monthName(ref.watch(nowProvider)().month);
    return ResponsiveGrid(
      children: [
        KpiTile(
          key: const ValueKey('kpi-open'),
          label: 'Still due',
          value: formatCount(k.open),
          caption: 'Order lines pending or part supplied →',
          icon: Icons.pending_actions_rounded,
          tone: StatusTone.warning,
          onTap: () => ref.read(purchasesTabStateProvider.notifier).set(PurchasesTab.pending),
        ),
        KpiTile(
          key: const ValueKey('kpi-received'),
          label: 'Received in $month',
          value: formatInr(k.receivedThisMonth, decimals: 0),
          caption: 'Stockist invoices, as billed',
          icon: Icons.local_shipping_outlined,
        ),
        KpiTile(
          key: const ValueKey('kpi-owed'),
          label: 'Owed to stockists',
          value: formatInr(dues.owed, decimals: 0),
          caption: dues.overdue.value > 0 ? '${formatInr(dues.overdue, decimals: 0)} overdue →' : 'Nothing overdue →',
          captionTone: dues.overdue.value > 0 ? StatusTone.danger : null,
          icon: Icons.account_balance_wallet_outlined,
          tone: StatusTone.info,
          onTap: () => ref.read(purchasesTabStateProvider.notifier).set(PurchasesTab.dues),
        ),
        KpiTile(
          label: 'Short supplied',
          value: formatCount(k.shortThisMonth),
          caption: 'Lines this month that came in short',
          icon: Icons.remove_shopping_cart_outlined,
          tone: StatusTone.danger,
        ),
      ],
    );
  }
}

class _Toolbar extends ConsumerWidget {
  const _Toolbar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(purchasesTabStateProvider);
    final canEdit = ref.watch(canProvider(Permission.changeStock));
    return Wrap(
      spacing: AppSpace.gap10,
      runSpacing: AppSpace.gap10,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedPills<PurchasesTab>(
          semanticLabel: 'Purchases view',
          options: [for (final t in PurchasesTab.values) PillOption(t, t.label)],
          selected: tab,
          onChanged: (t) => ref.read(purchasesTabStateProvider.notifier).set(t),
        ),
        Wrap(
          spacing: AppSpace.gap10,
          runSpacing: AppSpace.gap10,
          children: [
            AppButton.secondary(
              key: const ValueKey('receive-invoice'),
              label: 'Receive invoice',
              icon: Icons.move_to_inbox_rounded,
              onPressed: canEdit ? () => showReceiveInvoiceDialog(context) : null,
            ),
            AppButton(
              key: const ValueKey('new-order'),
              label: 'New order',
              icon: Icons.add_rounded,
              onPressed: canEdit ? () => showNewOrderDialog(context) : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// Search field with a short debounce.
class _SearchBox extends StatefulWidget {
  const _SearchBox({required this.fieldKey, required this.hint, required this.value, required this.onSearch});

  final Key fieldKey;
  final String hint;
  final String value;
  final ValueChanged<String> onSearch;

  @override
  State<_SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<_SearchBox> {
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 380),
      child: AppTextField(
        fieldKey: widget.fieldKey,
        label: '',
        hint: widget.hint,
        prefixIcon: Icons.search_rounded,
        value: widget.value,
        onChanged: (v) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 150), () => widget.onSearch(v));
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pending

class _PendingTab extends ConsumerWidget {
  const _PendingTab();

  static const _columns = [
    GridColumn.fixed('', 44),
    GridColumn.fixed('Ordered on', 104),
    GridColumn('Item', flex: 2.4, minWidth: 200),
    GridColumn.fixed('Ordered', 90),
    GridColumn.fixed('Received', 130),
    GridColumn.fixed('Status', 116),
    GridColumn.fixed('Action', 190, alignEnd: true),
  ];

  Future<void> _receive(BuildContext context, WidgetRef ref, List<int> ids) async {
    final rows = await ref.read(purchasesRepositoryProvider).orderRows(ids);
    if (!context.mounted) return;
    await showReceiveInvoiceDialog(context, orders: [for (final r in rows) if (r.status.isOpen) r]);
  }

  Future<void> _close(BuildContext context, WidgetRef ref, OrderRow r) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Close ${r.itemName} short?',
      message: '${r.receivedLabel} of ${qtyLabel(r.qty, r.unit)} came in. Closing means the rest isn’t coming; '
          'the line leaves the Pending list. This can’t be undone.',
      confirmLabel: 'Close short',
    );
    if (!ok) return;
    try {
      await ref.read(guardedActionsProvider).closeOrderLineShort(r.id);
      ref.read(toastsProvider.notifier).show('${r.itemName} closed short');
    } on Object catch (e) {
      _toastError(ref, e);
    }
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref, OrderRow r) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Cancel ${r.itemName}?',
      message: 'Nothing has been received for this line. It stays in the order book as Cancelled. This can’t be undone.',
      confirmLabel: 'Cancel line',
      cancelLabel: 'Keep',
      tone: ConfirmTone.danger,
    );
    if (!ok) return;
    try {
      await ref.read(guardedActionsProvider).cancelOrderLine(r.id);
      ref.read(toastsProvider.notifier).show('${r.itemName} cancelled');
    } on Object catch (e) {
      _toastError(ref, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(openListControllerProvider);
    final ctl = ref.read(openListControllerProvider.notifier);
    final pageAsync = ref.watch(openOrderPageProvider);
    final page = pageAsync.value;
    final rows = page?.rows ?? const <OrderRow>[];
    final selected = ref.watch(selectedOrderLinesProvider);
    final canEdit = ref.watch(canProvider(Permission.changeStock));
    final sources = ref.watch(pendingSourcesProvider).value ?? const <int, SourceRow>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpace.gap10,
          runSpacing: AppSpace.gap10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _SearchBox(fieldKey: const ValueKey('pending-search'), hint: 'Find an item on order…', value: st.search, onSearch: ctl.setSearch),
            if (selected.isNotEmpty) ...[
              AppButton(
                key: const ValueKey('receive-selected'),
                label: 'Receive selected (${selected.length})',
                icon: Icons.move_to_inbox_rounded,
                onPressed: canEdit ? () => _receive(context, ref, selected.toList()..sort()) : null,
              ),
              AppButton.secondary(label: 'Clear', onPressed: ref.read(selectedOrderLinesProvider.notifier).clear),
            ],
          ],
        ),
        const SizedBox(height: AppSpace.gap14),
        AppCard(
          padding: EdgeInsets.zero,
          clip: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (pageAsync.isLoading && page == null) const LinearProgressIndicator(minHeight: 2),
              DataGrid(
                semanticLabel: 'Order lines still due',
                columns: _columns,
                rowCount: rows.length,
                empty: page == null
                    ? const SizedBox(height: 120)
                    : EmptyState(
                        icon: Icons.inventory_outlined,
                        title: st.search.isEmpty ? 'Nothing on order' : 'No open line matches',
                        message: st.search.isEmpty ? 'Everything ordered has come in. Start a New order when you need stock.' : 'Try another name, or clear the search.',
                      ),
                cells: (context, i) => _cells(context, ref, rows[i], selected.contains(rows[i].id), canEdit, sources),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Page ${st.page} · oldest first${page == null ? '' : ' · ${page.ms.toStringAsFixed(1)} ms'}',
                        style: AppType.small.copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                    PagerButton(label: '‹ Previous', semanticLabel: 'Previous page', onTap: st.cursors.isEmpty ? null : ctl.previous),
                    const SizedBox(width: 4),
                    PagerButton(
                      label: 'Next ›',
                      semanticLabel: 'Next page',
                      onTap: page?.hasMore ?? false ? () => ctl.next(PurchaseCursor(rows.last.orderDate, rows.last.id)) : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _cells(BuildContext context, WidgetRef ref, OrderRow r, bool selected, bool canEdit, Map<int, SourceRow> sources) {
    return [
      Tooltip(
        message: selected ? 'Unselect' : 'Select to receive together',
        child: Checkbox(
          key: ValueKey('select-${r.id}'),
          value: selected,
          semanticLabel: 'Select ${r.itemName}',
          onChanged: (_) => ref.read(selectedOrderLinesProvider.notifier).toggle(r.id),
        ),
      ),
      Text(dayLabel(r.orderDate), style: AppType.small.copyWith(color: AppColors.body)),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Flexible(child: Text(r.itemName, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis)),
              if (r.productId == null) ...[const SizedBox(width: 6), const StatusBadge.tag('Free text')],
            ],
          ),
          if (r.note.isNotEmpty) Text(r.note, style: AppType.caption, overflow: TextOverflow.ellipsis),
          if (r.productId != null && sources[r.productId] != null)
            Text(
              'Get from ${sources[r.productId]!.supplierName}${sources[r.productId]!.phone.isEmpty ? '' : ' · ${sources[r.productId]!.phone}'}',
              key: ValueKey('get-from-${r.id}'),
              style: AppType.caption.copyWith(color: StatusTone.info.colors.fg),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
      Text(qtyLabel(r.qty, r.unit), style: AppType.bodyStrong),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(r.receivedLabel.isEmpty ? '—' : r.receivedLabel, style: AppType.small.copyWith(color: AppColors.body), overflow: TextOverflow.ellipsis),
          if (r.receivedSameUnit > 0) Text('${r.due} due', style: AppType.caption.copyWith(color: StatusTone.warning.colors.fg)),
        ],
      ),
      StatusBadge(r.status.label, tone: _statusTone(r.status)),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          AppButton.secondary(
            key: ValueKey('receive-line-${r.id}'),
            label: 'Receive',
            height: 36,
            onPressed: canEdit ? () => _receive(context, ref, [r.id]) : null,
          ),
          if (r.status == OrderStatus.part)
            IconButton(
              key: ValueKey('close-line-${r.id}'),
              tooltip: 'Close short — the rest isn’t coming',
              onPressed: canEdit ? () => _close(context, ref, r) : null,
              icon: const Icon(Icons.task_alt_rounded, size: 20),
            )
          else
            IconButton(
              key: ValueKey('cancel-line-${r.id}'),
              tooltip: 'Cancel this line',
              onPressed: canEdit ? () => _cancel(context, ref, r) : null,
              icon: const Icon(Icons.block_rounded, size: 20),
            ),
        ],
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// Order book

class _BookTab extends ConsumerStatefulWidget {
  const _BookTab();

  @override
  ConsumerState<_BookTab> createState() => _BookTabState();
}

class _BookTabState extends ConsumerState<_BookTab> {
  bool _exporting = false;

  static const _columns = [
    GridColumn.fixed('S/N', 44),
    GridColumn('Name of item', flex: 2, minWidth: 200),
    GridColumn.fixed('Quantity', 90),
    GridColumn('Supplied by', flex: 1.6, minWidth: 200),
    GridColumn.fixed('Qty received', 112),
    GridColumn.fixed('Amount', 104, alignEnd: true),
    GridColumn.fixed('Status', 104),
  ];

  Future<void> _jump(bool forward) async {
    final day = ref.read(bookDayKeyProvider);
    final next = await ref.read(purchasesRepositoryProvider).adjacentDay(day, forward: forward);
    if (next == null) {
      ref.read(toastsProvider.notifier).show(forward ? 'No later orders' : 'No earlier orders');
      return;
    }
    ref.read(bookDayProvider.notifier).set(next);
  }

  Future<void> _export({required bool month}) async {
    setState(() => _exporting = true);
    try {
      final day = ref.read(bookDayKeyProvider);
      final from = month ? '${day.substring(0, 7)}-01' : day;
      final to = month ? '${day.substring(0, 7)}-31' : day;
      final rows = await ref.read(purchasesRepositoryProvider).book(from, to);
      final sheets = bookSheets(rows, storeName: ref.read(settingsProvider).name);
      if (sheets.isEmpty) {
        ref.read(toastsProvider.notifier).show('Nothing to export for ${month ? 'this month' : 'this day'}');
        return;
      }
      final d = parseDateKey(day);
      final name = month ? 'order-book-${monthName(d.month).toLowerCase()}-${d.year}' : 'order-book-$day';
      String? path;
      try {
        path = await saveBytesAs('$name.xlsx', await buildBookXlsxInIsolate(sheets));
      } on Object {
        path = await saveTextAs('$name.csv', bookCsv(sheets)); // CSV fallback
      }
      if (path != null) {
        ref.read(toastsProvider.notifier).show(
              '${path.split(RegExp(r'[/\\]')).last} saved · ${sheets.length} ${sheets.length == 1 ? 'day' : 'days'} · ${formatCount(rows.length)} lines',
            );
      }
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('Export failed: $e', warn: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final day = ref.watch(bookDayKeyProvider);
    final today = dateKey(ref.watch(nowProvider)());
    final async = ref.watch(bookRowsProvider);
    final rows = async.value ?? const <BookRow>[];
    final total = rows.map((r) => r.amount).sum();
    final p = context.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.gap10,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(tooltip: 'Previous day with orders', onPressed: () => _jump(false), icon: const Icon(Icons.chevron_left_rounded)),
                AppButton.secondary(
                  key: const ValueKey('book-day'),
                  label: dayLabel(day),
                  icon: Icons.calendar_today_rounded,
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: parseDateKey(day),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) ref.read(bookDayProvider.notifier).set(dateKey(picked));
                  },
                ),
                IconButton(tooltip: 'Next day with orders', onPressed: () => _jump(true), icon: const Icon(Icons.chevron_right_rounded)),
                if (day != today) TextButton(onPressed: () => ref.read(bookDayProvider.notifier).set(today), child: const Text('Today')),
              ],
            ),
            Wrap(
              spacing: AppSpace.gap10,
              children: [
                AppButton.secondary(
                  key: const ValueKey('export-day'),
                  label: _exporting ? 'Exporting…' : 'Export day',
                  icon: Icons.download_rounded,
                  onPressed: _exporting ? null : () => _export(month: false),
                ),
                AppButton.secondary(
                  key: const ValueKey('export-month'),
                  label: 'Export ${monthName(parseDateKey(day).month)}',
                  icon: Icons.table_view_rounded,
                  onPressed: _exporting ? null : () => _export(month: true),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: AppSpace.gap14),
        AppCard(
          padding: EdgeInsets.zero,
          clip: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (async.isLoading && async.value == null) const LinearProgressIndicator(minHeight: 2),
              DataGrid(
                semanticLabel: 'Order book for ${dayLabel(day)}',
                columns: _columns,
                rowCount: rows.length,
                empty: async.value == null
                    ? const SizedBox(height: 120)
                    : const EmptyState(
                        icon: Icons.event_note_outlined,
                        title: 'No orders this day',
                        message: 'Use ‹ › to jump to a day with orders, or start a New order.',
                      ),
                cells: (context, i) => _cells(i, rows[i]),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(child: Text('${rows.length} ${rows.length == 1 ? 'line' : 'lines'}', style: AppType.small.copyWith(color: AppColors.textSecondary))),
                    Text('Total ', style: AppType.bodyStrong),
                    Text(
                      formatInr(total),
                      key: const ValueKey('book-total'),
                      style: AppType.cardTitle.copyWith(color: p.accent, fontFeatures: AppType.tabular),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _cells(int i, BookRow r) {
    final received = r.receivedDate;
    final supplied = [
      if (r.invoiceNo.isNotEmpty) 'Inv ${r.invoiceNo}',
      if (received != null && received.isNotEmpty) dayLabel(received),
    ].join(' · ');
    return [
      Text('${i + 1}', style: AppType.small.copyWith(color: AppColors.textSecondary)),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(r.item, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis),
          if (r.order?.note case final n? when n.isNotEmpty) Text(n, style: AppType.caption, overflow: TextOverflow.ellipsis),
        ],
      ),
      Text(r.orderedLabel.isEmpty ? '—' : r.orderedLabel, style: AppType.small.copyWith(color: AppColors.body)),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(r.stockist.isEmpty ? '—' : r.stockist, style: AppType.small.copyWith(color: AppColors.body), overflow: TextOverflow.ellipsis),
          if (supplied.isNotEmpty) Text(supplied, style: AppType.caption, overflow: TextOverflow.ellipsis),
        ],
      ),
      Text(r.receivedLabel.isEmpty ? '—' : r.receivedLabel, style: AppType.smallStrong),
      Text(r.amount.value == 0 ? '—' : formatInr(r.amount), style: AppType.bodyStrong.copyWith(fontFeatures: AppType.tabular)),
      if (r.tag == SupplyTag.none) const SizedBox.shrink() else StatusBadge.tag(r.tag.label, tone: _tagTone(r.tag)),
    ];
  }
}

// ---------------------------------------------------------------------------
// Receipts

class _ReceiptsTab extends ConsumerWidget {
  const _ReceiptsTab();

  static const _columns = [
    GridColumn.fixed('', 44),
    GridColumn.fixed('Received', 116),
    GridColumn('Stockist', flex: 1.6, minWidth: 160),
    GridColumn('Invoice no', flex: 1.2, minWidth: 130),
    GridColumn.fixed('Bill total', 116, alignEnd: true),
    GridColumn.fixed('Due', 104),
    GridColumn.fixed('Outstanding', 116, alignEnd: true),
    GridColumn.fixed('Status', 104),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(receiptListControllerProvider);
    final ctl = ref.read(receiptListControllerProvider.notifier);
    final async = ref.watch(receiptPageProvider);
    final page = async.value;
    final rows = page?.rows ?? const <ReceiptRow>[];
    final open = ref.watch(expandedReceiptProvider);
    final today = dateKey(ref.watch(nowProvider)());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: _SearchBox(fieldKey: const ValueKey('receipt-search'), hint: 'Stockist or invoice no…', value: st.search, onSearch: ctl.setSearch),
        ),
        const SizedBox(height: AppSpace.gap14),
        AppCard(
          padding: EdgeInsets.zero,
          clip: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (async.isLoading && page == null) const LinearProgressIndicator(minHeight: 2),
              DataGrid(
                semanticLabel: 'Stockist invoices',
                columns: _columns,
                rowCount: rows.length,
                empty: page == null
                    ? const SizedBox(height: 120)
                    : const EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: 'No stockist invoices',
                        message: 'Invoices appear here once you receive them.',
                      ),
                onRowTap: (i) => ref.read(expandedReceiptProvider.notifier).toggle(rows[i].id),
                belowRow: (context, i) => open == rows[i].id ? _ReceiptLines(receiptId: rows[i].id) : null,
                cells: (context, i) {
                  final r = rows[i];
                  return [
                    AnimatedRotation(
                      turns: open == r.id ? 0.25 : 0,
                      duration: context.motion(AppMotion.chevron),
                      child: Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.label, semanticLabel: open == r.id ? 'Hide lines' : 'Show lines'),
                    ),
                    Text(dayLabel(r.receivedDate), style: AppType.small.copyWith(color: AppColors.body)),
                    Text(r.supplier, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(r.invoiceNo, style: AppType.mono, overflow: TextOverflow.ellipsis),
                        Text('${r.lines} ${r.lines == 1 ? 'line' : 'lines'}', style: AppType.caption),
                      ],
                    ),
                    Text(formatInr(r.billTotal), style: AppType.bodyStrong.copyWith(fontFeatures: AppType.tabular)),
                    Text(
                      r.dueDate.isEmpty ? '—' : dayLabel(r.dueDate),
                      style: AppType.small.copyWith(color: r.overdueOn(today) ? StatusTone.danger.colors.fg : AppColors.body),
                    ),
                    Text(r.outstanding.value == 0 ? '—' : formatInr(r.outstanding), style: AppType.small.copyWith(fontFeatures: AppType.tabular)),
                    if (r.billTotal.value == 0)
                      const SizedBox.shrink()
                    else
                      StatusBadge.tag(
                        r.overdueOn(today) ? 'Overdue' : r.status.label,
                        tone: _billTone(r.status, overdue: r.overdueOn(today)),
                      ),
                  ];
                },
              ),
              const Divider(),
              KeysetPager(
                label: 'Page ${st.page} · newest first',
                onNewer: st.cursors.isEmpty ? null : ctl.newer,
                onOlder: page?.hasMore ?? false ? () => ctl.older(PurchaseCursor(rows.last.receivedDate, rows.last.id)) : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReceiptLines extends ConsumerWidget {
  const _ReceiptLines({required this.receiptId});

  final int receiptId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(receiptLinesProvider(receiptId)).value;
    Widget head(String t, {bool end = false}) =>
        Text(t, textAlign: end ? TextAlign.right : TextAlign.left, style: AppType.overline.copyWith(letterSpacing: 0.4));
    return Container(
      color: AppColors.surfaceAlt,
      padding: const EdgeInsets.fromLTRB(70, 4, 16, 14),
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
                  Expanded(child: head('ITEM')),
                  SizedBox(width: 100, child: head('BATCH')),
                  SizedBox(width: 84, child: head('EXPIRY')),
                  SizedBox(width: 90, child: head('QTY', end: true)),
                  SizedBox(width: 90, child: head('STOCK +', end: true)),
                  SizedBox(width: 100, child: head('AMOUNT', end: true)),
                ],
              ),
            ),
            if (lines == null)
              const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator(minHeight: 2))
            else
              for (final l in lines)
                Container(
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.divider))),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  child: Row(
                    children: [
                      Expanded(child: Text(l.itemName, style: AppType.small, overflow: TextOverflow.ellipsis)),
                      SizedBox(width: 100, child: Text(l.batchNo, style: AppType.mono)),
                      SizedBox(width: 84, child: Text(formatExpiry(l.expiry), style: AppType.small)),
                      SizedBox(
                        width: 90,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(qtyLabel(l.qty, l.unit), textAlign: TextAlign.right, style: AppType.small),
                            // The stockist's box size on this invoice (v16).
                            if (l.packsPerBox case final n?) Text('$n per box', key: ValueKey('receipt-perbox-${l.id}'), style: AppType.caption),
                          ],
                        ),
                      ),
                      SizedBox(width: 90, child: Text(formatCount(l.stockUnits), textAlign: TextAlign.right, style: AppType.smallStrong)),
                      SizedBox(
                        width: 100,
                        child: Text(formatInr(Paise(l.amountPaise)), textAlign: TextAlign.right, style: AppType.small.copyWith(fontFeatures: AppType.tabular)),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dues (SPEC §4.8)

class _DuesTab extends ConsumerWidget {
  const _DuesTab();

  static const _columns = [
    GridColumn('Stockist', flex: 2, minWidth: 200),
    GridColumn.fixed('Credit', 80),
    GridColumn.fixed('Open bills', 90, alignEnd: true),
    GridColumn.fixed('Owed', 120, alignEnd: true),
    GridColumn.fixed('Overdue', 120, alignEnd: true),
    GridColumn.fixed('Oldest due', 110),
    GridColumn.fixed('Action', 240, alignEnd: true),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(duesListControllerProvider);
    final ctl = ref.read(duesListControllerProvider.notifier);
    final async = ref.watch(duesPageProvider);
    final page = async.value;
    final rows = page?.rows ?? const <SupplierDues>[];
    final today = dateKey(ref.watch(nowProvider)());
    final canPay = ref.watch(canProvider(Permission.supplierPayments));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: _SearchBox(fieldKey: const ValueKey('dues-search'), hint: 'Find a stockist…', value: st.search, onSearch: ctl.setSearch),
        ),
        const SizedBox(height: AppSpace.gap14),
        AppCard(
          padding: EdgeInsets.zero,
          clip: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (async.isLoading && page == null) const LinearProgressIndicator(minHeight: 2),
              DataGrid(
                semanticLabel: 'Stockist dues',
                columns: _columns,
                rowCount: rows.length,
                empty: page == null
                    ? const SizedBox(height: 120)
                    : const EmptyState(
                        icon: Icons.account_balance_wallet_outlined,
                        title: 'No stockists yet',
                        message: 'Stockists appear here once you receive their first invoice.',
                      ),
                onRowTap: (i) => showStatementDialog(context, supplierId: rows[i].supplierId),
                cells: (context, i) {
                  final d = rows[i];
                  final overdue = d.overdue.value > 0;
                  return [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(d.name, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis),
                        if (d.advance.value > 0)
                          Text('${formatInr(d.advance)} on account', style: AppType.caption.copyWith(color: StatusTone.info.colors.fg)),
                      ],
                    ),
                    Text('${d.creditDays} days', style: AppType.small.copyWith(color: AppColors.body)),
                    Text(formatCount(d.openBills), style: AppType.small),
                    Text(formatInr(d.balance), style: AppType.bodyStrong.copyWith(fontFeatures: AppType.tabular)),
                    Text(
                      overdue ? formatInr(d.overdue) : '—',
                      style: AppType.smallStrong.copyWith(fontFeatures: AppType.tabular, color: overdue ? StatusTone.danger.colors.fg : AppColors.textMuted),
                    ),
                    Text(
                      d.oldestDue == null ? '—' : dayLabel(d.oldestDue!),
                      style: AppType.small.copyWith(color: overdue ? StatusTone.danger.colors.fg : AppColors.body),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        AppButton.secondary(
                          key: ValueKey('pay-${d.supplierId}'),
                          label: 'Pay',
                          height: 36,
                          onPressed: canPay ? () => showPaymentDialog(context, supplierId: d.supplierId) : null,
                        ),
                        const SizedBox(width: AppSpace.sm),
                        AppButton.secondary(
                          key: ValueKey('statement-${d.supplierId}'),
                          label: 'Statement',
                          height: 36,
                          onPressed: () => showStatementDialog(context, supplierId: d.supplierId),
                        ),
                      ],
                    ),
                  ];
                },
              ),
              const Divider(),
              Pager(
                page: st.page,
                pageSize: st.pageSize,
                totalRows: page?.total ?? 0,
                onPage: ctl.setPage,
                onPageSize: ctl.setPageSize,
                trailingNote: page == null ? null : 'as of ${dayLabel(today)}',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
