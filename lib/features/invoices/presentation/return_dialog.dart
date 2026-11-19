import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/sales_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/money/paise.dart';
import '../../../core/sales/bill_rules.dart';
import '../../../core/sales/credit_rules.dart';
import '../../../core/sales/return_rules.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/pack.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/guarded_actions.dart';
import '../../staff/application/session.dart';
import '../application/invoice_list.dart';
import '../application/invoice_printer.dart';
import '../application/invoice_selection.dart';

/// Opens the sales-return dialog for invoice [invoiceId] (SPEC §4.5, §5.4).
Future<void> showReturnDialog(BuildContext context, {required int invoiceId}) =>
    showAppDialog<void>(context, maxWidth: 720, topPadding: 40, builder: (_) => ReturnItemsDialog(invoiceId: invoiceId));

/// Return items from a bill → a credit note. One row per original line with
/// a qty stepper and a "damaged" switch; Schedule H / H1 lines are locked.
class ReturnItemsDialog extends ConsumerStatefulWidget {
  const ReturnItemsDialog({super.key, required this.invoiceId});

  final int invoiceId;

  @override
  ConsumerState<ReturnItemsDialog> createState() => _ReturnItemsDialogState();
}

class _ReturnItemsDialogState extends ConsumerState<ReturnItemsDialog> {
  final Map<int, int> _qty = {};
  final Set<int> _damaged = {};
  String? _mode;
  String _reason = '';
  bool _saving = false;

  List<ReturnLineRequest> get _lines => [
        for (final e in _qty.entries)
          if (e.value > 0) ReturnLineRequest(itemId: e.key, qty: e.value, restock: !_damaged.contains(e.key)),
      ];

