import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/cash/cash_rules.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/daos/cash_dao.dart';
import '../../../core/money/paise.dart';
import '../../../core/utils/expiry.dart';
import '../../invoices/application/invoice_pdf.dart';

/// A one-page day-end cash summary (SPEC §4.14), A4.
Future<Uint8List> buildCashSummaryPdf({
  required String storeName,
  required CashClosing closing,
  required List<CashPaidOut> paidOuts,
  required String closedBy,
  required InvoiceFonts fonts,
  required int accentArgb,
}) {
  final accent = PdfColor.fromInt(accentArgb);
  const muted = PdfColors.grey700;
  final f = closingFigures(closing);
  final pdf = pw.Document(title: 'Day close ${closing.closeDate}', author: storeName, creator: 'RxDesk');
  final theme = pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold).copyWith(defaultTextStyle: const pw.TextStyle(fontSize: 10.5));
  final bold = pw.TextStyle(font: fonts.bold);
  const small = pw.TextStyle(fontSize: 9, color: muted);

  pw.Widget row(String label, Paise v, {String sign = '', bool strong = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Row(children: [
          pw.Expanded(child: pw.Text(label, style: strong ? bold : null)),
          pw.Text('$sign${formatInr(v)}', style: strong ? bold : null),
        ]),
      );

  final day = DateTime.parse(closing.closeDate);
  final at = DateTime.fromMillisecondsSinceEpoch(closing.closedAt).toLocal();
  final diff = Paise(closing.differencePaise);
  pdf.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4.copyWith(marginLeft: 20 * PdfPageFormat.mm, marginRight: 20 * PdfPageFormat.mm, marginTop: 18 * PdfPageFormat.mm),
      theme: theme,
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(storeName, style: pw.TextStyle(font: fonts.bold, fontSize: 15, color: accent)),
          pw.SizedBox(height: 4),
          pw.Text('DAY CLOSE — CASH', style: pw.TextStyle(font: fonts.bold, letterSpacing: 1)),
          pw.Text('${formatDate(day)} · closed ${formatTime(at)} by $closedBy', style: small),
          pw.SizedBox(height: 14),
          row('Opening cash', Paise(closing.openingPaise)),
          row('Cash sales', f.cashSales, sign: '+ '),
          row('Cash refunds', f.cashRefunds, sign: '− '),
          row('Dues collected in cash', f.duesCollected, sign: '+ '),
          row('Paid to stockists in cash', f.stockistsPaid, sign: '− '),
          row('Paid out', f.paidOuts, sign: '− '),
          pw.Divider(color: PdfColors.grey400),
          row('Expected in drawer', Paise(closing.expectedPaise), strong: true),
          row('Counted', Paise(closing.countedPaise), strong: true),
          row(diff.value == 0 ? 'Difference' : diff.isNegative ? 'Short' : 'Over', diff.abs(), strong: true),
          if (closing.handedOverPaise > 0) row('Handed over', Paise(closing.handedOverPaise)),
          row('Opening for the next day', openingFrom(counted: Paise(closing.countedPaise), handedOver: Paise(closing.handedOverPaise))),
          if (closing.note.isNotEmpty) ...[pw.SizedBox(height: 8), pw.Text('Note: ${closing.note}', style: small)],
          if (paidOuts.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Text('PAID OUT', style: pw.TextStyle(font: fonts.bold, fontSize: 9, letterSpacing: 0.8)),
            pw.SizedBox(height: 4),
            for (final p in paidOuts)
              pw.Row(children: [
                pw.Expanded(child: pw.Text(p.status == 'void' ? '${p.note} (void: ${p.voidReason ?? ''})' : p.note, style: p.status == 'void' ? small : null)),
                pw.Text(formatInr(Paise(p.amountPaise)), style: p.status == 'void' ? small : null),
              ]),
          ],
          pw.SizedBox(height: 40),
          pw.Row(children: [
            pw.Expanded(child: pw.Text('Counted by ____________________', style: small)),
            pw.Text('Checked by ____________________', style: small),
          ]),
        ],
      ),
    ),
  );
  return pdf.save();
}
