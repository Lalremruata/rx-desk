import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/db_provider.dart';
import 'package:rx_desk/core/fy/fy.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';
import 'package:rx_desk/features/settings/application/settings_providers.dart';
import 'package:rx_desk/features/settings/data/settings_repository.dart';
import 'package:rx_desk/features/staff/application/session.dart';

import '../helpers/test_db.dart';

void main() {
  group('AppSettings', () {
    test('defaults match SPEC §7', () {
      const s = AppSettings();
      expect(s.name, '[Your Pharmacy Name]');
      expect((s.prefix, s.separator, s.digits, s.fyInNumber), ('INV', '/', 5, true));
      expect((s.paper, s.copies, s.autoPrint), (InvoicePaper.a4, 1, true));
      expect((s.showSalt, s.showBatch, s.showExpiry, s.showHsn, s.showDoctor, s.showSaved, s.showUpiQr), (false, true, true, false, true, true, true));
      expect(s.signatureLabel, 'Registered Pharmacist');
      expect((s.gstRegistered, s.mrpIncludesGst, s.roundOff, s.maxDiscountPct, s.defaultPayment), (true, true, true, 15, 'Cash'));
      expect((s.requireDoctorForRx, s.blockExpired, s.allowNegativeStock), (true, true, false));
      expect((s.expiryWindowMonths, s.deadStockDays, s.defaultReorderLevel, s.suggestFefo, s.showLowStockBadge), (3, 90, 20, true, true));
      expect((s.accent, s.showKeyHints, s.autoLockMinutes), ('#0F766E', true, 15));
    });

    test('JSON round trip', () {
      final s = const AppSettings().copyWith(paper: InvoicePaper.t58, gstin: '15ABCDE1234F1Z5', rolePermissions: {'Cashier': ['sellRx']});
      expect(AppSettings.fromJson(s.toJson()), s);
      expect(s.toJson()['paper'], 'T58');
    });

    test('numbering + bill rules follow settings and role', () {
      const s = AppSettings(separator: 'none', fyInNumber: false, digits: 4);
      expect(s.numbering.format(fy: '26-27', seq: 12), 'INV0012');
      expect(s.numbering.separator, InvoiceSeparator.none);
      expect(s.billRules(role: StaffRole.cashier).canSellRx, isFalse);
      expect(s.billRules(role: StaffRole.cashier).canGiveHighDiscount, isFalse);
      expect(s.billRules(role: StaffRole.pharmacist).canSellRx, isTrue);
      expect(s.billRules().canSellRx, isTrue); // owner
    });

    test('initials', () {
      expect(const AppSettings().initials, 'YP');
      expect(const AppSettings(name: 'Zion Medicos').initials, 'ZM');
      expect(const AppSettings(name: '  ').initials, 'Rx');
    });
  });

  group('validation', () {
    test('GSTIN', () {
      expect(validateGstin(''), isNull);
      expect(validateGstin('15ABCDE1234F1Z5'), isNull);
      expect(validateGstin('15ABCDE1234F1Z'), contains('15 characters'));
      expect(validateGstin('1XABCDE1234F1Z5'), isNotNull);
    });
    test('PIN code', () {
      expect(validatePin('796001'), isNull);
      expect(validatePin('7960'), isNotNull);
    });
    test('prefix', () {
      expect(validatePrefix('INV'), isNull);
      expect(validatePrefix('inv'), isNotNull);
      expect(validatePrefix('TOOLONGXX'), isNotNull);
    });
    test('settingsErrors collects all', () {
      final e = settingsErrors(const AppSettings(name: ' ', gstin: 'BAD', pin: '12'));
      expect(e.keys, containsAll(['name', 'gstin', 'pin']));
    });
    test('changedKeys', () {
      const a = AppSettings();
      expect(changedKeys(a, a), isEmpty);
      expect(changedKeys(a.copyWith(name: 'X', copies: 2), a), unorderedEquals(['name', 'copies']));
      expect(changedKeys(a.copyWith(rolePermissions: {...defaultRolePermissions}), a), isEmpty);
    });
  });

  group('repository + draft (DB-backed)', () {
    late ProviderContainer c;
    setUp(() {
      final db = memoryDb();
      addTearDown(db.close);
      c = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          initialSessionProvider.overrideWithValue(const SessionUser(name: 'Owner', role: StaffRole.owner)),
        ],
      );
      addTearDown(c.dispose);
    });

    test('every field persists across restarts', () async {
      final repo = c.read(settingsRepositoryProvider);
      expect(await repo.load(), const AppSettings());
      final changed = const AppSettings().copyWith(
        name: 'Zion Medicos',
        gstin: '15ABCDE1234F1Z5',
        paper: InvoicePaper.t80,
        copies: 2,
        showSalt: true,
        maxDiscountPct: 10,
        defaultPayment: 'UPI',
        expiryWindowMonths: 6,
        accent: '#BE123C',
        rolePermissions: {'Pharmacist': ['sellRx'], 'Cashier': ['viewReports']},
      );
      await repo.save(changed);
      // A fresh repository (≈ app restart) reads the same values.
      final reloaded = await SettingsRepository(c.read(appDatabaseProvider).settingsDao).load();
      expect(reloaded, changed);
    });

    test('a corrupt stored value falls back to its default', () async {
      final db = c.read(appDatabaseProvider);
      await db.settingsDao.writeAll({'copies': '"lots"', 'name': '"Kept"', 'unknownKey': '1'});
      final s = await c.read(settingsRepositoryProvider).load();
      expect(s.copies, 1);
      expect(s.name, 'Kept');
    });

    test('draft: edit → dirty; discard reverts; save persists; reset keeps store identity', () async {
      final draft = c.read(settingsDraftProvider.notifier);
      draft.edit((s) => s.copyWith(maxDiscountPct: 5, prefix: 'RX'));
      expect(c.read(settingsChangesProvider), unorderedEquals(['maxDiscountPct', 'prefix']));
      expect(c.read(settingsProvider).maxDiscountPct, 15); // app unchanged until saved

      draft.discard();
      expect(c.read(settingsDraftProvider), isNull);

      draft.edit((s) => s.copyWith(name: 'Zion Medicos', roundOff: false));
      expect(await draft.save(), isA<DraftSaved>());
      expect(c.read(settingsProvider).roundOff, isFalse);
      expect((await c.read(settingsRepositoryProvider).load()).name, 'Zion Medicos');

      // Editing back to the saved value clears the draft.
      draft.edit((s) => s.copyWith(roundOff: true));
      draft.edit((s) => s.copyWith(roundOff: false));
      expect(c.read(settingsDraftProvider), isNull);

      draft.resetToDefaults();
      expect(c.read(settingsChangesProvider), ['roundOff']);
      expect(c.read(settingsDraftProvider)!.name, 'Zion Medicos');
    });

    test('invalid draft is not saved', () async {
      final draft = c.read(settingsDraftProvider.notifier)..edit((s) => s.copyWith(gstin: '12'));
      final r = await draft.save();
      expect(r, isA<DraftInvalid>());
      expect((r as DraftInvalid).errors, contains('gstin'));
      expect(c.read(settingsProvider).gstin, '');
    });

    test('accent previews the draft only while Settings is open', () {
      c.read(settingsDraftProvider.notifier).edit((s) => s.copyWith(accent: '#2563EB'));
      expect(c.read(accentProvider).toARGB32(), 0xFF0F766E);
      c.read(settingsOnScreenProvider.notifier).set(true);
      expect(c.read(accentProvider).toARGB32(), 0xFF2563EB);
    });
  });
}
