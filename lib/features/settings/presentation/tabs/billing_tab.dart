import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/fy/fy.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../billing/data/sales_repository.dart';
import '../../application/settings_providers.dart';
import '../settings_widgets.dart';

/// Next credit-note number for a format (display only).
final _nextCreditNoteProvider = FutureProvider.autoDispose.family<String, InvoiceNumberFormat>(
  (ref, fmt) => ref.watch(salesRepositoryProvider).peekNextNumber(fmt),
);

class BillingTab extends ConsumerWidget {
  const BillingTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = watchEditing(ref);
    final errors = ref.watch(settingsDraftErrorsProvider);
    final cnFmt = s.numbering.creditNotes(s.creditNotePrefix);
    final nextCn = ref.watch(_nextCreditNoteProvider(cnFmt)).value ?? cnFmt.format(fy: fyLabel(DateTime.now()), seq: 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'Tax',
          children: [
            SettingToggle(
              label: 'GST registered',
              help: 'Off: bills print as “Bill of supply” without a GST breakup.',
              value: (x) => x.gstRegistered,
              onChanged: (x, v) => x.copyWith(gstRegistered: v),
            ),
            SettingToggle(
              label: 'MRP includes GST',
              help: 'Medicine MRP is tax-inclusive, so tax is worked out from it.',
              value: (x) => x.mrpIncludesGst,
              onChanged: (x, v) => x,
              locked: true,
            ),
            SettingToggle(
              label: 'Round total to the nearest rupee',
              help: 'Adds a round-off line to the bill.',
              value: (x) => x.roundOff,
              onChanged: (x, v) => x.copyWith(roundOff: v),
            ),
            SettingRow(
              label: 'UQC for GST returns',
              help: 'Unit code in the GSTR-1 HSN table (NOS, BOX, BTL, STR…). Ask your CA.',
              child: SizedBox(
                width: 140,
                child: AppTextField(
                  key: const ValueKey('setting-uqc'),
                  label: 'UQC',
                  value: s.gstUqc,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[A-Za-z]')), LengthLimitingTextInputFormatter(3)],
                  onChanged: (v) => editSettings(ref, (x) => x.copyWith(gstUqc: v.toUpperCase())),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        SettingsSection(
          title: 'Billing rules',
          children: [
            SettingRow(
              label: 'Highest discount allowed',
              help: 'Discount buttons above this are hidden at the counter.',
              child: SegmentedPills<int>(
                semanticLabel: 'Highest discount allowed',
                options: const [PillOption(0, '0%'), PillOption(5, '5%'), PillOption(10, '10%'), PillOption(15, '15%'), PillOption(20, '20%')],
                selected: s.maxDiscountPct,
                onChanged: (v) => editSettings(ref, (x) => x.copyWith(maxDiscountPct: v)),
              ),
            ),
            SettingRow(
              label: 'Default payment mode',
              help: 'Selected when a new bill starts.',
              child: SegmentedPills<String>(
                semanticLabel: 'Default payment mode',
                options: const [PillOption('Cash', 'Cash'), PillOption('UPI', 'UPI'), PillOption('Card', 'Card')],
                selected: s.defaultPayment,
                onChanged: (v) => editSettings(ref, (x) => x.copyWith(defaultPayment: v)),
              ),
            ),
            SettingToggle(
              label: 'Ask for the doctor on Schedule H / H1 items',
              help: 'The bill cannot be saved until the doctor is entered.',
              value: (x) => x.requireDoctorForRx,
              onChanged: (x, v) => x.copyWith(requireDoctorForRx: v),
            ),
            SettingToggle(
              label: 'Block expired batches',
              help: 'Selling expired medicine is not allowed, so this stays on.',
              value: (x) => x.blockExpired,
              onChanged: (x, v) => x,
              locked: true,
            ),
            SettingToggle(
              label: 'Allow billing more than stock',
              help: 'Off is safer: stock can never go below zero.',
              value: (x) => x.allowNegativeStock,
              onChanged: (x, v) => x.copyWith(allowNegativeStock: v),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        SettingsSection(
          title: 'Returns',
          subtitle: 'A return issues a credit note against the bill. Schedule H / H1 medicines can’t be returned.',
          children: [
            SettingRow(
              label: 'Credit note prefix',
              help: 'Own numbering series, sharing the invoice separator, digits and year. Next: $nextCn',
              child: SizedBox(
                width: 160,
                child: AppTextField(
                  key: const ValueKey('credit-note-prefix'),
                  label: '',
                  hint: 'CN',
                  value: s.creditNotePrefix,
                  maxLength: 8,
                  error: errors['creditNotePrefix'],
                  onChanged: (v) =>
                      editSettings(ref, (x) => x.copyWith(creditNotePrefix: v.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), ''))),
                ),
              ),
            ),
            SettingRow(
              label: 'Accept returns within',
              help: 'Older bills can only be returned by the Owner.',
              child: SegmentedPills<int>(
                semanticLabel: 'Return window',
                options: const [
                  PillOption(7, '7 days'),
                  PillOption(15, '15 days'),
                  PillOption(30, '30 days'),
                  PillOption(90, '90 days'),
                  PillOption(0, 'No limit'),
                ],
                selected: s.returnWindowDays,
                onChanged: (v) => editSettings(ref, (x) => x.copyWith(returnWindowDays: v)),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        SettingsSection(
          title: 'Customer credit (udhaar)',
          subtitle: 'Bills paid by “Credit” go on the customer’s dues. A customer’s own limit (Customers screen) wins over this.',
          children: [
            SettingRow(
              label: 'Default credit limit',
              help: 'Whole rupees. Leave empty for no limit. Going over needs the Owner.',
              child: SizedBox(
                width: 160,
                child: AppTextField(
                  key: const ValueKey('default-credit-limit'),
                  label: '',
                  hint: 'No limit',
                  value: s.defaultCreditLimitPaise == 0 ? '' : '${s.defaultCreditLimitPaise ~/ 100}',
                  error: errors['defaultCreditLimitPaise'],
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(9)],
                  prefixIcon: Icons.currency_rupee_rounded,
                  onChanged: (v) => editSettings(ref, (x) => x.copyWith(defaultCreditLimitPaise: (int.tryParse(v) ?? 0) * 100)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
