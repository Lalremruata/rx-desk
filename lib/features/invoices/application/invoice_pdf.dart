import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/theme/tokens.dart';
import '../../settings/application/app_settings.dart';
import 'invoice_document.dart';

/// Fonts embedded in invoice PDFs (bundled Inter — has the ₹ glyph).
class InvoiceFonts {
  const InvoiceFonts({required this.regular, required this.medium, required this.bold});

  final pw.Font regular;
  final pw.Font medium;
  final pw.Font bold;

  static InvoiceFonts? _cache;

  /// Loads from the app's asset bundle.
  static Future<InvoiceFonts> load() async => _cache ??= InvoiceFonts(
        regular: pw.Font.ttf(await rootBundle.load('assets/fonts/Inter-Regular.ttf')),
        medium: pw.Font.ttf(await rootBundle.load('assets/fonts/Inter-SemiBold.ttf')),
        bold: pw.Font.ttf(await rootBundle.load('assets/fonts/Inter-Bold.ttf')),
      );

  /// Loads from a fonts directory on disk (tests / isolates).
  static InvoiceFonts fromDirectory(String dir) {
    pw.Font f(String n) => pw.Font.ttf(ByteData.sublistView(File('$dir/$n').readAsBytesSync()));
    return InvoiceFonts(regular: f('Inter-Regular.ttf'), medium: f('Inter-SemiBold.ttf'), bold: f('Inter-Bold.ttf'));
  }
}

PdfColor _c(int argb) => PdfColor.fromInt(argb);

/// Page format per paper. Thermal rolls are one long page.
PdfPageFormat pageFormatFor(InvoicePaper p) => switch (p) {
      InvoicePaper.a4 => PdfPageFormat.a4,
      InvoicePaper.a5 => PdfPageFormat.a5,
      InvoicePaper.t80 => PdfPageFormat.roll80,
      InvoicePaper.t58 => PdfPageFormat.roll57,
    };

/// Builds the invoice PDF from the shared view-model (SPEC §6). Pure apart
/// from reading the logo file.
Future<Uint8List> buildInvoicePdf(InvoiceDoc doc, {required InvoiceFonts fonts, required int accentArgb}) async {
  final pdf = pw.Document(title: doc.number, author: doc.storeName, creator: 'RxDesk');
  pw.MemoryImage? logo;
  if (doc.logoPath.isNotEmpty) {
    final f = File(doc.logoPath);
    if (f.existsSync()) logo = pw.MemoryImage(await f.readAsBytes());
  }
  final b = _Builder(doc, fonts, _c(accentArgb), logo);
  final format = pageFormatFor(doc.paper);
  if (doc.thermal) {
    pdf.addPage(
      pw.Page(
        pageFormat: format.copyWith(marginLeft: 3 * PdfPageFormat.mm, marginRight: 3 * PdfPageFormat.mm, marginTop: 4 * PdfPageFormat.mm, marginBottom: 6 * PdfPageFormat.mm),
        theme: b.theme,
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: b.thermalBody()),
      ),
    );
  } else {
    final margin = doc.paper == InvoicePaper.a5 ? 10 * PdfPageFormat.mm : 14 * PdfPageFormat.mm;
    pdf.addPage(
      pw.MultiPage(
        pageFormat: format.copyWith(marginLeft: margin, marginRight: margin, marginTop: margin, marginBottom: margin),
        theme: b.theme,
        build: (_) => b.pageBody(),
        footer: (ctx) => ctx.pagesCount > 1
            ? pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('${doc.number} · page ${ctx.pageNumber} of ${ctx.pagesCount}', style: b.small))
            : pw.SizedBox(),
      ),
    );
  }
  return pdf.save();
}

class _Builder {
  _Builder(this.doc, this.fonts, this.accent, this.logo);

  final InvoiceDoc doc;
  final InvoiceFonts fonts;
  final PdfColor accent;
  final pw.MemoryImage? logo;

  late final PdfColor ink = _c(AppColors.text.toARGB32());
  late final PdfColor muted = _c(AppColors.textSecondary.toARGB32());
  late final PdfColor label = _c(AppColors.label.toARGB32());
  late final PdfColor rule = _c(AppColors.divider.toARGB32());
  late final PdfColor band = _c(AppColors.surfaceAlt.toARGB32());
  late final PdfColor white = _c(AppColors.surface.toARGB32());
  late final PdfColor danger = _c(StatusTone.danger.colors.fg.toARGB32());

