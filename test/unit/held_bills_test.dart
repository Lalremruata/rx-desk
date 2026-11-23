import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/db_provider.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/held_bill.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/billing/application/bill_controller.dart';
import 'package:rx_desk/features/billing/application/bill_state.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';
import 'package:rx_desk/features/settings/application/settings_providers.dart';
import 'package:rx_desk/features/staff/application/session.dart';

import '../helpers/billing_fixture.dart';
import '../helpers/fake_printer.dart';
import '../helpers/test_db.dart';

/// Hold / recall bills at the counter (SPEC §5.2).
void main() {
  group('codec', () {
    test('round-trips every field', () {
      const d = HeldBillData(
        lines: [HeldLine(productId: 3, batchId: 7, qty: 12, loose: true, mrpPaise: 2500, gstRate: 12)],
        customer: 'Mawii',
        phone: '9800000000',
        doctor: 'Dr. R. Lalthangliana',
        discountCustom: true,
        discountKind: 'flat',
        discountInput: '12.50',
        payment: 'Credit',
        paidNow: '100',
        paidNowMode: 'UPI',
      );
      final r = HeldBillData.decode(d.encode());
      final l = r.lines.single;
      expect((l.productId, l.batchId, l.qty, l.loose, l.mrpPaise, l.gstRate), (3, 7, 12, true, 2500, 12));
      expect(
        (r.customer, r.phone, r.doctor, r.discountCustom, r.discountKind, r.discountInput, r.payment, r.paidNow, r.paidNowMode),
        ('Mawii', '9800000000', 'Dr. R. Lalthangliana', true, 'flat', '12.50', 'Credit', '100', 'UPI'),
      );
    });

    test('label: the customer, else the first item', () {
      expect(heldBillLabel(' Mawii ', 'Crocin', 2), 'Mawii');
      expect(heldBillLabel('', 'Crocin Advance', 1), 'Walk-in · Crocin Advance');
      expect(heldBillLabel('', 'Crocin Advance', 3), 'Walk-in · Crocin Advance +2');
    });
  });

  group('controller', () {
    late ProviderContainer c;
    late AppDatabase db;
    late BillController bill;
    BillState st() => c.read(billControllerProvider);
    List<String> toasts() => [for (final t in c.read(toastsProvider)) t.text];

    setUp(() async {
      db = memoryDb();
      addTearDown(db.close);
      await billingFixture(db);
      c = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowProvider.overrideWithValue(() => t0),
          initialSettingsProvider.overrideWithValue(const AppSettings()),
          fakePrinterOverride,
        ],
      );
      addTearDown(c.dispose);
      c.read(sessionProvider.notifier).signIn(const SessionUser(name: 'Owner', role: StaffRole.owner));
      bill = c.read(billControllerProvider.notifier);
    });

    Future<void> add(String q, {int times = 1}) async {
      for (var i = 0; i < times; i++) {
        bill.setQuery(q);
        await bill.runSearch();
        await bill.enter();
        if (st().drop is DropBatchPicker) await bill.enter();
      }
    }

    Future<List<HeldBill>> held() => db.heldBillsDao.watchAll().first;

    test('hold clears the counter; recall puts everything back', () async {
      await add('crocin');
      bill
        ..setCustomer('Mawii')
        ..setPhone('9800000000')
        ..setDiscount(5);
      expect(await bill.hold(), isTrue);
      expect(st().isEmpty, isTrue);
      expect(toasts().last, 'Bill held — F6 to recall');
      final h = (await held()).single;
      expect((h.label, h.itemCount, h.totalPaise), ('Mawii', 1, 2400)); // 25.00 − 5 % = 23.75 → 24

      await bill.recall(h.id);
      expect(st().lines.single.name, 'Crocin Advance');
      expect((st().customer, st().phone, st().discountPct), ('Mawii', '9800000000', 5));
      expect(await held(), isEmpty);
      expect(toasts().last, 'Bill for Mawii recalled');
    });

    test('recall rebuilds from today’s stock: short stock is cut, a new MRP is named, expired batches are dropped', () async {
      await add('para 500', times: 3);
      await add('crocin');
      await add('8904021650153'); // Para 650, FEFO batch PCM2540
      await bill.hold();
      final id = (await held()).single.id;
      await db.customStatement("UPDATE batches SET qty = 1 WHERE batch_no = 'PCM5001'");
      await db.customStatement("UPDATE batches SET mrp_paise = 2600 WHERE batch_no = 'CRO77'");
      await db.customStatement("UPDATE batches SET expiry = '2026-10' WHERE batch_no = 'PCM2540'");

      await bill.recall(id);
      expect(st().lines.map((l) => (l.batchNo, l.qty, l.mrp)), [('PCM5001', 1, const Paise(1800)), ('CRO77', 1, const Paise(2600))]);
      final t = toasts().last;
      expect(t, contains('only 1 of Paracetamol 500 mg Tablet left'));
      expect(t, contains('MRP of Crocin Advance is now ₹26.00'));
      expect(t, contains('Paracetamol 650 mg Tablet batch PCM2540 has expired'));
    });

    test('recalling while a bill is open holds the open one (swap)', () async {
      await add('crocin');
      bill.setCustomer('First');
      await bill.hold();
      final first = (await held()).single.id;
      await add('para 500');
      bill.setCustomer('Second');
      await bill.recall(first);
      expect(st().customer, 'First');
      expect((await held()).map((h) => h.label), ['Second']);
    });

    test('at most $maxHeldBills held bills', () async {
      for (var i = 0; i < maxHeldBills; i++) {
        await add('crocin');
        expect(await bill.hold(), isTrue);
      }
      await add('crocin');
      expect(await bill.hold(), isFalse);
      expect(toasts().last, '$maxHeldBills bills are already held — recall or discard one first');
      expect(st().lines, hasLength(1)); // the open bill stays
    });

    test('a cashier recalling a held Schedule H item gets it dropped', () async {
      await add('amoxi');
      await add('crocin');
      bill.setDoctor('Dr. K');
      await bill.hold();
      c.read(sessionProvider.notifier).signIn(const SessionUser(name: 'Mawii', role: StaffRole.cashier));
      await bill.recall((await held()).single.id);
      expect(st().lines.map((l) => l.name), ['Crocin Advance']);
      expect(toasts().last, contains('your role can’t sell Amoxicillin 500 mg Capsule'));
    });

    test('discard removes a held bill; nothing else changes', () async {
      await add('crocin');
      await bill.hold();
      await bill.discardHeld((await held()).single.id);
      expect(await held(), isEmpty);
      expect(await countOf(db, 'invoices'), 0);
    });
  });
}
