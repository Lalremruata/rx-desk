import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/daos/dues_dao.dart';
import 'package:rx_desk/core/db/db_provider.dart';
import 'package:rx_desk/core/db/models.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/return_rules.dart';
import 'package:rx_desk/features/billing/application/bill_controller.dart';
import 'package:rx_desk/features/billing/application/bill_state.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';
import 'package:rx_desk/features/settings/application/settings_providers.dart';
import 'package:rx_desk/features/staff/application/guarded_actions.dart';
import 'package:rx_desk/features/staff/application/pin_hash.dart';
import 'package:rx_desk/features/staff/application/session.dart';
import 'package:rx_desk/features/staff/data/staff_repository.dart';

import '../helpers/billing_fixture.dart';
import '../helpers/fake_printer.dart';
import '../helpers/test_db.dart';

const cashier = SessionUser(staffId: 3, name: 'Cash', role: StaffRole.cashier);
const pharmacist = SessionUser(staffId: 2, name: 'Pharma', role: StaffRole.pharmacist);
const owner = SessionUser(staffId: 1, name: 'Owner', role: StaffRole.owner);

void main() {
  group('PIN hashing (rule 13)', () {
    test('salted PBKDF2; verifies right PIN only; never stores the PIN', () async {
      final (h1, s1) = await hashPin('4821', iterations: 1000);
      final (h2, s2) = await hashPin('4821', iterations: 1000);
      expect(h1, startsWith(r'pbkdf2-sha256$1000$'));
      expect(h1, isNot(contains('4821')));
      expect(s1, isNot(s2));
      expect(h1, isNot(h2));
      expect(await verifyPin('4821', hash: h1, salt: s1), isTrue);
      expect(await verifyPin('4822', hash: h1, salt: s1), isFalse);
      expect(await verifyPin('4821', hash: 'garbage', salt: s1), isFalse);
    });
    test('PIN format', () {
      expect(isValidPin('0420'), isTrue);
      expect(isValidPin('42'), isFalse);
      expect(isValidPin('abcd'), isFalse);
    });
  });

  group('staff repository', () {
    test('add, verify, disable, keep one Owner', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final repo = StaffRepository(db, () => t0, iterations: 1000);
      final o = await repo.add(name: 'Ruata', role: StaffRole.owner, pin: '1111');
      final c = await repo.add(name: 'Mawii', role: StaffRole.cashier, pin: '2222');
      expect((await repo.verify(c, '2222'))!.name, 'Mawii');
      expect(await repo.verify(c, '1111'), isNull);
      await repo.setActive(c, false);
      expect(await repo.verify(c, '2222'), isNull); // disabled can't sign in
      await expectLater(repo.setRole(o, StaffRole.cashier), throwsA(isA<StaffException>()));
      await expectLater(repo.setActive(o, false), throwsA(isA<StaffException>()));
      await repo.resetPin(o, '9999');
      expect(await repo.verify(o, '9999'), isNotNull);
      await expectLater(repo.add(name: 'X', role: StaffRole.cashier, pin: '12'), throwsA(isA<StaffException>()));
      final row = await db.staffDao.byId(o);
      expect(row!.pinHash, isNot(contains('9999')));
    });
  });

  group('permissions (SPEC §7.6) are enforced in services', () {
    Future<ProviderContainer> make(SessionUser user) async {
      final db = memoryDb();
      addTearDown(db.close);
      await billingFixture(db);
      final staff = StaffRepository(db, () => t0, iterations: 1000);
      await staff.add(name: 'Owner', role: StaffRole.owner, pin: '1111');
      await staff.add(name: 'Pharma', role: StaffRole.pharmacist, pin: '2222');
      await staff.add(name: 'Cash', role: StaffRole.cashier, pin: '3333');
      final c = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowProvider.overrideWithValue(() => t0),
          initialSessionProvider.overrideWithValue(user),
          fakePrinterOverride,
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('Cashier cannot sell Schedule H / H1', () async {
      final c = await make(cashier);
      final bill = c.read(billControllerProvider.notifier)..setQuery('amoxi');
      await bill.runSearch();
      await bill.enter();
      expect(c.read(billControllerProvider).lines, isEmpty);
      // And the save path refuses even if a line got in.
      final rules = c.read(settingsProvider).billRules(role: StaffRole.cashier);
      expect(rules.canSellRx, isFalse);
    });

    test('Cashier cannot give more than 5 % discount', () async {
      final c = await make(cashier);
      final bill = c.read(billControllerProvider.notifier)..setDiscount(10);
      expect(c.read(billControllerProvider).discountPct, 0);
      bill.setDiscount(5);
      expect(c.read(billControllerProvider).discountPct, 5);
    });

    test('Cashier cannot change settings', () async {
      final c = await make(cashier);
      final d = c.read(settingsDraftProvider.notifier)..edit((s) => s.copyWith(maxDiscountPct: 20));
      expect(await d.save(), isA<DraftDenied>());
      expect(c.read(settingsProvider).maxDiscountPct, 15);
    });

    test('Cashier cannot export or restore backups', () async {
      final c = await make(cashier);
      final a = c.read(guardedActionsProvider);
      expect(a.prepareBackup, throwsA(isA<PermissionDenied>()));
      expect(() => a.restoreBackup(Uint8List(0)), throwsA(isA<PermissionDenied>()));
    });

    test('Cashier cannot cancel bills or change stock; cannot see reports', () async {
      final c = await make(cashier);
      final a = c.read(guardedActionsProvider);
      expect(() => a.cancelInvoice(1), throwsA(isA<PermissionDenied>()));
      expect(() => a.receiveStock(productId: 1, batchNo: 'X', qty: 1), throwsA(isA<PermissionDenied>()));
      expect(
        () => a.addMedicine(const NewProduct(name: 'x', maker: 'm', category: 'Tablet', gstRate: 12, mrp: Paise(100))),
        throwsA(isA<PermissionDenied>()),
      );
      expect(c.read(canProvider(Permission.viewReports)), isFalse);
      expect(
        () => a.acceptReturn(invoiceId: 1, lines: const [ReturnLineRequest(itemId: 1, qty: 1)], refundMode: 'Cash'),
        throwsA(isA<PermissionDenied>()),
      );
    });

    test('Pharmacist defaults: Rx, discount, cancel, stock, reports, returns yes; backups and settings no', () async {
      final c = await make(pharmacist);
      bool can(Permission p) => c.read(canProvider(p));
      expect([for (final p in Permission.values) can(p)], [true, true, true, true, true, false, false, false, true, true, true, false, true]);
      expect(
        () => c.read(guardedActionsProvider).recordSupplierPayment(supplierId: 1, date: '2026-11-09', payment: const PaymentInput(amount: Paise(100), mode: 'Cash')),
        throwsA(isA<PermissionDenied>()),
      );
      final bill = c.read(billControllerProvider.notifier)..setQuery('amoxi');
      await bill.runSearch();
      await bill.enter();
      expect(c.read(billControllerProvider).lines.single.isRx, isTrue);
      final r = await c.read(guardedActionsProvider).receiveStock(productId: 1, batchNo: 'NEW1', expiry: '2028-01', qty: 5);
      expect(r.newBatch, isTrue);
    });

    test('Owner has everything; locked session has nothing', () async {
      final c = await make(owner);
      expect(Permission.values.every((p) => c.read(canProvider(p))), isTrue);
      c.read(sessionProvider.notifier).lock();
      expect(Permission.values.any((p) => c.read(canProvider(p))), isFalse);
    });

    test('bills record the staff member', () async {
      final c = await make(pharmacist);
      final bill = c.read(billControllerProvider.notifier)..setQuery('crocin');
      await bill.runSearch();
      await bill.enter();
      final r = await bill.save();
      final saved = (r as BillSavedOutcome).saved;
      final db = c.read(appDatabaseProvider);
      expect((await db.salesDao.invoiceWithItems(saved.invoiceId))!.invoice.staffId, 2);
      final mv = await db.customSelect('SELECT staff_id FROM stock_movements WHERE reason = \'sale\'').getSingle();
      expect(mv.read<int>('staff_id'), 2);
      expect(c.read(billControllerProvider).drop, isA<DropClosed>());
    });
  });
}
