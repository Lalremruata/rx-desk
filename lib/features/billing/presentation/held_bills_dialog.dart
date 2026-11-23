import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/db_provider.dart';
import '../../../core/money/paise.dart';
import '../../../core/sales/held_bill.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/widgets/widgets.dart';
import '../application/bill_controller.dart';

/// Held bills (SPEC §5.2): recall one onto the counter or discard it.
Future<void> showHeldBillsDialog(BuildContext context) =>
    showAppDialog<void>(context, maxWidth: 560, topPadding: 90, builder: (_) => const HeldBillsDialog());

class HeldBillsDialog extends ConsumerWidget {
  const HeldBillsDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final held = ref.watch(heldBillsProvider).value ?? const [];
    final bill = ref.read(billControllerProvider.notifier);
    final open = !ref.watch(billControllerProvider.select((s) => s.isEmpty));
    final today = ref.watch(nowProvider)();

    String when(int ms) {
      final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
      final sameDay = d.year == today.year && d.month == today.month && d.day == today.day;
      return sameDay ? 'held ${formatTime(d)}' : 'held ${formatDate(d)} ${formatTime(d)}';
    }

    return AppDialogPanel(
      semanticLabel: 'Held bills',
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Held bills', style: AppType.dialogTitle),
                  const SizedBox(height: 4),
                  Text(
                    open
                        ? 'Recalling puts the bill on the counter; the bill open now is held in its place.'
                        : 'Up to $maxHeldBills bills. Stock isn’t kept aside — it is checked again when you recall.',
                    style: AppType.small.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            IconButton(tooltip: 'Close', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded, size: 20)),
          ],
        ),
        if (held.isEmpty)
          const EmptyState(title: 'No held bills', message: 'Press F6 (or Hold bill) to park the bill on the counter and serve the next customer.')
        else
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final h in held)
                Container(
                  key: ValueKey('held-${h.id}'),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.divider))),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(h.label, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis),
                            Text(
                              '${h.itemCount} ${h.itemCount == 1 ? 'item' : 'items'} · ${formatInr(Paise(h.totalPaise))} · ${when(h.heldAt)}',
                              style: AppType.caption,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: ValueKey('held-discard-${h.id}'),
                        tooltip: 'Discard held bill',
                        icon: const Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.textMuted),
                        onPressed: () async {
                          final ok = await showConfirmDialog(
                            context,
                            title: 'Discard this held bill?',
                            message: '${h.label} · ${h.itemCount} items. Nothing was billed, so nothing else changes.',
                            confirmLabel: 'Discard',
                          );
                          if (ok) await bill.discardHeld(h.id);
                        },
                      ),
                      const SizedBox(width: 6),
                      AppButton(
                        key: ValueKey('held-recall-${h.id}'),
                        label: 'Recall',
                        height: 38,
                        onPressed: () async {
                          Navigator.of(context).pop();
                          await bill.recall(h.id);
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// "Hold bill" and "Held bills (N)" under the search box; shown when a bill
/// is open or bills are held (touch users have no F6).
class HoldBar extends ConsumerWidget {
  const HoldBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = !ref.watch(billControllerProvider.select((s) => s.isEmpty));
    final n = ref.watch(heldBillsProvider).value?.length ?? 0;
    if (!open && n == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: AppSpace.sm,
        runSpacing: AppSpace.sm,
        children: [
          if (open)
            AppButton.secondary(
              key: const ValueKey('hold-bill'),
              label: 'Hold bill (F6)',
              icon: Icons.pause_circle_outline_rounded,
              height: 36,
              onPressed: () => ref.read(billControllerProvider.notifier).hold(),
            ),
          if (n > 0)
            AppButton.secondary(
              key: const ValueKey('held-bills'),
              label: 'Held bills ($n)',
              icon: Icons.receipt_long_outlined,
              height: 36,
              onPressed: () => showHeldBillsDialog(context),
            ),
        ],
      ),
    );
  }
}
