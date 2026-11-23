import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../core/db/daos/customers_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/money/paise.dart';
import '../../../core/sales/credit_rules.dart';
import '../../../core/tax/gstin.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/save_file.dart';
import '../../../core/widgets/widgets.dart';
import '../../invoices/application/invoice_pdf.dart';
import '../../purchases/presentation/purchase_dialogs.dart' show PurchaseDateField, PurchaseDialogHeader;
import '../../sales_register/application/register_export.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/guarded_actions.dart';
import '../../staff/application/session.dart';
import '../application/customer_statement.dart';
import '../application/customers_providers.dart';
import '../data/customers_repository.dart';

Future<void> showCustomerStatement(BuildContext context, {required int customerId}) =>
    showAppDialog<void>(context, maxWidth: 1000, topPadding: 32, builder: (_) => CustomerStatementDialog(customerId: customerId));

Future<void> showCustomerPayment(BuildContext context, {required int customerId}) =>
    showAppDialog<void>(context, maxWidth: 720, topPadding: 40, builder: (_) => CustomerPaymentDialog(customerId: customerId));

/// Add (no [dues]) or edit a customer.
Future<void> showCustomerEdit(BuildContext context, {CustomerDues? dues}) =>
    showAppDialog<void>(context, maxWidth: 520, builder: (_) => CustomerEditDialog(dues: dues));

final _money = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];
const _moneyKb = TextInputType.numberWithOptions(decimal: true);

String _today(WidgetRef ref) => dateKey(ref.read(nowProvider)());

void toastCustomerError(WidgetRef ref, Object e) {
  final msg = switch (e) {
    CustomerException(:final message) => message,
    PermissionDenied() => '$e',
    _ => 'Something went wrong: $e',
  };
  ref.read(toastsProvider.notifier).show(msg, warn: true);
}

StatusTone agingTone(AgingBucket b) => switch (b) {
      AgingBucket.none => StatusTone.neutral,
      AgingBucket.d30 => StatusTone.success,
      AgingBucket.d60 => StatusTone.warning,
      AgingBucket.d90 => StatusTone.warning,
      AgingBucket.over90 => StatusTone.danger,
    };

String limitLabel(int? own, int defaultLimit) {
  final l = effectiveCreditLimit(customerLimit: own, defaultLimit: defaultLimit);
  if (l == 0) return 'No limit';
  return '${formatInr(Paise(l), decimals: 0)}${own == null ? ' (default)' : ''}';
}

// ---------------------------------------------------------------------------
// Record payment

class CustomerPaymentDialog extends ConsumerStatefulWidget {
  const CustomerPaymentDialog({super.key, required this.customerId});

  final int customerId;

  @override
  ConsumerState<CustomerPaymentDialog> createState() => _CustomerPaymentDialogState();
}

class _CustomerPaymentDialogState extends ConsumerState<CustomerPaymentDialog> {
  late String date = _today(ref);
  String amount = '', mode = 'Cash', reference = '', note = '';
  final Set<int> picked = {};
  String? error;
  bool saving = false;

