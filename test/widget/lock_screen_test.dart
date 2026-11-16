import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';
import 'package:rx_desk/features/shell/presentation/app_shell.dart';
import 'package:rx_desk/features/staff/application/session.dart';
import 'package:rx_desk/features/staff/data/staff_repository.dart';
import 'package:rx_desk/features/staff/presentation/access_denied.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_db.dart';

Future<void> _run(WidgetTester tester, [int ms = 600]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _staff(AppDatabase db) async {
  final repo = StaffRepository(db, () => t0, iterations: 1000);
  await repo.add(name: 'Ruata', role: StaffRole.owner, pin: '1111');
  await repo.add(name: 'Mawii', role: StaffRole.cashier, pin: '2222');
}

void main() {
  setUpAll(setUpFormatting);

  testWidgets('first run: create Owner → signed in', (tester) async {
    final c = await pumpApp(tester, size: const Size(1280, 1100), session: null);
    await _run(tester);
    expect(find.text('Create owner account'), findsOneWidget);
    Future<void> type(String k, String v) => tester.enterText(find.descendant(of: find.byKey(ValueKey(k)), matching: find.byType(TextField)), v);
    await type('owner-name', 'Ruata');
    await type('owner-pin', '4821');
    await type('owner-confirm', '4821');
    await tester.ensureVisible(find.byKey(const ValueKey('owner-create')));
    await tester.tap(find.byKey(const ValueKey('owner-create')));
    await _run(tester, 1500);
    expect(c.read(sessionProvider)?.role, StaffRole.owner);
    expect(find.byType(PageHeader), findsOneWidget);
  });

  testWidgets('lock screen: wrong PIN, then right PIN via keyboard; cashier gets no Settings', (tester) async {
    final c = await pumpApp(tester, size: const Size(1280, 1100), session: null, setUpDb: _staff, location: '/settings/store');
    await _run(tester);
    expect(find.text('Locked — choose your name and enter your PIN'), findsOneWidget);
    await tester.tap(find.text('Mawii'));
    await _run(tester, 100);
    for (final d in ['9', '9', '9', '9']) {
      await tester.tap(find.byKey(ValueKey('pad-$d')));
      await tester.pump();
    }
    await _run(tester, 1000);
    expect(find.text('Wrong PIN'), findsOneWidget);
    expect(c.read(sessionProvider), isNull);

    for (final k in [LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit2]) {
      await tester.sendKeyEvent(k);
    }
    await _run(tester, 1000);
    expect(c.read(sessionProvider)?.name, 'Mawii');
    expect(find.byType(AccessDenied), findsOneWidget); // cashier can't open Settings

    // Lock again from the header.
    await tester.tap(find.byKey(const ValueKey('lock-button')));
    await _run(tester);
    expect(c.read(sessionProvider), isNull);
    expect(find.text('Locked — choose your name and enter your PIN'), findsOneWidget);
  });

  testWidgets('auto-lock after the idle time', (tester) async {
    final c = await pumpApp(tester, settings: const AppSettings(autoBackup: false, autoLockMinutes: 5), setUpDb: _staff);
    await _run(tester);
    await tester.tapAt(const Offset(640, 760)); // any input resets the idle timer
    await tester.pump(const Duration(minutes: 4));
    expect(c.read(sessionProvider), isNotNull);
    await tester.pump(const Duration(minutes: 2));
    await _run(tester);
    expect(c.read(sessionProvider), isNull);
  });
}
