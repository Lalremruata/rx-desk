import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/purchases_dao.dart';
import 'package:rx_desk/core/db/daos/sources_dao.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/purchases/purchase_rules.dart';

import '../helpers/test_db.dart';

void main() {
  late AppDatabase db;
  late SourcesDao src;
  late int pcm, cough;

  setUp(() async {
    db = memoryDb();
    src = db.sourcesDao;
    (pcm, _) = await addMed(db);
    (cough, _) = await addMed(db, name: 'Ascoril LS Syrup', salt: 'Ambroxol', batch: 'ASC1', category: 'Syrup');
  });
  tearDown(() => db.close());

  Future<void> receive(String stockist, int productId, String batch, String date, String inv) => db.purchasesDao.receive(
        ReceiveRequest(
          supplierName: stockist,
          invoiceNo: inv,
          receivedDate: date,
          lines: [ReceiveLineInput(productId: productId, batchNo: batch, qty: 1, unit: 'Box', stockUnits: 10, amount: const Paise(10000))],
        ),
        at: t0,
        now: t0,
      );

  const rows = [
    DirectoryImportRow(supplierName: 'EMY PHARMACY', itemName: 'Tab. Paracetamol 650', phones: ['9862958415', '0389-2323442']),
    DirectoryImportRow(supplierName: 'EMY PHARMACY', itemName: 'Judiliv Syrub 200ml', phones: ['9862958415', '0389-2323442']),
    DirectoryImportRow(supplierName: 'RB PAHRMACY', itemName: 'Nitrocube Sr 100', mrName: 'Tluangtea', phones: ['7005679742']),
  ];

  test('import: stockists with phones, linked + free-text rows; re-import adds nothing', () async {
    final linkedRows = [
      DirectoryImportRow(supplierName: rows[0].supplierName, itemName: rows[0].itemName, productId: pcm, phones: rows[0].phones),
      rows[1],
      rows[2],
    ];
    final r = await src.importRows(linkedRows, at: t0);
    expect((r.stockistsAdded, r.added, r.linked, r.skipped), (2, 3, 1, 0));
    final emy = (await src.stockists()).firstWhere((s) => s.name == 'EMY PHARMACY');
    expect((emy.phone, emy.otherPhones), ('9862958415', '0389-2323442'));
    final page = await src.page();
    expect(page.rows.map((x) => (x.supplierName, x.itemName, x.productId)), [
      ('EMY PHARMACY', 'Judiliv Syrub 200ml', null),
      ('EMY PHARMACY', 'Paracetamol 650 mg Tablet', pcm),
      ('RB PAHRMACY', 'Nitrocube Sr 100', null),
    ]);
    expect(page.rows[1].note, 'Sheet: Tab. Paracetamol 650');
    expect(page.rows.last.mr, 'Tluangtea');
    expect(page.rows.first.phones, '9862958415 / 0389-2323442');

    final again = await src.importRows([...linkedRows, const DirectoryImportRow(supplierName: 'emy pharmacy', itemName: 'x', phones: ['98629 58415', '9999900000'])], at: t0);
    expect((again.stockistsAdded, again.added, again.skipped), (0, 1, 3));
    final emy2 = (await src.stockists()).firstWhere((s) => s.name == 'EMY PHARMACY');
    expect(emy2.otherPhones, '0389-2323442 / 9999900000');
  });

  test('search, stockist filter, keyset pages', () async {
    await src.importRows(rows, at: t0);
    expect((await src.page(search: 'tluang')).rows.single.itemName, 'Nitrocube Sr 100');
    expect((await src.page(search: '0389')).total, 2);
    final rb = (await src.stockists()).firstWhere((s) => s.name == 'RB PAHRMACY');
    expect((await src.page(supplierId: rb.id)).rows.single.itemName, 'Nitrocube Sr 100');
    final p1 = await src.page(limit: 2);
    expect((p1.total, p1.hasMore), (3, true));
    final last = p1.rows.last;
    final p2 = await src.page(limit: 2, after: SourceCursor(last.supplierName, last.itemName, last.id));
    expect((p2.rows.single.itemName, p2.hasMore), ('Nitrocube Sr 100', false));
  });

  test('receiving learns the source, links a free-text line, newest stockist first', () async {
    await src.add(supplierName: 'Life Drugs Centre', itemName: 'Ascoril LS Syrup', mrName: 'Muana', at: t0);
    await receive('Life Drugs Centre', cough, 'ASC1', '2026-10-01', 'L1');
    await receive('Hills Medical Store', cough, 'ASC1', '2026-11-02', 'H1');
    await receive('Life Drugs Centre', cough, 'ASC1', '2026-09-01', 'L0'); // older invoice keeps the later date
    final s = await src.sourcesFor(cough);
    expect(s.map((x) => (x.supplierName, x.lastReceived, x.origin)), [
      ('Hills Medical Store', '2026-11-02', 'receipt'),
      ('Life Drugs Centre', '2026-10-01', 'manual'),
    ]);
    expect(s.last.productId, cough); // the typed line got linked, MR kept
    expect(s.last.mrName, 'Muana');
    final first = await src.firstSources([cough, pcm]);
    expect(first.keys, [cough]);
    expect(first[cough]!.supplierName, 'Hills Medical Store');
  });

  test('manual add / edit / remove; duplicates refused', () async {
    final id = await src.add(supplierName: 'Hills Medical Store', productId: pcm, at: t0);
    await expectLater(src.add(supplierName: 'hills medical store', productId: pcm, at: t0), throwsA(isA<PurchaseException>()));
    final free = await src.add(supplierName: 'Hills Medical Store', itemName: 'Calpol 500', at: t0);
    await expectLater(src.updateSource(free, productId: pcm, itemName: '', at: t0), throwsA(isA<PurchaseException>()));
    await src.updateSource(free, productId: cough, itemName: '', mrName: 'Becca', at: t0);
    expect((await src.sourcesFor(cough)).single.mrName, 'Becca');
    await src.remove(id);
    expect(await src.sourcesFor(pcm), isEmpty);
    final hills = (await src.stockists()).single;
    await src.setStockistContact(hills.id, phone: '0389-2322236', otherPhones: '9436366036', note: 'Opp. Civil Hospital');
    expect((await src.page()).rows.single.phones, '0389-2322236 / 9436366036');
  });
}
