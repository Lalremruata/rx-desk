import 'package:drift/drift.dart';

import '../app_database.dart';

part 'staff_dao.g.dart';

/// Staff accounts (PIN hashes only — CLAUDE.md rule 13).
@DriftAccessor(tables: [Staff])
class StaffDao extends DatabaseAccessor<AppDatabase> with _$StaffDaoMixin {
  StaffDao(super.attachedDatabase);

  Future<List<StaffMember>> all() => (select(staff)..orderBy([(s) => OrderingTerm.asc(s.id)])).get();

  Stream<List<StaffMember>> watchAll() => (select(staff)..orderBy([(s) => OrderingTerm.asc(s.id)])).watch();

  Future<StaffMember?> byId(int id) => (select(staff)..where((s) => s.id.equals(id))).getSingleOrNull();

  Future<int> add({
    required String name,
    required String role,
    required String pinHash,
    required String pinSalt,
    required DateTime at,
  }) =>
      into(staff).insert(
        StaffCompanion.insert(
          name: name.trim(),
          role: role,
          pinHash: pinHash,
          pinSalt: pinSalt,
          createdAt: at.toUtc().millisecondsSinceEpoch,
        ),
      );

  Future<void> updateMember(int id, {String? name, String? role, bool? active, String? pinHash, String? pinSalt}) =>
      (update(staff)..where((s) => s.id.equals(id))).write(
        StaffCompanion(
          name: name == null ? const Value.absent() : Value(name.trim()),
          role: role == null ? const Value.absent() : Value(role),
          active: active == null ? const Value.absent() : Value(active),
          pinHash: pinHash == null ? const Value.absent() : Value(pinHash),
          pinSalt: pinSalt == null ? const Value.absent() : Value(pinSalt),
        ),
      );

  Future<int> count() async =>
      (await customSelect('SELECT COUNT(*) AS c FROM staff', readsFrom: {staff}).getSingle()).read<int>('c');
}
