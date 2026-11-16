import 'package:excel/excel.dart' show Excel;
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/daos/purchases_dao.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/purchases/purchase_rules.dart';
import 'package:rx_desk/features/purchases/application/purchases_export.dart';

OrderRow _order(int id, String date, String name, {int got = 0, OrderStatus status = OrderStatus.pending, int amount = 0}) => OrderRow(
      id: id,
      orderDate: date,
      productId: 1,
      itemName: name,
      qty: 10,
      unit: 'Box',
      note: '',
      status: status,
      receivedSameUnit: got,
      receivedOther: '',
      amount: Paise(amount),
      suppliers: got > 0 ? 'Life Drugs Centre' : '',
      invoiceNos: got > 0 ? '2600073' : '',
      lastReceived: got > 0 ? '2026-09-02' : null,
    );

void main() {
  final rows = [
    BookRow.ordered(_order(1, '2026-09-01', 'Etodase TH-4', got: 6, status: OrderStatus.closed, amount: 361200)),
    BookRow.ordered(_order(2, '2026-09-01', 'Taxim 250')),
    BookRow.ordered(_order(3, '2026-09-02', 'L-Tonin 10', got: 10, status: OrderStatus.received, amount: 204800)),
    const BookRow.extra(
      itemName: 'Plaster of Paris',
      receivedQty: 24,
      receivedUnit: 'Pcs',
      extraAmount: Paise(325100),
      extraSupplier: 'Copex Healthcare',
      extraInvoice: 'CHP/1777',
      extraDate: '2026-09-02',
    ),
  ];

  test('one sheet per day, S/N restarts, totals per day, workbook layout', () {
    final sheets = bookSheets(rows, storeName: 'Test Pharmacy');
    expect(sheets.map((s) => s.name), ['Sep 1', 'Sep 2']);
    expect(sheets[0].rows.map((r) => r[0]), [1, 2]);
    expect(sheets[1].rows.map((r) => r[0]), [1, 2]);
    expect(sheets[0].total, 3612.0);
    expect(sheets[1].total, 5299.0);
    final first = sheets[0].rows[0];
    expect(first.sublist(2, 5), ['Etodase TH-4', '10 Box', 'Life Drugs Centre']);
    expect(first.sublist(6), ['2600073', '6 Box', 3612.0, 'Short']);
    expect(sheets[0].rows[1].last, 'Pending');
    expect(sheets[1].rows[1][1], ''); // not ordered → no order date
    expect(sheets[1].rows[1].last, 'Not ordered');
  });

  test('xlsx round-trips with headings and Total', () {
    final bytes = buildBookXlsx(bookSheets(rows, storeName: 'Test Pharmacy'));
    final x = Excel.decodeBytes(bytes);
    expect(x.tables.keys, containsAll(['Sep 1', 'Sep 2']));
    final s = x.tables['Sep 1']!;
    expect(s.rows[1].map((c) => c?.value.toString()), bookColumns);
    expect(s.rows[2][2]?.value.toString(), 'Etodase TH-4');
    final total = s.rows.last;
    expect(total[7]?.value.toString(), 'Total');
    expect(num.parse(total[8]!.value.toString()), 3612);
  });

  test('csv fallback lists every day with its total', () {
    final csv = bookCsv(bookSheets(rows, storeName: 'Test Pharmacy')).split('\n');
    expect(csv.first, bookColumns.join(','));
    expect(csv.where((l) => l.contains('Total')), hasLength(2));
    expect(csv[1], startsWith('1,2026-09-01,Etodase TH-4,10 Box,Life Drugs Centre,2026-09-02,2600073,6 Box,3612.0,Short'));
  });
}
