import 'dart:isolate';
import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../../core/db/daos/purchases_dao.dart';
import '../../../core/money/paise.dart';
import '../../../core/utils/expiry.dart';

/// Column headings, as in the store's "Order & Received List" workbook.
const List<String> bookColumns = [
  'S/N',
  'Date of Order',
  'Name of Items',
  'Quantity',
  'Stockist',
  'Receive Date',
  'Inv. No',
  'Qty Received',
  'Amount ₹',
  'Status',
];

/// One day's sheet: rows as plain values (sendable to an isolate).
class BookSheet {
  const BookSheet({required this.name, required this.title, required this.rows, required this.total});

  /// Tab name, e.g. "Sep 1".
  final String name;
  final String title;

  /// Each cell is String, int, double (rupees) or a 'YYYY-MM-DD' date marked
  /// by [BookDate].
  final List<List<Object>> rows;
  final double total;
}

/// A date cell.
class BookDate {
  const BookDate(this.key);
  final String key;
}

double _r(Paise p) => p.value / 100; // export display only

/// Groups [rows] by day (order date, or receive date for unordered items)
/// into one sheet per day, S/N restarting each day.
List<BookSheet> bookSheets(List<BookRow> rows, {required String storeName}) {
  final byDay = <String, List<BookRow>>{};
  for (final r in rows) {
    byDay.putIfAbsent(r.orderDate ?? r.receivedDate ?? '', () => []).add(r);
  }
  final days = byDay.keys.toList()..sort();
  return [
    for (final d in days)
      BookSheet(
        name: d.isEmpty ? 'Undated' : '${monthName(int.parse(d.substring(5, 7)))} ${int.parse(d.substring(8))}',
        title: '$storeName — Order & Received List${d.isEmpty ? '' : ' — ${dayLabel(d)}'}',
        rows: [
          for (final (i, r) in byDay[d]!.indexed)
            [
              i + 1,
              if (r.orderDate == null) '' else BookDate(r.orderDate!),
              r.item,
              r.orderedLabel,
              r.stockist,
              if (r.receivedDate == null) '' else BookDate(r.receivedDate!),
              r.invoiceNo,
              r.receivedLabel,
              if (r.amount.value == 0) '' else _r(r.amount),
              r.tag.label,
            ],
        ],
        total: _r(byDay[d]!.map((r) => r.amount).sum()),
      ),
  ];
}

/// .xlsx with one sheet per day: title, bold headings, rows, bold Total.
Uint8List buildBookXlsx(List<BookSheet> sheets) {
  final excel = Excel.createExcel();
  final first = excel.getDefaultSheet() ?? 'Sheet1';
  if (sheets.isEmpty) return Uint8List.fromList(excel.encode()!);
  excel.rename(first, sheets.first.name);
  final bold = CellStyle(bold: true);
  CellValue cell(Object v) => switch (v) {
        final int i => IntCellValue(i),
        final double d => DoubleCellValue(d),
        final BookDate d => DateCellValue(
            year: int.parse(d.key.substring(0, 4)),
            month: int.parse(d.key.substring(5, 7)),
            day: int.parse(d.key.substring(8, 10)),
          ),
        _ => TextCellValue('$v'),
      };
  for (final s in sheets) {
    final sheet = excel[s.name];
    sheet.appendRow([TextCellValue(s.title)]);
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).cellStyle = CellStyle(bold: true, fontSize: 14);
    sheet.appendRow([for (final c in bookColumns) TextCellValue(c)]);
    for (var c = 0; c < bookColumns.length; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 1)).cellStyle = bold;
    }
    for (final r in s.rows) {
      sheet.appendRow([for (final v in r) cell(v)]);
    }
    final totalRow = s.rows.length + 2;
    sheet.appendRow([for (var c = 0; c < 7; c++) TextCellValue(''), TextCellValue('Total'), DoubleCellValue(s.total)]);
    for (final c in [7, 8]) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: totalRow)).cellStyle = bold;
    }
    for (var c = 0; c < bookColumns.length; c++) {
      sheet.setColumnAutoFit(c);
    }
  }
  return Uint8List.fromList(excel.encode()!);
}

/// Builds the workbook off the UI isolate (SPEC §10).
Future<Uint8List> buildBookXlsxInIsolate(List<BookSheet> sheets) => Isolate.run(() => buildBookXlsx(sheets));

/// CSV fallback: all days in one table (S/N restarts per day).
String bookCsv(List<BookSheet> sheets) {
  String q(Object v) {
    final s = v is BookDate ? v.key : '$v';
    return s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
  }

  return [
    bookColumns.map(q).join(','),
    for (final s in sheets) ...[
      for (final r in s.rows) r.map(q).join(','),
      [for (var c = 0; c < 7; c++) '', 'Total', s.total].map(q).join(','),
    ],
  ].join('\n');
}
