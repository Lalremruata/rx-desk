import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/db_provider.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/billing/application/bill_controller.dart';
import 'package:rx_desk/features/billing/application/bill_state.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';
import 'package:rx_desk/features/settings/application/settings_providers.dart';
import 'package:rx_desk/features/staff/application/session.dart';

import '../helpers/fake_printer.dart';
import '../helpers/test_db.dart';

void main() {
  late ProviderContainer c;
  late BillController bill;
  BillState st() => c.read(billControllerProvider);
  BillLine line() => st().lines.single;
  List<String> toasts() => [for (final t in c.read(toastsProvider)) t.text];

  Future<void> make({AppSettings settings = const AppSettings()}) async {
    final db = memoryDb();
    addTearDown(db.close);
    // ₹30.90 per strip of 10; 25 tabs = 2 strips + 5.
    await addMed(db, name: 'Cetirizine 10 mg Tablet', salt: 'Cetirizine 10 mg', batch: 'CTZ1', qty: 25, packSize: 10);
    // Only 7 loose tabs left.
    await addMed(db, name: 'Montelukast 10 mg Tablet', salt: 'Montelukast 10 mg', batch: 'MON1', qty: 7, packSize: 10, mrp: 2000);
    c = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowProvider.overrideWithValue(() => t0),
        initialSettingsProvider.overrideWithValue(settings),
        fakePrinterOverride,
      ],
    );
    addTearDown(c.dispose);
    c.read(sessionProvider.notifier).signIn(const SessionUser(name: 'Owner', role: StaffRole.owner));
    bill = c.read(billControllerProvider.notifier);
  }

  Future<void> add(String q) async {
    bill.setQuery(q);
    await bill.runSearch();
    await bill.enter();
  }

  test('a loose-sold medicine starts as 1 strip; repeat adds a strip; capped at whole strips', () async {
    await make();
    await add('ceti');
    expect((line().qty, line().loose, line().shownQty, line().packSize), (10, false, 1, 10));
    expect(line().amount, const Paise(3090));
    await add('ceti');
    expect(line().qty, 20);
    await add('ceti'); // 2 strips + 5 left: no third strip
    expect(line().qty, 20);
    expect(toasts().last, 'Only 2 strips + 5 tabs left in batch CTZ1');
    expect(st().units, 2);
  });

  test('Strip → Tab keeps the tablets; tab qty is pro-rata; Tab → Strip rounds down', () async {
    await make();
    await add('ceti');
    final key = line().key;
    bill.setLoose(key, true);
    expect((line().qty, line().shownQty, line().loose), (10, 10, true));
    bill.setQty(key, 15);
    expect(line().qty, 15);
    expect(line().amount, const Paise(4635));
    expect(c.read(billTotalsProvider).subtotal, const Paise(4635));
    bill.setQty(key, 99);
    expect(line().qty, 25); // every tab in the batch
    bill.setLoose(key, false);
    expect((line().qty, line().shownQty), (20, 2));
    bill.setQty(key, 3);
    expect(line().qty, 20);
  });

  test('less than a strip left → starts loose and can’t switch to strips', () async {
    await make();
    await add('montelukast');
    expect((line().qty, line().loose), (1, true));
    expect(line().amount, const Paise(200));
    bill.setLoose(line().key, false);
    expect(line().loose, isTrue);
    expect(toasts().last, contains('Less than a strip left'));
  });

  test('the saved bill has the tablets and the pro-rata total', () async {
    await make();
    await add('ceti');
    bill.setLoose(line().key, true);
    bill.setQty(line().key, 5);
    final out = await bill.save();
    final saved = (out as BillSavedOutcome).saved;
    expect(saved.totals.subtotal, const Paise(1545));
    expect(saved.totals.total, const Paise(1500));
  });
}
