import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/dues_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/db/models.dart';
import '../../../core/money/paise.dart';
import '../../../core/purchases/dues_rules.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/pack.dart';
import '../../../core/utils/save_file.dart';
import '../../../core/widgets/widgets.dart';
import '../../inventory/application/inventory_providers.dart';
import '../../sales_register/application/register_export.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/guarded_actions.dart';
import '../../staff/application/session.dart';
import '../application/purchases_providers.dart';
import '../data/purchases_repository.dart';
import 'purchase_dialogs.dart';

Future<void> showPaymentDialog(BuildContext context, {required int supplierId, Set<int> pickedBills = const {}}) => showAppDialog<void>(
  context,
  maxWidth: 720,
  topPadding: 40,
  builder: (_) => PaymentDialog(supplierId: supplierId, initialPicked: pickedBills),
);

Future<void> showReturnDialog(BuildContext context, {required int supplierId}) =>
    showAppDialog<void>(context, maxWidth: 760, topPadding: 40, builder: (_) => ReturnDialog(supplierId: supplierId));

Future<void> showStatementDialog(BuildContext context, {required int supplierId}) =>
    showAppDialog<void>(context, maxWidth: 1000, topPadding: 32, builder: (_) => StatementDialog(supplierId: supplierId));

final _money = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];
const _moneyKb = TextInputType.numberWithOptions(decimal: true);

String _today(WidgetRef ref) => dateKey(ref.read(nowProvider)());

// ---------------------------------------------------------------------------
// Record payment

class PaymentDialog extends ConsumerStatefulWidget {
  const PaymentDialog({super.key, required this.supplierId, this.initialPicked = const {}});

  final int supplierId;
  final Set<int> initialPicked;

