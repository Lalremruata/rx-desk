import 'dart:isolate';
import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../../core/db/report_models.dart';
import '../../../core/money/paise.dart';
import '../../../core/utils/expiry.dart';

/// A plain table to export (sendable to an isolate).
class ExportTable {
  const ExportTable({required this.title, required this.headerBlock, required this.columns, required this.rows, required this.totals});

  final String title;

  /// Lines above the table: store name, GSTIN, range, filters.
  final List<String> headerBlock;
  final List<String> columns;

  /// Cells are String, int or double (rupees).
  final List<List<Object>> rows;
  final List<Object> totals;
}

double _r(Paise p) => p.value / 100; // export display only

/// Builds the export table for exactly what's on screen (SPEC §5.5).
ExportTable registerExportTable({
  required RegisterFilter filter,
  required RegisterTotals totals,
  required List<RegisterLine> lines,
  required List<RegisterGroupRow> groups,
  required String storeName,
  required String gstin,
  required String rangeLabel,
  required DateTime generatedAt,
}) {
  final filters = <String>[
    if (filter.search.trim().isNotEmpty) 'Search: ${filter.search.trim()}',
    if (filter.maker != null) 'Maker: ${filter.maker}',
    if (filter.category != null) 'Category: ${filter.category}',
    if (filter.schedule != ScheduleFilter.all) 'Schedule: ${filter.schedule.label}',
    if (filter.payment != null) 'Payment: ${filter.payment}',
    if (filter.doctor != null) 'Doctor: ${filter.doctor}',
  ];
  final title = filter.schedule.isRxRegister && filter.group == RegisterGroup.none
      ? 'Schedule H / H1 register'
      : filter.group == RegisterGroup.none
          ? 'Sales register — item lines'
          : 'Sales register — by ${filter.group.label.toLowerCase()}';
  final header = [
    storeName,
    if (gstin.isNotEmpty) 'GSTIN $gstin',
    title,
    'Period: $rangeLabel',
    if (filters.isNotEmpty) 'Filters: ${filters.join(' · ')}',
    'Generated ${formatDate(generatedAt)} ${formatTime(generatedAt)}',
  ];

  if (filter.group != RegisterGroup.none) {
    final share = totals.net.value == 0 ? 0.0 : 1 / totals.net.value;
    return ExportTable(
      title: title,
      headerBlock: header,
      columns: [filter.group.label, 'Bills', 'Units', 'Gross ₹', 'Taxable ₹', 'GST ₹', 'Net ₹', 'Share %'],
      rows: [
        for (final g in groups)
          [g.label, g.bills, g.units, _r(g.gross), _r(g.taxable), _r(g.tax), _r(g.net), double.parse((g.net.value * share * 100).toStringAsFixed(1))],
      ],
      totals: ['Total', totals.bills, totals.units, _r(totals.gross), _r(totals.taxable), _r(totals.tax), _r(totals.net), 100.0],
    );
  }

  String when(RegisterLine l) {
    final at = DateTime.fromMillisecondsSinceEpoch(l.createdAt, isUtc: true).toLocal();
    return '${formatDate(at)} ${formatTime(at)}';
  }

  if (filter.schedule.isRxRegister) {
    return ExportTable(
      title: title,
      headerBlock: header,
      columns: ['Date · time', 'Bill no', 'Patient', 'Doctor', 'Medicine', 'Schedule', 'Batch', 'Qty'],
      rows: [for (final l in lines) [when(l), l.billNo, l.customer, l.doctor ?? '', l.medicine, l.schedule, l.batchNo, l.qty]],
      totals: ['Total', '${totals.bills} bills', '', '', '', '', '', totals.units],
    );
  }
  return ExportTable(
    title: title,
    headerBlock: header,
    columns: ['Date · time', 'Bill no', 'Medicine', 'Salt', 'Maker', 'HSN', 'Batch', 'Qty', 'MRP ₹', 'Discount ₹', 'Taxable ₹', 'GST %', 'Net ₹', 'Payment'],
    rows: [
      for (final l in lines)
        [when(l), l.billNo, l.medicine, l.salt, l.maker, l.hsn, l.batchNo, l.qty, _r(l.mrp), _r(l.discount), _r(l.taxable), l.gstRate, _r(l.net), l.payment],
    ],
    totals: ['Total', '${totals.bills} bills', '', '', '', '', '', totals.units, '', _r(totals.discount), _r(totals.taxable), '', _r(totals.net), ''],
  );
}

/// .xlsx bytes with header block, bold column row and totals row.
Uint8List buildXlsx(ExportTable t, {String sheetName = 'Sales register'}) {
  final excel = Excel.createExcel();
  final defaultSheet = excel.getDefaultSheet() ?? 'Sheet1';
  excel.rename(defaultSheet, sheetName);
  final sheet = excel[sheetName];
  final bold = CellStyle(bold: true);
  CellValue cell(Object v) => switch (v) {
        final int i => IntCellValue(i),
        final double d => DoubleCellValue(d),
        _ => TextCellValue('$v'),
      };
  for (final (i, h) in t.headerBlock.indexed) {
    sheet.appendRow([TextCellValue(h)]);
    if (i == 0) sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).cellStyle = CellStyle(bold: true, fontSize: 14);
  }
  sheet.appendRow([]);
  final headerRow = t.headerBlock.length + 1;
  sheet.appendRow([for (final c in t.columns) TextCellValue(c)]);
  for (var c = 0; c < t.columns.length; c++) {
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: headerRow)).cellStyle = bold;
  }
  for (final r in t.rows) {
    sheet.appendRow([for (final v in r) cell(v)]);
  }
  final totalRow = headerRow + t.rows.length + 1;
  sheet.appendRow([for (final v in t.totals) cell(v)]);
  for (var c = 0; c < t.totals.length; c++) {
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: totalRow)).cellStyle = bold;
  }
  for (var c = 0; c < t.columns.length; c++) {
    sheet.setColumnAutoFit(c);
  }
  return Uint8List.fromList(excel.encode()!);
}

/// CSV fallback.
String buildCsv(ExportTable t) {
  String q(Object v) {
    final s = '$v';
    return s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
  }

  return [
    ...t.headerBlock.map(q),
    '',
    t.columns.map(q).join(','),
    for (final r in t.rows) r.map(q).join(','),
    t.totals.map(q).join(','),
  ].join('\n');
}

/// Builds the workbook off the UI isolate (SPEC §10).
Future<Uint8List> buildXlsxInIsolate(ExportTable t, {String sheetName = 'Sales register'}) =>
    Isolate.run(() => buildXlsx(t, sheetName: sheetName));
