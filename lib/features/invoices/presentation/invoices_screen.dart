import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/sales_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/money/paise.dart';
import '../../../core/sales/return_rules.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/date_range.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/guarded_actions.dart';
import '../../staff/application/session.dart';
import '../application/invoice_list.dart';
import '../application/invoice_printer.dart';
import '../application/invoice_selection.dart';
import 'invoice_paper.dart';
import 'return_dialog.dart';

/// Invoices (SPEC §5.4): list with presets, search, payment filter and
/// keyset paging; preview identical to the printed layout.
class InvoicesScreen extends ConsumerWidget {
  const InvoicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, c) {
        final compact = MediaQuery.sizeOf(context).width < AppSizes.breakpointRail;
        final x = compact ? AppSpace.lg : AppSpace.pageX;
        final padding = EdgeInsets.fromLTRB(x, compact ? AppSpace.lg : 0, x, 40);
        if (c.maxWidth < 900) {
          return SingleChildScrollView(
            padding: padding,
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [PageEnter(child: _ListPanel()), SizedBox(height: 18), PageEnter(index: 1, child: _PreviewPanel())],
            ),
          );
        }
        return SingleChildScrollView(
          padding: padding,
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 2, child: PageEnter(child: _ListPanel())),
              SizedBox(width: 18),
              Expanded(flex: 3, child: PageEnter(index: 1, child: _PreviewPanel())),
            ],
          ),
        );
      },
    );
  }
}

class _ListPanel extends ConsumerStatefulWidget {
  const _ListPanel();

  @override
  ConsumerState<_ListPanel> createState() => _ListPanelState();
}

class _ListPanelState extends ConsumerState<_ListPanel> {
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(invoiceListControllerProvider);
    final ctl = ref.read(invoiceListControllerProvider.notifier);
    final page = ref.watch(invoicePageProvider).value;
    final summary = ref.watch(invoiceSummaryProvider).value;
    final selected = ref.watch(selectedInvoiceProvider);
    final now = ref.watch(nowProvider)();
    final range = rangeFor(s.preset, now);
    final rows = page?.rows ?? const <Invoice>[];

    // Default selection: first bill in the list.
    if (selected == null && rows.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(selectedInvoiceProvider) == null) ref.read(selectedInvoiceProvider.notifier).select(rows.first.id);
      });
    }

    return AppCard(
      padding: const EdgeInsets.all(AppSpace.gap14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilterChipRow<DatePreset>(
            semanticLabel: 'Date range',
            options: [for (final p in DatePreset.values.take(5)) PillOption(p, p.label)],
            selected: s.preset,
            onChanged: ctl.setPreset,
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              Expanded(
                child: AppTextField(
                  key: const ValueKey('invoice-search'),
                  label: '',
                  hint: 'Bill no., customer or phone…',
                  prefixIcon: Icons.search_rounded,
                  value: s.search,
                  onChanged: (v) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 200), () => ctl.setSearch(v));
                  },
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              AppDropdown<String?>(
                semanticLabel: 'Payment mode',
                value: s.payment,
                options: const [
                  DropdownOption(null, 'All modes'),
                  DropdownOption('Cash', 'Cash'),
                  DropdownOption('UPI', 'UPI'),
                  DropdownOption('Card', 'Card'),
                  DropdownOption('Credit', 'Credit'),
                ],
                onChanged: ctl.setPayment,
              ),
            ],
          ),
          const SizedBox(height: AppSpace.gap10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: formatCount(summary?.count ?? 0), style: AppType.label.copyWith(color: AppColors.text)),
                        TextSpan(text: ' bills · ${range.label}'),
                      ],
                    ),
                    style: AppType.caption,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'Total '),
                      TextSpan(text: formatInr(summary?.total ?? Paise.zero), style: AppType.label.copyWith(color: AppColors.text)),
                    ],
                  ),
                  style: AppType.caption,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          if (page != null && rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Text('No bills in this range.', textAlign: TextAlign.center, style: AppType.small.copyWith(color: AppColors.textSecondary)),
            ),
          for (final r in rows) _InvoiceRow(row: r, selected: r.id == selected, now: now),
          const Divider(height: 20),
          KeysetPager(
            label: 'Page ${s.page}',
            onNewer: s.cursors.isEmpty ? null : ctl.newer,
            onOlder: page?.hasOlder ?? false ? () => ctl.older(InvoiceCursor(rows.last.saleDate, rows.last.id)) : null,
          ),
        ],
      ),
    );
  }
}

String _when(Invoice i, DateTime now) {
  final at = DateTime.fromMillisecondsSinceEpoch(i.createdAt, isUtc: true).toLocal();
  final today = dateKey(now);
  final yesterday = dateKey(now.subtract(const Duration(days: 1)));
  final day = i.saleDate == today
      ? 'Today'
      : i.saleDate == yesterday
          ? 'Yesterday'
          : dayLabel(i.saleDate).substring(4);
  return '$day, ${formatTime(at)}';
}

class _InvoiceRow extends ConsumerWidget {
  const _InvoiceRow({required this.row, required this.selected, required this.now});

