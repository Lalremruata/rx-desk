import 'package:drift/drift.dart';

import '../app_database.dart';

part 'settings_dao.g.dart';

/// Key → JSON value store behind `settingsProvider` (SPEC §7).
@DriftAccessor(tables: [SettingsEntries])
class SettingsDao extends DatabaseAccessor<AppDatabase> with _$SettingsDaoMixin {
  SettingsDao(super.attachedDatabase);

  Future<Map<String, String>> readAll() async {
    final rows = await select(settingsEntries).get();
    return {for (final r in rows) r.key: r.value};
  }

  /// Writes every entry in one transaction.
  Future<void> writeAll(Map<String, String> values) => transaction(() async {
        for (final e in values.entries) {
          await into(settingsEntries).insertOnConflictUpdate(SettingsEntriesCompanion.insert(key: e.key, value: e.value));
        }
      });

  Future<void> clear() => delete(settingsEntries).go();
}
