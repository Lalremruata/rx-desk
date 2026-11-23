import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../../core/tax/gstin.dart';
import '../../../core/tax/gstr1.dart';

/// GSTR-1 workbook (SPEC §4.15): a summary sheet, then one sheet per table
/// in the GST offline tool's layout. Check the headings against the
/// current template with your CA before filing.
Uint8List buildGstr1Xlsx(Gstr1Report r, {required String storeName, required String gstin, required String period, required String uqc}) {
  final excel = Excel.createExcel();
  final first = excel.getDefaultSheet() ?? 'Sheet1';
  excel.rename(first, 'summary');
  final bold = CellStyle(bold: true);
  double rs(int paise) => paise / 100;
  CellValue cell(Object v) => switch (v) {
        final int i => IntCellValue(i),
        final double d => DoubleCellValue(d),
        _ => TextCellValue('$v'),
      };
  void table(String name, List<String> headers, List<List<Object>> rows) {
    final sheet = excel[name];
    sheet.appendRow([for (final h in headers) TextCellValue(h)]);
    for (var c = 0; c < headers.length; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0)).cellStyle = bold;
      sheet.setColumnAutoFit(c);
    }
    for (final row in rows) {
      sheet.appendRow([for (final v in row) cell(v)]);
    }
  }

  final pos = placeOfSupplyLabel(r.storeState);
  final summary = excel['summary'];
  for (final line in <List<Object>>[
    [storeName],
    ['GSTIN $gstin'],
    ['GSTR-1 · $period'],
    ['Check every sheet against the current GST offline tool template before filing.'],
    [],
    ['Table', 'Rows', 'Taxable value ₹'],
    ['B2B invoices (b2b)', r.b2b.length, rs(r.b2bTaxable)],
    ['B2C small, net of returns (b2cs)', r.b2cs.length, rs(r.b2csTaxable)],
    ['Credit notes to registered buyers (cdnr)', r.cdnr.length, rs(r.cdnrTaxable)],
    ['Net taxable value', '', rs(r.netTaxable)],
    ['HSN summary taxable (should match)', r.hsnB2b.length + r.hsnB2c.length, rs(r.hsnTaxable)],
  ]) {
    summary.appendRow([for (final v in line) cell(v)]);
  }
  summary.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).cellStyle = CellStyle(bold: true, fontSize: 14);
  for (var c = 0; c < 3; c++) {
    summary.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 5)).cellStyle = bold;
  }

  table('b2b', const [
    'GSTIN/UIN of Recipient',
    'Receiver Name',
    'Invoice Number',
    'Invoice date',
    'Invoice Value',
    'Place Of Supply',
    'Reverse Charge',
    'Applicable % of Tax Rate',
    'Invoice Type',
    'E-Commerce GSTIN',
    'Rate',
    'Taxable Value',
    'Cess Amount',
  ], [
    for (final x in r.b2b)
      [
        x.doc.buyerGstin!,
        x.doc.customerName,
        x.doc.number,
        gstr1Date(x.doc.saleDate),
        rs(x.doc.totalPaise),
        placeOfSupplyLabel(x.doc.placeOfSupply ?? gstinState(x.doc.buyerGstin!)),
        'N',
        '',
        'Regular B2B',
        '',
        x.rate,
        rs(x.taxablePaise),
        0,
      ],
  ]);
  table('b2cs', const ['Type', 'Place Of Supply', 'Applicable % of Tax Rate', 'Rate', 'Taxable Value', 'Cess Amount', 'E-Commerce GSTIN'], [
    for (final x in r.b2cs) ['OE', pos, '', x.rate, rs(x.taxablePaise), 0, ''],
  ]);
  table('cdnr', const [
    'GSTIN/UIN of Recipient',
    'Receiver Name',
    'Note Number',
    'Note Date',
    'Note Type',
    'Place Of Supply',
    'Reverse Charge',
    'Note Supply Type',
    'Note Value',
    'Applicable % of Tax Rate',
    'Rate',
    'Taxable Value',
    'Cess Amount',
  ], [
    for (final x in r.cdnr)
      [
        x.doc.buyerGstin!,
        x.doc.customerName,
        x.doc.number,
        gstr1Date(x.doc.saleDate),
        'C',
        placeOfSupplyLabel(x.doc.placeOfSupply ?? gstinState(x.doc.buyerGstin!)),
        'N',
        'Regular B2B',
        rs(-x.doc.totalPaise),
        '',
        x.rate,
        rs(x.taxablePaise),
        0,
      ],
  ]);
  const hsnHeaders = [
    'HSN',
    'Description',
    'UQC',
    'Total Quantity',
    'Total Value',
    'Rate',
    'Taxable Value',
    'Integrated Tax Amount',
    'Central Tax Amount',
    'State/UT Tax Amount',
    'Cess Amount',
  ];
  List<Object> hsnRow(Gstr1Hsn h) => [h.hsn, h.description, uqc, h.qty, rs(h.valuePaise), h.rate, rs(h.taxablePaise), 0, rs(h.cgstPaise), rs(h.sgstPaise), 0];
  table('hsn(b2b)', hsnHeaders, [for (final h in r.hsnB2b) hsnRow(h)]);
  table('hsn(b2c)', hsnHeaders, [for (final h in r.hsnB2c) hsnRow(h)]);
  table('docs', const ['Nature of Document', 'Sr. No. From', 'Sr. No. To', 'Total Number', 'Cancelled'], [
    for (final d in r.docs) [d.nature, d.from, d.to, d.total, d.cancelled],
  ]);
  return Uint8List.fromList(excel.encode()!);
}
