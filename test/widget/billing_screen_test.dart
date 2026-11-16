import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/billing/application/bill_controller.dart';
import 'package:rx_desk/features/shell/presentation/app_shell.dart';

import '../helpers/billing_fixture.dart';
import '../helpers/pump_app.dart';
import '../helpers/test_db.dart';

Future<void> _run(WidgetTester tester, [int ms = 400]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await _run(tester, 150);
}

Finder get _search => find.byKey(const ValueKey('billing-search'));

void main() {
  setUpAll(setUpFormatting);

  testWidgets('type → ↓ → Enter → batch → Enter → F10 (BUILD_PLAN phase 4)', (tester) async {
    late AppDatabase db;
    final c = await pumpApp(tester, size: const Size(1440, 900), setUpDb: (d) async {
      db = d;
      await billingFixture(d);
    });
    await _run(tester);
    expect(find.text('Bill is empty'), findsOneWidget);

    await tester.enterText(_search, 'para');
    await _run(tester, 300); // debounce 120 ms
    expect(find.textContaining('3 matches'), findsOneWidget);
    expect(find.text('Paracetamol 650 mg Tablet'), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(find.text('Choose batch · Paracetamol 650 mg Tablet'), findsOneWidget);
    expect(find.text('FEFO · sell first'), findsOneWidget);
    expect(find.text('Expired · blocked'), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.enter);
    expect(find.text('Choose batch · Paracetamol 650 mg Tablet'), findsNothing);
    expect(find.text('PCM2540'), findsOneWidget); // line added (FEFO)
    expect(find.text('Bill is empty'), findsNothing);
    // Billing badge in the sidebar shows units.
    expect(find.descendant(of: find.byKey(const ValueKey('nav-billing')), matching: find.text('1')), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.f10);
    await _run(tester, 600);
    // Saved → Invoices, toast with the number, bill reset.
    expect(find.descendant(of: find.byType(PageHeader), matching: find.text('Invoices')), findsOneWidget);
    expect(c.read(toastsProvider).map((t) => t.text).first, 'INV/26-27/00001 saved · ₹31.00 · printing 1 copy');
    expect(c.read(billControllerProvider).lines, isEmpty);
    await tester.runAsync(() async {
      expect(await countOf(db, 'invoices'), 1);
      expect(await qtyOf(db, (await db.catalogDao.batchesOf(1)).firstWhere((b) => b.batchNo == 'PCM2540').id), 49);
    });
  });

  testWidgets('Schedule H without a doctor: label turns required and F10 is blocked', (tester) async {
    late AppDatabase db;
    final c = await pumpApp(tester, size: const Size(1440, 900), setUpDb: (d) async {
      db = d;
      await billingFixture(d);
    });
    await _run(tester);
    await tester.enterText(_search, 'amoxi');
    await _run(tester, 300);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(find.text('Prescribing doctor — required (Schedule H item in bill)'), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.f10);
    await _run(tester, 300);
    expect(c.read(toastsProvider).last.text, 'Schedule H item in bill — enter the prescribing doctor');
    expect(c.read(billControllerProvider).lines, hasLength(1));
    await tester.runAsync(() async => expect(await countOf(db, 'invoices'), 0));

    // F4 → customer field; then fill the doctor and save.
    await _key(tester, LogicalKeyboardKey.f4);
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('bill-doctor')), matching: find.byType(TextField)), 'Dr. K. Lalnunmawii');
    await _run(tester, 100);
    await tester.ensureVisible(find.byKey(const ValueKey('save-bill')));
    await tester.tap(find.byKey(const ValueKey('save-bill')));
    await _run(tester, 600);
    await tester.runAsync(() async => expect(await countOf(db, 'invoices'), 1));
  });

  testWidgets('barcode scan + Enter adds immediately; Esc clears; F8 cycles payment; F2 new bill', (tester) async {
    final c = await pumpApp(tester, size: const Size(1440, 900), setUpDb: billingFixture);
    await _run(tester);
    await tester.enterText(_search, 'crocin');
    await _key(tester, LogicalKeyboardKey.enter); // before debounce
    expect(c.read(billControllerProvider).lines.single.name, 'Crocin Advance');

    await tester.enterText(_search, 'xyz');
    await _run(tester, 300);
    expect(find.textContaining('No medicine matches'), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.escape);
    expect(c.read(billControllerProvider).query, '');

    await _key(tester, LogicalKeyboardKey.f8);
    expect(c.read(billControllerProvider).payment, 'UPI');

    await _key(tester, LogicalKeyboardKey.f2);
    expect(c.read(billControllerProvider).lines, isEmpty);
    expect(find.text('Bill is empty'), findsOneWidget);
  });

  testWidgets('out of stock shows substitutes; qty field clamps to batch stock', (tester) async {
    final c = await pumpApp(tester, size: const Size(1440, 900), setUpDb: billingFixture);
    await _run(tester);
    await tester.enterText(_search, 'ibuprofen');
    await _run(tester, 300);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(find.text('Ibuprofen 400 mg Tablet is out of stock'), findsOneWidget);
    expect(find.text('Brufen 400'), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.enter);
    final line = c.read(billControllerProvider).lines.single;
    expect(line.name, 'Brufen 400');

    final qty = find.byKey(ValueKey('qty-${line.key}'));
    await tester.enterText(qty, '50');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _run(tester, 200);
    expect(c.read(billControllerProvider).lines.single.qty, 12);
  });

  testWidgets('billing lays out on tablet portrait without overflow', (tester) async {
    await pumpApp(tester, size: tabletPortrait, setUpDb: billingFixture);
    await _run(tester);
    expect(tester.takeException(), isNull);
  });
}
