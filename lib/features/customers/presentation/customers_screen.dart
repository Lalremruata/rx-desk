import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/daos/customers_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/money/paise.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/save_file.dart';
import '../../../core/widgets/widgets.dart';
import '../../sales_register/application/register_export.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/session.dart';
import '../application/customers_providers.dart';
import '../data/customers_repository.dart';
import 'customer_dialogs.dart';

/// Customers — who owes what (SPEC §5.10).
class CustomersScreen extends ConsumerWidget {
  const CustomersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const PageScroll(
      gap: AppSpace.gap14,
      children: [_Kpis(), _Toolbar(), _List()],
    );
  }
}

class _Kpis extends ConsumerWidget {
  const _Kpis();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(customerDuesTotalsProvider).value?.$1 ?? const CustomerDuesTotals();
    final ctl = ref.read(customerListControllerProvider.notifier);
    return ResponsiveGrid(
      children: [
        KpiTile(
          key: const ValueKey('kpi-cdues'),
          label: 'Customer dues',
          value: formatInr(t.owed, decimals: 0),
          caption: 'Owed to the store on credit bills →',
          icon: Icons.account_balance_wallet_outlined,
          tone: StatusTone.info,
          onTap: () => ctl.setWithDues(true),
        ),
        KpiTile(
          key: const ValueKey('kpi-cwith'),
          label: 'Customers with dues',
          value: formatCount(t.customers),
          caption: 'Largest dues first',
          icon: Icons.people_alt_outlined,
        ),
        KpiTile(
          key: const ValueKey('kpi-c90'),
          label: 'Unpaid 90+ days',
          value: formatInr(t.over90, decimals: 0),
          caption: t.over90Customers == 0 ? 'Nothing that old' : '${formatCount(t.over90Customers)} ${t.over90Customers == 1 ? 'customer' : 'customers'}',
          captionTone: t.over90Customers > 0 ? StatusTone.danger : null,
          icon: Icons.hourglass_bottom_rounded,
          tone: StatusTone.danger,
        ),
      ],
    );
  }
}

class _Toolbar extends ConsumerStatefulWidget {
  const _Toolbar();

  @override
  ConsumerState<_Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends ConsumerState<_Toolbar> {
  Timer? _debounce;
  bool _exporting = false;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final repo = ref.read(customersRepositoryProvider);
      final rows = <CustomerDues>[];
      for (var p = 1;; p++) {
        final page = await repo.duesPage(withDues: true, page: p, pageSize: 500);
        rows.addAll(page.rows);
        if (rows.length >= page.total || page.rows.isEmpty) break;
      }
      final now = ref.read(nowProvider)();
      final today = dateKey(now);
      double r(Paise p) => p.value / 100; // export display only
      final table = ExportTable(
        title: 'Customer dues',
        headerBlock: [ref.read(settingsProvider).name, 'Customer dues as of ${formatDate(now)}'],
        columns: const ['Customer', 'Phone', 'Dues ₹', 'Open bills', 'Oldest unpaid', 'Age', 'Last payment'],
        rows: [
          for (final d in rows)
            [d.name, d.phone, r(d.balance), d.openBills, d.oldestOpen ?? '', d.agingOn(today).label, d.lastPayment ?? ''],
        ],
        totals: ['Total', '', r(rows.fold(Paise.zero, (a, d) => a + d.balance)), '', '', '', ''],
      );
      final name = 'customer-dues-$today';
      String? path;
      try {
        path = await saveBytesAs('$name.xlsx', await buildXlsxInIsolate(table, sheetName: 'Customer dues'));
      } on Object {
        path = await saveTextAs('$name.csv', buildCsv(table));
      }
      if (path != null) ref.read(toastsProvider.notifier).show('${path.split(RegExp(r'[/\\]')).last} saved · ${rows.length} customers');
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('Export failed: $e', warn: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(customerListControllerProvider);
    final ctl = ref.read(customerListControllerProvider.notifier);
    final canCollect = ref.watch(canProvider(Permission.collectPayments));
    return Wrap(
      spacing: AppSpace.md,
      runSpacing: AppSpace.md,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 240, maxWidth: 380),
          child: AppTextField(
            fieldKey: const ValueKey('customers-search'),
            label: '',
            hint: 'Find by name or phone…',
            prefixIcon: Icons.search_rounded,
            value: st.search,
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 150), () => ctl.setSearch(v));
            },
          ),
        ),
        SegmentedPills<bool>(
          key: const ValueKey('customers-filter'),
          semanticLabel: 'Show',
          options: const [PillOption(true, 'With dues'), PillOption(false, 'All customers')],
          selected: st.withDues,
          onChanged: ctl.setWithDues,
        ),
        AppButton(
          key: const ValueKey('customers-add'),
          label: 'Add customer',
          icon: Icons.person_add_alt_1_outlined,
          onPressed: canCollect ? () => showCustomerEdit(context) : null,
        ),
        AppButton.secondary(
          label: _exporting ? 'Exporting…' : 'Export dues',
          icon: Icons.download_rounded,
          onPressed: _exporting ? null : _export,
        ),
      ],
    );
  }
}

