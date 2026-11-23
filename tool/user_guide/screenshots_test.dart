// Screenshots for docs/user-guide/images.
//
//   flutter test tool/user_guide/screenshots_test.dart
//   node tool/user_guide/build_pdf.mjs
//
// Runs the real screens on the demo data (seedDemoData + a few purchases) at
// 1280×800 and saves each one at 2× as a PNG. Not part of the normal test
// suite. Delete build/user_guide/demo.sqlite to rebuild the demo data.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/dues_dao.dart';
import 'package:rx_desk/core/db/daos/purchases_dao.dart';
import 'package:rx_desk/core/db/models.dart';
import 'package:rx_desk/core/db/seed/seed.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';
import 'package:rx_desk/features/shell/presentation/app_shell.dart';
import 'package:rx_desk/features/staff/application/session.dart';
import 'package:rx_desk/features/staff/data/staff_repository.dart';

import '../../test/helpers/pump_app.dart';

const _out = 'docs/user-guide/images';
const _demo = 'build/user_guide/demo.sqlite';

/// A made-up store for the pictures.
const _settings = AppSettings(
  autoBackup: false,
  name: 'Zion Medicos',
  phone: '0389 2345678',
  addr1: 'Main Road, Dawrpui',
  city: 'Aizawl',
  state: 'Mizoram',
  pin: '796001',
  gstin: '15ABCDE1234F1Z5',
  dl20b: 'MZ-AZL-20B-1234',
  dl21b: 'MZ-AZL-21B-1234',
  pharmacistName: 'C. Lalhmingliani',
  pharmacistRegNo: 'MZPC/2019/0456',
  upiId: 'zionmedicos@upi',
);
const _owner = SessionUser(name: 'Zoremi', role: StaffRole.owner);

// ---------------------------------------------------------------------------
// Fonts and capture

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final l = FontLoader(family);
    for (final p in paths) {
      l.addFont(Future.value(ByteData.sublistView(File(p).readAsBytesSync())));
    }
    await l.load();
  }

  const f = 'assets/fonts';
  await load('Inter', ['$f/Inter-Regular.ttf', '$f/Inter-Medium.ttf', '$f/Inter-SemiBold.ttf', '$f/Inter-Bold.ttf']);
  await load('SpaceGrotesk', ['$f/SpaceGrotesk-Medium.ttf', '$f/SpaceGrotesk-SemiBold.ttf', '$f/SpaceGrotesk-Bold.ttf']);
  final root = Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final material = '$root/bin/cache/artifacts/material_fonts';
  await load('MaterialIcons', ['$material/MaterialIcons-Regular.otf']);
  await load('Roboto', ['$material/Roboto-Regular.ttf', '$material/Roboto-Medium.ttf', '$material/Roboto-Bold.ttf']);
  for (final mono in ['/System/Library/Fonts/Menlo.ttc', r'C:\Windows\Fonts\consola.ttf']) {
    if (File(mono).existsSync()) await load('Consolas', [mono]);
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  await _run(tester, 400);
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  await tester.runAsync(() async {
    final img = await layer.toImage(view.paintBounds, pixelRatio: 2);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$_out/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  // Debug flags must be back to normal before the test body ends.
  debugDisableShadows = true;
  debugDefaultTargetPlatformOverride = null;
}

Future<void> _run(WidgetTester tester, [int ms = 600]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)).first, text);
  await _run(tester, 300);
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f.first);
  await _run(tester, 100);
  await tester.tap(f.first);
  await _run(tester);
}

/// Scrolls [f] into view, [alignment] 0 = top of its scroll view.
Future<void> _reveal(WidgetTester tester, Finder f, {double alignment = 0}) async {
  await Scrollable.ensureVisible(tester.element(f.first), alignment: alignment);
  await _run(tester, 300);
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await _run(tester, 200);
}

/// Opens the app on a fresh copy of the demo database.
Future<AppDatabase> _open(WidgetTester tester, String location, {SessionUser? session = _owner, Size size = desktop}) async {
  debugDisableShadows = false;
  // The counter PC: Windows look (no touch selection handles).
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  debugShowWidgetGallery = false;
  addTearDown(() => debugShowWidgetGallery = true);
  final copy = '${Directory.systemTemp.path}/rxdesk_guide_${DateTime.now().microsecondsSinceEpoch}.sqlite';
  File(_demo).copySync(copy);
  final db = AppDatabase(NativeDatabase(File(copy)));
  addTearDown(() => tester.runAsync(() async {
        await db.close();
        File(copy).deleteSync();
      }));
  await pumpApp(tester, db: db, location: location, settings: _settings, session: session, size: size);
  await _run(tester);
  return db;
}

