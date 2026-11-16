import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/settings_providers.dart';

/// Debug-only `/_gallery` route: every shared widget from SPEC §8, live.
/// Sample data here is illustrative only.
class WidgetGalleryScreen extends ConsumerStatefulWidget {
  const WidgetGalleryScreen({super.key});

  @override
  ConsumerState<WidgetGalleryScreen> createState() => _WidgetGalleryScreenState();
}

class _SampleRow {
  const _SampleRow(this.name, this.salt, this.schedule, this.stock, this.reorder, this.mrp);

  final String name;
  final String salt;
  final String schedule;
  final int stock;
  final int reorder;
  final String mrp;
}

const _rows = [
  _SampleRow('Paracetamol 650', 'Paracetamol 650 mg', '', 240, 40, '₹30.50'),
  _SampleRow('Amoxicillin 500', 'Amoxicillin 500 mg', 'H', 18, 20, '₹96.00'),
  _SampleRow('Alprazolam 0.25', 'Alprazolam 0.25 mg', 'H1', 0, 10, '₹42.75'),
  _SampleRow('Cetirizine 10', 'Cetirizine 10 mg', '', 75, 30, '₹18.00'),
  _SampleRow('Pantoprazole 40', 'Pantoprazole 40 mg', 'H', 6, 25, '₹112.40'),
];

class _WidgetGalleryScreenState extends ConsumerState<WidgetGalleryScreen> {
  String _range = '7D';
  String _preset = 'today';
  bool _encrypt = true;
  bool _auto = false;
  String _sort = 'name';
  bool _asc = true;
  int _page = 5;
  int _pageSize = 50;
  int? _selected;
  int _replay = 0;

  List<_SampleRow> get _sorted {
    final r = [..._rows];
    int cmp(_SampleRow a, _SampleRow b) => switch (_sort) {
          'stock' => a.stock.compareTo(b.stock),
          _ => a.name.compareTo(b.name),
        };
    r.sort((a, b) => _asc ? cmp(a, b) : cmp(b, a));
    return r;
  }

  void _toast(String msg, {bool warn = false}) => ref.read(toastsProvider.notifier).show(msg, warn: warn);

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(accentProvider);
    final rows = _sorted;

