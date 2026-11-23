import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/cash/cash_rules.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/money/paise.dart';

part 'cash_repository.g.dart';

/// Day-end cash closing data (wraps [CashDao]).
class CashRepository {
  CashRepository(this._db, this._now);

  final AppDatabase _db;
  final DateTime Function() _now;

  DateTime get now => _now();

  Stream<CashFigures> watchFigures(String date) => _db.cashDao.watchFigures(date);
  Stream<List<CashPaidOut>> watchPaidOuts(String date) => _db.cashDao.watchPaidOuts(date);
  Stream<CashClosing?> watchClosing(String date) => _db.cashDao.watchClosing(date);
  Stream<CashClosing?> watchPreviousClosing(String date) => _db.cashDao.watchPreviousClosing(date);
  Future<List<CashClosing>> closingsOf(String date) => _db.cashDao.closingsOf(date);

  Future<int> addPaidOut({required String date, required Paise amount, required String note, int? staffId}) =>
      _db.cashDao.addPaidOut(date: date, amount: amount, note: note, at: _now(), staffId: staffId);

  Future<void> voidPaidOut(int id, {required String reason}) => _db.cashDao.voidPaidOut(id, reason: reason);

  Future<CashClosing> closeDay({
    required String date,
    required Paise opening,
    required Paise counted,
    Paise handedOver = Paise.zero,
    String note = '',
    int? staffId,
  }) =>
      _db.cashDao.closeDay(date: date, opening: opening, counted: counted, handedOver: handedOver, note: note, at: _now(), staffId: staffId);
}

@riverpod
CashRepository cashRepository(Ref ref) => CashRepository(ref.watch(appDatabaseProvider), ref.watch(nowProvider));
