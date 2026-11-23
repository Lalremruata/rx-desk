import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../core/cash/cash_rules.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/money/paise.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/widgets/widgets.dart';
import '../../invoices/application/invoice_pdf.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/guarded_actions.dart';
import '../../staff/application/session.dart';
import '../../staff/presentation/access_denied.dart';
import '../application/cash_providers.dart';
import '../application/cash_summary_pdf.dart';

final _money = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];
const _moneyKb = TextInputType.numberWithOptions(decimal: true);

void _toastError(WidgetRef ref, Object e) => ref.read(toastsProvider.notifier).show(
      switch (e) {
        CashException(:final message) => message,
        PermissionDenied() => '$e',
        _ => 'Something went wrong: $e',
      },
      warn: true,
    );

/// Day close (SPEC §4.14): what should be in the cash drawer, paid-outs,
/// counting and closing the day.
class CashScreen extends ConsumerWidget {
  const CashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(canProvider(Permission.cashClose))) return const AccessDenied(permission: Permission.cashClose);
    final date = ref.watch(cashDateProvider);
    return PageScroll(
      children: [
        _DayBar(date: date),
        ResponsiveGrid(
          minTileWidth: 380,
          equalHeight: false,
          children: [_DrawerCard(date: date), _CloseCard(key: ValueKey('close-$date'), date: date)],
        ),
        _PaidOutCard(date: date),
      ],
    );
  }
}

class _DayBar extends ConsumerWidget {
  const _DayBar({required this.date});

  final String date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = dateKey(ref.watch(nowProvider)());
    final closing = ref.watch(cashClosingProvider(date)).value;
    final changed = ref.watch(changedSinceClosingProvider(date));
    final ctl = ref.read(cashDateProvider.notifier);
    return Wrap(
      spacing: AppSpace.md,
      runSpacing: AppSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton(tooltip: 'Previous day', onPressed: () => ctl.shift(-1), icon: const Icon(Icons.chevron_left_rounded)),
        Text(formatDate(DateTime.parse(date)), key: const ValueKey('cash-date'), style: AppType.cardTitle),
        IconButton(
          tooltip: 'Next day',
          onPressed: date.compareTo(today) >= 0 ? null : () => ctl.shift(1),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
        if (date != today) AppButton.secondary(label: 'Today', height: 36, onPressed: () => ctl.set(today)),
        if (closing == null)
          const StatusBadge('Not closed yet', tone: StatusTone.warning)
        else
          StatusBadge(
            'Closed ${formatTime(DateTime.fromMillisecondsSinceEpoch(closing.closedAt).toLocal())}',
            tone: StatusTone.success,
          ),
        if (changed)
          const StatusBadge('Changed since closing — close again', tone: StatusTone.danger),
      ],
    );
  }
}

/// Opening + cash in − cash out = expected in the drawer.
class _DrawerCard extends ConsumerWidget {
  const _DrawerCard({required this.date});

  final String date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ref.watch(cashFiguresProvider(date)).value ?? const CashFigures();
    final opening = ref.watch(_openingProvider(date));
    final carried = ref.watch(carriedOpeningProvider(date));
    final closing = ref.watch(cashClosingProvider(date)).value;

    Widget row(String label, Paise v, {String sign = '', String? help, Key? key}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: AppType.body),
                    if (help != null) Text(help, style: AppType.caption),
                  ],
                ),
              ),
              Text('$sign${formatInr(v)}', key: key, style: AppType.bodyStrong.copyWith(fontFeatures: AppType.tabular)),
            ],
          ),
        );

    final openingHelp = closing != null
        ? 'As used when the day was closed'
        : carried != null
        ? 'Counted at the last closing, less what was handed over'
        : 'Type it in the next card — there is no earlier closing';
    return AppCard(
      title: 'Cash in the drawer',
      subtitle: const Text('What RxDesk expects, from the day’s cash bills, refunds and payments'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row('Opening cash', opening ?? Paise.zero, help: openingHelp, key: const ValueKey('cash-opening-value')),
          row('Cash sales', f.cashSales, sign: '+ ', help: 'Cash bills, not cancelled'),
          row('Cash refunds', f.cashRefunds, sign: '− ', help: 'Returns refunded in cash'),
          row('Dues collected in cash', f.duesCollected, sign: '+ ', help: 'Customer payments, incl. paid now on credit bills'),
          row('Paid to stockists in cash', f.stockistsPaid, sign: '− ', help: 'Incl. paid on delivery'),
          row('Paid out', f.paidOuts, sign: '− ', help: 'Shop expenses below'),
          const Divider(height: 24),
          Row(
            children: [
              Expanded(child: Text('Expected in drawer', style: AppType.cardTitle)),
              Text(formatInr(f.expected(opening ?? Paise.zero)), key: const ValueKey('cash-expected'), style: AppType.total),
            ],
          ),
        ],
      ),
    );
  }
}

