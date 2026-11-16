import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/db_provider.dart';
import '../../settings/application/app_settings.dart';
import '../application/pin_hash.dart';

part 'staff_repository.g.dart';

class StaffException implements Exception {
  const StaffException(this.message);
  final String message;
  @override
  String toString() => message;
}

class StaffRepository {
  StaffRepository(this._db, this._now, {this.iterations = pinIterations});

  final AppDatabase _db;
  final DateTime Function() _now;
  final int iterations;

  Stream<List<StaffMember>> watchAll() => _db.staffDao.watchAll();
  Future<List<StaffMember>> all() => _db.staffDao.all();
  Future<int> count() => _db.staffDao.count();
  Future<StaffMember?> byId(int id) => _db.staffDao.byId(id);

  Future<int> add({required String name, required StaffRole role, required String pin}) async {
    if (name.trim().isEmpty) throw const StaffException('Enter the staff member’s name');
    if (!isValidPin(pin)) throw const StaffException('PIN must be 4 digits');
    final (hash, salt) = await hashPin(pin, iterations: iterations);
    return _db.staffDao.add(name: name, role: role.label, pinHash: hash, pinSalt: salt, at: _now());
  }

  Future<void> setRole(int id, StaffRole role) async {
    await _guardLastOwner(id, demoting: role != StaffRole.owner);
    await _db.staffDao.updateMember(id, role: role.label);
  }

  Future<void> setActive(int id, bool active) async {
    if (!active) await _guardLastOwner(id, demoting: true);
    await _db.staffDao.updateMember(id, active: active);
  }

  Future<void> resetPin(int id, String pin) async {
    if (!isValidPin(pin)) throw const StaffException('PIN must be 4 digits');
    final (hash, salt) = await hashPin(pin, iterations: iterations);
    await _db.staffDao.updateMember(id, pinHash: hash, pinSalt: salt);
  }

  /// The member if [pin] is right and the account is active, else null.
  Future<StaffMember?> verify(int id, String pin) async {
    final m = await _db.staffDao.byId(id);
    if (m == null || !m.active) return null;
    return await verifyPin(pin, hash: m.pinHash, salt: m.pinSalt) ? m : null;
  }

  /// An active Owner whose PIN is [pin] (Owner override, SPEC §4.10).
  Future<StaffMember?> verifyOwnerPin(String pin) async {
    for (final m in await _db.staffDao.all()) {
      if (!m.active || m.role != StaffRole.owner.label) continue;
      if (await verifyPin(pin, hash: m.pinHash, salt: m.pinSalt)) return m;
    }
    return null;
  }

  /// There must always be one active Owner.
  Future<void> _guardLastOwner(int id, {required bool demoting}) async {
    if (!demoting) return;
    final all = await _db.staffDao.all();
    final me = all.where((s) => s.id == id).firstOrNull;
    if (me == null || me.role != StaffRole.owner.label) return;
    final others = all.where((s) => s.id != id && s.active && s.role == StaffRole.owner.label);
    if (others.isEmpty) throw const StaffException('Keep at least one active Owner');
  }
}

@Riverpod(keepAlive: true)
StaffRepository staffRepository(Ref ref) => StaffRepository(ref.watch(appDatabaseProvider), ref.watch(nowProvider));