Future<int> _id(WidgetTester tester, AppDatabase db, String sql, [List<Object> args = const []]) async =>
    (await tester.runAsync(() => db.customSelect(sql, variables: [for (final a in args) Variable(a)]).getSingle()))!.read<int>('id');

/// Search the bill and take the first match (and its FEFO batch).
Future<void> _addToBill(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const ValueKey('billing-search')), query);
  await _run(tester, 300);
  await _key(tester, LogicalKeyboardKey.arrowDown);
  await _key(tester, LogicalKeyboardKey.enter);
  if (find.textContaining('Choose batch').evaluate().isNotEmpty) await _key(tester, LogicalKeyboardKey.enter);
}

// ---------------------------------------------------------------------------
// Demo data on top of seedDemoData: staff, stockists, orders, receipts, dues.

Future<void> _extras(AppDatabase db) async {
  final staff = StaffRepository(db, () => testNow, iterations: 1000);
  await staff.add(name: 'Zoremi', role: StaffRole.owner, pin: '1111');
  await staff.add(name: 'Mawia', role: StaffRole.pharmacist, pin: '2222');
  await staff.add(name: 'Mawii', role: StaffRole.cashier, pin: '3333');

  final dolo = await db.catalogDao.addProduct(
    const NewProduct(
      name: 'Dolo 650 Tablet',
      salt: 'Paracetamol 650 mg',
      maker: 'Micro Labs',
      pack: 'Strip of 15',
      category: 'Tablet',
      gstRate: 12,
      mrp: Paise(3360),
      rack: 'A2',
    ),
    at: DateTime(2026, 10),
  );

  // A price revision: new stock of product 1 at a higher MRP (SPEC §4.5).
  await db.catalogDao.receiveStock(productId: 1, batchNo: 'PCM2710', expiry: '2028-10', qty: 60, mrp: const Paise(3240), at: DateTime(2026, 11, 2));

  final pd = db.purchasesDao;
  final oct = DateTime(2026, 10, 2, 11);
  // Older orders, received in October.
  final octLines = await pd.addOrderLines('2026-10-01', [
    const NewOrderLine(productId: 2, itemName: '', qty: 20, unit: 'Strip'),
    const NewOrderLine(productId: 8, itemName: '', qty: 10, unit: 'Strip'),
    const NewOrderLine(productId: 3, itemName: '', qty: 5, unit: 'Box', note: '10x10'),
  ], at: oct);
  await pd.receive(
    ReceiveRequest(supplierName: 'FMT Pharmacy', invoiceNo: 'FP/401/26-27', receivedDate: '2026-10-02', lines: [
      ReceiveLineInput(orderLineId: octLines[0], productId: 2, batchNo: 'AMX2610', expiry: '2028-03', qty: 20, unit: 'Strip', stockUnits: 20, amount: const Paise(152000)),
      ReceiveLineInput(orderLineId: octLines[1], productId: 8, batchNo: 'AZ2610', expiry: '2028-01', qty: 10, unit: 'Strip', stockUnits: 10, amount: const Paise(98000)),
    ]),
    at: oct,
    now: oct,
  );
  await pd.receive(
    ReceiveRequest(supplierName: 'Life Drugs Centre', invoiceNo: 'LDC/2610/118', receivedDate: '2026-10-20', lines: [
      ReceiveLineInput(orderLineId: octLines[2], productId: 3, batchNo: 'CTZ2610', expiry: '2028-06', qty: 5, unit: 'Box', stockUnits: 50, amount: const Paise(64000), packsPerBox: 10),
    ]),
    at: DateTime(2026, 10, 20, 12),
    now: DateTime(2026, 10, 20, 12),
  );
  Future<int> supplier(String name) async =>
      (await db.customSelect('SELECT id FROM suppliers WHERE name = ?1', variables: [Variable(name)]).getSingle()).read<int>('id');
  final fmt = await supplier('FMT Pharmacy');
  final ldc = await supplier('Life Drugs Centre');
  await db.duesDao.recordPayment(
    supplierId: fmt,
    date: '2026-10-25',
    payment: const PaymentInput(amount: Paise(100000), mode: 'UPI', reference: 'UTR 4521'),
    at: DateTime(2026, 10, 25),
  );
  await db.duesDao.setOpeningBalance(supplierId: ldc, date: '2026-04-01', amount: const Paise(1250000), at: DateTime(2026, 4));
  await db.sourcesDao.setStockistContact(fmt, phone: '9862012345', otherPhones: '0389 2311234');
  await db.sourcesDao.setStockistContact(ldc, phone: '9436154321');
  await db.sourcesDao.add(supplierName: 'Life Drugs Centre', productId: dolo, mrName: 'Lalrinfela', mrPhone: '9612233445', at: oct);
  await db.sourcesDao.add(supplierName: 'Mizo Pharma Agencies', itemName: 'Mycospor Cream', note: 'Cash only', at: oct);

  // This week's orders: catalogue and free-text lines.
  final nov = DateTime(2026, 11, 7, 10);
  await pd.addOrderLines('2026-11-07', [
    const NewOrderLine(itemName: 'Dolo', qty: 10, unit: 'Box'),
    const NewOrderLine(productId: 4, itemName: '', qty: 15, unit: 'Strip'),
    const NewOrderLine(itemName: 'Mycospor Cream', qty: 10, unit: 'Nos'),
  ], at: nov);
  final today = await pd.addOrderLines('2026-11-09', [
    const NewOrderLine(productId: 5, itemName: '', qty: 20, unit: 'Strip'),
    const NewOrderLine(productId: 6, itemName: '', qty: 12, unit: 'Bottle'),
    const NewOrderLine(productId: 13, itemName: '', qty: 2, unit: 'Box', note: '10x15'),
  ], at: testNow);
  await pd.receive(
    ReceiveRequest(supplierName: 'FMT Pharmacy', invoiceNo: 'FP/488/26-27', receivedDate: '2026-11-09', lines: [
      ReceiveLineInput(orderLineId: today[0], productId: 5, batchNo: 'MET2611', expiry: '2028-09', qty: 12, unit: 'Strip', stockUnits: 12, amount: const Paise(30600), moreExpected: true),
      ReceiveLineInput(orderLineId: today[1], productId: 6, batchNo: 'DXM2611', expiry: '2028-04', qty: 12, unit: 'Bottle', stockUnits: 12, amount: const Paise(91200)),
    ]),
    at: testNow,
    now: testNow,
  );
}

