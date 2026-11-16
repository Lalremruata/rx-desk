import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/reports_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/db/report_models.dart';

part 'register_repository.g.dart';

class RegisterRepository {
  RegisterRepository(this._db, [DateTime Function()? now]) : _now = now ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _now;

  // Monthly consumption register (SPEC §4.12).

  Future<ConsumptionPage> consumptionPage(String month, {String search = '', bool includeAll = false, int page = 1, int pageSize = 50}) =>
      _db.reportsDao.consumptionPage(month, now: _now(), search: search, includeAll: includeAll, page: page, pageSize: pageSize);

  Future<List<ConsumptionRow>> consumptionAll(String month, {bool includeAll = false}) =>
      _db.reportsDao.consumptionAll(month, now: _now(), includeAll: includeAll);

  Future<RegisterTotals> totals(RegisterFilter f) => _db.reportsDao.registerTotals(f);

  Future<RegisterLinesPage> lines(RegisterFilter f, {RegisterCursor? after, int limit = 50}) =>
      _db.reportsDao.registerLines(f, after: after, limit: limit);

  Future<RegisterGroupsPage> groups(RegisterFilter f, {int offset = 0, int? limit = 50}) =>
      _db.reportsDao.registerGroups(f, offset: offset, limit: limit);

  Future<List<String>> doctors() => _db.reportsDao.doctors();

  Future<List<String>> makers() => _db.reportsDao.soldMakers();

  /// Every line matching [f] (export), fetched in keyset chunks.
  Future<List<RegisterLine>> allLines(RegisterFilter f) async {
    final out = <RegisterLine>[];
    RegisterCursor? after;
    while (true) {
      final page = await lines(f, after: after, limit: 2000);
      out.addAll(page.rows);
      if (!page.hasMore || page.rows.isEmpty) break;
      after = RegisterCursor(page.rows.last.sortValue, page.rows.last.id);
    }
    return out;
  }
}

@Riverpod(keepAlive: true)
RegisterRepository registerRepository(Ref ref) => RegisterRepository(ref.watch(appDatabaseProvider), ref.watch(nowProvider));
