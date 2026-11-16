import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/db/models.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../inventory/data/inventory_repository.dart';
import '../../application/settings_providers.dart';
import '../settings_widgets.dart';

/// Inventory counts for a given (expiry window, dead-stock days).
final _countsProvider = FutureProvider.autoDispose.family<InventoryCounts, (int, int)>(
  (ref, k) => ref.watch(inventoryRepositoryProvider).counts(expiryWindowMonths: k.$1, deadStockDays: k.$2),
);

class InventoryTab extends ConsumerWidget {
  const InventoryTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = watchEditing(ref);
    final counts = ref.watch(_countsProvider((s.expiryWindowMonths, s.deadStockDays))).value;
    final errors = ref.watch(settingsDraftErrorsProvider);
    return SettingsSection(
      title: 'Stock alerts',
      subtitle: 'Controls the dashboard cards and inventory views.',
      children: [
        SettingRow(
          label: 'Warn about expiry within',
          help: counts == null ? null : 'Currently ${formatCount(counts.expiring)} medicines fall in this window.',
          child: SegmentedPills<int>(
            semanticLabel: 'Expiry window',
            options: const [PillOption(1, '30 days'), PillOption(2, '60 days'), PillOption(3, '90 days'), PillOption(6, '180 days')],
            selected: s.expiryWindowMonths,
            onChanged: (v) => editSettings(ref, (x) => x.copyWith(expiryWindowMonths: v)),
          ),
        ),
        SettingRow(
          label: 'Mark as dead stock after',
          help: counts == null ? 'Days without a sale.' : 'Days without a sale. Currently ${formatCount(counts.dead)} medicines.',
          child: SegmentedPills<int>(
            semanticLabel: 'Dead stock after',
            options: const [PillOption(60, '60 days'), PillOption(90, '90 days'), PillOption(180, '180 days')],
            selected: s.deadStockDays,
            onChanged: (v) => editSettings(ref, (x) => x.copyWith(deadStockDays: v)),
          ),
        ),
        SizedBox(
          width: 320,
          child: AppTextField(
            key: const ValueKey('default-reorder'),
            label: 'Default reorder level for new medicines',
            value: '${s.defaultReorderLevel}',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 5,
            onChanged: (v) => editSettings(ref, (x) => x.copyWith(defaultReorderLevel: int.tryParse(v) ?? 0)),
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        SettingToggle(
          label: 'Suggest earliest expiry first (FEFO)',
          help: 'The batch that expires first is picked by default at billing.',
          value: (x) => x.suggestFefo,
          onChanged: (x, v) => x.copyWith(suggestFefo: v),
        ),
        SettingToggle(
          label: 'Show low-stock count on the menu',
          help: 'The amber number next to Inventory.',
          value: (x) => x.showLowStockBadge,
          onChanged: (x, v) => x.copyWith(showLowStockBadge: v),
        ),
        const SizedBox(height: AppSpace.sm),
        SettingRow(
          label: 'Stockist lead time (days)',
          help: errors['leadTime'] ??
              'How long a stockist takes to supply — average and maximum. Used for the reorder level, minimum and buffer '
                  'stock in the monthly consumption register.',
          child: Wrap(
            spacing: AppSpace.md,
            children: [
              SizedBox(
                width: 110,
                child: AppTextField(
                  key: const ValueKey('avg-lead'),
                  label: 'Average',
                  value: '${s.avgLeadTimeDays}',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                  onChanged: (v) => editSettings(ref, (x) => x.copyWith(avgLeadTimeDays: int.tryParse(v) ?? 0)),
                ),
              ),
              SizedBox(
                width: 110,
                child: AppTextField(
                  key: const ValueKey('max-lead'),
                  label: 'Maximum',
                  value: '${s.maxLeadTimeDays}',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                  onChanged: (v) => editSettings(ref, (x) => x.copyWith(maxLeadTimeDays: int.tryParse(v) ?? 0)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
