import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/purchases_dao.dart';
import 'package:rx_desk/core/db/db_provider.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/widgets/widgets.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_db.dart';

Future<void> _seed(AppDatabase db) async {
  await addMed(db); // id 1, batch PCM2611, qty 100
  await addMed(db, name: 'Amoxicillin 500 mg Capsule', salt: 'Amoxicillin 500 mg', batch: 'AMX0942', qty: 18, category: 'Capsule');
}

Future<void> _run(WidgetTester tester, [int ms = 600]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
}

List<String> _toasts(ProviderContainer c) => [for (final t in c.read(toastsProvider)) t.text];

void main() {
  setUpAll(setUpFormatting);

  testWidgets('order → pending → receive part → close short → order book and receipts', (tester) async {
    final c = await pumpApp(tester, size: const Size(1440, 1000), location: '/purchases', setUpDb: _seed);
    final db = c.read(appDatabaseProvider);
    await _run(tester);
    expect(find.text('Nothing on order'), findsOneWidget);

    // New order: one catalogue item, one free-text item.
    await tester.tap(find.byKey(const ValueKey('new-order')));
    await _run(tester);
    await _type(tester, 'order-search', 'para');
    await _run(tester, 300);
    await tester.tap(find.byKey(const ValueKey('pick-1')));
    await tester.pump();
    await _type(tester, 'order-search', 'Mycospor Cream');
    await _run(tester, 300);
    await tester.tap(find.byKey(const ValueKey('pick-free-text')));
    await tester.pump();
    await _type(tester, 'order-qty-0', '10');
    await _type(tester, 'order-qty-1', '20');
    await tester.ensureVisible(find.byKey(const ValueKey('order-save')));
    await tester.tap(find.byKey(const ValueKey('order-save')));
    await _run(tester);
    expect(_toasts(c), contains('2 items added to the order for Mon 9 Nov 26'));
    expect(find.text('Mycospor Cream'), findsOneWidget);
    expect(find.text('Free text'), findsOneWidget);

    // Receive 6 of 10 on one stockist invoice.
    await tester.tap(find.byKey(const ValueKey('receive-line-1')));
    await _run(tester);
    expect(find.text('Save and add to stock'), findsOneWidget);
    await _type(tester, 'recv-supplier', 'Life Drugs Centre');
    await _type(tester, 'recv-invoice', '26000730032563');
    await _type(tester, 'recv-qty-0', '6');
    await _type(tester, 'recv-batch-0', 'pcm2611');
    await _run(tester, 100);
    expect(find.textContaining('Adding to batch PCM2611'), findsOneWidget);
    expect(find.text('Still expecting more from this order'), findsOneWidget);
    await _type(tester, 'recv-units-0', '60');
    await _type(tester, 'recv-amount-0', '360.50');
    expect(find.text('₹360.50'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('recv-save-invoice')));
    await tester.tap(find.byKey(const ValueKey('recv-save-invoice')));
    await _run(tester);
    expect(_toasts(c).last, 'Invoice 26000730032563 saved · 1 line · +60 units · ₹360.50');
    expect(await tester.runAsync(() => qtyOf(db, 1)), 160);
    expect(find.text('Part supplied'), findsOneWidget);
    expect(find.text('4 due'), findsOneWidget);

    // Close the rest short.
    await tester.tap(find.byKey(const ValueKey('close-line-1')));
    await _run(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Close short'));
    await _run(tester);
    expect(_toasts(c).last, 'Paracetamol 650 mg Tablet closed short');
    expect(find.text('Part supplied'), findsNothing);
    expect(find.text('Mycospor Cream'), findsOneWidget);

    // Order book for today: both lines, total, Short tag.
    await tester.tap(find.text('Order book'));
    await _run(tester);
    expect(find.text('Paracetamol 650 mg Tablet'), findsOneWidget);
    expect(find.text('Life Drugs Centre'), findsOneWidget);
    expect(find.text('Short'), findsOneWidget);
    expect(find.text('Pending'), findsWidgets);
    expect(tester.widget<Text>(find.byKey(const ValueKey('book-total'))).data, '₹360.50');

    // Receipts.
    await tester.tap(find.text('Receipts'));
    await _run(tester);
    expect(find.text('26000730032563'), findsOneWidget);
    await tester.tap(find.text('26000730032563'));
    await _run(tester);
    expect(find.text('PCM2611'), findsOneWidget);
  });

  testWidgets('free-text line must be linked before receiving; tablet portrait has no overflow', (tester) async {
    final c = await pumpApp(
      tester,
      size: tabletPortrait,
      location: '/purchases',
      setUpDb: (db) async {
        await _seed(db);
        await db.purchasesDao.addOrderLines('2026-11-09', [const NewOrderLine(itemName: 'Amoxy caps', qty: 5, unit: 'Strip')], at: t0);
      },
    );
    await _run(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('receive-line-1')));
    await _run(tester, 100);
    await tester.tap(find.byKey(const ValueKey('receive-line-1')));
    await _run(tester);
    expect(find.textContaining('was ordered as free text'), findsOneWidget);
    await _type(tester, 'recv-supplier', 'FMT Pharmacy');
    await _type(tester, 'recv-invoice', 'FP/401/26-27');
    await tester.ensureVisible(find.byKey(const ValueKey('recv-save-invoice')));
    await tester.tap(find.byKey(const ValueKey('recv-save-invoice')));
    await _run(tester);
    expect(_toasts(c).last, 'Check the highlighted fields');
    expect(find.text('Pick the medicine this is'), findsOneWidget);

    await _type(tester, 'recv-link-0', 'amox');
    await _run(tester, 300);
    await tester.tap(find.byKey(const ValueKey('pick-2')));
    await _run(tester, 100);
    await _type(tester, 'recv-batch-0', 'AMX0942');
    await tester.ensureVisible(find.byKey(const ValueKey('recv-save-invoice')));
    await tester.tap(find.byKey(const ValueKey('recv-save-invoice')));
    await _run(tester);
    expect(_toasts(c).last, startsWith('Invoice FP/401/26-27 saved'));
    final row = (await tester.runAsync(() => c.read(appDatabaseProvider).purchasesDao.orderRows([1])))!.single;
    expect(row.productId, 2);
  });

  testWidgets('free-text "10 Box": strips per box is asked, multiplies into stock and is remembered; add-from-receive has no opening stock', (tester) async {
    final c = await pumpApp(
      tester,
      size: tabletPortrait,
      location: '/purchases',
      setUpDb: (db) async {
        await _seed(db);
        await db.purchasesDao.addOrderLines('2026-11-09', [
          const NewOrderLine(itemName: 'Paracetamol', qty: 10, unit: 'Box'),
          const NewOrderLine(itemName: 'Paracetamol', qty: 2, unit: 'Box'),
        ], at: t0);
      },
    );
    String field(String key) => tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;
    await _run(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('receive-line-1')));
    await _run(tester, 100);
    await tester.tap(find.byKey(const ValueKey('receive-line-1')));
    await _run(tester);

    // Adding a new medicine from a receipt: no opening stock (the receipt adds it).
    await _type(tester, 'recv-link-0', 'Crocin');
    await _run(tester, 300);
    await tester.tap(find.byKey(const ValueKey('pick-add-medicine')));
    await _run(tester);
    expect(find.byKey(const ValueKey('add-perbox')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-qty')), findsNothing);
    expect(find.byKey(const ValueKey('add-batch')), findsNothing);
    await tester.tap(find.byTooltip('Close').last);
    await _run(tester);

    await _type(tester, 'recv-link-0', 'para');
    await _run(tester, 300);
    await tester.tap(find.byKey(const ValueKey('pick-1')));
    await _run(tester, 100);
    expect(find.byKey(const ValueKey('recv-perbox-0')), findsOneWidget);
    expect(field('recv-units-0'), '');
    await _type(tester, 'recv-supplier', 'FMT Pharmacy');
    await _type(tester, 'recv-invoice', 'FP/501/26-27');
    await _type(tester, 'recv-batch-0', 'PCM2611');
    await tester.ensureVisible(find.byKey(const ValueKey('recv-save-invoice')));
    await tester.tap(find.byKey(const ValueKey('recv-save-invoice')));
    await _run(tester);
    expect(_toasts(c).last, 'Check the highlighted fields');
    expect(find.text('How many strips in a box?'), findsOneWidget);

    await _type(tester, 'recv-perbox-0', '15');
    expect(field('recv-units-0'), '150');
    expect(find.byKey(const ValueKey('recv-boxmaths-0')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('recv-save-invoice')));
    await tester.tap(find.byKey(const ValueKey('recv-save-invoice')));
    await _run(tester);
    expect(_toasts(c).last, startsWith('Invoice FP/501/26-27 saved'));
    final db = c.read(appDatabaseProvider);
    final p = (await tester.runAsync(() => db.catalogDao.stockRow(1, now: t0)))!;
    expect((p.saleable, p.packsPerBox), (250, 15));

    // Next Box receipt for the same medicine: prefilled from the medicine.
    await tester.ensureVisible(find.byKey(const ValueKey('receive-line-2')));
    await _run(tester, 100);
    await tester.tap(find.byKey(const ValueKey('receive-line-2')));
    await _run(tester);
    await _type(tester, 'recv-link-0', 'para');
    await _run(tester, 300);
    await tester.tap(find.byKey(const ValueKey('pick-1')));
    await _run(tester, 100);
    expect((field('recv-perbox-0'), field('recv-units-0')), ('15', '30'));
  });

  testWidgets('receive with rate details: amount from rate, free goods in stock, a new batch MRP is saved', (tester) async {
    final c = await pumpApp(
      tester,
      location: '/purchases',
      setUpDb: (db) async {
        await _seed(db);
        await db.purchasesDao.addOrderLines('2026-11-09', [const NewOrderLine(productId: 1, itemName: '', qty: 10, unit: 'Strip')], at: t0);
      },
    );
    String field(String key) => tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;
    await _run(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('receive-line-1')));
    await _run(tester, 100);
    await tester.tap(find.byKey(const ValueKey('receive-line-1')));
    await _run(tester);
    await _type(tester, 'recv-supplier', 'FMT Pharmacy');
    await _type(tester, 'recv-invoice', 'FP/601/26-27');
    await _type(tester, 'recv-free-0', '1');
    expect(field('recv-units-0'), '11');
    await _type(tester, 'recv-rate-0', '20');
    await _type(tester, 'recv-disc-0', '5');
    expect(field('recv-amount-0'), '212.80'); // 200 − 10 + 12 % GST
    expect(find.byKey(const ValueKey('recv-cost-0')), findsOneWidget);
    await _type(tester, 'recv-batch-0', 'PCM2701');
    await _type(tester, 'recv-expiry-0', '01/2029');
    expect(field('recv-mrp-0'), '30.90');
    await _type(tester, 'recv-mrp-0', '33.60');
    expect(find.byKey(const ValueKey('recv-mrpnote-0')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('recv-save-invoice')));
    await tester.tap(find.byKey(const ValueKey('recv-save-invoice')));
    await _run(tester);
    expect(_toasts(c).last, startsWith('Invoice FP/601/26-27 saved'));
    final db = c.read(appDatabaseProvider);
    final b = (await tester.runAsync(() => db.catalogDao.batchesOf(1)))!.firstWhere((x) => x.batchNo == 'PCM2701');
    expect((b.qty, b.mrpPaise), (11, 3360));
    final p = (await tester.runAsync(() => db.catalogDao.stockRow(1, now: t0)))!;
    expect(p.mrp, const Paise(3360));
  });
}
