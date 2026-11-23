import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money/gst.dart';
import '../../../core/money/paise.dart';
import '../../../core/sales/bill_rules.dart';
import '../../../core/sales/credit_rules.dart';
import '../../../core/tax/gstin.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../customers/application/customers_providers.dart';
import '../../settings/application/settings_providers.dart';
import '../application/bill_controller.dart';
import '../application/bill_state.dart';

/// Right column: customer, doctor, discount, totals, payment, Save & print.
class BillDetails extends ConsumerWidget {
  const BillDetails({super.key, required this.customerFocus, required this.onSave});

  final FocusNode customerFocus;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bill = ref.watch(billControllerProvider);
    final ctl = ref.read(billControllerProvider.notifier);
    final t = ref.watch(billTotalsProvider);
    final s = ref.watch(settingsProvider);
    final chips = ref.watch(discountChipsProvider);
    final next = ref.watch(nextInvoiceNumberProvider).value ?? '';
    final p = context.palette;

    final needRx = s.requireDoctorForRx && bill.hasRx;
    final docMissing = needRx && bill.doctor.trim().isEmpty;
    final danger = StatusTone.danger.colors.fg;
    final credit = bill.isCredit;
    final nameMissing = credit && bill.customer.trim().isEmpty;
    final phoneMissing = credit && bill.phone.trim().isEmpty;

