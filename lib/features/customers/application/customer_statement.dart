import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/db/daos/customers_dao.dart';
import '../../../core/money/paise.dart';
import '../../../core/sales/credit_rules.dart';
import '../../../core/utils/expiry.dart';
import '../../invoices/application/invoice_pdf.dart';
import '../../sales_register/application/register_export.dart';

/// Everything a customer statement shows (SPEC §5.10). Built from the
/// ledger; nothing is recomputed.
class CustomerStatementData {
  const CustomerStatementData({
    required this.storeName,
    required this.storeLines,
    required this.customer,
    required this.rows,
    required this.generated,
  });

  final String storeName;

  /// Address, phone, GSTIN — already joined, blanks dropped.
  final List<String> storeLines;
  final CustomerDues customer;

  /// Oldest first, void rows included (marked).
  final List<CustomerStatementRow> rows;
  final DateTime generated;
}

String _refText(CustomerStatementRow r) =>
    [r.reference, if (r.mode != null) r.mode!].where((s) => s.isNotEmpty).join(' · ');

String _noteText(CustomerStatementRow r) => r.active ? r.note : 'VOID: ${r.voidReason ?? ''}';

/// The statement as an export table (Excel / CSV). Rupee cells are doubles
/// for display only.
ExportTable customerStatementTable(CustomerStatementData d) {
  double r(Paise p) => p.value / 100;
  final c = d.customer;
  return ExportTable(
    title: 'Customer statement',
    headerBlock: [
      d.storeName,
      'Statement — ${c.name}${c.phone.isEmpty ? '' : ' (${c.phone})'}',
      'Generated ${formatDate(d.generated)} ${formatTime(d.generated)}',
    ],
    columns: const ['Date', 'Type', 'Reference', 'Debit ₹', 'Credit ₹', 'Balance ₹', 'Note'],
    rows: [
      for (final x in d.rows)
        [
          x.date,
          x.kind.label,
          _refText(x),
          x.debit.value == 0 ? '' : r(x.debit),
          x.credit.value == 0 ? '' : r(x.credit),
          r(x.balance),
          _noteText(x),
        ],
    ],
    totals: ['Dues', '', '', '', '', r(c.balance), ''],
  );
}

/// A4 statement to hand to the customer.
Future<Uint8List> buildCustomerStatementPdf(CustomerStatementData d, {required InvoiceFonts fonts, required int accentArgb}) {
  final accent = PdfColor.fromInt(accentArgb);
  const muted = PdfColors.grey700;
  final c = d.customer;
  final pdf = pw.Document(title: 'Statement — ${c.name}', author: d.storeName, creator: 'RxDesk');
  final theme = pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold).copyWith(defaultTextStyle: const pw.TextStyle(fontSize: 9.5));
  const small = pw.TextStyle(fontSize: 8.5, color: muted);
  final strong = pw.TextStyle(font: fonts.bold);

  pw.Widget cell(String text, {bool end = false, pw.TextStyle? style}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: pw.Text(text, textAlign: end ? pw.TextAlign.right : pw.TextAlign.left, style: style),
      );

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.copyWith(
        marginLeft: 14 * PdfPageFormat.mm,
        marginRight: 14 * PdfPageFormat.mm,
        marginTop: 14 * PdfPageFormat.mm,
        marginBottom: 14 * PdfPageFormat.mm,
      ),
      theme: theme,
      header: (ctx) => ctx.pageNumber == 1
          ? pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Text(d.storeName, style: pw.TextStyle(font: fonts.bold, fontSize: 15, color: accent)),
                for (final l in d.storeLines) pw.Text(l, style: small),
                pw.SizedBox(height: 8),
                pw.Text('STATEMENT OF ACCOUNT', style: pw.TextStyle(font: fonts.bold, letterSpacing: 1)),
                pw.SizedBox(height: 6),
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(c.name, style: strong),
                          if (c.phone.isNotEmpty) pw.Text(c.phone, style: small),
                          if (c.address.isNotEmpty) pw.Text(c.address, style: small),
                        ],
                      ),
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text('As of ${formatDate(d.generated)}', style: small),
                        pw.Text(
                          c.balance.isNegative ? 'Advance ${formatInr(c.balance.abs())}' : 'Dues ${formatInr(c.balance)}',
                          style: pw.TextStyle(font: fonts.bold, fontSize: 13),
                        ),
                      ],
                    ),
                  ],
                ),
                pw.SizedBox(height: 10),
              ],
            )
          : pw.Text('Statement — ${c.name} (continued)', style: small),
      footer: (ctx) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: small),
      ),
      build: (_) => [
        pw.Table(
          border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColors.grey300, width: 0.5)),
          columnWidths: const {
            0: pw.FixedColumnWidth(74),
            1: pw.FixedColumnWidth(70),
            2: pw.FlexColumnWidth(),
            3: pw.FixedColumnWidth(66),
            4: pw.FixedColumnWidth(66),
            5: pw.FixedColumnWidth(72),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: [
                cell('Date', style: strong),
                cell('Type', style: strong),
                cell('Reference', style: strong),
                cell('Debit', end: true, style: strong),
                cell('Credit', end: true, style: strong),
                cell('Balance', end: true, style: strong),
              ],
            ),
            for (final r in d.rows)
              pw.TableRow(
                children: [
                  cell(dayLabel(r.date), style: r.active ? null : small),
                  cell(r.active ? r.kind.label : '${r.kind.label} (void)', style: r.active ? null : small),
                  cell(
                    [_refText(r), if (_noteText(r).isNotEmpty) _noteText(r)].join(' — '),
                    style: r.active ? null : small,
                  ),
                  cell(r.debit.value == 0 ? '' : formatInr(r.debit), end: true),
                  cell(r.credit.value == 0 ? '' : formatInr(r.credit), end: true),
                  cell(formatInr(r.balance), end: true, style: r.active ? strong : small),
                ],
              ),
          ],
        ),
        pw.SizedBox(height: 12),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            c.balance.isNegative ? 'Advance with us: ${formatInr(c.balance.abs())}' : 'Amount due: ${formatInr(c.balance)}',
            style: pw.TextStyle(font: fonts.bold, fontSize: 12),
          ),
        ),
        if (c.oldestOpen != null)
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text('Oldest unpaid since ${dayLabel(c.oldestOpen!)} (${agingBucket(c.oldestOpen, dateKey(d.generated)).label})', style: small),
          ),
      ],
    ),
  );
  return pdf.save();
}
