import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/billing/application/bill_controller.dart';
import 'package:rx_desk/features/invoices/presentation/invoice_paper.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_db.dart';

Future<void> _run(WidgetTester tester, [int ms = 400]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _ceti(AppDatabase db) async {
  // ₹30.90 per strip of 10; 25 tabs = 2 strips + 5.
  await addMed(db, name: 'Cetirizine 10 mg Tablet', salt: 'Cetirizine 10 mg', batch: 'CTZ1', qty: 25, packSize: 10);
}

void main() {
  setUpAll(setUpFormatting);

  testWidgets('bill 5 loose tabs with the Strip/Tab switch; invoice shows "5 tab"', (tester) async {
    late AppDatabase db;
    final c = await pumpApp(tester, size: const Size(1440, 900), setUpDb: (d) async {
      db = d;
      await _ceti(d);
    });
    await _run(tester);
    await tester.enterText(find.byKey(const ValueKey('billing-search')), 'ceti');
    await _run(tester, 300);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _run(tester);

    final key = c.read(billControllerProvider).lines.single.key;
    expect(find.byKey(ValueKey('unit-$key')), findsOneWidget);
    expect(find.text('Strip'), findsOneWidget);
    expect(find.text('per strip of 10'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('unit-$key')));
    await _run(tester, 200);
    expect(find.text('Tab'), findsOneWidget);
    final qty = find.byKey(ValueKey('qty-$key'));
    expect(tester.widget<TextField>(qty).controller!.text, '10');
    await tester.enterText(qty, '5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _run(tester, 200);
    expect(c.read(billControllerProvider).lines.single.qty, 5);
    expect(find.text('₹15.45'), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await _run(tester, 800);
    expect(c.read(toastsProvider).map((t) => t.text).first, startsWith('INV/26-27/00001 saved · ₹15.00'));
    expect(find.byType(InvoicePaperView), findsOneWidget);
    expect(find.text('5 tab'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await qtyOf(db, 1), 20);
    });
  });

  testWidgets('T / S keys in the qty field switch the unit', (tester) async {
    final c = await pumpApp(tester, size: const Size(1440, 900), setUpDb: _ceti);
    await _run(tester);
    await tester.enterText(find.byKey(const ValueKey('billing-search')), 'ceti');
    await _run(tester, 300);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _run(tester);
    final key = c.read(billControllerProvider).lines.single.key;
    await tester.tap(find.byKey(ValueKey('qty-$key')));
    await _run(tester, 100);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await _run(tester, 100);
    expect(c.read(billControllerProvider).lines.single.loose, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await _run(tester, 100);
    expect(c.read(billControllerProvider).lines.single.loose, isFalse);
  });

  testWidgets('Inventory › Sell loose… converts 12 strips to 120 tabs', (tester) async {
    late AppDatabase db;
    final c = await pumpApp(tester, size: const Size(1600, 1000), location: '/inventory', setUpDb: (d) async {
      db = d;
      await addMed(d, name: 'Azithral 500', salt: 'Azithromycin 500 mg', batch: 'AZ1', qty: 12);
    });
    await _run(tester);
    await tester.tap(find.byTooltip('Show batches').first);
    await _run(tester, 600);
    await tester.ensureVisible(find.byKey(const ValueKey('pack-size-1')));
    await tester.tap(find.byKey(const ValueKey('pack-size-1')));
    await _run(tester);
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('pack-size')), matching: find.byType(TextField)), '10');
    await _run(tester, 200);
    expect(find.textContaining('Stock becomes 12 strips'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pack-size-save')));
    await _run(tester, 600);
    expect(c.read(toastsProvider).map((t) => t.text), contains('Azithral 500: 10 tabs per strip — can be sold loose'));
    await tester.runAsync(() async {
      expect(await qtyOf(db, 1), 120);
    });
    expect(find.text('12 strips'), findsWidgets);
  });
}