class _List extends ConsumerWidget {
  const _List();

  static const _columns = [
    GridColumn('Customer', flex: 2, minWidth: 200),
    GridColumn.fixed('Phone', 130),
    GridColumn.fixed('Dues', 120, alignEnd: true),
    GridColumn.fixed('Oldest unpaid', 140),
    GridColumn.fixed('Limit', 120, alignEnd: true),
    GridColumn.fixed('Last payment', 120),
    GridColumn.fixed('Action', 300, alignEnd: true),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(customerListControllerProvider);
    final ctl = ref.read(customerListControllerProvider.notifier);
    final async = ref.watch(customerDuesPageProvider);
    final page = async.value;
    final rows = page?.rows ?? const <CustomerDues>[];
    final today = dateKey(ref.watch(nowProvider)());
    final canCollect = ref.watch(canProvider(Permission.collectPayments));
    final defaultLimit = ref.watch(settingsProvider.select((s) => s.defaultCreditLimitPaise));

    return AppCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (async.isLoading && page == null) const LinearProgressIndicator(minHeight: 2),
          DataGrid(
            semanticLabel: 'Customers',
            columns: _columns,
            rowCount: rows.length,
            empty: page == null
                ? const SizedBox(height: 120)
                : EmptyState(
                    icon: Icons.people_alt_outlined,
                    title: st.withDues ? 'Nobody owes anything' : 'No customers yet',
                    message: st.withDues
                        ? 'Bills paid by “Credit” put the amount on the customer’s dues.'
                        : 'Customers are added when you bill them with a phone number.',
                  ),
            onRowTap: (i) => showCustomerStatement(context, customerId: rows[i].customerId),
            cells: (context, i) {
              final d = rows[i];
              final age = d.agingOn(today);
              final owes = d.balance.value > 0;
              return [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(d.name, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis),
                    if (d.advance.value > 0 && d.balance.value <= 0)
                      Text('${formatInr(d.advance)} advance', style: AppType.caption.copyWith(color: StatusTone.info.colors.fg))
                    else if (d.openBills > 0)
                      Text('${formatCount(d.openBills)} open ${d.openBills == 1 ? 'bill' : 'bills'}', style: AppType.caption),
                  ],
                ),
                Text(d.phone, style: AppType.small.copyWith(color: AppColors.body)),
                Text(
                  owes ? formatInr(d.balance) : '—',
                  style: AppType.bodyStrong.copyWith(fontFeatures: AppType.tabular, color: owes ? null : AppColors.textMuted),
                ),
                d.oldestOpen == null
                    ? Text('—', style: AppType.small.copyWith(color: AppColors.textMuted))
                    : StatusBadge.tag(age.label, tone: agingTone(age)),
                Text(limitLabel(d.creditLimit, defaultLimit), style: AppType.small.copyWith(color: AppColors.body)),
                Text(d.lastPayment == null ? '—' : dayLabel(d.lastPayment!), style: AppType.small.copyWith(color: AppColors.body)),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    AppButton.secondary(
                      key: ValueKey('cpay-${d.customerId}'),
                      label: 'Receive',
                      height: 36,
                      onPressed: canCollect && owes ? () => showCustomerPayment(context, customerId: d.customerId) : null,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    AppButton.secondary(
                      key: ValueKey('cstatement-${d.customerId}'),
                      label: 'Statement',
                      height: 36,
                      onPressed: () => showCustomerStatement(context, customerId: d.customerId),
                    ),
                  ],
                ),
              ];
            },
          ),
          const Divider(),
          Pager(
            page: st.page,
            pageSize: st.pageSize,
            totalRows: page?.total ?? 0,
            onPage: ctl.setPage,
            onPageSize: ctl.setPageSize,
            trailingNote: page == null ? null : 'computed in ${page.ms.toStringAsFixed(1)} ms',
          ),
        ],
      ),
    );
  }
}
