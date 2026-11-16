import 'package:drift/drift.dart';

import '../app_database.dart';

part 'backup_dao.g.dart';

@DriftAccessor(tables: [BackupLog])
class BackupDao extends DatabaseAccessor<AppDatabase> with _$BackupDaoMixin {
  BackupDao(super.attachedDatabase);

  Future<int> log({
    required String fileName,
    required String path,
    required int sizeBytes,
    required String kind,
    required bool encrypted,
    required DateTime at,
    String? sha256,
  }) =>
      into(backupLog).insert(
        BackupLogCompanion.insert(
          fileName: fileName,
          path: path,
          sizeBytes: sizeBytes,
          kind: kind,
          encrypted: encrypted,
          createdAt: at.toUtc().millisecondsSinceEpoch,
          sha256: Value(sha256),
        ),
      );

  Stream<List<BackupEntry>> watchHistory({int limit = 50}) =>
      (select(backupLog)
            ..orderBy([(b) => OrderingTerm.desc(b.createdAt), (b) => OrderingTerm.desc(b.id)])
            ..limit(limit))
          .watch();

  Future<List<BackupEntry>> history({String? kind}) {
    final q = select(backupLog)..orderBy([(b) => OrderingTerm.desc(b.createdAt), (b) => OrderingTerm.desc(b.id)]);
    if (kind != null) q.where((b) => b.kind.equals(kind));
    return q.get();
  }

  Future<BackupEntry?> latest({String? kind}) async {
    final h = await history(kind: kind);
    return h.isEmpty ? null : h.first;
  }

  Future<void> remove(int id) => (delete(backupLog)..where((b) => b.id.equals(id))).go();
}
