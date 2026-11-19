import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/db_provider.dart';
import 'package:rx_desk/core/widgets/widgets.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_db.dart';

Future<void> _seed(AppDatabase db) async {
  await addMed(db, barcode: '8904021650153', qty: 142);
  await addMed(db, name: 'Amoxicillin 500 mg Capsule', salt: 'Amoxicillin 500 mg', maker: 'Aurelis Labs', schedule: 'H', batch: 'AMX0942', qty: 18, category: 'Capsule', mrp: 9850);
  await addMed(db, name: 'Ibuprofen 400 mg Tablet', salt: 'Ibuprofen 400 mg', batch: 'IBU6650', qty: 0, mrp: 3800);
  await addMed(db, name: 'Dextromethorphan Syrup', salt: 'Dextromethorphan 100 ml', batch: 'DXM3901', expiry: '2026-12', qty: 4, category: 'Syrup', mrp: 11800);
}

Future<void> _run(WidgetTester tester, [int ms = 600]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(setUpFormatting);

  testWidgets('views, counts, sort, expand', (tester) async {
    await pumpApp(tester, size: const Size(1600, 1000), location: '/inventory', setUpDb: _seed);
    await _run(tester);
    expect(find.text('Paracetamol 650 mg Tablet'), findsOneWidget);
    expect(find.text('4 medicines · batch-wise stock and expiry'), findsOneWidget);
    expect(find.text('1–4 of 4'), findsOneWidget);

    // Out of stock view.
    await tester.tap(find.byKey(const ValueKey('view-out')));
    await _run(tester);
    expect(find.text('Ibuprofen 400 mg Tablet'), findsOneWidget);
    expect(find.text('Paracetamol 650 mg Tablet'), findsNothing);

    // Expiring view → the Dec batch.
    await tester.tap(find.byKey(const ValueKey('view-expiring')));
    await _run(tester);
    expect(find.text('Dextromethorphan Syrup'), findsOneWidget);
    expect(find.text('Expiring'), findsOneWidget);

    // All, sorted by stock descending.
    await tester.tap(find.byKey(const ValueKey('view-all')));
    await _run(tester);
    await tester.tap(find.text('Saleable stock'));
    await _run(tester);
    await tester.tap(find.text('Saleable stock'));
    await _run(tester);
    final names = tester.widgetList<Text>(find.textContaining(RegExp(r'(Tablet|Capsule|Syrup)$'))).map((t) => t.data).toList();
    expect(names.first, 'Paracetamol 650 mg Tablet');

    // Expand batches.
    await tester.tap(find.byTooltip('Show batches').first);
    await _run(tester);
    expect(find.text('Sell first (FEFO)'), findsOneWidget);
  });

  testWidgets('receive into an existing batch, then into a new batch', (tester) async {
    final c = await pumpApp(tester, size: const Size(1600, 1000), location: '/inventory', setUpDb: _seed);
    await _run(tester);
    final receive = find.text('Receive');
    await tester.tap(receive.first);
    await _run(tester);
    expect(find.text('Receive stock'), findsOneWidget);

    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('recv-batch')), matching: find.byType(TextField)), 'amx0942');
    await tester.pump();
    expect(find.textContaining('Adding to existing batch AMX0942'), findsOneWidget);
    await tester.tap(find.text('+25'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('recv-save')));
    await _run(tester);
    expect(find.text('+25 received into batch AMX0942'), findsOneWidget);
    expect(find.text('43'), findsWidgets); // 18 + 25

    // New batch needs an expiry.
    await tester.tap(find.text('Receive').first);
    await _run(tester);
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('recv-batch')), matching: find.byType(TextField)), 'NEW77');
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('recv-qty')), matching: find.byType(TextField)), '10');
    await tester.tap(find.byKey(const ValueKey('recv-save')));
    await _run(tester);
    expect(find.textContaining('enter its expiry'), findsWidgets);
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('recv-expiry')), matching: find.byType(TextField)), '03/2028');
    await tester.tap(find.byKey(const ValueKey('recv-save')));
    await _run(tester);
    expect(c.read(toastsProvider).map((t) => t.text), contains('+10 received into batch NEW77'));
  });

  testWidgets('add medicine validates, saves and shows the new row', (tester) async {
    final c = await pumpApp(tester, size: const Size(1600, 1000), location: '/inventory', setUpDb: _seed);
    await _run(tester);
    await tester.tap(find.byKey(const ValueKey('add-medicine')));
    await _run(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('save-medicine')));
    await tester.tap(find.byKey(const ValueKey('save-medicine')));
    await _run(tester, 200);
    expect(find.text('Enter the medicine name'), findsOneWidget);

    Future<void> type(String key, String v) =>
        tester.enterText(find.descendant(of: find.byKey(ValueKey('add-$key')), matching: find.byType(TextField)), v);
    await type('name', 'Levocetirizine 5 mg Tablet');
    await type('maker', 'Lumina Remedies');
    await type('batch', 'LEV100');
    await type('expiry', '06/2028');
    await type('qty', '60');
    await type('mrp', '35.50');
    await tester.ensureVisible(find.byKey(const ValueKey('save-medicine')));
    await tester.tap(find.byKey(const ValueKey('save-medicine')));
    await _run(tester);
    expect(c.read(toastsProvider).map((t) => t.text), contains('Levocetirizine 5 mg Tablet added to inventory'));
    expect(find.text('Levocetirizine 5 mg Tablet added to inventory'), findsOneWidget);
    expect(find.text('Levocetirizine 5 mg Tablet'), findsNWidgets(2)); // row + search box
    expect(find.text('₹35.50'), findsWidgets);
    expect(find.byType(StatusBadge), findsWidgets);
  });

  testWidgets('same name, different salt: warns, Cancel keeps the form, Save anyway adds a second medicine', (tester) async {
    final c = await pumpApp(tester, size: const Size(1600, 1000), location: '/inventory', setUpDb: _seed);
    await _run(tester);
    final before = (await tester.runAsync(() => c.read(appDatabaseProvider).catalogDao.productsNamed('Paracetamol 650 mg Tablet')))!;
    expect(before, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('add-medicine')));
    await _run(tester);
    Future<void> type(String key, String v) =>
        tester.enterText(find.descendant(of: find.byKey(ValueKey('add-$key')), matching: find.byType(TextField)), v);
    await type('name', 'paracetamol 650 mg tablet');
    await type('salt', 'Paracetamol 650 mg + Caffeine 50 mg');
    await type('maker', 'Aurelis Labs');
    await type('mrp', '42');
    Future<void> save() async {
      await tester.ensureVisible(find.byKey(const ValueKey('save-medicine')));
      await tester.tap(find.byKey(const ValueKey('save-medicine')));
      await _run(tester);
    }

    await save();
    expect(find.text('Medicine name already exists'), findsOneWidget);
    expect(find.textContaining('Paracetamol 650 mg · Northline Pharma'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(ConfirmDialog), matching: find.text('Cancel')));
    await _run(tester);
    expect(find.text('Medicine name already exists'), findsNothing);
    expect(find.byKey(const ValueKey('save-medicine')), findsOneWidget); // form still open
    expect(c.read(toastsProvider).map((t) => t.text), isNot(contains('paracetamol 650 mg tablet added to inventory')));

    await save();
    await tester.tap(find.text('Save anyway'));
    await _run(tester);
    expect(c.read(toastsProvider).map((t) => t.text), contains('paracetamol 650 mg tablet added to inventory'));
    final after = (await tester.runAsync(() => c.read(appDatabaseProvider).catalogDao.productsNamed('Paracetamol 650 mg Tablet')))!;
    expect(after.map((m) => m.salt), containsAll(['Paracetamol 650 mg', 'Paracetamol 650 mg + Caffeine 50 mg']));
  });

  Future<void> typeIn(WidgetTester tester, String key, String v) =>
      tester.enterText(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(TextField)), v);

  testWidgets('edit batch: counted stock with a reason updates the batch', (tester) async {
    final c = await pumpApp(tester, size: const Size(1600, 1000), location: '/inventory', setUpDb: _seed);
    await _run(tester);
    await tester.tap(find.byTooltip('Show batches').last); // Paracetamol sorts last
    await _run(tester);
    await tester.tap(find.byKey(const ValueKey('edit-batch-PCM2611')));
    await _run(tester);
    expect(find.text('Edit batch PCM2611'), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-batch-history')), findsOneWidget);

    await typeIn(tester, 'edit-batch-packs', '140');
    await tester.pump();
    expect(find.textContaining('Stock 142 → 140'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('edit-batch-save')));
    await tester.tap(find.byKey(const ValueKey('edit-batch-save')));
    await _run(tester, 200);
    expect(find.text('Pick a reason'), findsOneWidget);

    await tester.tap(find.text('Damaged'));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('edit-batch-save')));
    await tester.tap(find.byKey(const ValueKey('edit-batch-save')));
    await _run(tester);
    expect(c.read(toastsProvider).map((t) => t.text), contains('Batch PCM2611 updated · stock 142 → 140'));
    final qty = tester.widget<Text>(find.byKey(const ValueKey('batch-qty-PCM2611')));
    expect(qty.data, '140');
  });

  testWidgets('edit medicine: new MRP shows in the grid', (tester) async {
    final c = await pumpApp(tester, size: const Size(1600, 1000), location: '/inventory', setUpDb: _seed);
    await _run(tester);
    await tester.tap(find.byTooltip('Show batches').last);
    await _run(tester);
    await tester.tap(find.text('Edit medicine'));
    await _run(tester);
    expect(find.text('Edit medicine'), findsWidgets);
    expect(find.byKey(const ValueKey('add-batch')), findsNothing);
    await typeIn(tester, 'add-mrp', '33.60');
    await tester.pump();
    expect(find.textContaining('applies to new bills only'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('save-medicine')));
    await tester.tap(find.byKey(const ValueKey('save-medicine')));
    await _run(tester);
    expect(c.read(toastsProvider).map((t) => t.text), contains('Paracetamol 650 mg Tablet updated'));
    expect(find.text('₹33.60'), findsWidgets);
  });

  testWidgets('hide a medicine, find it under Hidden, unhide it', (tester) async {
    final c = await pumpApp(tester, size: const Size(1600, 1000), location: '/inventory', setUpDb: _seed);
    await _run(tester);
    expect(find.byKey(const ValueKey('view-hidden')), findsNothing);
    await tester.tap(find.byTooltip('Show batches').last);
    await _run(tester);
    await tester.tap(find.text('Hide medicine'));
    await _run(tester);
    expect(find.text('Hide Paracetamol 650 mg Tablet?'), findsOneWidget);
    await tester.tap(find.text('Hide'));
    await _run(tester);
    expect(c.read(toastsProvider).map((t) => t.text), contains('Paracetamol 650 mg Tablet hidden — find it under Hidden'));
    expect(find.text('Paracetamol 650 mg Tablet'), findsNothing);
    expect(find.text('1–3 of 3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('view-hidden')));
    await _run(tester);
    expect(find.text('Paracetamol 650 mg Tablet'), findsOneWidget);
    await tester.tap(find.text('Unhide'));
    await _run(tester);
    expect(c.read(toastsProvider).map((t) => t.text), contains('Paracetamol 650 mg Tablet is back on sale'));
    await tester.tap(find.byKey(const ValueKey('view-all')));
    await _run(tester);
    expect(find.text('1–4 of 4'), findsOneWidget);
  });

  testWidgets('tablet portrait: batch panel, edit batch and edit medicine lay out without overflow', (tester) async {
    await pumpApp(tester, size: const Size(800, 1280), location: '/inventory', setUpDb: _seed);
    await _run(tester);
    await tester.ensureVisible(find.byTooltip('Show batches').last);
    await tester.tap(find.byTooltip('Show batches').last);
    await _run(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('edit-batch-PCM2611')));
    await tester.tap(find.byKey(const ValueKey('edit-batch-PCM2611')));
    await _run(tester);
    await typeIn(tester, 'edit-batch-packs', '1');
    await tester.pump();
    expect(find.text('Damaged'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _run(tester);
    await tester.ensureVisible(find.text('Edit medicine'));
    await tester.tap(find.text('Edit medicine'));
    await _run(tester);
    expect(find.byKey(const ValueKey('save-medicine')), findsOneWidget);
  });
}