/// The opening cash on screen: the closing's own, else carried over, else
/// what the user typed (first closing ever).
class _TypedOpening extends Notifier<String> {
  _TypedOpening(this.date);

  final String date;

  @override
  String build() => '';

  void set(String v) => state = v;
}

final _typedOpeningProvider = NotifierProvider.autoDispose.family<_TypedOpening, String, String>(_TypedOpening.new);

final _openingProvider = Provider.autoDispose.family<Paise?, String>((ref, date) {
  final closing = ref.watch(cashClosingProvider(date)).value;
  if (closing != null) return Paise(closing.openingPaise);
  final carried = ref.watch(carriedOpeningProvider(date));
  if (carried != null) return carried;
  return Paise.tryParse(ref.watch(_typedOpeningProvider(date)));
});

class _CloseCard extends ConsumerStatefulWidget {
  const _CloseCard({super.key, required this.date});

  final String date;

  @override
  ConsumerState<_CloseCard> createState() => _CloseCardState();
}

class _CloseCardState extends ConsumerState<_CloseCard> {
  String counted = '', handed = '', note = '', coins = '';
  final Map<int, String> notes = {};
  bool byNotes = false;
  bool prefilled = false;
  bool saving = false;
  Map<String, String> errors = const {};

  Paise? get _fromNotes => countedFromNotes(
        {for (final d in noteDenominations) d: int.tryParse(notes[d] ?? '') ?? 0},
        coins: Paise.tryParse(coins) ?? Paise.zero,
      );

  Paise? get _counted => byNotes ? _fromNotes : Paise.tryParse(counted);