  Future<void> _save(ReturnContext ctx) async {
    final toasts = ref.read(toastsProvider.notifier);
    final lines = _lines;
    if (lines.isEmpty) {
      toasts.show('Pick at least one item to return', warn: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await ref.read(guardedActionsProvider).acceptReturn(
            invoiceId: widget.invoiceId,
            lines: lines,
            refundMode: _mode ?? defaultRefundMode(billPaymentMode: ctx.invoice.paymentMode, customerId: ctx.invoice.customerId),
            reason: _reason.trim().isEmpty ? null : _reason.trim(),
          );
      final s = ref.read(settingsProvider);
      final units = lines.fold<int>(0, (a, l) => a + l.qty);
      final how = (_mode ?? defaultRefundMode(billPaymentMode: ctx.invoice.paymentMode, customerId: ctx.invoice.customerId)) == creditMode
          ? '${formatInr(saved.totals.total)} off dues'
          : 'Refund ${formatInr(saved.totals.total)}';
      toasts.show(
        '${saved.number} saved · $how · ${formatCount(units)} ${units == 1 ? 'unit' : 'units'}'
        '${s.autoPrint ? ' · printing' : ''}',
      );
      ref.read(selectedInvoiceProvider.notifier).select(saved.creditNoteId);
      if (s.autoPrint) unawaited(ref.read(invoicePrinterProvider).printSaved(saved.creditNoteId, copies: s.copies));
      if (mounted) Navigator.of(context).pop();
    } on BillException catch (e) {
      toasts.show(e.message, warn: true);
    } on Object catch (e) {
      toasts.show('$e', warn: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctx = ref.watch(returnContextProvider(widget.invoiceId)).value;
    if (ctx == null) {
      return const AppDialogPanel(children: [SizedBox(height: 160, child: Center(child: CircularProgressIndicator()))]);
    }
    final inv = ctx.invoice;
    final settings = ref.watch(settingsProvider);
    final role = ref.watch(sessionProvider)?.role ?? StaffRole.owner;
    final rules = settings.returnRules(role: role);
    final now = ref.watch(nowProvider)();
    final late = pastReturnWindow(inv.saleDate, now, rules.windowDays);
    final blocked = late && !rules.canOverrideWindow;
    final mode = _mode ?? defaultRefundMode(billPaymentMode: inv.paymentMode, customerId: inv.customerId);
    final toDues = canRefundToDues(customerId: inv.customerId);
    final totals = returnTotals(
      lines: _lines,
      sold: ctx.sold,
      prior: ctx.prior,
      discount: invoiceDiscount(inv),
      gstRegistered: inv.gstRegistered,
      roundOff: rules.roundOff,
    );
    final days = daysSinceSale(inv.saleDate, now);

    return AppDialogPanel(
      semanticLabel: 'Return items',
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Return items', style: AppType.dialogTitle),
                  const SizedBox(height: 4),
                  Text(
                    '${inv.number} · ${inv.customerName} · ${dayLabel(inv.saleDate)}'
                    '${invoiceDiscount(inv).isZero ? '' : ' · ${invoiceDiscount(inv).label} discount'}',
                    style: AppType.small.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            IconButton(tooltip: 'Close', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded, size: 20)),
          ],
        ),
        if (late)
          _Notice(
            tone: blocked ? StatusTone.danger : StatusTone.warning,
            text: blocked
                ? 'This bill is $days days old — returns are accepted within ${rules.windowDays} days. Only the Owner can accept it.'
                : 'This bill is $days days old (return window ${rules.windowDays} days). Accepting as Owner.',
          ),
        for (final it in ctx.items)
          _LineRow(
            item: it,
            sold: ctx.sold[it.id]!,
            prior: ctx.prior[it.id] ?? PriorReturn.none,
            qty: _qty[it.id] ?? 0,
            damaged: _damaged.contains(it.id),
            enabled: !blocked && !_saving,
            onQty: (q) => setState(() => _qty[it.id] = q),
            onDamaged: (v) => setState(() => v ? _damaged.add(it.id) : _damaged.remove(it.id)),
          ),
        Wrap(
          spacing: AppSpace.lg,
          runSpacing: AppSpace.md,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Refund by', style: AppType.label),
                const SizedBox(height: 6),
                SegmentedPills<String>(
                  key: const ValueKey('return-mode'),
                  semanticLabel: 'Refund mode',
                  options: [
                    for (final m in paymentModes) PillOption(m, m),
                    if (toDues) const PillOption(creditMode, 'Adjust in dues'),
                  ],
                  selected: mode,
                  onChanged: blocked ? null : (v) => setState(() => _mode = v),
                ),
              ],
            ),
            SizedBox(
              width: 320,
              child: AppTextField(
                fieldKey: const ValueKey('return-reason'),
                label: 'Reason',
                hint: 'Optional — e.g. doctor changed the medicine',
                value: _reason,
                onChanged: (v) => _reason = v,
              ),
            ),
          ],
        ),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: const BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.all(Radius.circular(12))),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  totals.items == 0
                      ? 'Nothing selected yet'
                      : '${formatCount(totals.units)} ${totals.units == 1 ? 'unit' : 'units'}'
                          '${inv.gstRegistered ? ' · taxable ${formatInr(totals.taxable)} · GST ${formatInr(totals.tax)}' : ''}'
                          '${totals.roundOff.isZero ? '' : ' · round off ${totals.roundOff.isNegative ? '−' : '+'}${formatInr(totals.roundOff.abs())}'}',
                  style: AppType.caption,
                ),
              ),
              Text('Refund ', style: AppType.small),
              Text(formatInr(totals.total), key: const ValueKey('return-total'), style: AppType.cardTitle.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          runSpacing: AppSpace.sm,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(
              key: const ValueKey('return-save'),
              icon: Icons.assignment_return_outlined,
              label: _saving ? 'Saving…' : (settings.autoPrint ? 'Save & print credit note' : 'Save credit note'),
              onPressed: _saving || blocked || totals.items == 0 ? null : () => _save(ctx),
            ),
          ],
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.tone, required this.text});

  final StatusTone tone;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = tone.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: c.bg, borderRadius: const BorderRadius.all(Radius.circular(10))),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: c.fg),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: AppType.small.copyWith(color: c.fg))),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  String _q(int units) => formatPackQty(units, item.packSize, item.category);

  const _LineRow({
    required this.item,
    required this.sold,
    required this.prior,
    required this.qty,
    required this.damaged,
    required this.enabled,
    required this.onQty,
    required this.onDamaged,
  });

  final InvoiceItem item;
  final SoldLine sold;
  final PriorReturn prior;
  final int qty;
  final bool damaged;
  final bool enabled;
  final ValueChanged<int> onQty;
  final ValueChanged<bool> onDamaged;

  @override
  Widget build(BuildContext context) {
    final left = returnable(sold, prior);
    final rx = sold.isRx;
    final canEdit = enabled && !rx && left > 0;
    return Container(
      key: ValueKey('return-line-${item.lineNo}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: qty > 0 ? AppColors.textMuted : AppColors.border),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: Text(item.productName, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis)),
                        if (rx) ...[const SizedBox(width: 6), RxBadge(item.schedule)],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Batch ${item.batchNo} · exp ${formatExpiry(item.expiry)} · ${formatInr(Paise(item.mrpPaise))}'
                      '${item.packSize > 1 ? ' per ${PackNouns.of(item.category).pack} of ${item.packSize}' : ''} · '
                      'sold ${_q(item.qty)}${prior.qty > 0 ? ' · returned ${_q(prior.qty)}' : ''}',
                      style: AppType.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (rx)
                const StatusBadge.tag('Rx — can’t return', tone: StatusTone.warning)
              else if (left == 0)
                const StatusBadge.tag('Returned')
              else if (item.packSize > 1)
                _PackStepper(
                  label: item.productName,
                  value: qty,
                  max: left,
                  packSize: item.packSize,
                  nouns: PackNouns.of(item.category),
                  enabled: canEdit,
                  onChanged: onQty,
                  keyPrefix: 'return-qty-${item.lineNo}',
                )
              else
                _Stepper(
                  label: item.productName,
                  value: qty,
                  max: left,
                  enabled: canEdit,
                  onChanged: onQty,
                  keyPrefix: 'return-qty-${item.lineNo}',
                ),
            ],
          ),
          if (qty > 0) ...[
            const SizedBox(height: 8),
            ToggleRow(
              key: ValueKey('return-damaged-${item.lineNo}'),
              label: 'Damaged — don’t restock',
              help: damaged ? 'Written off: stock stays the same.' : 'Goes back into batch ${item.batchNo}.',
              value: damaged,
              bordered: false,
              onChanged: enabled ? onDamaged : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// Strips and loose tabs to return, as two steppers (SPEC §4.9).
class _PackStepper extends StatelessWidget {
  const _PackStepper({
    required this.label,
    required this.value,
    required this.max,
    required this.packSize,
    required this.nouns,
    required this.enabled,
    required this.onChanged,
    required this.keyPrefix,
  });

  final String label;

  /// Units.
  final int value;
  final int max;
  final int packSize;
  final PackNouns nouns;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final packs = value ~/ packSize, loose = value % packSize;
    final maxPacks = (max - loose) ~/ packSize;
    final maxLoose = (max - packs * packSize).clamp(0, packSize - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Stepper(
          label: '$label ${nouns.packs}',
          value: packs,
          max: maxPacks,
          enabled: enabled,
          onChanged: (p) => onChanged(p * packSize + loose),
          keyPrefix: '$keyPrefix-packs',
          suffix: nouns.packs,
        ),
        _Stepper(
          label: '$label ${nouns.units}',
          value: loose,
          max: maxLoose,
          enabled: enabled,
          onChanged: (l) => onChanged(packs * packSize + l),
          keyPrefix: '$keyPrefix-loose',
          suffix: nouns.units,
        ),
      ],
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.max,
    required this.enabled,
    required this.onChanged,
    required this.keyPrefix,
    this.suffix,
  });

  final String label;
  final int value;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final String keyPrefix;

  /// Unit word after the number ("strips").
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: ValueKey('$keyPrefix-minus'),
          tooltip: 'Return one less $label',
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          onPressed: enabled && value > 0 ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_rounded, size: 20),
        ),
        Semantics(
          label: 'Return quantity for $label',
          value: '$value of $max',
          child: SizedBox(
            width: suffix == null ? 56 : 96,
            child: Text(
              suffix == null ? '$value / $max' : '$value $suffix',
              key: ValueKey(keyPrefix),
              textAlign: TextAlign.center,
              style: AppType.bodyStrong,
            ),
          ),
        ),
        IconButton(
          key: ValueKey('$keyPrefix-plus'),
          tooltip: 'Return one more $label',
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          onPressed: enabled && value < max ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add_rounded, size: 20),
        ),
      ],
    );
  }
}
