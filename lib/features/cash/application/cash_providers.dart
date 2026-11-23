import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cash/cash_rules.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/daos/cash_dao.dart';
import '../../../core/money/paise.dart';
import '../../../core/utils/expiry.dart';
import '../data/cash_repository.dart';

/// The day shown on the Day close screen ('YYYY-MM-DD'); today by default.
class CashDateNotifier extends Notifier<String> {
  @override
  String build() => dateKey(ref.read(cashRepositoryProvider).now);

  void set(String date) => state = date;

  void shift(int days) {
    final d = DateTime.parse(state).add(Duration(days: days));
    state = dateKey(d);
  }
}

final cashDateProvider = NotifierProvider<CashDateNotifier, String>(CashDateNotifier.new);

final cashFiguresProvider = StreamProvider.autoDispose.family<CashFigures, String>((ref, date) => ref.watch(cashRepositoryProvider).watchFigures(date));

final cashPaidOutsProvider =
    StreamProvider.autoDispose.family<List<CashPaidOut>, String>((ref, date) => ref.watch(cashRepositoryProvider).watchPaidOuts(date));

final cashClosingProvider = StreamProvider.autoDispose.family<CashClosing?, String>((ref, date) => ref.watch(cashRepositoryProvider).watchClosing(date));

final previousClosingProvider =
    StreamProvider.autoDispose.family<CashClosing?, String>((ref, date) => ref.watch(cashRepositoryProvider).watchPreviousClosing(date));

/// The opening cash RxDesk can work out for [date]: the previous closing's
/// counted cash less what was handed over; null when there is none yet.
final carriedOpeningProvider = Provider.autoDispose.family<Paise?, String>((ref, date) {
  final prev = ref.watch(previousClosingProvider(date)).value;
  return prev == null ? null : openingFrom(counted: Paise(prev.countedPaise), handedOver: Paise(prev.handedOverPaise));
});

/// True when the day's figures moved after it was closed (a late sale, a
/// voided payment…): the closing should be done again.
final changedSinceClosingProvider = Provider.autoDispose.family<bool, String>((ref, date) {
  final c = ref.watch(cashClosingProvider(date)).value;
  final f = ref.watch(cashFiguresProvider(date)).value;
  return c != null && f != null && f != closingFigures(c);
});