  Future<void> _close(CashFigures f, Paise? opening, bool alreadyClosed) async {
    final c = _counted;
    final h = handed.trim().isEmpty ? Paise.zero : Paise.tryParse(handed);
    final e = {
      if (opening == null) 'opening': 'Opening cash, e.g. 2000',
      if (c == null) 'counted': 'Cash counted, e.g. 4520',
      if (h == null) 'handed': 'Amount',
      if (c != null && h != null && h.value > c.value) 'handed': 'More than was counted',
    };
    setState(() => errors = e);
    if (e.isNotEmpty) return;
    setState(() => saving = true);
    try {
      final saved = await ref.read(guardedActionsProvider).closeDay(
            date: widget.date,
            opening: opening!,
            counted: c!,
            handedOver: h!,
            note: note,
            alreadyClosed: alreadyClosed,
          );
      final d = Paise(saved.differencePaise);
      ref.read(toastsProvider.notifier).show(
            'Day closed · expected ${formatInr(Paise(saved.expectedPaise))} · counted ${formatInr(c)}'
            '${d.value == 0 ? ' · exact' : d.isNegative ? ' · ${formatInr(d.abs())} short' : ' · ${formatInr(d)} over'}',
            warn: d.value != 0,
          );
    } on Object catch (e) {
      _toastError(ref, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _print(CashClosing closing) async {
    try {
      final db = ref.read(appDatabaseProvider);
      final staff = closing.staffId == null ? null : await db.staffDao.byId(closing.staffId!);
      final paidOuts = ref.read(cashPaidOutsProvider(widget.date)).value ?? const [];
      final s = ref.read(settingsProvider);
      final bytes = await buildCashSummaryPdf(
        storeName: s.name,
        closing: closing,
        paidOuts: paidOuts,
        closedBy: staff?.name ?? ref.read(sessionProvider)?.name ?? '—',
        fonts: await InvoiceFonts.load(),
        accentArgb: colorFromHex(s.accent).toARGB32(),
      );
      // dynamicLayout: false — see InvoicePrinter (macOS deadlock).
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'Day close ${widget.date}', dynamicLayout: false);
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('Printing failed: $e', warn: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = widget.date;
    final f = ref.watch(cashFiguresProvider(date)).value ?? const CashFigures();
    final closing = ref.watch(cashClosingProvider(date)).value;
    final carried = ref.watch(carriedOpeningProvider(date));
    final opening = ref.watch(_openingProvider(date));
    if (closing != null && !prefilled) {
      // Start from what was counted, so closing again only needs the change.
      prefilled = true;
      counted = Paise(closing.countedPaise).toInputString();
      handed = closing.handedOverPaise == 0 ? '' : Paise(closing.handedOverPaise).toInputString();
      note = closing.note;
    }
    final expected = f.expected(opening ?? Paise.zero);
    final c = _counted;
    final diff = c == null ? null : Paise(c.value - expected.value);
    final h = handed.trim().isEmpty ? Paise.zero : Paise.tryParse(handed);
    final isOwner = ref.watch(sessionProvider)?.role == StaffRole.owner;
    final today = dateKey(ref.watch(nowProvider)());
    final canClose = closing == null || date == today || isOwner;

    return AppCard(
      title: 'Count and close',
      subtitle: const Text('Count the drawer, then close the day'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (closing == null && carried == null) ...[
            AppTextField(
              fieldKey: const ValueKey('cash-opening'),
              label: 'Opening cash (₹)',
              hint: 'In the drawer this morning',
              value: ref.watch(_typedOpeningProvider(date)),
              error: errors['opening'],
              keyboardType: _moneyKb,
              inputFormatters: _money,
              onChanged: (v) => ref.read(_typedOpeningProvider(date).notifier).set(v),
            ),
            const SizedBox(height: AppSpace.md),
          ],
          ToggleRow(
            key: const ValueKey('cash-by-notes'),
            label: 'Count by notes',
            help: '₹500 × 4, ₹100 × 12 … plus coins',
            value: byNotes,
            onChanged: (v) => setState(() => byNotes = v),
          ),
          const SizedBox(height: AppSpace.sm),
          if (byNotes)
            FieldGrid(
              minColumnWidth: 110,
              gap: AppSpace.md,
              children: [
                for (final d in noteDenominations)
                  AppTextField(
                    fieldKey: ValueKey('cash-note-$d'),
                    label: '₹$d ×',
                    hint: '0',
                    value: notes[d] ?? '',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (v) => setState(() => notes[d] = v),
                  ),
                AppTextField(
                  fieldKey: const ValueKey('cash-coins'),
                  label: 'Coins (₹)',
                  hint: '0',
                  value: coins,
                  keyboardType: _moneyKb,
                  inputFormatters: _money,
                  onChanged: (v) => setState(() => coins = v),
                ),
              ],
            )
          else
            AppTextField(
              fieldKey: const ValueKey('cash-counted'),
              label: 'Cash counted (₹)',
              hint: '0.00',
              value: counted,
              error: errors['counted'],
              keyboardType: _moneyKb,
              inputFormatters: _money,
              onChanged: (v) => setState(() => counted = v),
            ),
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              Expanded(child: Text(byNotes ? 'Counted ${c == null ? '—' : formatInr(c)}' : 'Difference', style: AppType.bodyStrong)),
              if (diff != null)
                StatusBadge(
                  diff.value == 0 ? 'Exact' : diff.isNegative ? '${formatInr(diff.abs())} short' : '${formatInr(diff)} over',
                  key: const ValueKey('cash-diff'),
                  tone: diff.value == 0 ? StatusTone.success : StatusTone.warning,
                ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          FieldGrid(
            minColumnWidth: 160,
            gap: AppSpace.md,
            children: [
              AppTextField(
                fieldKey: const ValueKey('cash-handed'),
                label: 'Handed over (₹)',
                hint: '0.00',
                helper: c != null && h != null ? 'Opening tomorrow ${formatInr(openingFrom(counted: c, handedOver: h))}' : 'To the bank / the Owner',
                value: handed,
                error: errors['handed'],
                keyboardType: _moneyKb,
                inputFormatters: _money,
                onChanged: (v) => setState(() => handed = v),
              ),
              AppTextField(label: 'Note', hint: 'e.g. ₹50 short — change given twice', value: note, onChanged: (v) => setState(() => note = v)),
            ],
          ),
          const SizedBox(height: AppSpace.lg),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              if (closing != null)
                AppButton.secondary(
                  key: const ValueKey('cash-print'),
                  label: 'Print summary',
                  icon: Icons.print_outlined,
                  onPressed: () => _print(closing),
                ),
              AppButton(
                key: const ValueKey('cash-close'),
                label: saving ? 'Closing…' : closing == null ? 'Close the day' : 'Close again',
                icon: Icons.lock_clock_outlined,
                onPressed: saving || !canClose ? null : () => _close(f, opening, closing != null),
              ),
            ],
          ),
          if (!canClose) ...[
            const SizedBox(height: 6),
            Text('Only the Owner can close a past day again.', style: AppType.caption, textAlign: TextAlign.right),
          ],
        ],
      ),
    );
  }
}

class _PaidOutCard extends ConsumerWidget {
  const _PaidOutCard({required this.date});

  final String date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(cashPaidOutsProvider(date)).value ?? const <CashPaidOut>[];
    final isOwner = ref.watch(sessionProvider)?.role == StaffRole.owner;
    return AppCard(
      title: 'Paid out',
      subtitle: const Text('Cash taken from the drawer for shop expenses'),
      trailing: AppButton.secondary(
        key: const ValueKey('cash-add-paidout'),
        label: 'Record paid out',
        icon: Icons.add_rounded,
        height: 36,
        onPressed: () => showAppDialog<void>(context, builder: (_) => _PaidOutDialog(date: date)),
      ),
      child: list.isEmpty
          ? Text('Nothing paid out on this day.', style: AppType.small.copyWith(color: AppColors.textSecondary))
          : Column(
              children: [
                for (final p in list)
                  Container(
                    key: ValueKey('paidout-${p.id}'),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.divider))),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 56,
                          child: Text(formatTime(DateTime.fromMillisecondsSinceEpoch(p.createdAt).toLocal()), style: AppType.caption),
                        ),
                        Expanded(
                          child: Text(
                            p.status == 'void' ? '${p.note} — void: ${p.voidReason ?? ''}' : p.note,
                            style: p.status == 'void' ? AppType.small.copyWith(color: AppColors.textMuted, decoration: TextDecoration.lineThrough) : AppType.body,
                          ),
                        ),
                        Text(formatInr(Paise(p.amountPaise)), style: AppType.bodyStrong),
                        if (isOwner && p.status == 'active')
                          IconButton(
                            tooltip: 'Void this paid-out',
                            icon: const Icon(Icons.block_rounded, size: 18, color: AppColors.textMuted),
                            onPressed: () => showAppDialog<void>(context, maxWidth: 420, builder: (_) => _VoidPaidOutDialog(paidOut: p)),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _PaidOutDialog extends ConsumerStatefulWidget {
  const _PaidOutDialog({required this.date});

  final String date;

  @override
  ConsumerState<_PaidOutDialog> createState() => _PaidOutDialogState();
}

class _PaidOutDialogState extends ConsumerState<_PaidOutDialog> {
  String amount = '', note = '';
  Map<String, String> errors = const {};

  Future<void> _save() async {
    final a = Paise.tryParse(amount);
    final e = {
      if (a == null || a.value <= 0) 'amount': 'Amount, e.g. 120',
      if (note.trim().isEmpty) 'note': 'What it was for',
    };
    setState(() => errors = e);
    if (e.isNotEmpty) return;
    try {
      await ref.read(guardedActionsProvider).addPaidOut(date: widget.date, amount: a!, note: note);
      ref.read(toastsProvider.notifier).show('Paid out ${formatInr(a)} · ${note.trim()}');
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      _toastError(ref, e);
    }
  }

  @override
  Widget build(BuildContext context) => AppDialogPanel(
        semanticLabel: 'Record paid out',
        children: [
          Text('Record paid out', style: AppType.dialogTitle),
          AppTextField(
            fieldKey: const ValueKey('paidout-amount'),
            label: 'Amount (₹)',
            hint: '0.00',
            value: amount,
            error: errors['amount'],
            autofocus: true,
            keyboardType: _moneyKb,
            inputFormatters: _money,
            onChanged: (v) => setState(() => amount = v),
          ),
          AppTextField(
            fieldKey: const ValueKey('paidout-note'),
            label: 'What for',
            hint: 'e.g. Tea, auto fare, cleaning',
            value: note,
            error: errors['note'],
            onChanged: (v) => setState(() => note = v),
            onSubmitted: (_) => _save(),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpace.gap10,
            children: [
              AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
              AppButton(key: const ValueKey('paidout-save'), label: 'Save', onPressed: _save),
            ],
          ),
        ],
      );
}

class _VoidPaidOutDialog extends ConsumerStatefulWidget {
  const _VoidPaidOutDialog({required this.paidOut});

  final CashPaidOut paidOut;

  @override
  ConsumerState<_VoidPaidOutDialog> createState() => _VoidPaidOutDialogState();
}

class _VoidPaidOutDialogState extends ConsumerState<_VoidPaidOutDialog> {
  String reason = '';
  String? error;

  Future<void> _save() async {
    if (reason.trim().isEmpty) {
      setState(() => error = 'Say why');
      return;
    }
    try {
      await ref.read(guardedActionsProvider).voidPaidOut(widget.paidOut.id, reason: reason);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      _toastError(ref, e);
    }
  }

  @override
  Widget build(BuildContext context) => AppDialogPanel(
        semanticLabel: 'Void paid-out',
        children: [
          Text('Void this paid-out?', style: AppType.dialogTitle),
          Text('${widget.paidOut.note} · ${formatInr(Paise(widget.paidOut.amountPaise))}. It stays listed, marked void.', style: AppType.small),
          AppTextField(label: 'Reason', hint: 'e.g. Entered twice', value: reason, error: error, autofocus: true, onChanged: (v) => setState(() => reason = v)),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpace.gap10,
            children: [
              AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
              AppButton(label: 'Void', onPressed: _save),
            ],
          ),
        ],
      );
}
