import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/daos/settings_dao.dart';
import '../../../core/db/db_provider.dart';
import '../application/app_settings.dart';

part 'settings_repository.g.dart';

class SettingsRepository {
  SettingsRepository(this._dao);

  final SettingsDao _dao;

  /// Stored values merged over the defaults. Unknown keys are ignored and a
  /// corrupt value falls back to its default, so a bad row never blocks
  /// startup.
  Future<AppSettings> load() async {
    final stored = await _dao.readAll();
    final merged = const AppSettings().toJson();
    for (final e in stored.entries) {
      if (!merged.containsKey(e.key)) continue;
      try {
        final candidate = Map<String, dynamic>.of(merged)..[e.key] = jsonDecode(e.value);
        AppSettings.fromJson(candidate); // validates this key
        merged[e.key] = candidate[e.key];
      } on Object {
        // keep default
      }
    }
    return AppSettings.fromJson(merged);
  }

  Future<void> save(AppSettings s) =>
      _dao.writeAll({for (final e in s.toJson().entries) e.key: jsonEncode(e.value)});

  /// Copies a picked logo into the app data folder (SPEC §7.1) and returns
  /// the new path.
  Future<String> importLogo(String sourcePath) async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'branding'));
    await dir.create(recursive: true);
    final ext = p.extension(sourcePath).toLowerCase();
    final dest = p.join(dir.path, 'logo-${DateTime.now().millisecondsSinceEpoch}$ext');
    await File(sourcePath).copy(dest);
    return dest;
  }
}

@Riverpod(keepAlive: true)
SettingsRepository settingsRepository(Ref ref) => SettingsRepository(ref.watch(appDatabaseProvider).settingsDao);
