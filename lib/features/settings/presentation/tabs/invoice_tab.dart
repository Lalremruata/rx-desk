import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/fy/fy.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../billing/data/sales_repository.dart';
import '../../../invoices/presentation/invoice_settings_preview.dart';
import '../../application/app_settings.dart';
import '../../application/settings_providers.dart';
import '../settings_widgets.dart';

/// Next invoice number for a numbering format (display only).
final _nextNumberProvider = FutureProvider.autoDispose.family<String, InvoiceNumberFormat>(
  (ref, fmt) => ref.watch(salesRepositoryProvider).peekNextNumber(fmt),
);

class InvoiceTab extends ConsumerWidget {
  const InvoiceTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = watchEditing(ref);
    final errors = ref.watch(settingsDraftErrorsProvider);
    final fmt = s.numbering;
    final next = ref.watch(_nextNumberProvider(fmt)).value ?? fmt.format(fy: fyLabel(DateTime.now()), seq: 1);

    final form = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'Invoice numbering',
          subtitle: 'Applies to new bills. Numbers restart at 1 every financial year when the year is included.',
          children: [
            Wrap(
              spacing: AppSpace.lg,
              runSpacing: AppSpace.md,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                SizedBox(
                  width: 160,
                  child: AppTextField(
                    key: const ValueKey('invoice-prefix'),
                    label: 'Prefix',
                    hint: 'INV',
                    value: s.prefix,
                    maxLength: 8,
                    error: errors['prefix'],
                    onChanged: (v) => editSettings(ref, (x) => x.copyWith(prefix: v.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), ''))),
                  ),
                ),
                _Labeled(
                  label: 'Separator',
                  child: SegmentedPills<String>(
                    semanticLabel: 'Separator',
                    options: const [PillOption('/', '/'), PillOption('-', '–'), PillOption('none', 'None')],
                    selected: s.separator,
                    onChanged: (v) => editSettings(ref, (x) => x.copyWith(separator: v)),
                  ),
                ),
                _Labeled(
                  label: 'Digits',
                  child: SegmentedPills<int>(
                    semanticLabel: 'Digits',
                    options: const [PillOption(4, '4'), PillOption(5, '5'), PillOption(6, '6')],
                    selected: s.digits,
                    onChanged: (v) => editSettings(ref, (x) => x.copyWith(digits: v)),
                  ),
                ),
              ],
            ),
            SettingToggle(
              label: 'Include financial year',
              help: 'e.g. INV/26-27/00001 — numbering restarts every 1 April.',
              value: (x) => x.fyInNumber,
              onChanged: (x, v) => x.copyWith(fyInNumber: v),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(color: context.palette.accentSoft, borderRadius: const BorderRadius.all(Radius.circular(12))),
              child: Row(
                children: [
                  Expanded(child: Text('Next invoice number', style: AppType.smallStrong)),
                  Text(next, key: const ValueKey('next-number'), style: AppType.mono.copyWith(fontSize: 14, color: context.palette.accent)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        SettingsSection(
          title: 'Paper & printing',
          subtitle: 'Pick the printer you use at the counter.',
          children: [
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                for (final p in InvoicePaper.values)
                  _PaperOption(paper: p, selected: s.paper == p, onTap: () => editSettings(ref, (x) => x.copyWith(paper: p))),
              ],
            ),
            SettingRow(
              label: 'Copies per bill',
              child: SegmentedPills<int>(
                semanticLabel: 'Copies per bill',
                options: const [PillOption(1, '1'), PillOption(2, '2'), PillOption(3, '3')],
                selected: s.copies,
                onChanged: (v) => editSettings(ref, (x) => x.copyWith(copies: v)),
              ),
            ),
            SettingToggle(
              label: 'Print automatically on save',
              help: 'F10 saves the bill and sends it to the printer in one step.',
              value: (x) => x.autoPrint,
              onChanged: (x, v) => x.copyWith(autoPrint: v),
            ),
            const PrinterPicker(),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        SettingsSection(
          title: 'What the invoice shows',
          subtitle: 'Watch the preview update as you switch these.',
          children: [
            SettingToggle(label: 'Salt / composition under each item', help: 'Helps customers match generics.', value: (x) => x.showSalt, onChanged: (x, v) => x.copyWith(showSalt: v)),
            SettingToggle(label: 'Batch number', help: 'Hidden on thermal paper to save width.', value: (x) => x.showBatch, onChanged: (x, v) => x.copyWith(showBatch: v)),
            SettingToggle(label: 'Expiry date', help: 'Hidden on 58 mm paper.', value: (x) => x.showExpiry, onChanged: (x, v) => x.copyWith(showExpiry: v)),
            SettingToggle(label: 'HSN code column', help: 'Needed when you bill another business (B2B).', value: (x) => x.showHsn, onChanged: (x, v) => x.copyWith(showHsn: v)),
            SettingToggle(label: 'Prescribing doctor', help: 'Printed when the bill has one.', value: (x) => x.showDoctor, onChanged: (x, v) => x.copyWith(showDoctor: v)),
            SettingToggle(label: '“You saved” line', help: 'Shows the discount given against MRP.', value: (x) => x.showSaved, onChanged: (x, v) => x.copyWith(showSaved: v)),
            SettingToggle(label: 'UPI payment QR', help: 'Customers scan it to pay the bill amount.', value: (x) => x.showUpiQr, onChanged: (x, v) => x.copyWith(showUpiQr: v)),
            if (s.showUpiQr)
              AppTextField(
                key: const ValueKey('invoice-upi'),
                label: 'UPI ID for the payment QR',
                hint: 'yourshop@upi',
                value: s.upiId,
                onChanged: (v) => editSettings(ref, (x) => x.copyWith(upiId: v.trim())),
              ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        SettingsSection(
          title: 'Footer & signature',
          children: [
            AppTextField(
              key: const ValueKey('invoice-footer'),
              label: 'Footer note',
              value: s.footer,
              maxLines: 4,
              minLines: 3,
              maxLength: 240,
              helper: '${s.footer.length} / 240',
              onChanged: (v) => editSettings(ref, (x) => x.copyWith(footer: v)),
            ),
            AppTextField(
              key: const ValueKey('invoice-sign'),
              label: 'Signature label',
              hint: 'Registered Pharmacist',
              value: s.signatureLabel,
              onChanged: (v) => editSettings(ref, (x) => x.copyWith(signatureLabel: v)),
            ),
          ],
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 980) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [form, const SizedBox(height: AppSpace.lg), InvoiceSettingsPreview(settings: s)],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: form),
            const SizedBox(width: AppSpace.lg),
            Expanded(flex: 6, child: InvoiceSettingsPreview(settings: s)),
          ],
        );
      },
    );
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [Text(label, style: AppType.label), const SizedBox(height: 6), child],
      );
}

class _PaperOption extends StatelessWidget {
  const _PaperOption({required this.paper, required this.selected, required this.onTap});

  final InvoicePaper paper;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final w = switch (paper) {
      InvoicePaper.a4 => 34.0,
      InvoicePaper.a5 => 26.0,
      InvoicePaper.t80 => 16.0,
      InvoicePaper.t58 => 11.0,
    };
    return Semantics(
      button: true,
      selected: selected,
      label: '${paper.label}, ${paper.help}',
      excludeSemantics: true,
      child: Pressable(
        child: Material(
          color: selected ? p.accentSoft : AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            side: BorderSide(color: selected ? p.accent : AppColors.chipBorder, width: selected ? 1.5 : 1),
          ),
          child: InkWell(
            key: ValueKey('paper-${paper.code}'),
            onTap: onTap,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: SizedBox(
              width: 132,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 44,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Container(
                          width: w,
                          height: 42,
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: AppRadius.tinyAll,
                            border: Border.all(color: selected ? p.accent : AppColors.kbdBorder),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(paper.label, style: AppType.smallStrong),
                    Text(paper.help, style: AppType.caption),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
