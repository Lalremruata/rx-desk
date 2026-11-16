import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/db_provider.dart';
import '../../../core/utils/expiry.dart';
import '../../billing/application/bill_controller.dart';
import '../../inventory/data/inventory_repository.dart';
import '../../settings/application/settings_providers.dart';

part 'shell_status.g.dart';

// Values shown by the shell chrome (nav badges, offline card, header).

/// Units in the current bill — Billing nav badge (hidden at 0).
@riverpod
int billUnits(Ref ref) => ref.watch(billControllerProvider.select((b) => b.units));

/// Low + out-of-stock medicines — Inventory nav badge; 0 (hidden) when the
/// `showLowStockBadge` setting is off.
@riverpod
Stream<int> inventoryAlertCount(Ref ref) {
  final s = ref.watch(settingsProvider);
  if (!s.showLowStockBadge) return Stream.value(0);
  return ref
      .watch(inventoryRepositoryProvider)
      .watchCounts(expiryWindowMonths: s.expiryWindowMonths, deadStockDays: s.deadStockDays)
      .map((c) => c.low);
}

/// Whether Settings has unsaved draft changes — amber dot on the nav item.
@riverpod
bool settingsDirty(Ref ref) => ref.watch(settingsChangesProvider).isNotEmpty;

/// Medicines stored on this device (offline card, Inventory subtitle).
@riverpod
Stream<int> storedMedicineCount(Ref ref) => ref.watch(inventoryRepositoryProvider).watchProductCount();

/// "Today, 07:30" / "Never" — offline card (from `backup_log`).
@riverpod
Stream<String> lastBackupLabel(Ref ref) {
  final now = ref.watch(nowProvider);
  return ref.watch(appDatabaseProvider).backupDao.watchHistory(limit: 1).map((h) {
    if (h.isEmpty) return 'Never';
    return backupWhen(h.first.createdAt, now());
  });
}

/// "Today, 07:30", "Yesterday, 21:30", "7 Nov, 21:30".
String backupWhen(int createdAt, DateTime now) {
  final at = DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true).toLocal();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(at.year, at.month, at.day)).inDays;
  final day = days <= 0 ? 'Today' : days == 1 ? 'Yesterday' : '${at.day} ${monthName(at.month)}';
  return '$day, ${formatTime(at)}';
}