    Widget totalRow(String label, String value, {bool strong = false, Key? key}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(child: Text(label, style: AppType.small.copyWith(color: strong ? AppColors.text : AppColors.textSecondary))),
              Text(value, key: key, style: (strong ? AppType.bodyStrong : AppType.small).copyWith(fontFeatures: AppType.tabular)),
            ],
          ),
        );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Semantics(header: true, child: Text('Bill details', style: AppType.cardTitle))),
              if (next.isNotEmpty)
                Text(next, key: const ValueKey('next-invoice-no'), style: AppType.mono.copyWith(color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: AppSpace.lg),
          AppTextField(
            key: const ValueKey('bill-customer'),
            label: credit ? 'Customer — required for credit' : 'Customer',
            labelColor: nameMissing ? danger : null,
            borderColor: nameMissing ? StatusTone.danger.colors.icon : null,
            hint: 'Walk-in',
            value: bill.customer,
            focusNode: customerFocus,
            textCapitalization: TextCapitalization.words,
            onChanged: ctl.setCustomer,
          ),
          const SizedBox(height: AppSpace.md),
          AppTextField(
            key: const ValueKey('bill-phone'),
            label: credit ? 'Phone — required for credit' : 'Phone',
            labelColor: phoneMissing ? danger : null,
            borderColor: phoneMissing ? StatusTone.danger.colors.icon : null,
            hint: credit ? 'Mobile number' : 'Optional',
            value: bill.phone,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')), LengthLimitingTextInputFormatter(15)],
            onChanged: ctl.setPhone,
          ),
          if (s.gstRegistered) ...[
            const SizedBox(height: AppSpace.md),
            _BuyerGstin(storeGstin: s.gstin),
          ],
          const SizedBox(height: AppSpace.md),
          AppTextField(
            key: const ValueKey('bill-doctor'),
            label: needRx ? 'Prescribing doctor — required (Schedule H item in bill)' : 'Prescribing doctor',
            labelColor: docMissing ? danger : null,
            borderColor: docMissing ? StatusTone.danger.colors.icon : null,
            hint: 'Dr. name / Reg. no.',
            value: bill.doctor,
            textCapitalization: TextCapitalization.words,
            onChanged: ctl.setDoctor,
          ),
          const SizedBox(height: AppSpace.lg),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSpace.md,
            runSpacing: AppSpace.sm,
            children: [
              Text('Discount', style: AppType.label),
              SegmentedPills<int>(
                semanticLabel: 'Discount',
                options: [for (final d in chips) PillOption(d, '$d%')],
                // None highlighted while a typed discount is in use.
                selected: bill.discountCustom ? -1 : (chips.contains(bill.discountPct) ? bill.discountPct : 0),
                onChanged: ctl.setDiscount,
              ),
              // Its own pill so it wraps under the chips in a narrow column.
              SegmentedPills<bool>(
                key: const ValueKey('discount-custom'),
                semanticLabel: 'Custom discount',
                options: const [PillOption(true, 'Custom', tooltip: 'Type a % or a ₹ amount')],
                selected: bill.discountCustom,
                onChanged: (_) => ctl.useCustomDiscount(),
              ),
            ],
          ),
          if (bill.discountCustom) ...[
            const SizedBox(height: AppSpace.md),
            _ManualDiscount(subtotal: t.subtotal, maxPct: s.maxDiscountPct),
          ],
          const SizedBox(height: AppSpace.lg),
          Container(
            padding: const EdgeInsets.all(AppSpace.gap14),
            decoration: const BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.all(Radius.circular(12))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                totalRow('Items / units', '${t.items} / ${t.units}'),
                totalRow('Subtotal (MRP)', formatInr(t.subtotal)),
                totalRow('Discount', '− ${formatInr(t.discount)}'),
                if (s.gstRegistered) ...[
                  totalRow('Taxable value', formatInr(t.taxable)),
                  totalRow('CGST + SGST (incl.)', formatInr(t.tax)),
                ],
                if (!t.roundOff.isZero) totalRow('Round off', '${t.roundOff.isNegative ? '−' : '+'} ${formatInr(t.roundOff.abs())}'),
                const Divider(height: 20),
                Row(
                  children: [
                    Expanded(child: Text('Net payable', style: AppType.bodyStrong)),
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: t.total.value.toDouble()),
                      duration: context.motion(const Duration(milliseconds: 250)),
                      builder: (context, v, _) => Text(
                        formatInr(Paise(v.round())),
                        key: const ValueKey('net-payable'),
                        style: AppType.total.copyWith(fontFeatures: AppType.tabular),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          Semantics(
            container: true,
            label: 'Payment mode',
            child: Row(
              children: [
                for (final (i, m) in billPaymentModes.indexed) ...[
                  if (i > 0) const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Semantics(
                      selected: bill.payment == m,
                      button: true,
                      child: Pressable(
                        child: Material(
                          color: bill.payment == m ? p.accentSoft : AppColors.surface,
                          shape: RoundedRectangleBorder(
                            borderRadius: AppRadius.controlAll,
                            side: BorderSide(color: bill.payment == m ? p.accent : AppColors.chipBorder, width: bill.payment == m ? 1.5 : 1),
                          ),
                          child: InkWell(
                            key: ValueKey('pay-$m'),
                            borderRadius: AppRadius.controlAll,
                            onTap: () => ctl.setPayment(m),
                            child: SizedBox(
                              height: AppSizes.controlMin,
                              child: Center(
                                child: Text(m, style: AppType.bodyStrong.copyWith(color: bill.payment == m ? p.accent : AppColors.body)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (credit) ...[
            const SizedBox(height: AppSpace.md),
            _CreditPanel(total: t.total),
          ],
          const SizedBox(height: AppSpace.md),
          Pressable(
            enabled: !bill.isEmpty && !bill.saving,
            child: SizedBox(
              height: AppSizes.primaryCta,
              child: FilledButton(
                key: const ValueKey('save-bill'),
                onPressed: bill.isEmpty || bill.saving ? null : onSave,
                style: FilledButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: AppColors.onAccent,
                  disabledBackgroundColor: p.accent.withValues(alpha: 0.45),
                  disabledForegroundColor: AppColors.onAccent,
                  shape: const RoundedRectangleBorder(borderRadius: AppRadius.controlAll),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        bill.saving ? 'Saving…' : 'Save & print invoice',
                        overflow: TextOverflow.ellipsis,
                        style: AppType.bodyStrong.copyWith(color: AppColors.onAccent, fontSize: 15),
                      ),
                    ),
                    const SizedBox(width: AppSpace.gap10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.onAccent.withValues(alpha: 0.5)),
                        borderRadius: AppRadius.tinyAll,
                      ),
                      child: Text('F10', style: AppType.badge.copyWith(color: AppColors.onAccent)),
                    ),
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

/// Credit bill (SPEC §4.10): who owes what, paid now, and what this adds.
class _CreditPanel extends ConsumerWidget {
  const _CreditPanel({required this.total});

  final Paise total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bill = ref.watch(billControllerProvider);
    final ctl = ref.read(billControllerProvider.notifier);
    final defaultLimit = ref.watch(settingsProvider.select((s) => s.defaultCreditLimitPaise));
    final phone = bill.phone.trim();
    final info = phone.isEmpty ? null : ref.watch(creditInfoProvider(phone)).value;
    final dues = info?.dues ?? 0;
    final limit = effectiveCreditLimit(customerLimit: info?.customer.creditLimitPaise, defaultLimit: defaultLimit);
    final paid = bill.paidNowPaise;
    final adding = total - paid;
    final paidBad = bill.paidNow.trim().isNotEmpty && (Paise.tryParse(bill.paidNow) == null || paid.value >= total.value);
    final over = creditOverBy(dues: dues, adding: adding.value, limit: limit);

    final who = phone.isEmpty
        ? 'Enter the phone to see what they owe'
        : info == null
            ? 'New customer — no dues yet'
            : '${info.customer.name} · owes ${formatInr(Paise(dues))}';
    return Container(
      key: const ValueKey('credit-panel'),
      padding: const EdgeInsets.all(AppSpace.gap14),
      decoration: BoxDecoration(
        color: StatusTone.info.colors.bg,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(who, key: const ValueKey('credit-who'), style: AppType.smallStrong),
          Text(
            limit == 0 ? 'No credit limit' : 'Credit limit ${formatInr(Paise(limit))}',
            style: AppType.caption,
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              SizedBox(
                width: 140,
                child: AppTextField(
                  fieldKey: const ValueKey('bill-paid-now'),
                  label: 'Paid now (₹)',
                  hint: '0',
                  value: bill.paidNow,
                  error: paidBad ? 'Less than ${formatInr(total)}' : null,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  onChanged: ctl.setPaidNow,
                  // Enter would drop focus out of the billing shortcuts.
                  onSubmitted: (_) => ctl.requestSearchFocus(),
                ),
              ),
              if (paid.value > 0)
                SegmentedPills<String>(
                  semanticLabel: 'Paid now by',
                  options: [for (final m in collectModes) PillOption(m, m)],
                  selected: bill.paidNowMode,
                  onChanged: ctl.setPaidNowMode,
                ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            'Adds ${formatInr(adding.isNegative ? Paise.zero : adding)} to dues'
            '${phone.isEmpty ? '' : ' → ${formatInr(Paise(dues) + (adding.isNegative ? Paise.zero : adding))}'}',
            key: const ValueKey('credit-adds'),
            style: AppType.bodyStrong.copyWith(fontFeatures: AppType.tabular),
          ),
          if (over > 0)
            Text(
              '${formatInr(Paise(over))} over the limit — the Owner must allow it',
              key: const ValueKey('credit-over'),
              style: AppType.smallStrong.copyWith(color: StatusTone.danger.colors.fg),
            ),
        ],
      ),
    );
  }
}

/// Manual discount (SPEC §4.6): a whole % or a flat ₹ amount, with the
/// limit or the problem shown underneath.
class _ManualDiscount extends ConsumerWidget {
  const _ManualDiscount({required this.subtotal, required this.maxPct});

  final Paise subtotal;
  final int maxPct;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bill = ref.watch(billControllerProvider);
    final ctl = ref.read(billControllerProvider.notifier);
    final problem = ref.watch(billDiscountProblemProvider);
    final flat = bill.discountKind == DiscountKind.flat;

    String helper() {
      if (!flat) return 'Whole number, up to $maxPct%';
      final max = 'max ${formatInr(maxFlatDiscount(subtotal, maxPct))}';
      final d = bill.discount;
      if (d is! FlatDiscount || d.amount.value <= 0 || subtotal.value <= 0) return 'Up to $maxPct% of the MRP · $max';
      final tenths = divRound(d.amount.value * 1000, subtotal.value);
      return '= ${tenths ~/ 10}.${tenths % 10}% of the MRP · $max';
    }

    return Wrap(
      spacing: AppSpace.md,
      runSpacing: AppSpace.sm,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 22),
          child: SegmentedPills<DiscountKind>(
            semanticLabel: 'Discount as',
            options: const [
              PillOption(DiscountKind.percent, '%', tooltip: 'Percentage of the MRP'),
              PillOption(DiscountKind.flat, '₹', tooltip: 'Flat rupees off the bill'),
            ],
            selected: bill.discountKind,
            onChanged: ctl.setDiscountKind,
          ),
        ),
        SizedBox(
          width: 220,
          child: AppTextField(
            key: ValueKey('discount-input-${bill.discountKind.name}'),
            fieldKey: const ValueKey('discount-input'),
            label: flat ? 'Discount (₹)' : 'Discount (%)',
            hint: flat ? 'e.g. 25' : 'e.g. 7',
            value: bill.discountInput,
            error: problem,
            helper: problem == null ? helper() : null,
            keyboardType: flat ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(flat ? r'[0-9.]' : r'[0-9]'))],
            autofocus: true,
            onChanged: ctl.setDiscountInput,
            // Enter would drop focus out of the billing shortcuts.
            onSubmitted: (_) => ctl.requestSearchFocus(),
          ),
        ),
      ],
    );
  }
}

/// B2B bills (SPEC §4.15): the buyer's GSTIN, checked as it's typed; a known
/// customer's GSTIN can be filled in with one tap.
class _BuyerGstin extends ConsumerWidget {
  const _BuyerGstin({required this.storeGstin});

  final String storeGstin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bill = ref.watch(billControllerProvider);
    final ctl = ref.read(billControllerProvider.notifier);
    final g = bill.buyerGstin;
    final phone = bill.phone.trim();
    final known = phone.isEmpty ? null : ref.watch(creditInfoProvider(phone)).value?.customer.gstin;
    final problem = g.length < 15 && g.isNotEmpty ? null : buyerGstinProblem(g, storeGstin: storeGstin, gstRegistered: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        AppTextField(
          key: const ValueKey('bill-gstin'),
          fieldKey: const ValueKey('bill-gstin-field'),
          label: 'Buyer GSTIN (B2B, optional)',
          hint: 'For a clinic or hospital',
          value: g,
          error: problem,
          helper: problem == null && g.length == 15 ? 'B2B tax invoice · place of supply ${placeOfSupplyLabel(gstinState(g))}' : null,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9A-Za-z]')), LengthLimitingTextInputFormatter(15)],
          onChanged: ctl.setBuyerGstin,
        ),
        if (g.isEmpty && known != null && known.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('bill-gstin-use'),
              onPressed: () => ctl.setBuyerGstin(known),
              child: Text('Use $known'),
            ),
          ),
      ],
    );
  }
}