  final Invoice row;
  final bool selected;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final cancelled = row.status == 'cancelled';
    final badge = switch ((row.docType, row.status)) {
      (_, 'cancelled') => const StatusBadge.tag('Cancelled', tone: StatusTone.danger),
      ('credit_note', _) => StatusBadge.tag('Credit note · ${row.paymentMode}', tone: StatusTone.info),
      (_, 'part_returned') => const StatusBadge.tag('Part returned', tone: StatusTone.warning),
      (_, 'returned') => const StatusBadge.tag('Returned', tone: StatusTone.warning),
      _ => StatusBadge.tag(row.paymentMode),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? p.accentSoft : AppColors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            side: BorderSide(color: selected ? p.accent : AppColors.transparent, width: 1.5),
          ),
          child: InkWell(
            key: ValueKey('invoice-${row.number}'),
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            onTap: () => ref.read(selectedInvoiceProvider.notifier).select(row.id),
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row.customerName, style: AppType.smallStrong, overflow: TextOverflow.ellipsis),
                        Text('${row.number} · ${_when(row, now)}', style: AppType.caption, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        formatInr(Paise(row.totalPaise)),
                        style: AppType.smallStrong.copyWith(
                          fontWeight: FontWeight.w700,
                          decoration: cancelled ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      const SizedBox(height: 4),
                      badge,
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewPanel extends ConsumerStatefulWidget {
  const _PreviewPanel();

  @override
  ConsumerState<_PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends ConsumerState<_PreviewPanel> {
  bool _busy = false;

  Future<void> _guard(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('$e', warn: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = ref.watch(selectedInvoiceProvider);
    if (id == null) {
      return const AppCard(child: EmptyState(icon: Icons.receipt_long_outlined, title: 'No bill selected', message: 'Pick a bill on the left to see it here.'));
    }
    final doc = ref.watch(invoiceDocProvider(id)).value;
    final detail = ref.watch(invoiceDetailProvider(id)).value;
    final canCancel = ref.watch(canProvider(Permission.editBills));
    final canReturn = ref.watch(canProvider(Permission.acceptReturns));
    final printer = ref.read(invoicePrinterProvider);
    final toasts = ref.read(toastsProvider.notifier);
    final number = doc?.number ?? '';
    final inv = detail?.invoice;
    final isInvoice = inv?.docType == 'invoice';
    final paid = isInvoice && inv?.status == 'paid';
    final returnable = isInvoice && (inv?.status == 'paid' || inv?.status == 'part_returned');
    final role = ref.watch(sessionProvider)?.role ?? StaffRole.owner;
    final rules = ref.watch(settingsProvider).returnRules(role: role);
    final now = ref.watch(nowProvider)();
    final windowShut = inv != null && pastReturnWindow(inv.saleDate, now, rules.windowDays) && !rules.canOverrideWindow;
    final creditNotes = isInvoice ? ref.watch(creditNotesProvider(id)).value ?? const <Invoice>[] : const <Invoice>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            if (returnable && canReturn)
              Tooltip(
                message: windowShut ? 'Older than ${rules.windowDays} days — only the Owner can accept a return' : 'Return items and issue a credit note',
                child: AppButton.secondary(
                  key: const ValueKey('return-invoice'),
                  label: 'Return items',
                  icon: Icons.assignment_return_outlined,
                  onPressed: windowShut || _busy ? null : () => showReturnDialog(context, invoiceId: id),
                ),
              ),
            if (paid)
              AppButton.secondary(
                key: const ValueKey('cancel-invoice'),
                label: 'Cancel bill',
                icon: Icons.block_rounded,
                onPressed: !canCancel || _busy
                    ? null
                    : () async {
                        final ok = await showConfirmDialog(
                          context,
                          title: 'Cancel $number?',
                          message: 'The bill stays on record marked “Cancelled”, its number is not reused, and the stock goes back to the same batches.',
                          confirmLabel: 'Cancel bill',
                          cancelLabel: 'Keep bill',
                          tone: ConfirmTone.danger,
                        );
                        if (!ok) return;
                        await _guard(() async {
                          await ref.read(guardedActionsProvider).cancelInvoice(id);
                          toasts.show('$number cancelled · stock restored');
                        });
                      },
              ),
            AppButton.secondary(
              key: const ValueKey('print-invoice'),
              label: 'Print',
              icon: Icons.print_outlined,
              onPressed: doc == null || _busy ? null : () => _guard(() => printer.printWithDialog(id)),
            ),
            AppButton(
              key: const ValueKey('pdf-invoice'),
              label: 'Download PDF',
              icon: Icons.picture_as_pdf_outlined,
              onPressed: doc == null || _busy
                  ? null
                  : () => _guard(() async {
                        final path = await printer.savePdf(id);
                        if (path != null) toasts.show('$number.pdf saved');
                      }),
            ),
          ],
        ),
        if (inv != null && (creditNotes.isNotEmpty || inv.refInvoiceId != null)) ...[
          const SizedBox(height: AppSpace.md),
          _LinkedDocs(
            label: inv.refInvoiceId != null ? 'Against bill' : 'Credit notes',
            links: inv.refInvoiceId != null
                ? [(inv.refInvoiceId!, doc?.against?.replaceFirst('Against ', '') ?? 'Original bill')]
                : [for (final c in creditNotes) (c.id, '${c.number} · ${formatInr(Paise(-c.totalPaise))}')],
          ),
        ],
        const SizedBox(height: AppSpace.md),
        if (doc == null)
          const SizedBox(height: 300, child: Center(child: CircularProgressIndicator()))
        else
          InvoicePaperView(doc: doc),
      ],
    );
  }
}

/// Links between a bill and its credit notes (or a credit note and its bill).
class _LinkedDocs extends ConsumerWidget {
  const _LinkedDocs({required this.label, required this.links});

  final String label;
  final List<(int id, String text)> links;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('$label:', style: AppType.label),
        for (final (id, text) in links)
          ActionChip(
            key: ValueKey('linked-doc-$id'),
            label: Text(text, style: AppType.smallStrong),
            tooltip: 'Open $text',
            onPressed: () => ref.read(selectedInvoiceProvider.notifier).select(id),
          ),
      ],
    );
  }
}