  Future<void> _save() async {
    final a = Paise.tryParse(amount);
    if (a == null || a.value <= 0) {
      setState(() => error = 'Enter the amount received');
      return;
    }
    setState(() {
      error = null;
      saving = true;
    });
    try {
      await ref.read(guardedActionsProvider).recordCustomerPayment(
            customerId: widget.customerId,
            date: date,
            payment: CustomerPaymentInput(amount: a, mode: mode, reference: reference, note: note),
            pickedBillIds: picked.isEmpty ? null : picked,
          );
      ref.read(toastsProvider.notifier).show('${formatInr(a)} received by $mode');
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      toastCustomerError(ref, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = ref.watch(customerDuesProvider(widget.customerId)).value;
    final bills = ref.watch(customerOpenBillsProvider(widget.customerId)).value ?? const <CustomerOpenBill>[];
    final a = Paise.tryParse(amount) ?? Paise.zero;
    final (allocs, left) = allocate(0, a.value, [
      for (final b in bills) OpenDebit(id: b.ledgerId, dueDate: b.date, outstanding: b.outstanding.value),
    ], picked: picked.isEmpty ? null : picked);
    final byBill = {for (final x in allocs) x.debitId: x.amount};

    return AppDialogPanel(
      semanticLabel: 'Receive payment',
      children: [
        PurchaseDialogHeader(
          title: 'Receive payment',
          subtitle: d == null ? null : '${d.name} · owes ${formatInr(d.balance)}',
        ),
        FieldGrid(
          minColumnWidth: 200,
          children: [
            PurchaseDateField(fieldKey: const ValueKey('cpay-date'), label: 'Received on', value: date, onChanged: (v) => setState(() => date = v)),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                AppTextField(
                  fieldKey: const ValueKey('cpay-amount'),
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
                      key: const ValueKey('cpay-all'),
                      onPressed: () => setState(() => amount = d.balance.toInputString()),
                      child: Text('All dues ${formatInr(d.balance)}'),
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
                    options: [for (final m in collectModes) PillOption(m, m)],
                    selected: mode,
                    onChanged: (v) => setState(() => mode = v),
                  ),
                ],
              ),
            ),
            AppTextField(label: 'Reference', hint: 'UTR / card slip', value: reference, onChanged: (v) => setState(() => reference = v)),
            AppTextField(label: 'Note', hint: 'Optional', value: note, onChanged: (v) => setState(() => note = v)),
          ],
        ),
        Text(picked.isEmpty ? 'Applied to the oldest bills first. Tick bills to settle only those.' : 'Settling only the ticked bills.', style: AppType.caption),
        if (bills.isEmpty)
          const EmptyState(title: 'No open bills', message: 'The whole amount is kept as an advance for the next credit bill.')
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
                    decoration: BoxDecoration(border: i == 0 ? null : const Border(top: BorderSide(color: AppColors.divider))),
                    padding: const EdgeInsets.only(right: 14),
                    child: Row(
                      children: [
                        Checkbox(
                          key: ValueKey('cpay-bill-${b.ledgerId}'),
                          value: picked.contains(b.ledgerId),
                          semanticLabel: 'Settle ${b.reference}',
                          onChanged: (_) => setState(() => picked.contains(b.ledgerId) ? picked.remove(b.ledgerId) : picked.add(b.ledgerId)),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(b.reference, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis),
                              Text(
                                '${dayLabel(b.date)} · ${formatInr(b.amount)}${b.partPaid ? ' · part paid' : ''}',
                                style: AppType.caption,
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
                          width: 130,
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
            '${formatInr(Paise(left))} is kept as an advance and goes to the next credit bill.',
            key: const ValueKey('cpay-left'),
            style: AppType.smallStrong.copyWith(color: StatusTone.info.colors.fg),
          ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(key: const ValueKey('cpay-save'), label: saving ? 'Saving…' : 'Receive payment', onPressed: saving ? null : _save),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Statement

class CustomerStatementDialog extends ConsumerStatefulWidget {
  const CustomerStatementDialog({super.key, required this.customerId});

  final int customerId;

  @override
  ConsumerState<CustomerStatementDialog> createState() => _CustomerStatementDialogState();
}

class _CustomerStatementDialogState extends ConsumerState<CustomerStatementDialog> {
  final List<CustomerStatementCursor> cursors = [];
  bool busy = false;

  static const _columns = [
    GridColumn.fixed('Date', 104),
    GridColumn.fixed('Type', 110),
    GridColumn('Reference', flex: 1.4, minWidth: 160),
    GridColumn.fixed('Debit', 110, alignEnd: true),
    GridColumn.fixed('Credit', 110, alignEnd: true),
    GridColumn.fixed('Balance', 120, alignEnd: true),
    GridColumn.fixed('', 52, alignEnd: true),
  ];

  Future<void> _void(CustomerStatementRow r) async {
    final reason = await showAppDialog<String>(context, builder: (_) => _VoidDialog(row: r));
    if (reason == null) return;
    try {
      await ref.read(guardedActionsProvider).voidCustomerEntry(r.id, reason: reason);
      ref.read(toastsProvider.notifier).show('${r.kind.label} ${formatInr(r.amount)} voided');
    } on Object catch (e) {
      toastCustomerError(ref, e);
    }
  }

  Future<CustomerStatementData> _data() async {
    final repo = ref.read(customersRepositoryProvider);
    final d = await repo.customerDues(widget.customerId);
    final rows = <CustomerStatementRow>[];
    CustomerStatementCursor? after;
    while (true) {
      final p = await repo.statement(widget.customerId, after: after, limit: 500);
      rows.addAll(p.rows);
      if (!p.hasMore) break;
      after = CustomerStatementCursor(p.rows.last.date, p.rows.last.id);
    }
    final s = ref.read(settingsProvider);
    final place = [s.city, s.state, s.pin].where((x) => x.trim().isNotEmpty).join(', ');
    return CustomerStatementData(
      storeName: s.name,
      storeLines: [
        [s.addr1, s.addr2, place].where((x) => x.trim().isNotEmpty).join(', '),
        [if (s.phone.isNotEmpty) 'Ph ${s.phone}', if (s.gstin.isNotEmpty) 'GSTIN ${s.gstin}'].join(' · '),
      ].where((x) => x.isNotEmpty).toList(),
      customer: d,
      rows: rows,
      generated: ref.read(nowProvider)(),
    );
  }

  Future<void> _print() async {
    setState(() => busy = true);
    try {
      final data = await _data();
      final bytes = await buildCustomerStatementPdf(
        data,
        fonts: await InvoiceFonts.load(),
        accentArgb: colorFromHex(ref.read(settingsProvider).accent).toARGB32(),
      );
      // dynamicLayout: false — see InvoicePrinter (macOS deadlock).
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'Statement ${data.customer.name}', dynamicLayout: false);
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('Printing failed: $e', warn: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _export() async {
    setState(() => busy = true);
    try {
      final data = await _data();
      final table = customerStatementTable(data);
      final name = 'statement-${data.customer.name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-')}-${dateKey(data.generated)}';
      String? path;
      try {
        path = await saveBytesAs('$name.xlsx', await buildXlsxInIsolate(table, sheetName: 'Statement'));
      } on Object {
        path = await saveTextAs('$name.csv', buildCsv(table));
      }
      if (path != null) ref.read(toastsProvider.notifier).show('${path.split(RegExp(r'[/\\]')).last} saved · ${data.rows.length} entries');
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('Export failed: $e', warn: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.customerId;
    final d = ref.watch(customerDuesProvider(id)).value;
    final c = cursors.isEmpty ? null : cursors.last;
    final page = ref.watch(customerStatementProvider((id, c?.date, c?.id))).value;
    final rows = page?.rows ?? const <CustomerStatementRow>[];
    final canCollect = ref.watch(canProvider(Permission.collectPayments));
    final canManage = ref.watch(canProvider(Permission.manageCustomerCredit));
    final defaultLimit = ref.watch(settingsProvider.select((s) => s.defaultCreditLimitPaise));
    final today = dateKey(ref.watch(nowProvider)());

    Widget stat(String label, String value, {StatusTone? tone, Key? key}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: AppType.caption),
            Text(value, key: key, style: AppType.cardTitle.copyWith(color: tone?.colors.fg, fontFeatures: AppType.tabular)),
          ],
        );

    return AppDialogPanel(
      semanticLabel: 'Customer statement',
      children: [
        PurchaseDialogHeader(
          title: d?.name ?? 'Statement',
          subtitle: d == null ? null : [d.phone, if (d.address.isNotEmpty) d.address, if (d.note.isNotEmpty) d.note].join(' · '),
        ),
        if (d != null)
          Wrap(
            spacing: AppSpace.xl,
            runSpacing: AppSpace.md,
            children: [
              stat('Dues', formatInr(d.balance.isNegative ? Paise.zero : d.balance), key: const ValueKey('cstmt-balance')),
              if (d.advance.value > 0) stat('Advance', formatInr(d.advance), tone: StatusTone.info),
              stat('Open bills', formatCount(d.openBills)),
              stat('Oldest unpaid', d.oldestOpen == null ? '—' : d.agingOn(today).label, tone: d.oldestOpen == null ? null : agingTone(d.agingOn(today))),
              stat('Credit limit', limitLabel(d.creditLimit, defaultLimit)),
            ],
          ),
        Wrap(
          spacing: AppSpace.gap10,
          runSpacing: AppSpace.gap10,
          children: [
            AppButton(
              key: const ValueKey('cstmt-pay'),
              label: 'Receive payment',
              icon: Icons.payments_outlined,
              onPressed: canCollect ? () => showCustomerPayment(context, customerId: id) : null,
            ),
            AppButton.secondary(
              key: const ValueKey('cstmt-edit'),
              label: 'Edit',
              icon: Icons.edit_outlined,
              onPressed: canCollect && d != null ? () => showCustomerEdit(context, dues: d) : null,
            ),
            if (d != null && !d.hasOpening)
              AppButton.secondary(
                key: const ValueKey('cstmt-opening'),
                label: 'Opening dues',
                icon: Icons.history_rounded,
                onPressed: canManage ? () => showAppDialog<void>(context, builder: (_) => _OpeningDialog(customerId: id)) : null,
              ),
            AppButton.secondary(
              key: const ValueKey('cstmt-print'),
              label: 'Print statement',
              icon: Icons.print_outlined,
              onPressed: busy || d == null ? null : _print,
            ),
            AppButton.secondary(label: 'Export', icon: Icons.download_rounded, onPressed: busy || d == null ? null : _export),
          ],
        ),
        AppCard(
          padding: EdgeInsets.zero,
          clip: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DataGrid(
                semanticLabel: 'Customer ledger',
                columns: _columns,
                rowCount: rows.length,
                empty: page == null ? const SizedBox(height: 80) : const EmptyState(title: 'No entries yet', message: 'Credit bills and payments show up here.'),
                cells: (context, i) {
                  final r = rows[i];
                  final dim = r.active ? null : AppColors.textMuted;
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
                    Text(r.debit.value == 0 ? '' : formatInr(r.debit), style: AppType.small.copyWith(fontFeatures: AppType.tabular)),
                    Text(
                      r.credit.value == 0 ? '' : formatInr(r.credit),
                      style: AppType.small.copyWith(fontFeatures: AppType.tabular, color: StatusTone.success.colors.fg),
                    ),
                    Text(formatInr(r.balance), style: AppType.smallStrong.copyWith(fontFeatures: AppType.tabular, color: dim)),
                    // Payments taken with a bill go away by cancelling the bill.
                    if (r.active && r.kind.voidable && canManage && !(r.kind == CustomerLedgerKind.payment && r.invoiceId != null))
                      IconButton(
                        key: ValueKey('cvoid-${r.id}'),
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
                    Expanded(child: Text('Page ${cursors.length + 1} · oldest first', style: AppType.small.copyWith(color: AppColors.textSecondary))),
                    PagerButton(label: '‹ Earlier', semanticLabel: 'Earlier entries', onTap: cursors.isEmpty ? null : () => setState(cursors.removeLast)),
                    const SizedBox(width: 4),
                    PagerButton(
                      label: 'Later ›',
                      semanticLabel: 'Later entries',
                      onTap: page?.hasMore ?? false ? () => setState(() => cursors.add(CustomerStatementCursor(rows.last.date, rows.last.id))) : null,
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

  final CustomerStatementRow row;

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
          fieldKey: const ValueKey('cvoid-reason'),
          label: 'Reason',
          hint: 'e.g. UPI failed, entered twice',
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
              key: const ValueKey('cvoid-confirm'),
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

class _OpeningDialog extends ConsumerStatefulWidget {
  const _OpeningDialog({required this.customerId});

  final int customerId;

  @override
  ConsumerState<_OpeningDialog> createState() => _OpeningDialogState();
}

class _OpeningDialogState extends ConsumerState<_OpeningDialog> {
  late String date = _today(ref);
  String amount = '';

  Future<void> _save() async {
    final a = Paise.tryParse(amount);
    if (a == null || a.value <= 0) {
      ref.read(toastsProvider.notifier).show('Enter what they owed', warn: true);
      return;
    }
    try {
      await ref.read(guardedActionsProvider).setCustomerOpeningBalance(customerId: widget.customerId, date: date, amount: a);
      ref.read(toastsProvider.notifier).show('Opening dues ${formatInr(a)} set');
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      toastCustomerError(ref, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppDialogPanel(
      semanticLabel: 'Opening dues',
      children: [
        const PurchaseDialogHeader(title: 'Opening dues', subtitle: 'What this customer owed before RxDesk (e.g. from the khata book).'),
        PurchaseDateField(label: 'As of', value: date, onChanged: (v) => setState(() => date = v)),
        AppTextField(
          fieldKey: const ValueKey('copening-amount'),
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
            AppButton(key: const ValueKey('copening-save'), label: 'Save', onPressed: _save),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Add / edit

class CustomerEditDialog extends ConsumerStatefulWidget {
  const CustomerEditDialog({super.key, this.dues});

  /// Null = add a new customer.
  final CustomerDues? dues;

  @override
  ConsumerState<CustomerEditDialog> createState() => _CustomerEditDialogState();
}

class _CustomerEditDialogState extends ConsumerState<CustomerEditDialog> {
  late String name = widget.dues?.name ?? '';
  late String phone = widget.dues?.phone ?? '';
  late String address = widget.dues?.address ?? '';
  late String note = widget.dues?.note ?? '';
  late String gstin = widget.dues?.gstin ?? '';

  /// Own limit; null = use the default.
  late bool ownLimit = widget.dues?.creditLimit != null;
  late String limit = widget.dues?.creditLimit == null || widget.dues!.creditLimit == 0 ? '' : '${widget.dues!.creditLimit! ~/ 100}';
  bool saving = false;

  Future<void> _save() async {
    final l = ownLimit ? (int.tryParse(limit) ?? 0) * 100 : null;
    setState(() => saving = true);
    try {
      final g = ref.read(guardedActionsProvider);
      final d = widget.dues;
      if (d == null) {
        await g.addCustomer(name: name, phone: phone, creditLimit: l, address: address, note: note, gstin: gstin);
        ref.read(toastsProvider.notifier).show('${name.trim()} added');
      } else {
        await g.updateCustomer(d.customerId, name: name, phone: phone, creditLimit: l, address: address, note: note, gstin: gstin);
        ref.read(toastsProvider.notifier).show('${name.trim()} updated');
      }
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      toastCustomerError(ref, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canManage = ref.watch(canProvider(Permission.manageCustomerCredit));
    final defaultLimit = ref.watch(settingsProvider.select((s) => s.defaultCreditLimitPaise));
    return AppDialogPanel(
      semanticLabel: widget.dues == null ? 'Add customer' : 'Edit customer',
      children: [
        PurchaseDialogHeader(
          title: widget.dues == null ? 'Add customer' : 'Edit customer',
          subtitle: widget.dues == null ? 'Customers are also added when you bill them with a phone number.' : null,
        ),
        AppTextField(
          fieldKey: const ValueKey('cedit-name'),
          label: 'Name',
          value: name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          onChanged: (v) => setState(() => name = v),
        ),
        AppTextField(
          fieldKey: const ValueKey('cedit-phone'),
          label: 'Phone',
          value: phone,
          keyboardType: TextInputType.phone,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')), LengthLimitingTextInputFormatter(15)],
          onChanged: (v) => setState(() => phone = v),
        ),
        AppTextField(label: 'Address', hint: 'Optional', value: address, onChanged: (v) => setState(() => address = v)),
        AppTextField(
          fieldKey: const ValueKey('cedit-gstin'),
          label: 'GSTIN',
          hint: 'Optional — for B2B bills to a clinic or hospital',
          value: gstin,
          error: gstin.trim().isEmpty || isValidGstin(gstin) ? null : 'Check the 15 characters',
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9A-Za-z]')), LengthLimitingTextInputFormatter(15)],
          onChanged: (v) => setState(() => gstin = v.toUpperCase()),
        ),
        AppTextField(label: 'Note', hint: 'Optional — e.g. pays on the 1st', value: note, onChanged: (v) => setState(() => note = v)),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Credit limit', style: AppType.label),
            const SizedBox(height: 6),
            SegmentedPills<bool>(
              semanticLabel: 'Credit limit',
              options: [
                PillOption(false, 'Default (${limitLabel(null, defaultLimit).replaceAll(' (default)', '')})'),
                const PillOption(true, 'Own limit'),
              ],
              selected: ownLimit,
              onChanged: canManage ? (v) => setState(() => ownLimit = v) : null,
            ),
            if (ownLimit) ...[
              const SizedBox(height: AppSpace.sm),
              SizedBox(
                width: 200,
                child: AppTextField(
                  fieldKey: const ValueKey('cedit-limit'),
                  label: 'Limit (₹, empty = no limit)',
                  value: limit,
                  enabled: canManage,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(9)],
                  onChanged: (v) => setState(() => limit = v),
                ),
              ),
            ],
            if (!canManage) Text('Only the Owner can change credit limits.', style: AppType.caption),
          ],
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(key: const ValueKey('cedit-save'), label: saving ? 'Saving…' : 'Save', onPressed: saving ? null : _save),
          ],
        ),
      ],
    );
  }
}