  @override
  ConsumerState<PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends ConsumerState<PaymentDialog> {
  late String date = _today(ref);
  String amount = '', mode = 'Cash', reference = '', note = '';
  late Set<int> picked = {...widget.initialPicked};
  String? error;
  bool saving = false;

  Future<void> _save() async {
    final a = Paise.tryParse(amount);
    if (a == null || a.value <= 0) {
      setState(() => error = 'Enter the amount paid');
      return;
    }
    setState(() {
      error = null;
      saving = true;
    });
    try {
      await ref
          .read(guardedActionsProvider)
          .recordSupplierPayment(
            supplierId: widget.supplierId,
            date: date,
            payment: PaymentInput(amount: a, mode: mode, reference: reference, note: note),
            pickedBillIds: picked.isEmpty ? null : picked,
          );
      ref.read(toastsProvider.notifier).show('${formatInr(a)} paid by $mode');
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      toastPurchaseError(ref, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = ref.watch(supplierDuesProvider(widget.supplierId)).value;
    final bills = ref.watch(openBillsProvider(widget.supplierId)).value ?? const <OpenBill>[];
    final today = dateKey(ref.watch(nowProvider)());
    final a = Paise.tryParse(amount) ?? Paise.zero;
    final (allocs, left) = allocate(0, a.value, [
      for (final b in bills) OpenDebit(id: b.ledgerId, dueDate: b.dueDate, outstanding: b.outstanding.value),
    ], picked: picked.isEmpty ? null : picked);
    final byBill = {for (final x in allocs) x.debitId: x.amount};

    return AppDialogPanel(
      semanticLabel: 'Record payment',
      children: [
        PurchaseDialogHeader(
          title: 'Record payment',
          subtitle: d == null ? null : '${d.name} · owed ${formatInr(d.balance)}${d.overdue.value > 0 ? ' · ${formatInr(d.overdue)} overdue' : ''}',
        ),
        FieldGrid(
          minColumnWidth: 200,
          children: [
            PurchaseDateField(fieldKey: const ValueKey('pay-date'), label: 'Paid on', value: date, onChanged: (v) => setState(() => date = v)),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                AppTextField(
                  fieldKey: const ValueKey('pay-amount'),
                  label: 'Amount (₹)',
                  hint: '0.00',
                  value: amount,
                  error: error,
                  autofocus: true,
                  keyboardType: _moneyKb,
                  inputFormatters: _money,
                  onChanged: (v) => setState(() => amount = v),
                ),
                if (d != null && d.balance.value > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const ValueKey('pay-all'),
                      onPressed: () => setState(() => amount = d.balance.toInputString()),
                      child: Text('Pay all ${formatInr(d.balance)}'),
                    ),
                  ),
              ],
            ),
            FieldSpan(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Paid by', style: AppType.label),
                  const SizedBox(height: 6),
                  SegmentedPills<String>(
                    semanticLabel: 'Paid by',
                    options: [for (final m in paymentModes) PillOption(m, m)],
                    selected: mode,
                    onChanged: (v) => setState(() => mode = v),
                  ),
                ],
              ),
            ),
            AppTextField(label: 'Reference', hint: 'Cheque no / UTR', value: reference, onChanged: (v) => setState(() => reference = v)),
            FieldSpan(
              child: AppTextField(label: 'Note', hint: 'Optional', value: note, onChanged: (v) => setState(() => note = v)),
            ),
          ],
        ),
        Text(picked.isEmpty ? 'Applied to the oldest bills first. Tick bills to pay only those.' : 'Paying only the ticked bills.', style: AppType.caption),
        if (bills.isEmpty)
          const EmptyState(title: 'No open bills', message: 'The whole amount will be kept on account.')
        else
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: const BorderRadius.all(Radius.circular(12)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (i, b) in bills.indexed)
                  Container(
                    decoration: BoxDecoration(
                      border: i == 0 ? null : const Border(top: BorderSide(color: AppColors.divider)),
                    ),
                    padding: const EdgeInsets.only(right: 14),
                    child: Row(
                      children: [
                        Checkbox(
                          key: ValueKey('pay-bill-${b.ledgerId}'),
                          value: picked.contains(b.ledgerId),
                          semanticLabel: 'Pay ${b.reference}',
                          onChanged: (_) => setState(() => picked.contains(b.ledgerId) ? picked.remove(b.ledgerId) : picked.add(b.ledgerId)),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                b.kind == LedgerKind.opening ? 'Opening balance' : 'Inv ${b.reference}',
                                style: AppType.bodyStrong,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '${dayLabel(b.date)} · due ${dayLabel(b.dueDate)}${b.overdueOn(today) ? ' · ${daysOverdue(b.dueDate, today)} days overdue' : ''}',
                                style: AppType.caption.copyWith(color: b.overdueOn(today) ? StatusTone.danger.colors.fg : null),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 120,
                          child: Text(
                            formatInr(b.outstanding),
                            textAlign: TextAlign.right,
                            style: AppType.smallStrong.copyWith(fontFeatures: AppType.tabular),
                          ),
                        ),
                        SizedBox(
                          width: 140,
                          child: Text(
                            byBill[b.ledgerId] == null
                                ? ''
                                : byBill[b.ledgerId] == b.outstanding.value
                                ? '→ clears'
                                : '→ ${formatInr(Paise(byBill[b.ledgerId]!))}',
                            textAlign: TextAlign.right,
                            style: AppType.caption.copyWith(color: StatusTone.success.colors.fg),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        if (left > 0)
          Text(
            '${formatInr(Paise(left))} stays on account (advance) and goes to the next bill.',
            key: const ValueKey('pay-left'),
            style: AppType.smallStrong.copyWith(color: StatusTone.info.colors.fg),
          ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(key: const ValueKey('pay-save'), label: saving ? 'Saving…' : 'Record payment', onPressed: saving ? null : _save),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Return / credit note

class _ReturnDraft {
  _ReturnDraft(this.product);
  final int key = _next++;
  static int _next = 0;
  final StockRow product;
  int? batchId;
  String qty = '';
}

class ReturnDialog extends ConsumerStatefulWidget {
  const ReturnDialog({super.key, required this.supplierId});

  final int supplierId;

  @override
  ConsumerState<ReturnDialog> createState() => _ReturnDialogState();
}

class _ReturnDialogState extends ConsumerState<ReturnDialog> {
  bool stock = true;
  late String date = _today(ref);
  String amount = '', reference = '', note = '';
  final List<_ReturnDraft> lines = [];
  Map<String, String> errors = const {};
  bool saving = false;

  Future<void> _save() async {
    final a = Paise.tryParse(amount);
    final e = <String, String>{
      if (a == null || a.value <= 0) 'amount': 'Credit amount',
      if (reference.trim().isEmpty) 'ref': 'Their credit note no.',
      if (stock)
        for (final l in lines) ...{if (l.batchId == null) '${l.key}-batch': 'Pick a batch', if ((int.tryParse(l.qty) ?? 0) < 1) '${l.key}-qty': 'Qty'},
    };
    setState(() => errors = e);
    if (stock && lines.isEmpty) {
      ref.read(toastsProvider.notifier).show('Add the medicines being returned', warn: true);
      return;
    }
    if (e.isNotEmpty) return;
    setState(() => saving = true);
    try {
      final g = ref.read(guardedActionsProvider);
      if (stock) {
        await g.recordSupplierReturn(
          supplierId: widget.supplierId,
          date: date,
          amount: a!,
          reference: reference,
          note: note,
          lines: [for (final l in lines) ReturnLineInput(productId: l.product.id, batchId: l.batchId!, qty: int.parse(l.qty))],
        );
        final units = lines.fold<int>(0, (s, l) => s + int.parse(l.qty));
        ref.read(toastsProvider.notifier).show('Return saved · −${formatCount(units)} units · ${formatInr(a)} credit');
      } else {
        await g.recordCreditNote(supplierId: widget.supplierId, date: date, amount: a!, reference: reference, note: note);
        ref.read(toastsProvider.notifier).show('Credit note ${reference.trim()} · ${formatInr(a)}');
      }
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      toastPurchaseError(ref, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = ref.watch(supplierDuesProvider(widget.supplierId)).value;
    final now = ref.watch(nowProvider)();
    return AppDialogPanel(
      semanticLabel: 'Return or credit note',
      children: [
        PurchaseDialogHeader(title: 'Return / credit note', subtitle: d?.name),
        SegmentedPills<bool>(
          semanticLabel: 'Kind',
          options: const [PillOption(true, 'Return stock'), PillOption(false, 'Credit note only')],
          selected: stock,
          onChanged: (v) => setState(() => stock = v),
        ),
        Text(
          stock
              ? 'Stock leaves inventory now; the credit lowers what you owe. Expired batches can be returned.'
              : 'A credit from the stockist with no stock going back (rate difference, scheme, damage claim).',
          style: AppType.caption,
        ),
        FieldGrid(
          minColumnWidth: 200,
          children: [
            PurchaseDateField(label: 'Date', value: date, onChanged: (v) => setState(() => date = v)),
            AppTextField(
              fieldKey: const ValueKey('ret-ref'),
              label: 'Credit note no.',
              hint: 'As on their note',
              value: reference,
              error: errors['ref'],
              onChanged: (v) => setState(() => reference = v),
            ),
            AppTextField(
              fieldKey: const ValueKey('ret-amount'),
              label: 'Credit amount (₹)',
              hint: '0.00',
              value: amount,
              error: errors['amount'],
              keyboardType: _moneyKb,
              inputFormatters: _money,
              onChanged: (v) => setState(() => amount = v),
            ),
            AppTextField(label: 'Note', hint: 'Optional', value: note, onChanged: (v) => setState(() => note = v)),
          ],
        ),
        if (stock) ...[
          for (final (i, l) in lines.indexed)
            _ReturnLineRow(index: i, line: l, errors: errors, now: now, onChanged: () => setState(() {}), onRemove: () => setState(() => lines.remove(l))),
          ProductPicker(fieldKey: const ValueKey('ret-add'), label: 'Add medicine to return', onPicked: (p) => setState(() => lines.add(_ReturnDraft(p)))),
        ],
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(
              key: const ValueKey('ret-save'),
              label: saving ? 'Saving…' : (stock ? 'Save return' : 'Save credit note'),
              onPressed: saving ? null : _save,
            ),
          ],
        ),
      ],
    );
  }
}

class _ReturnLineRow extends ConsumerWidget {
  const _ReturnLineRow({required this.index, required this.line, required this.errors, required this.now, required this.onChanged, required this.onRemove});

  final int index;
  final _ReturnDraft line;
  final Map<String, String> errors;
  final DateTime now;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batches = [
      for (final b in ref.watch(productBatchesProvider(line.product.id)).value ?? const <StockBatch>[])
        if (b.qty > 0) b,
    ];
    final chosen = batches.where((b) => b.id == line.batchId).firstOrNull;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(line.product.name, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                tooltip: 'Remove ${line.product.name}',
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.textMuted),
              ),
            ],
          ),
          if (batches.isEmpty)
            Text('No batch of this medicine has stock to return.', style: AppType.caption.copyWith(color: StatusTone.warning.colors.fg))
          else
            FieldGrid(
              minColumnWidth: 200,
              children: [
                AppDropdown<int?>(
                  label: 'Batch',
                  labelAbove: true,
                  value: line.batchId,
                  semanticLabel: 'Batch',
                  options: [
                    const DropdownOption(null, 'Pick a batch'),
                    for (final b in batches)
                      DropdownOption(
                        b.id,
                        '${b.batchNo} · exp ${formatExpiry(b.expiry)}${isExpired(b.expiry, now) ? ' (expired)' : ''} · '
                        '${formatPackQty(b.qty, line.product.packSize, line.product.category)} in stock',
                      ),
                  ],
                  onChanged: (v) {
                    line.batchId = v;
                    onChanged();
                  },
                ),
                AppTextField(
                  fieldKey: ValueKey('ret-qty-$index'),
                  label: line.product.sellsLoose
                      ? (chosen == null
                          ? 'Qty (${PackNouns.of(line.product.category).units})'
                          : 'Qty in ${PackNouns.of(line.product.category).units} (max ${chosen.qty})')
                      : (chosen == null ? 'Qty' : 'Qty (max ${chosen.qty})'),
                  hint: '0',
                  value: line.qty,
                  error: errors['${line.key}-qty'] ?? errors['${line.key}-batch'],
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (v) {
                    line.qty = v;
                    onChanged();
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Statement

class StatementDialog extends ConsumerStatefulWidget {
  const StatementDialog({super.key, required this.supplierId});

  final int supplierId;

  @override
  ConsumerState<StatementDialog> createState() => _StatementDialogState();
}

class _StatementDialogState extends ConsumerState<StatementDialog> {
  final List<StatementCursor> cursors = [];
  bool exporting = false;

  static const _columns = [
    GridColumn.fixed('Date', 104),
    GridColumn.fixed('Type', 110),
    GridColumn('Reference', flex: 1.4, minWidth: 150),
    GridColumn.fixed('Due', 104),
    GridColumn.fixed('Debit', 110, alignEnd: true),
    GridColumn.fixed('Credit', 110, alignEnd: true),
    GridColumn.fixed('Balance', 120, alignEnd: true),
    GridColumn.fixed('', 52, alignEnd: true),
  ];

  Future<void> _void(StatementRow r) async {
    final reason = await showAppDialog<String>(context, builder: (_) => _VoidDialog(row: r));
    if (reason == null) return;
    try {
      await ref.read(guardedActionsProvider).voidLedgerEntry(r.id, reason: reason);
      ref.read(toastsProvider.notifier).show('${r.kind.label} ${formatInr(r.amount)} voided');
    } on Object catch (e) {
      toastPurchaseError(ref, e);
    }
  }

  Future<void> _export(SupplierDues d) async {
    setState(() => exporting = true);
    try {
      final repo = ref.read(purchasesRepositoryProvider);
      final rows = <StatementRow>[];
      StatementCursor? after;
      while (true) {
        final p = await repo.statement(widget.supplierId, after: after, limit: 500);
        rows.addAll(p.rows);
        if (!p.hasMore) break;
        after = StatementCursor(p.rows.last.date, p.rows.last.id);
      }
      final now = ref.read(nowProvider)();
      double r(Paise p) => p.value / 100; // export display only
      final table = ExportTable(
        title: 'Stockist statement',
        headerBlock: [
          ref.read(settingsProvider).name,
          'Statement — ${d.name}${d.gstin.isEmpty ? '' : ' (GSTIN ${d.gstin})'}',
          'Credit terms ${d.creditDays} days',
          'Generated ${formatDate(now)} ${formatTime(now)}',
        ],
        columns: const ['Date', 'Type', 'Reference', 'Due', 'Debit ₹', 'Credit ₹', 'Balance ₹', 'Note'],
        rows: [
          for (final x in rows)
            [
              x.date,
              x.kind.label,
              [x.reference, if (x.mode != null) x.mode!].where((s) => s.isNotEmpty).join(' · '),
              x.dueDate ?? '',
              x.debit.value == 0 ? '' : r(x.debit),
              x.credit.value == 0 ? '' : r(x.credit),
              r(x.balance),
              x.active ? x.note : 'VOID: ${x.voidReason ?? ''}',
            ],
        ],
        totals: ['Balance', '', '', '', '', '', r(d.balance), ''],
      );
      final name = 'statement-${d.name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-')}-${dateKey(now)}';
      String? path;
      try {
        path = await saveBytesAs('$name.xlsx', await buildXlsxInIsolate(table, sheetName: 'Statement'));
      } on Object {
        path = await saveTextAs('$name.csv', buildCsv(table));
      }
      if (path != null) ref.read(toastsProvider.notifier).show('${path.split(RegExp(r'[/\\]')).last} saved · ${rows.length} entries');
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('Export failed: $e', warn: true);
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sid = widget.supplierId;
    final d = ref.watch(supplierDuesProvider(sid)).value;
    final c = cursors.isEmpty ? null : cursors.last;
    final page = ref.watch(statementPageProvider((sid, c?.date, c?.id))).value;
    final rows = page?.rows ?? const <StatementRow>[];
    final canPay = ref.watch(canProvider(Permission.supplierPayments));
    final canStock = ref.watch(canProvider(Permission.changeStock));
    final today = dateKey(ref.watch(nowProvider)());

    Widget stat(String label, String value, {StatusTone? tone, Key? key}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppType.caption),
        Text(
          value,
          key: key,
          style: AppType.cardTitle.copyWith(color: tone?.colors.fg, fontFeatures: AppType.tabular),
        ),
      ],
    );

    return AppDialogPanel(
      semanticLabel: 'Stockist statement',
      children: [
        PurchaseDialogHeader(
          title: d?.name ?? 'Statement',
          subtitle: d == null ? null : ['${d.creditDays} days credit', if (d.phone.isNotEmpty) d.phone, if (d.gstin.isNotEmpty) 'GSTIN ${d.gstin}'].join(' · '),
        ),
        if (d != null)
          Wrap(
            spacing: AppSpace.xl,
            runSpacing: AppSpace.md,
            children: [
              stat('Owed', formatInr(d.balance), key: const ValueKey('stmt-balance')),
              stat('Overdue', formatInr(d.overdue), tone: d.overdue.value > 0 ? StatusTone.danger : null),
              if (d.advance.value > 0) stat('On account', formatInr(d.advance), tone: StatusTone.info),
              stat('Open bills', formatCount(d.openBills)),
            ],
          ),
        Wrap(
          spacing: AppSpace.gap10,
          runSpacing: AppSpace.gap10,
          children: [
            AppButton(
              key: const ValueKey('stmt-pay'),
              label: 'Record payment',
              icon: Icons.payments_outlined,
              onPressed: canPay ? () => showPaymentDialog(context, supplierId: sid) : null,
            ),
            AppButton.secondary(
              key: const ValueKey('stmt-return'),
              label: 'Return / credit note',
              icon: Icons.assignment_return_outlined,
              onPressed: canPay ? () => showReturnDialog(context, supplierId: sid) : null,
            ),
            AppButton.secondary(
              label: 'Terms',
              icon: Icons.edit_outlined,
              onPressed: canPay && d != null ? () => showAppDialog<void>(context, builder: (_) => _TermsDialog(dues: d)) : null,
            ),
            if (d != null && !d.hasOpening)
              AppButton.secondary(
                key: const ValueKey('stmt-opening'),
                label: 'Opening balance',
                icon: Icons.history_rounded,
                onPressed: canPay ? () => showAppDialog<void>(context, builder: (_) => _OpeningDialog(supplierId: sid)) : null,
              ),
            AppButton.secondary(
              label: exporting ? 'Exporting…' : 'Export',
              icon: Icons.download_rounded,
              onPressed: exporting || d == null ? null : () => _export(d),
            ),
          ],
        ),
        if (!canStock && canPay) Text('Returning stock also needs “Change stock”.', style: AppType.caption),
        AppCard(
          padding: EdgeInsets.zero,
          clip: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DataGrid(
                semanticLabel: 'Ledger',
                columns: _columns,
                rowCount: rows.length,
                empty: page == null ? const SizedBox(height: 80) : const EmptyState(title: 'No entries yet'),
                cells: (context, i) {
                  final r = rows[i];
                  final dim = r.active ? null : AppColors.textMuted;
                  final overdue = r.active && r.kind.debit && r.dueDate != null && r.dueDate!.compareTo(today) < 0 && d != null && d.overdue.value > 0;
                  return [
                    Text(dayLabel(r.date), style: AppType.small.copyWith(color: dim ?? AppColors.body)),
                    r.active ? Text(r.kind.label, style: AppType.smallStrong) : const StatusBadge.tag('Void', tone: StatusTone.dead),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          [if (!r.active) r.kind.label, r.reference, if (r.mode != null) r.mode!].where((s) => s.isNotEmpty).join(' · '),
                          style: AppType.small.copyWith(color: dim),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (!r.active && r.voidReason != null)
                          Text('Void: ${r.voidReason}', style: AppType.caption, overflow: TextOverflow.ellipsis)
                        else if (r.note.isNotEmpty)
                          Text(r.note, style: AppType.caption, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                    Text(
                      r.dueDate == null || !r.kind.debit ? '' : dayLabel(r.dueDate!),
                      style: AppType.small.copyWith(color: overdue ? StatusTone.danger.colors.fg : AppColors.body),
                    ),
                    Text(r.debit.value == 0 ? '' : formatInr(r.debit), style: AppType.small.copyWith(fontFeatures: AppType.tabular)),
                    Text(
                      r.credit.value == 0 ? '' : formatInr(r.credit),
                      style: AppType.small.copyWith(fontFeatures: AppType.tabular, color: StatusTone.success.colors.fg),
                    ),
                    Text(
                      formatInr(r.balance),
                      style: AppType.smallStrong.copyWith(fontFeatures: AppType.tabular, color: dim),
                    ),
                    if (r.active && r.kind.voidable && canPay)
                      IconButton(
                        key: ValueKey('void-${r.id}'),
                        tooltip: 'Void this ${r.kind.label.toLowerCase()}',
                        onPressed: () => _void(r),
                        icon: const Icon(Icons.block_rounded, size: 18),
                      )
                    else
                      const SizedBox.shrink(),
                  ];
                },
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Page ${cursors.length + 1} · oldest first', style: AppType.small.copyWith(color: AppColors.textSecondary)),
                    ),
                    PagerButton(label: '‹ Earlier', semanticLabel: 'Earlier entries', onTap: cursors.isEmpty ? null : () => setState(cursors.removeLast)),
                    const SizedBox(width: 4),
                    PagerButton(
                      label: 'Later ›',
                      semanticLabel: 'Later entries',
                      onTap: page?.hasMore ?? false ? () => setState(() => cursors.add(StatementCursor(rows.last.date, rows.last.id))) : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: AppButton.secondary(label: 'Close', onPressed: () => Navigator.of(context).pop()),
        ),
      ],
    );
  }
}

class _VoidDialog extends StatefulWidget {
  const _VoidDialog({required this.row});

  final StatementRow row;

  @override
  State<_VoidDialog> createState() => _VoidDialogState();
}

class _VoidDialogState extends State<_VoidDialog> {
  String reason = '';
  String? error;

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    return AppDialogPanel(
      semanticLabel: 'Void entry',
      children: [
        PurchaseDialogHeader(
          title: 'Void ${r.kind.label.toLowerCase()}?',
          subtitle: '${formatInr(r.amount)} on ${dayLabel(r.date)}. It stays in the statement marked void; bills it paid become due again.',
        ),
        AppTextField(
          fieldKey: const ValueKey('void-reason'),
          label: 'Reason',
          hint: 'e.g. Cheque bounced, entered twice',
          value: reason,
          autofocus: true,
          error: error,
          onChanged: (v) => setState(() => reason = v),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Keep', onPressed: () => Navigator.of(context).pop()),
            AppButton(
              key: const ValueKey('void-confirm'),
              label: 'Void',
              variant: AppButtonVariant.danger,
              onPressed: () {
                if (reason.trim().isEmpty) {
                  setState(() => error = 'Give a reason');
                  return;
                }
                Navigator.of(context).pop(reason.trim());
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _TermsDialog extends ConsumerStatefulWidget {
  const _TermsDialog({required this.dues});

  final SupplierDues dues;

  @override
  ConsumerState<_TermsDialog> createState() => _TermsDialogState();
}

class _TermsDialogState extends ConsumerState<_TermsDialog> {
  late String days = '${widget.dues.creditDays}';
  late String phone = widget.dues.phone;
  late String gstin = widget.dues.gstin;

  Future<void> _save() async {
    final n = int.tryParse(days);
    if (n == null) {
      ref.read(toastsProvider.notifier).show('Credit days must be a number', warn: true);
      return;
    }
    try {
      await ref.read(guardedActionsProvider).updateSupplier(widget.dues.supplierId, creditDays: n, phone: phone, gstin: gstin);
      ref.read(toastsProvider.notifier).show('${widget.dues.name} updated · new bills due in $n days');
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      toastPurchaseError(ref, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppDialogPanel(
      semanticLabel: 'Stockist terms',
      children: [
        PurchaseDialogHeader(title: widget.dues.name, subtitle: 'Credit days apply to bills received from now on.'),
        AppTextField(
          fieldKey: const ValueKey('terms-days'),
          label: 'Credit days',
          value: days,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (v) => setState(() => days = v),
        ),
        AppTextField(label: 'Phone', value: phone, keyboardType: TextInputType.phone, onChanged: (v) => setState(() => phone = v)),
        AppTextField(label: 'GSTIN', value: gstin, maxLength: 15, onChanged: (v) => setState(() => gstin = v.toUpperCase())),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(key: const ValueKey('terms-save'), label: 'Save', onPressed: _save),
          ],
        ),
      ],
    );
  }
}

class _OpeningDialog extends ConsumerStatefulWidget {
  const _OpeningDialog({required this.supplierId});

  final int supplierId;

  @override
  ConsumerState<_OpeningDialog> createState() => _OpeningDialogState();
}

class _OpeningDialogState extends ConsumerState<_OpeningDialog> {
  late String date = _today(ref);
  String amount = '';

  Future<void> _save() async {
    final a = Paise.tryParse(amount);
    if (a == null || a.value <= 0) {
      ref.read(toastsProvider.notifier).show('Enter what you owed them', warn: true);
      return;
    }
    try {
      await ref.read(guardedActionsProvider).setOpeningBalance(supplierId: widget.supplierId, date: date, amount: a);
      ref.read(toastsProvider.notifier).show('Opening balance ${formatInr(a)} set');
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      toastPurchaseError(ref, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppDialogPanel(
      semanticLabel: 'Opening balance',
      children: [
        const PurchaseDialogHeader(title: 'Opening balance', subtitle: 'What you owed this stockist before using RxDesk. It is due at once.'),
        PurchaseDateField(label: 'As of', value: date, onChanged: (v) => setState(() => date = v)),
        AppTextField(
          fieldKey: const ValueKey('opening-amount'),
          label: 'Amount owed (₹)',
          value: amount,
          autofocus: true,
          keyboardType: _moneyKb,
          inputFormatters: _money,
          onChanged: (v) => setState(() => amount = v),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(key: const ValueKey('opening-save'), label: 'Save', onPressed: _save),
          ],
        ),
      ],
    );
  }
}