    return PageScroll(
      key: ValueKey(_replay),
      children: [
        _Section(
          'Accent (Settings › Appearance)',
          child: Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              for (final e in AppColors.accentOptions.entries)
                _Swatch(
                  name: e.key,
                  color: e.value,
                  selected: e.value == accent,
                  onTap: () {
                    final s = ref.read(settingsProvider);
                    ref.read(settingsProvider.notifier).save(s.copyWith(accent: hexOf(e.value)));
                  },
                ),
            ],
          ),
        ),
        _Section(
          'AppButton',
          child: Wrap(
            spacing: AppSpace.gap10,
            runSpacing: AppSpace.gap10,
            children: [
              AppButton(label: 'New bill', icon: Icons.add_rounded, onPressed: () => _toast('New bill started')),
              AppButton.secondary(label: 'Export', icon: Icons.download_rounded, onPressed: () {}),
              AppButton(label: 'Restore', variant: AppButtonVariant.warning, onPressed: () {}),
              AppButton(label: 'Cancel bill', variant: AppButtonVariant.danger, onPressed: () {}),
              const AppButton(label: 'Disabled', onPressed: null),
              AppButton(
                label: 'Save & print invoice  F10',
                height: AppSizes.primaryCta,
                onPressed: () => _toast('INV/26-27/00412 saved · ₹1,234.00 · printing 1 copy'),
              ),
            ],
          ),
        ),
        _Section(
          'KpiTile',
          child: ResponsiveGrid(
            children: [
              const KpiTile(
                label: 'Today’s sales',
                value: '₹18,450',
                caption: '42 invoices · avg ₹439',
                icon: Icons.trending_up_rounded,
              ),
              const KpiTile(
                label: 'Stock value',
                value: '₹12,84,300',
                caption: '1,649 medicines at MRP',
                icon: Icons.inventory_2_outlined,
                tone: StatusTone.info,
              ),
              KpiTile(
                label: 'Low / out of stock',
                value: '37',
                caption: 'Review and reorder →',
                icon: Icons.warning_amber_rounded,
                tone: StatusTone.warning,
                captionTone: StatusTone.warning,
                onTap: () => _toast('Opens Inventory › Low stock'),
              ),
              KpiTile(
                label: 'Expiring ≤ 90 days',
                value: '12',
                caption: 'Medicines with near-expiry batches →',
                icon: Icons.schedule_rounded,
                tone: StatusTone.danger,
                captionTone: StatusTone.danger,
                onTap: () => _toast('Opens Inventory › Expiring'),
              ),
            ],
          ),
        ),
        _Section(
          'SegmentedPills · FilterChipRow',
          child: Wrap(
            spacing: AppSpace.xl,
            runSpacing: AppSpace.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedPills<String>(
                semanticLabel: 'Chart range',
                options: const [PillOption('7D', '7D'), PillOption('30D', '30D'), PillOption('12M', '12M')],
                selected: _range,
                onChanged: (v) => setState(() => _range = v),
              ),
              FilterChipRow<String>(
                semanticLabel: 'Date range',
                options: const [
                  PillOption('today', 'Today'),
                  PillOption('yesterday', 'Yesterday'),
                  PillOption('d7', 'Last 7 days'),
                  PillOption('month', 'This month'),
                  PillOption('lastmonth', 'Last month'),
                ],
                selected: _preset,
                onChanged: (v) => setState(() => _preset = v),
              ),
            ],
          ),
        ),
        _Section(
          'ToggleRow · AppSwitch',
          child: Column(
            children: [
              ToggleRow(
                label: 'Encrypt with password',
                help: 'Recommended for patient data',
                value: _encrypt,
                onChanged: (v) => setState(() => _encrypt = v),
              ),
              const SizedBox(height: AppSpace.sm),
              ToggleRow(
                label: 'Automatic backup',
                help: 'Runs on close and at first launch of the day',
                value: _auto,
                onChanged: (v) => setState(() => _auto = v),
              ),
              const SizedBox(height: AppSpace.sm),
              const ToggleRow(
                label: 'Block expired batches',
                help: 'Expired stock can never be sold',
                value: true,
                onChanged: null,
                locked: true,
              ),
            ],
          ),
        ),
        _Section(
          'StatusBadge · RxBadge · KeyHint · PulseDot',
          child: Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const StatusBadge('In stock', tone: StatusTone.success),
              const StatusBadge('Low stock', tone: StatusTone.warning),
              const StatusBadge('Out of stock', tone: StatusTone.danger),
              const StatusBadge('Dead stock', tone: StatusTone.dead),
              const StatusBadge('Manual', tone: StatusTone.info),
              const StatusBadge.tag('Sell first (FEFO)', tone: StatusTone.accent),
              const StatusBadge.tag('Near expiry', tone: StatusTone.warning),
              const StatusBadge.tag('Expired · return to supplier', tone: StatusTone.danger),
              const StatusBadge.tag('Sold out'),
              const StatusBadge.count('1,649', tone: StatusTone.accent),
              const StatusBadge.count('37'),
              const RxBadge('H'),
              const RxBadge('H1'),
              const RxBadge('X'),
              for (final k in const [
                ('F2', 'New bill'),
                ('F3', 'Search'),
                ('F4', 'Customer'),
                ('F8', 'Payment mode'),
                ('F10', 'Save & print'),
                ('Esc', 'Close list'),
              ])
                KeyHint(k.$1, label: k.$2),
              const KeyHint('↑'),
              const KeyHint('↓'),
              const KeyHint('Enter'),
              const PulseDot(semanticLabel: 'Working offline'),
            ],
          ),
        ),
        _Section(
          'StockBar',
          child: Column(
            children: [
              for (final r in _rows) ...[
                StockBar(
                  fraction: r.stock / 240,
                  level: r.stock == 0
                      ? StockLevel.out
                      : r.stock <= r.reorder
                          ? StockLevel.low
                          : StockLevel.ok,
                  trailing: '${r.stock}',
                ),
                const SizedBox(height: AppSpace.md),
              ],
            ],
          ),
        ),
        AppCard(
          padding: EdgeInsets.zero,
          clip: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpace.cardPad),
                child: Text('DataGrid · Pager · KeysetPager', style: AppType.cardTitle),
              ),
              DataGrid(
                semanticLabel: 'Sample inventory',
                columns: const [
                  GridColumn('Medicine', flex: 2.6, minWidth: 240, sortKey: 'name'),
                  GridColumn('Saleable stock', flex: 1.3, minWidth: 170, sortKey: 'stock'),
                  GridColumn.fixed('MRP', 92, alignEnd: true),
                  GridColumn.fixed('Status', 116),
                  GridColumn.fixed('Action', 104, alignEnd: true),
                ],
                rowCount: rows.length,
                sortKey: _sort,
                sortAscending: _asc,
                onSort: (k) => setState(() {
                  _asc = _sort == k ? !_asc : true;
                  _sort = k;
                }),
                selectedRow: _selected,
                onRowTap: (i) => setState(() => _selected = i),
                cells: (context, i) {
                  final r = rows[i];
                  final level = r.stock == 0
                      ? StockLevel.out
                      : r.stock <= r.reorder
                          ? StockLevel.low
                          : StockLevel.ok;
                  return [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(child: Text(r.name, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis)),
                            const SizedBox(width: 6),
                            RxBadge(r.schedule),
                          ],
                        ),
                        Text(r.salt, style: AppType.caption, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                    StockBar(fraction: r.stock / 240, level: level, trailing: '${r.stock}'),
                    Text(r.mrp, style: AppType.bodyStrong),
                    switch (level) {
                      StockLevel.out => const StatusBadge('Out of stock', tone: StatusTone.danger),
                      StockLevel.low => const StatusBadge('Low stock', tone: StatusTone.warning),
                      StockLevel.ok => const StatusBadge('In stock', tone: StatusTone.success),
                    },
                    AppButton.secondary(label: 'Receive', height: 36, onPressed: () => _toast('Receive ${r.name}')),
                  ];
                },
              ),
              const Divider(),
              Pager(
                page: _page,
                pageSize: _pageSize,
                totalRows: 1649,
                onPage: (p) => setState(() => _page = p),
                onPageSize: (s) => setState(() {
                  _pageSize = s;
                  _page = 1;
                }),
              ),
              const Divider(),
              KeysetPager(label: '30 bills · Today · Total ₹18,450.00', onOlder: () {}),
            ],
          ),
        ),
        _Section(
          'AppToast · ConfirmDialog · PageEnter',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppToast(text: 'Backup saved · rxdesk-backup-2026-11-09-1930.rxbak'),
              const SizedBox(height: AppSpace.sm),
              const AppToast(text: 'Only 3 left in batch AB1234', kind: ToastKind.warning),
              const SizedBox(height: AppSpace.lg),
              Wrap(
                spacing: AppSpace.gap10,
                runSpacing: AppSpace.gap10,
                children: [
                  AppButton.secondary(label: 'Show toast', onPressed: () => _toast('Settings saved')),
                  AppButton.secondary(
                    label: 'Queue 3 toasts',
                    onPressed: () {
                      _toast('New bill started');
                      _toast('Schedule H item in bill — enter the prescribing doctor', warn: true);
                      _toast('+25 received into batch PCM2611');
                    },
                  ),
                  AppButton.secondary(
                    label: 'Open confirm dialog',
                    onPressed: () async {
                      final ok = await showConfirmDialog(
                        context,
                        title: 'Restore this backup?',
                        message: 'rxdesk-backup-2026-11-08-2130.rxbak will replace the current medicines, '
                            'stock and invoices on this device. A safety copy of today’s data is saved first.',
                        confirmLabel: 'Restore',
                      );
                      _toast(ok ? 'Confirmed' : 'Cancelled', warn: !ok);
                    },
                  ),
                  AppButton.secondary(label: 'Replay page enter', onPressed: () => setState(() => _replay++)),
                ],
              ),
            ],
          ),
        ),
        const _Section(
          'EmptyState',
          child: EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No medicines match',
            message: 'Try a salt name or barcode, or clear the filters.',
          ),
        ),
        _Section('Type & colour tokens', child: _TokenSamples(accent: context.palette)),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => AppCard(title: title, child: child);
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.name, required this.color, required this.selected, required this.onTap});

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Accent $name',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.controlAll,
          child: Container(
            constraints: const BoxConstraints(minHeight: AppSizes.controlMin),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: AppRadius.controlAll,
              border: Border.all(color: selected ? color : AppColors.chipBorder, width: selected ? 2 : 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: AppSpace.sm),
                Text(name, style: AppType.smallStrong),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TokenSamples extends StatelessWidget {
  const _TokenSamples({required this.accent});

  final RxPalette accent;

  @override
  Widget build(BuildContext context) {
    Widget chip(String name, Color c) => Container(
          width: 120,
          padding: const EdgeInsets.all(AppSpace.sm),
          decoration: BoxDecoration(
            borderRadius: AppRadius.smallAll,
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: c,
                  borderRadius: AppRadius.tinyAll,
                  border: Border.all(color: AppColors.border),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(child: Text(name, style: AppType.caption, overflow: TextOverflow.ellipsis)),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Page title 26/700', style: AppType.pageTitle),
        Text('Card title 17/600', style: AppType.cardTitle),
        Text('₹12,84,300', style: AppType.kpi.copyWith(fontFeatures: AppType.tabular)),
        Text('Body Inter 14 — Paracetamol 650 mg · Strip of 15', style: AppType.body),
        Text('LABEL 12/600', style: AppType.label),
        Text('Caption 12/400', style: AppType.caption),
        const Text('INV/26-27/00412 · PCM2611', style: AppType.mono),
        const SizedBox(height: AppSpace.lg),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            chip('accent', accent.accent),
            chip('accentSoft', accent.accentSoft),
            chip('accentMuted', accent.accentMuted),
            chip('background', AppColors.background),
            chip('border', AppColors.border),
            chip('text', AppColors.text),
            chip('textSecondary', AppColors.textSecondary),
            for (final t in StatusTone.values.where((t) => t != StatusTone.accent)) chip(t.name, t.colors.fg),
            for (final e in AppColors.category.entries) chip(e.key, e.value),
          ],
        ),
      ],
    );
  }
}
