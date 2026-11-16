import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../../core/db/app_database.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/db/migrations.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import 'backup_format.dart';

part 'backup_service.g.dart';

/// Replaces the live database with restored bytes and reconnects the app.
/// The bootstrap provides the real implementation.
abstract interface class DatabaseSwapper {
  Future<void> replaceWith(Uint8List dbBytes);
}

@Riverpod(keepAlive: true)
DatabaseSwapper databaseSwapper(Ref ref) => throw StateError('databaseSwapper must be overridden');

class PreparedBackup {
  const PreparedBackup({required this.fileName, required this.bytes, required this.manifest});
  final String fileName;
  final Uint8List bytes;
  final BackupManifest manifest;
}

/// Backup & restore (SPEC §5.6). Heavy work (hashing, encryption, zip) runs
/// in a background isolate.
class BackupService {
  BackupService(this._db, this._now, this._settings, this._swapper, {this.iterations = pbkdf2Iterations});

  final AppDatabase _db;
  final DateTime Function() _now;
  final AppSettings Function() _settings;
  final DatabaseSwapper Function() _swapper;

  static const int keepAuto = 30;

  /// PBKDF2 rounds (lower only in tests).
  final int iterations;

  /// Default folder: Documents/RxDesk/Backups (or the folder in settings).
  Future<String> backupFolder() async {
    final custom = _settings().backupFolder;
    final dir = custom.isNotEmpty ? custom : p.join((await getApplicationDocumentsDirectory()).path, 'RxDesk', 'Backups');
    await Directory(dir).create(recursive: true);
    return dir;
  }

  Future<BackupCounts> _counts() async {
    Future<int> c(String t) async => (await _db.customSelect('SELECT COUNT(*) AS c FROM $t').getSingle()).read<int>('c');
    return BackupCounts(products: await c('products'), batches: await c('batches'), invoices: await c('invoices'), items: await c('invoice_items'));
  }

  /// Consistent snapshot of the running DB (`VACUUM INTO`), packed and
  /// optionally encrypted. [onProgress] gets 0–1.
  Future<PreparedBackup> prepare({String? password, void Function(double)? onProgress}) async {
    onProgress?.call(0.05);
    final tmp = await Directory.systemTemp.createTemp('rxdesk-snap');
    final snap = p.join(tmp.path, 'snap.sqlite');
    try {
      await _db.customStatement('VACUUM INTO ?', [snap]);
      onProgress?.call(0.3);
      final counts = await _counts();
      final at = _now();
      final schema = _db.schemaVersion;
      final rounds = iterations;
      final bytes = await Isolate.run(() async {
        final db = File(snap).readAsBytesSync();
        return packBackup(dbBytes: db, schemaVersion: schema, counts: counts, createdAt: at, password: password, iterations: rounds);
      });
      onProgress?.call(0.9);
      return PreparedBackup(fileName: backupFileName(at), bytes: bytes, manifest: readManifest(bytes));
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  /// Records a backup the user saved somewhere.
  Future<void> record(String path, PreparedBackup b, {String kind = 'Manual'}) => _db.backupDao.log(
        fileName: p.basename(path),
        path: path,
        sizeBytes: b.bytes.length,
        kind: kind,
        encrypted: b.manifest.encrypted,
        at: _now(),
        sha256: b.manifest.sha256,
      );

  /// Writes a backup into the backup folder and logs it.
  Future<String> writeToFolder(PreparedBackup b, {required String kind}) async {
    final dir = await backupFolder();
    final name = kind == 'Safety' ? b.fileName.replaceFirst('rxdesk-backup', 'rxdesk-safety') : b.fileName;
    final path = p.join(dir, name);
    await File(path).writeAsBytes(b.bytes, flush: true);
    await record(path, b, kind: kind);
    return path;
  }

  /// Automatic backup at first launch of the day / on close when overdue.
  /// Keeps the latest [keepAuto] automatic backups. Not password-protected
  /// (no password can be stored safely). Returns the path, or null.
  Future<String?> runAutoIfDue({bool force = false}) async {
    final s = _settings();
    if (!s.autoBackup) return null;
    final last = await _db.backupDao.latest(kind: 'Auto');
    final lastAt = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last.createdAt, isUtc: true).toLocal();
    if (!force && !autoBackupDue(last: lastAt, now: _now(), frequency: s.autoBackupFrequency)) return null;
    final path = await writeToFolder(await prepare(), kind: 'Auto');
    await _prune();
    return path;
  }

  Future<void> _prune() async {
    final autos = await _db.backupDao.history(kind: 'Auto');
    for (final old in autos.skip(keepAuto)) {
      final f = File(old.path);
      if (f.existsSync()) await f.delete();
      await _db.backupDao.remove(old.id);
    }
  }

  /// What's inside a backup file (for the confirm dialog).
  BackupManifest inspect(Uint8List bytes) => readManifest(bytes);

  /// Restores: validate (manifest, schema, password, checksum) → save a
  /// Safety backup of current data → swap the database file → reconnect
  /// (migrations run on open).
  Future<BackupManifest> restore(Uint8List bytes, {String? password, void Function(double)? onProgress}) async {
    onProgress?.call(0.1);
    const current = latestSchemaVersion;
    final (manifest, db) = await Isolate.run(() => unpackBackup(bytes, currentSchema: current, password: password));
    onProgress?.call(0.5);
    final safety = await prepare();
    final safetyPath = await writeToFolder(safety, kind: 'Safety');
    onProgress?.call(0.8);
    // The restored file replaces this database, so record the safety copy
    // inside it too — otherwise the history would lose it.
    final restored = await _withLogEntry(db, safetyPath, safety);
    await _swapper().replaceWith(restored);
    onProgress?.call(1);
    return manifest;
  }
}

/// Inserts a backup_log row into a SQLite file given as bytes.
Future<Uint8List> _withLogEntry(Uint8List db, String path, PreparedBackup b) async {
  final tmp = await Directory.systemTemp.createTemp('rxdesk-restore');
  try {
    final file = File(p.join(tmp.path, 'restored.sqlite'));
    await file.writeAsBytes(db, flush: true);
    final s = sqlite.sqlite3.open(file.path);
    try {
      s.execute(
        'INSERT INTO backup_log (file_name, path, size_bytes, kind, encrypted, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        [p.basename(path), path, b.bytes.length, 'Safety', b.manifest.encrypted ? 1 : 0, b.manifest.createdAt.toUtc().millisecondsSinceEpoch],
      );
    } finally {
      s.close();
    }
    return await file.readAsBytes();
  } finally {
    await tmp.delete(recursive: true);
  }
}

@Riverpod(keepAlive: true)
BackupService backupService(Ref ref) => BackupService(
      ref.watch(appDatabaseProvider),
      ref.watch(nowProvider),
      () => ref.read(settingsProvider),
      () => ref.read(databaseSwapperProvider),
    );
