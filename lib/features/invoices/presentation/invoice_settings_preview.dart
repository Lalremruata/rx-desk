import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../core/db/db_provider.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../billing/application/bill_controller.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/presentation/settings_widgets.dart';
import '../application/invoice_document.dart';
import '../application/invoice_printer.dart';
import 'invoice_paper.dart';

/// Settings › Invoice: live preview of a sample bill rendered with the draft
/// settings, plus Test print (SPEC §5.7).
class InvoiceSettingsPreview extends ConsumerWidget {
  const InvoiceSettingsPreview({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final number = ref.watch(nextInvoiceNumberProvider).value ?? settings.numbering.format(fy: '26-27', seq: 1);
    final now = ref.watch(nowProvider)();
    final data = sampleInvoice(
      number: settings.numbering.format(fy: number.isEmpty ? '26-27' : _fyOf(number, settings), seq: _seqOf(number)),
      at: DateTime(now.year, now.month, now.day, 11, 42),
      gstRegistered: settings.gstRegistered,
      roundOff: settings.roundOff,
    );
    final doc = buildInvoiceDoc(data, settings);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('LIVE PREVIEW · ${settings.paper.label.toUpperCase()}', style: AppType.overline)),
            AppButton.secondary(
              key: const ValueKey('test-print'),
              label: 'Test print',
              icon: Icons.print_outlined,
              height: 40,
              onPressed: () async {
                try {
                  await ref.read(invoicePrinterProvider).printData(data, settings: settings);
                  ref.read(toastsProvider.notifier).show('Test page sent to the ${settings.paper.label} printer');
                } on Object catch (e) {
                  ref.read(toastsProvider.notifier).show('Printing failed: $e', warn: true);
                }
              },
            ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        Container(
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: const BoxDecoration(color: AppColors.track, borderRadius: AppRadius.cardAll),
          child: InvoicePaperView(key: const ValueKey('settings-preview'), doc: doc),
        ),
      ],
    );
  }

  static int _seqOf(String number) => int.tryParse(RegExp(r'(\d+)$').firstMatch(number)?.group(1) ?? '') ?? 1;
  static String _fyOf(String number, AppSettings s) => RegExp(r'\d{2}-\d{2}').firstMatch(number)?.group(0) ?? '26-27';
}

/// Default printer used by "Print automatically on save". Empty = show the
/// system print dialog each time.
final _printersProvider = FutureProvider.autoDispose<List<Printer>>((ref) async {
  try {
    return await ref.watch(invoicePrinterProvider).printers();
  } on Object {
    return const [];
  }
});

class PrinterPicker extends ConsumerWidget {
  const PrinterPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = watchEditing(ref);
    final printers = ref.watch(_printersProvider).value ?? const <Printer>[];
    final options = [
      const DropdownOption('', 'Ask each time (system dialog)'),
      for (final p in printers) DropdownOption(p.url, p.isDefault ? '${p.name} (system default)' : p.name),
      if (s.defaultPrinter.isNotEmpty && !printers.any((p) => p.url == s.defaultPrinter))
        DropdownOption(s.defaultPrinter, '${s.defaultPrinter} (not connected)'),
    ];
    return SettingRow(
      label: 'Counter printer',
      help: 'Used when printing automatically. Pick it once.',
      child: SizedBox(
        width: 280,
        child: AppDropdown<String>(
          semanticLabel: 'Counter printer',
          width: 280,
          value: s.defaultPrinter,
          options: options,
          onChanged: (v) => editSettings(ref, (x) => x.copyWith(defaultPrinter: v)),
        ),
      ),
    );
  }
}