  double get base => switch (doc.paper) {
        InvoicePaper.a4 => 9.5,
        InvoicePaper.a5 => 8.5,
        InvoicePaper.t80 => 8,
        InvoicePaper.t58 => 7,
      };

  pw.ThemeData get theme => pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold).copyWith(
        defaultTextStyle: pw.TextStyle(font: fonts.regular, fontBold: fonts.bold, fontSize: base, color: ink),
      );

  pw.TextStyle get small => pw.TextStyle(fontSize: base - 1.5, color: muted);
  pw.TextStyle get strong => pw.TextStyle(font: fonts.medium, fontSize: base);
  pw.TextStyle get capLabel => pw.TextStyle(font: fonts.medium, fontSize: base - 2, color: label, letterSpacing: 0.6);

  // ---------------------------------------------------------------- A4 / A5

  List<pw.Widget> pageBody() => [
        if (doc.cancelled) _cancelBanner(),
        _header(),
        pw.SizedBox(height: 12),
        _infoStrip(),
        pw.SizedBox(height: 12),
        _itemTable(),
        pw.SizedBox(height: 14),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(child: _qrAndFooter()),
            pw.SizedBox(width: 18),
            pw.SizedBox(width: doc.paper == InvoicePaper.a5 ? 170 : 210, child: _totals()),
          ],
        ),
        pw.SizedBox(height: 26),
        _signature(),
      ];

  pw.Widget _cancelBanner() => pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 8),
        padding: const pw.EdgeInsets.symmetric(vertical: 4),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: danger)),
        alignment: pw.Alignment.center,
        child: pw.Text('CANCELLED', style: pw.TextStyle(font: fonts.bold, color: danger, letterSpacing: 2)),
      );

  pw.Widget _brand(double size) => logo != null
      ? pw.SizedBox(width: size, height: size, child: pw.Image(logo!))
      : pw.Container(
          width: size,
          height: size,
          alignment: pw.Alignment.center,
          decoration: pw.BoxDecoration(color: accent, borderRadius: pw.BorderRadius.circular(size * 0.27)),
          child: pw.Text(doc.initials, style: pw.TextStyle(font: fonts.bold, color: white, fontSize: size * 0.36)),
        );

  pw.Widget _header() => pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _brand(34),
          pw.SizedBox(width: 10),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(doc.storeName, style: pw.TextStyle(font: fonts.bold, fontSize: base + 6)),
                pw.SizedBox(height: 2),
                pw.Text(doc.address, style: small),
                if (doc.contact.isNotEmpty) pw.Text(doc.contact, style: small),
                if (doc.registrations.isNotEmpty) pw.Text(doc.registrations, style: small),
              ],
            ),
          ),
          pw.SizedBox(width: 12),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(doc.docTitle, style: pw.TextStyle(font: fonts.bold, fontSize: base - 1.5, color: accent, letterSpacing: 1)),
              pw.SizedBox(height: 2),
              pw.Text(doc.number, style: pw.TextStyle(font: fonts.bold, fontSize: base + 3.5)),
              pw.Text('${doc.dateText} · ${doc.timeText}', style: small),
              if (doc.against != null) pw.Text(doc.against!, style: small),
            ],
          ),
        ],
      );

  pw.Widget _cell(String head, String value, {String? sub}) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(head, style: capLabel),
          pw.SizedBox(height: 2),
          pw.Text(value, style: strong),
          if (sub != null) pw.Text(sub, style: small),
        ],
      );

  pw.Widget _infoStrip() => pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(color: band, borderRadius: pw.BorderRadius.circular(6)),
        child: pw.Row(
          children: [
            pw.Expanded(child: _cell('BILLED TO', doc.customer, sub: doc.phone)),
            if (doc.doctor != null) pw.Expanded(child: _cell('PRESCRIBED BY', doc.doctor!)),
            pw.Expanded(child: _cell(doc.paymentLabel.toUpperCase(), doc.payment, sub: doc.paymentSub)),
          ],
        ),
      );

  pw.Widget _itemTable() {
    final c = doc.columns;
    final heads = <(String, double?, bool)>[
      ('#', 18, false),
      ('Item', null, false),
      if (c.batch) ('Batch', 62, false),
      if (c.expiry) ('Exp', 58, false),
      if (c.hsn) ('HSN', 36, false),
      ('Qty', c.wideQty ? 50 : 26, true),
      ('MRP', 52, true),
      if (c.gst) ('GST', 30, true),
      ('Amount', 62, true),
    ];
    final widths = <int, pw.TableColumnWidth>{
      for (final (i, h) in heads.indexed) i: h.$2 == null ? const pw.FlexColumnWidth() : pw.FixedColumnWidth(h.$2!),
    };
    pw.Widget txt(String s, {bool right = false, pw.TextStyle? style}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 3),
          child: pw.Text(s, textAlign: right ? pw.TextAlign.right : pw.TextAlign.left, style: style),
        );
    return pw.Table(
      columnWidths: widths,
      border: pw.TableBorder(horizontalInside: pw.BorderSide(color: rule, width: 0.6)),
      children: [
        pw.TableRow(
          decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: ink, width: 1.1))),
          children: [for (final h in heads) txt(h.$1, right: h.$3, style: pw.TextStyle(font: fonts.medium, color: label))],
        ),
        for (final l in doc.lines)
          pw.TableRow(
            children: [
              txt('${l.sl}', style: pw.TextStyle(color: muted)),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 3),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(l.name, style: strong),
                    if (c.salt && l.salt.isNotEmpty) pw.Text(l.salt, style: small),
                  ],
                ),
              ),
              if (c.batch) txt(l.batch, style: pw.TextStyle(fontSize: base - 1)),
              if (c.expiry) txt(l.expiry),
              if (c.hsn) txt(l.hsn, style: pw.TextStyle(fontSize: base - 1)),
              txt(l.qty, right: true),
              txt(l.mrp, right: true),
              if (c.gst) txt(l.gst, right: true),
              txt(l.amount, right: true, style: strong),
            ],
          ),
      ],
    );
  }

  pw.Widget _qr(double size) => pw.Column(
        children: [
          if (doc.upiUri != null)
            pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: doc.upiUri!, width: size, height: size, drawText: false)
          else
            pw.Container(
              width: size,
              height: size,
              alignment: pw.Alignment.center,
              decoration: pw.BoxDecoration(border: pw.Border.all(color: muted, width: 0.8), borderRadius: pw.BorderRadius.circular(4)),
              child: pw.Text('UPI QR', style: capLabel),
            ),
          pw.SizedBox(height: 3),
          pw.SizedBox(width: size + 16, child: pw.Text(doc.upiId!, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: base - 2.5, color: muted))),
        ],
      );

  pw.Widget _qrAndFooter() => pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          if (doc.upiId != null) ...[_qr(70), pw.SizedBox(width: 12)],
          pw.Expanded(child: pw.Text(doc.footer, style: small.copyWith(lineSpacing: 2))),
        ],
      );

  pw.Widget _totRow(String l, String v, {bool big = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(
          children: [
            pw.Expanded(child: pw.Text(l, style: big ? pw.TextStyle(font: fonts.bold) : pw.TextStyle(color: muted))),
            pw.Text(v, style: big ? pw.TextStyle(font: fonts.bold, fontSize: base + 5) : null),
          ],
        ),
      );

  pw.Widget _totals() => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          _totRow('Subtotal (MRP)', doc.subtotal),
          _totRow('Discount', '− ${doc.discount}'),
          if (doc.showTax) ...[
            _totRow('Taxable value', doc.taxable),
            _totRow('CGST', doc.cgst),
            _totRow('SGST', doc.sgst),
          ],
          if (doc.roundOff != null) _totRow('Round off', doc.roundOff!),
          pw.Container(
            margin: const pw.EdgeInsets.only(top: 4),
            padding: const pw.EdgeInsets.only(top: 5),
            decoration: pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: ink, width: 1.1))),
            child: _totRow('Grand total', doc.total, big: true),
          ),
          if (doc.saved != null)
            pw.Container(
              margin: const pw.EdgeInsets.only(top: 6),
              padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              alignment: pw.Alignment.center,
              decoration: pw.BoxDecoration(color: band, borderRadius: pw.BorderRadius.circular(10)),
              child: pw.Text('You saved ${doc.saved} on MRP', style: pw.TextStyle(font: fonts.medium, color: accent)),
            ),
        ],
      );

  pw.Widget _signature() => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.SizedBox(
          width: 200,
          child: pw.Column(
            children: [
              pw.Container(height: 0.8, color: muted),
              pw.SizedBox(height: 3),
              pw.Text(doc.signatureLabel, textAlign: pw.TextAlign.center, style: small),
              pw.Text(doc.forStore, textAlign: pw.TextAlign.center, style: strong),
            ],
          ),
        ),
      );

  // ---------------------------------------------------------------- thermal

  List<pw.Widget> thermalBody() {
    final c = doc.columns;
    pw.Widget line() => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 3),
          child: pw.Divider(height: 1, thickness: 0.6, color: muted, borderStyle: pw.BorderStyle.dashed),
        );
    return [
      if (doc.cancelled) _cancelBanner(),
      pw.Center(child: _brand(22)),
      pw.SizedBox(height: 3),
      pw.Text(doc.storeName, textAlign: pw.TextAlign.center, style: pw.TextStyle(font: fonts.bold, fontSize: base + 3)),
      pw.Text(doc.address, textAlign: pw.TextAlign.center, style: small),
      if (doc.contact.isNotEmpty) pw.Text(doc.contact, textAlign: pw.TextAlign.center, style: small),
      if (doc.registrations.isNotEmpty) pw.Text(doc.registrations, textAlign: pw.TextAlign.center, style: small),
      pw.SizedBox(height: 4),
      pw.Text(doc.docTitle, textAlign: pw.TextAlign.center, style: pw.TextStyle(font: fonts.bold, letterSpacing: 1)),
      line(),
      pw.Text('${doc.number}   ${doc.dateText} ${doc.timeText}', style: strong),
      if (doc.against != null) pw.Text(doc.against!, style: small),
      pw.Text('To: ${doc.customer}${doc.phone == '—' ? '' : ' · ${doc.phone}'}'),
      if (doc.doctor != null) pw.Text('Dr: ${doc.doctor}'),
      pw.Text('${doc.paymentLabel}: ${doc.payment}'),
      if (doc.paymentSub != null) pw.Text(doc.paymentSub!, style: small),
      line(),
      for (final l in doc.lines) ...[
        pw.Text('${l.sl}. ${l.name}', style: strong),
        if (c.salt && l.salt.isNotEmpty) pw.Text(l.salt, style: small),
        pw.Row(
          children: [
            pw.Expanded(child: pw.Text(c.expiry ? 'Exp ${l.expiry}' : '', style: small)),
            pw.Text('${l.qty} × ${l.mrp}  '),
            pw.SizedBox(width: doc.paper == InvoicePaper.t58 ? 46 : 56, child: pw.Text(l.amount, textAlign: pw.TextAlign.right, style: strong)),
          ],
        ),
        pw.SizedBox(height: 2),
      ],
      line(),
      _totRow('Subtotal (MRP)', doc.subtotal),
      _totRow('Discount', '− ${doc.discount}'),
      if (doc.showTax) ...[
        _totRow('Taxable value', doc.taxable),
        _totRow('CGST', doc.cgst),
        _totRow('SGST', doc.sgst),
      ],
      if (doc.roundOff != null) _totRow('Round off', doc.roundOff!),
      line(),
      _totRow('Grand total', doc.total, big: true),
      if (doc.saved != null) pw.Text('You saved ${doc.saved} on MRP', textAlign: pw.TextAlign.center, style: pw.TextStyle(font: fonts.medium)),
      if (doc.upiId != null) ...[pw.SizedBox(height: 6), pw.Center(child: _qr(doc.paper == InvoicePaper.t58 ? 70 : 90))],
      pw.SizedBox(height: 6),
      pw.Text(doc.footer, textAlign: pw.TextAlign.center, style: small),
      pw.SizedBox(height: 16),
      pw.Text(doc.signatureLabel, textAlign: pw.TextAlign.center, style: small),
      pw.Text(doc.forStore, textAlign: pw.TextAlign.center, style: strong),
    ];
  }
}
