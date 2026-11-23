import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/db_provider.dart';
import '../../../core/money/paise.dart';
import '../../../core/tax/gstin.dart';
import '../../../core/tax/gstr1.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/save_file.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/settings_providers.dart';
import '../application/gstr1_export.dart';

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/// GSTR-1 tables for a month ('YYYY-MM'), from the bills' snapshots.
final gstr1ReportProvider = FutureProvider.autoDispose.family<Gstr1Report, String>((ref, month) async {
  final y = int.parse(month.substring(0, 4)), m = int.parse(month.substring(5, 7));
  final last = DateTime(y, m + 1, 0).day;
  final (docs, items) = await ref.watch(appDatabaseProvider).reportsDao.gstr1Source('$month-01', '$month-${last.toString().padLeft(2, '0')}');
  return buildGstr1(docs: docs, items: items, storeGstin: ref.watch(settingsProvider.select((s) => s.gstin)));
});

Future<void> showGstr1Dialog(BuildContext context) =>
    showAppDialog<void>(context, maxWidth: 560, topPadding: 80, builder: (_) => const Gstr1Dialog());

/// GSTR-1 (month) (SPEC §4.15): what goes in each table, and the Excel
/// workbook to hand to the accountant.
class Gstr1Dialog extends ConsumerStatefulWidget {
  const Gstr1Dialog({super.key});

  @override
  ConsumerState<Gstr1Dialog> createState() => _Gstr1DialogState();
}

class _Gstr1DialogState extends ConsumerState<Gstr1Dialog> {
  // Returns are filed for the month gone by.
  late DateTime month = () {
    final now = ref.read(nowProvider)();
    return DateTime(now.year, now.month - 1);
  }();
  bool busy = false;

  String get _key => '${month.year}-${month.month.toString().padLeft(2, '0')}';

  Future<void> _export(Gstr1Report r) async {
    setState(() => busy = true);
    try {
      final s = ref.read(settingsProvider);
      final bytes = buildGstr1Xlsx(r, storeName: s.name, gstin: s.gstin, period: '${_months[month.month - 1]} ${month.year}', uqc: s.gstUqc);
      final path = await saveBytesAs('GSTR-1-$_key.xlsx', bytes);
      if (path != null) ref.read(toastsProvider.notifier).show('${path.split(RegExp(r'[/\\]')).last} saved');
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('Export failed: $e', warn: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final report = ref.watch(gstr1ReportProvider(_key));
    final now = ref.watch(nowProvider)();
    final latest = DateTime(now.year, now.month);
    final noGstin = !s.gstRegistered || !isValidGstin(s.gstin);

    Widget row(String label, String value, {bool strong = false, Key? key}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Expanded(child: Text(label, style: strong ? AppType.bodyStrong : AppType.body)),
              Text(value, key: key, style: AppType.bodyStrong.copyWith(fontFeatures: AppType.tabular)),
            ],
          ),
        );
    String rs(int p) => formatInr(Paise(p));

    return AppDialogPanel(
      semanticLabel: 'GSTR-1',
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('GSTR-1 (month)', style: AppType.dialogTitle),
                  const SizedBox(height: 4),
                  Text(
                    'Outward supplies from your bills, laid out like the GST offline tool. Check it with your accountant before filing.',
                    style: AppType.small.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            IconButton(tooltip: 'Close', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded, size: 20)),
          ],
        ),
        Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              onPressed: () => setState(() => month = DateTime(month.year, month.month - 1)),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Text('${_months[month.month - 1]} ${month.year}', key: const ValueKey('gstr1-month'), style: AppType.cardTitle),
            IconButton(
              tooltip: 'Next month',
              onPressed: !month.isBefore(latest) ? null : () => setState(() => month = DateTime(month.year, month.month + 1)),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
        if (noGstin)
          Text(
            'Turn on GST registered and enter your GSTIN in Settings first.',
            style: AppType.small.copyWith(color: StatusTone.warning.colors.fg),
          ),
        switch (report) {
          AsyncData(value: final r) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                row('B2B invoices (b2b) · ${_n(r.b2b.map((x) => x.doc.id).toSet().length, 'bill')}', rs(r.b2bTaxable), key: const ValueKey('gstr1-b2b')),
                row('B2C, net of returns (b2cs) · ${_n(r.b2cs.length, 'rate')}', rs(r.b2csTaxable), key: const ValueKey('gstr1-b2cs')),
                row('Credit notes to registered buyers (cdnr)', '− ${rs(r.cdnrTaxable)}'),
                const Divider(height: 16),
                row('Net taxable value', rs(r.netTaxable), strong: true, key: const ValueKey('gstr1-net')),
                row('HSN summary · ${_n(r.hsnB2b.length + r.hsnB2c.length, 'row')}', rs(r.hsnTaxable)),
                for (final d in r.docs) row('${d.nature}: ${d.from} – ${d.to}', '${d.total}${d.cancelled > 0 ? ' · ${d.cancelled} cancelled' : ''}'),
                const SizedBox(height: AppSpace.md),
                Text('Place of supply for B2C: ${r.storeState.isEmpty ? '—' : placeOfSupplyLabel(r.storeState)} · UQC ${s.gstUqc}', style: AppType.caption),
                const SizedBox(height: AppSpace.md),
                Align(
                  alignment: Alignment.centerRight,
                  child: AppButton(
                    key: const ValueKey('gstr1-export'),
                    label: busy ? 'Exporting…' : 'Export Excel',
                    icon: Icons.download_rounded,
                    onPressed: busy || noGstin ? null : () => _export(r),
                  ),
                ),
              ],
            ),
          AsyncError(:final error) => Text('Couldn’t build the return: $error', style: AppType.small),
          _ => const Padding(padding: EdgeInsets.all(AppSpace.lg), child: Center(child: CircularProgressIndicator())),
        },
      ],
    );
  }
}

String _n(int n, String word) => '$n ${n == 1 ? word : '${word}s'}';
