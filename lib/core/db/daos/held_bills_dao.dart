import 'package:drift/drift.dart';

import '../../money/paise.dart';
import '../../sales/held_bill.dart';
import '../app_database.dart';

part 'held_bills_dao.g.dart';

/// Bills parked at the counter (SPEC §5.2 "Hold"). Not legal records: a
/// held bill is deleted when it is recalled or discarded.
@DriftAccessor(tables: [HeldBills])
class HeldBillsDao extends DatabaseAccessor<AppDatabase> with _$HeldBillsDaoMixin {
  HeldBillsDao(super.attachedDatabase);

  /// Parks a bill; refused when [maxHeldBills] are already held.
  Future<int> hold({
    required String label,
    required HeldBillData data,
    required int itemCount,
    required Paise total,
    required DateTime at,
    int? staffId,
  }) {
    return transaction(() async {
      if (data.lines.isEmpty) throw const HeldBillException('Add at least one item before holding the bill');
      if (await count() >= maxHeldBills) {
        throw const HeldBillException('$maxHeldBills bills are already held — recall or discard one first');
      }
      return into(heldBills).insert(
        HeldBillsCompanion.insert(
          label: label.trim().isEmpty ? 'Held bill' : label.trim(),
          payload: data.encode(),
          itemCount: itemCount,
          totalPaise: total.value,
          staffId: Value(staffId),
          heldAt: at.toUtc().millisecondsSinceEpoch,
        ),
      );
    });
  }

  Future<int> count() async => (await customSelect('SELECT COUNT(*) AS c FROM held_bills', readsFrom: {heldBills}).getSingle()).read<int>('c');

  /// Oldest first, like a queue at the counter.
  Stream<List<HeldBill>> watchAll() =>
      (select(heldBills)..orderBy([(h) => OrderingTerm.asc(h.heldAt), (h) => OrderingTerm.asc(h.id)])).watch();

  /// Removes and returns a held bill (recall), or null if it is gone.
  Future<HeldBill?> take(int id) {
    return transaction(() async {
      final h = await (select(heldBills)..where((x) => x.id.equals(id))).getSingleOrNull();
      if (h != null) await (delete(heldBills)..where((x) => x.id.equals(id))).go();
      return h;
    });
  }

  Future<void> discard(int id) => (delete(heldBills)..where((x) => x.id.equals(id))).go();
}
