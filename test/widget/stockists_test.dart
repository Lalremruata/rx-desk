import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/purchases_dao.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/purchases/presentation/stockists_tab.dart';
import 'package:rx_desk/features/sales_register/application/register_export.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_db.dart';

Future<void> _run(WidgetTester tester, [int ms = 500]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester tester, String key, [int ms = 500]) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey(key)));
  await _run(tester, ms);
}

List<String> _toasts(ProviderContainer c) => [for (final t in c.read(toastsProvider)) t.text];

/// A small "Damdawi lak na" workbook, written like the store's sheet.
Uint8List _workbook() => buildXlsx(
      const ExportTable(
        title: 'Damdawi lak na',
        headerBlock: ['Damdawi lak na'],
        columns: ['Sl.No', 'Dawr Hming', 'Damdawi hming', 'Phone numb', 'MR Hming'],
        rows: [
          [1, 'EMY PHARMACY', 'Tab. Paracetamol 650', '9862958415', ''],
          [2, 'EMY PHARMACY', 'Judiliv Syrub 200ml', 'or', ''],
          [3, 'EMY PHARMACY', 'Syp.Ostcred 60ml', '0389-2323442', ''],
          [4, 'RB PAHRMACY', 'Nitrocube Sr 100', '7005679742', 'Tluangtea'],
        ],
        totals: [],
      ),
      sheetName: 'Damdawi lak na',
    );

void main() {
  setUpAll(setUpFormatting);

  testWidgets('import the sheet → review → directory; edit links a medicine; Get from in Inventory', (tester) async {
    late AppDatabase db;
    final bytes = _workbook();
    final c = await pumpApp(
      tester,
      size: const Size(1440, 1000),
      location: '/purchases',
      setUpDb: (d) async {
        db = d;
        await addMed(d);
        await addMed(d, name: 'Ascoril LS Syrup', salt: 'Ambroxol', batch: 'ASC1', category: 'Syrup');
      },
      overrides: [directoryFilePickerProvider.overrideWithValue(() async => ('Daily Sales.xlsx', bytes))],
    );
    await _run(tester);
    await tester.tap(find.text('Stockists'));
    await _run(tester);
    expect(find.text('No stockists listed yet'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sources-import')));
    // The workbook is parsed in another isolate: let real time pass.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await _run(tester, 900);
    expect(find.textContaining('2 stockists · 4 medicines · 1 found in the catalogue · 3 not'), findsOneWidget);
    // Skip Ostcred (sheet row 5: header block, blank, columns, then rows).
    final ostcred = find.byKey(const ValueKey('import-row-6'));
    expect(find.descendant(of: ostcred, matching: find.text('Syp.Ostcred 60ml')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('import-choice-6')), matching: find.text('Skip')));
    await _run(tester, 100);
    expect(find.text('3 to import · 1 skipped'), findsOneWidget);
    await _tap(tester, 'import-save', 900);
    expect(_toasts(c).last, 'Imported 3 lines · 1 linked to the catalogue · 2 new stockists');

    expect(find.text('Paracetamol 650 mg Tablet'), findsOneWidget);
    expect(find.text('Judiliv Syrub 200ml'), findsOneWidget);
    expect(find.text('Syp.Ostcred 60ml'), findsNothing);
    expect(find.text('9862958415 / 0389-2323442'), findsWidgets);
    expect(find.text('Tluangtea'), findsOneWidget);
    expect(find.text('Not in catalogue'), findsNWidgets(2));

    // Search by MR.
    await tester.enterText(find.byKey(const ValueKey('sources-search')), 'tluang');
    await _run(tester, 400);
    expect(find.text('Judiliv Syrub 200ml'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('sources-search')), '');
    await _run(tester, 400);

    // Link "Judiliv" to Ascoril (id 2) via Edit → Change → pick.
    final judiliv = await tester.runAsync(() async => (await db.sourcesDao.page(search: 'judiliv')).rows.single);
    await _tap(tester, 'source-edit-${judiliv!.id}');
    await tester.tap(find.text('Change'));
    await _run(tester, 100);
    await tester.enterText(find.byKey(const ValueKey('source-pick')), 'ascoril');
    await _run(tester, 400);
    await tester.tap(find.byKey(const ValueKey('pick-2')));
    await _run(tester, 200);
    await tester.enterText(find.byKey(const ValueKey('source-mr')), 'Muana');
    await _tap(tester, 'source-save', 600);
    await tester.runAsync(() async {
      final s = await db.sourcesDao.sourcesFor(2);
      expect((s.single.supplierName, s.single.mrName), ('EMY PHARMACY', 'Muana'));
    });

    // Inventory batch panel shows where to get it.
    await tester.tap(find.text('Inventory').first);
    await _run(tester, 600);
    await tester.tap(find.byTooltip('Show batches').first);
    await _run(tester, 400);
    expect(find.byKey(const ValueKey('get-from-2')), findsOneWidget);
    expect(find.textContaining('EMY PHARMACY · 9862958415 / 0389-2323442 · MR Muana'), findsOneWidget);
  });

  testWidgets('receiving an invoice adds the stockist; Pending shows "Get from"', (tester) async {
    await pumpApp(tester, size: const Size(1440, 1000), location: '/purchases', setUpDb: (d) async {
      final (p, _) = await addMed(d);
      await d.purchasesDao.receive(
        ReceiveRequest(
          supplierName: 'Life Drugs Centre',
          invoiceNo: 'L1',
          receivedDate: '2026-11-02',
          lines: [ReceiveLineInput(productId: p, batchNo: 'PCM2611', qty: 1, unit: 'Box', stockUnits: 10, amount: const Paise(10000))],
        ),
        at: testNow,
        now: testNow,
      );
      await d.purchasesDao.addOrderLines('2026-11-09', [NewOrderLine(productId: p, itemName: '', qty: 2, unit: 'Box')], at: testNow);
    });
    await _run(tester);
    expect(find.text('Get from Life Drugs Centre'), findsOneWidget);
    await tester.tap(find.text('Stockists'));
    await _run(tester);
    expect(find.text('From invoices'), findsOneWidget);
  });

  testWidgets('Stockists tab fits a portrait tablet', (tester) async {
    await pumpApp(tester, size: tabletPortrait, location: '/purchases', setUpDb: (d) async {
      await d.sourcesDao.add(supplierName: 'EMY PHARMACY', itemName: 'Judiliv Syrub 200ml', mrName: 'Tluangtea', at: testNow);
    });
    await _run(tester);
    await tester.tap(find.text('Stockists'));
    await _run(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Judiliv Syrub 200ml'), findsOneWidget);
  });
}