// ---------------------------------------------------------------------------

void main() {
  setUpAll(() async {
    await setUpFormatting();
    await _loadFonts();
    if (!File(_demo).existsSync()) {
      File(_demo).parent.createSync(recursive: true);
      final db = AppDatabase(NativeDatabase(File(_demo)));
      await seedDemoData(db, now: testNow);
      await _extras(db);
      await db.close();
    }
  });

  // 1 · Getting started
  testWidgets('01-lock-screen', (tester) async {
    await _open(tester, '/billing', session: null);
    await _shot(tester, '01-lock-screen');
  });

  testWidgets('01-screen-layout', (tester) async {
    await _open(tester, '/billing');
    await _addToBill(tester, 'paracetamol 650');
    await _addToBill(tester, 'cetirizine 10');
    await _shot(tester, '01-screen-layout');
  });

  // 2 · Billing
  testWidgets('02-billing-search', (tester) async {
    await _open(tester, '/billing');
    await tester.enterText(find.byKey(const ValueKey('billing-search')), 'para');
    await _shot(tester, '02-billing-search');
  });

  testWidgets('02-billing-batches', (tester) async {
    final db = await _open(tester, '/billing');
    // Product 1 has batches at two MRPs (see _extras); scan its barcode.
    final barcode = (await tester.runAsync(() => db.customSelect('SELECT barcode FROM products WHERE id = 1').getSingle()))!.read<String>('barcode');
    await tester.enterText(find.byKey(const ValueKey('billing-search')), barcode);
    await _run(tester, 300);
    await _key(tester, LogicalKeyboardKey.enter);
    await _shot(tester, '02-billing-batches');
  });

  testWidgets('02-billing-bill', (tester) async {
    await _open(tester, '/billing');
    await _addToBill(tester, 'paracetamol 650');
    await _addToBill(tester, 'calcium vitamin');
    await _addToBill(tester, 'cetirizine 10');
    await _type(tester, 'bill-customer', 'B. Zonunmawii');
    await _type(tester, 'bill-phone', '9895042467');
    await _tap(tester, find.text('5%'));
    await _reveal(tester, find.text('Bill details'));
    await _shot(tester, '02-billing-bill');
  });

  testWidgets('02-billing-custom-discount', (tester) async {
    await _open(tester, '/billing');
    await _addToBill(tester, 'calcium vitamin');
    await _addToBill(tester, 'ambroxol');
    await _tap(tester, find.byKey(const ValueKey('discount-custom')));
    await _tap(tester, find.text('₹'));
    await _type(tester, 'discount-input', '10');
    await _shot(tester, '02-billing-custom-discount');
  });

  testWidgets('02-billing-credit', (tester) async {
    await _open(tester, '/billing');
    await _addToBill(tester, 'ferrous ascorbate');
    await _addToBill(tester, 'cetirizine 10');
    await _tap(tester, find.byKey(const ValueKey('pay-Credit')));
    await _type(tester, 'bill-customer', 'V. Lalmuanawma');
    await _type(tester, 'bill-phone', '9701047515');
    await _type(tester, 'bill-paid-now', '100');
    await tester.ensureVisible(find.byKey(const ValueKey('credit-panel')));
    await _shot(tester, '02-billing-credit');
  });

  // 3 · Dashboard
  testWidgets('03-dashboard', (tester) async {
    await _open(tester, '/dashboard');
    await _shot(tester, '03-dashboard');
  });

  // 4 · Inventory
  testWidgets('04-inventory-list', (tester) async {
    await _open(tester, '/inventory');
    await _shot(tester, '04-inventory-list');
  });

  Future<void> openParacetamol(WidgetTester tester) async {
    await _type(tester, 'inventory-search', 'PCM2611');
    await _run(tester);
    await _tap(tester, find.byTooltip('Show batches'));
  }

  testWidgets('04-inventory-batches', (tester) async {
    await _open(tester, '/inventory');
    await openParacetamol(tester);
    await _shot(tester, '04-inventory-batches');
  });

  testWidgets('04-add-medicine', (tester) async {
    await _open(tester, '/inventory', size: const Size(1280, 1000));
    await _tap(tester, find.byKey(const ValueKey('add-medicine')));
    for (final (k, v) in [
      ('add-name', 'Calpol 500 Tablet'),
      ('add-salt', 'Paracetamol 500 mg'),
      ('add-maker', 'GSK'),
      ('add-pack', 'Strip of 15'),
      ('add-batch', 'CP2611'),
      ('add-expiry', '08/2028'),
      ('add-qty', '30'),
      ('add-mrp', '16.20'),
      ('add-rack', 'A3'),
      ('add-perbox', '10'),
    ]) {
      await _type(tester, k, v);
    }
    await _reveal(tester, find.text('Add medicine').last);
    await _shot(tester, '04-add-medicine');
  });

  testWidgets('04-edit-medicine', (tester) async {
    await _open(tester, '/inventory', size: const Size(1280, 1000));
    await openParacetamol(tester);
    await _tap(tester, find.byKey(const ValueKey('edit-medicine-1')));
    await _shot(tester, '04-edit-medicine');
  });

  testWidgets('04-edit-batch', (tester) async {
    await _open(tester, '/inventory');
    await openParacetamol(tester);
    await _tap(tester, find.byKey(const ValueKey('edit-batch-PCM2611')));
    final current = tester.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('edit-batch-packs')), matching: find.byType(EditableText))).controller.text;
    await _type(tester, 'edit-batch-packs', '${int.parse(current) - 2}');
    await _tap(tester, find.text('Damaged'));
    await _type(tester, 'edit-batch-note', '2 strips crushed in delivery');
    await _shot(tester, '04-edit-batch');
  });

  // 5 · Purchases
  testWidgets('05-purchases-pending', (tester) async {
    await _open(tester, '/purchases');
    await _shot(tester, '05-purchases-pending');
  });

  testWidgets('05-new-order', (tester) async {
    await _open(tester, '/purchases');
    await _tap(tester, find.byKey(const ValueKey('new-order')));
    await _type(tester, 'order-search', 'cetirizine 10');
    await _tap(tester, find.byKey(const ValueKey('pick-3')));
    await _type(tester, 'order-search', 'Becosules');
    await _tap(tester, find.byKey(const ValueKey('pick-free-text')));
    await _type(tester, 'order-qty-0', '5');
    await _type(tester, 'order-qty-1', '10');
    await _shot(tester, '05-new-order');
  });

  testWidgets('05-receive-box', (tester) async {
    final db = await _open(tester, '/purchases', size: const Size(1280, 1000));
    final line = await _id(tester, db, "SELECT id FROM order_lines WHERE item_name = 'Dolo'");
    final dolo = await _id(tester, db, "SELECT id FROM products WHERE name = 'Dolo 650 Tablet'");
    await _tap(tester, find.byKey(ValueKey('receive-line-$line')));
    await _type(tester, 'recv-supplier', 'Life Drugs Centre');
    await _type(tester, 'recv-invoice', 'LDC/2611/052');
    await _type(tester, 'recv-link-0', 'dolo');
    await _tap(tester, find.byKey(ValueKey('pick-$dolo')));
    await _type(tester, 'recv-free-0', '1');
    await _type(tester, 'recv-perbox-0', '15');
    await _type(tester, 'recv-rate-0', '320');
    await _type(tester, 'recv-disc-0', '5');
    await _type(tester, 'recv-batch-0', 'DOBS3051');
    await _type(tester, 'recv-expiry-0', '06/2028');
    await _reveal(tester, find.byKey(const ValueKey('recv-perbox-0')), alignment: 0.25);
    await _shot(tester, '05-receive-box');
  });

  testWidgets('05-order-book', (tester) async {
    await _open(tester, '/purchases');
    await _tap(tester, find.text('Order book'));
    await _shot(tester, '05-order-book');
  });

  testWidgets('05-dues', (tester) async {
    await _open(tester, '/purchases');
    await _tap(tester, find.text('Dues'));
    await _shot(tester, '05-dues');
  });

  testWidgets('05-stockists', (tester) async {
    await _open(tester, '/purchases');
    await _tap(tester, find.text('Stockists'));
    await _shot(tester, '05-stockists');
  });

  // 6 · Invoices
  testWidgets('06-invoices', (tester) async {
    await _open(tester, '/invoices');
    await _shot(tester, '06-invoices');
  });

  testWidgets('06-return', (tester) async {
    await _open(tester, '/invoices');
    await _tap(tester, find.text('H. Vanlalruata'));
    await _tap(tester, find.byKey(const ValueKey('return-invoice')));
    final plus = find.byWidgetPredicate((w) => w.key is ValueKey<String> && RegExp(r'^return-qty-.*-plus$').hasMatch((w.key! as ValueKey<String>).value));
    await _tap(tester, plus);
    await _shot(tester, '06-return');
  });

  // 7 · Customers
  testWidgets('07-customers', (tester) async {
    await _open(tester, '/customers');
    await _shot(tester, '07-customers');
  });

  testWidgets('07-statement', (tester) async {
    await _open(tester, '/customers');
    await _tap(tester, find.text('Statement'));
    await _shot(tester, '07-statement');
  });

  // 8 · Reports
  testWidgets('08-sales-register', (tester) async {
    await _open(tester, '/register');
    await _shot(tester, '08-sales-register');
  });

  testWidgets('08-consumption', (tester) async {
    await _open(tester, '/register/consumption');
    await _shot(tester, '08-consumption');
  });

  // 9–11 · Backup, settings, staff
  testWidgets('09-backup', (tester) async {
    await _open(tester, '/backup');
    await _shot(tester, '09-backup');
  });

  testWidgets('10-settings-store', (tester) async {
    await _open(tester, '/settings/store');
    await _shot(tester, '10-settings-store');
  });

  testWidgets('10-settings-billing', (tester) async {
    await _open(tester, '/settings/billing');
    await _shot(tester, '10-settings-billing');
  });

  testWidgets('11-staff', (tester) async {
    await _open(tester, '/settings/staff');
    await _shot(tester, '11-staff');
  });
}
