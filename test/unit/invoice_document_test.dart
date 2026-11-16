import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/utils/expiry.dart';
import 'package:rx_desk/features/invoices/application/invoice_document.dart';
import 'package:rx_desk/features/invoices/application/invoice_pdf.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';

InvoiceData sample({bool gst = true, bool roundOff = true}) =>
    sampleInvoice(number: 'INV/26-27/00412', at: DateTime(2026, 11, 9, 11, 42), gstRegistered: gst, roundOff: roundOff);

const store = AppSettings(
  name: 'Zion Medicos',
  addr1: 'Main Road',
  city: 'Aizawl',
  state: 'Mizoram',
  pin: '796001',
  phone: '0389 222 1234',
  gstin: '15ABCDE1234F1Z5',
  dl20b: 'MZ-20B-0001',
  dl21b: 'MZ-21B-0001',
  pharmacistName: 'R. Lalhmangaihi',
  pharmacistRegNo: 'MZ1234',
  upiId: 'zion@upi',
  showHsn: true,
);

void main() {
  group('buildInvoiceDoc (SPEC §6, prototype invView)', () {
    test('header, info strip and registrations', () {
      final d = buildInvoiceDoc(sample(), store);
      expect(d.docTitle, 'TAX INVOICE');
      expect(d.initials, 'ZM');
      expect(d.address, 'Main Road, Aizawl, Mizoram – 796001');
      expect(d.contact, 'Ph 0389 222 1234');
      expect(d.registrations, 'GSTIN 15ABCDE1234F1Z5 · DL 20B MZ-20B-0001 · 21B MZ-21B-0001');
      expect(d.dateText, '9 Nov 2026');
      expect(d.timeText, '11:42');
      expect(d.doctor, 'Dr. K. Lalnunmawii');
      expect(d.signatureLabel, 'Registered Pharmacist · R. Lalhmangaihi (Reg. MZ1234)');
      expect(d.forStore, 'for Zion Medicos');
    });

    test('column rules per paper', () {
      InvoiceColumns cols(InvoicePaper p) => buildInvoiceDoc(sample(), store.copyWith(paper: p)).columns;
      final a4 = cols(InvoicePaper.a4);
      expect((a4.batch, a4.expiry, a4.hsn, a4.gst), (true, true, true, true));
      final a5 = cols(InvoicePaper.a5);
      expect((a5.batch, a5.expiry, a5.hsn, a5.gst), (true, true, true, true));
      final t80 = cols(InvoicePaper.t80);
      expect((t80.batch, t80.expiry, t80.hsn, t80.gst), (false, true, false, false));
      final t58 = cols(InvoicePaper.t58);
      expect((t58.batch, t58.expiry, t58.hsn, t58.gst), (false, false, false, false));
      expect(cols(InvoicePaper.a4).salt, isFalse);
      expect(buildInvoiceDoc(sample(), store.copyWith(showSalt: true, paper: InvoicePaper.t58)).columns.salt, isTrue);
    });

    test('show/hide switches', () {
      final d = buildInvoiceDoc(sample(), store.copyWith(showDoctor: false, showSaved: false, showUpiQr: false, showBatch: false));
      expect(d.doctor, isNull);
      expect(d.saved, isNull);
      expect(d.upiId, isNull);
      expect(d.columns.batch, isFalse);
    });

    test('credit note: title, against line, refund label, positive amounts, no UPI / saved', () {
      final inv = Invoice(
        id: 9,
        number: 'CN/26-27/00001',
        fy: '26-27',
        seq: 1,
        createdAt: DateTime(2026, 11, 11, 10).toUtc().millisecondsSinceEpoch,
        saleDate: '2026-11-11',
        customerName: 'Esther',
        paymentMode: 'Cash',
        discountPct: 5,
        subtotalPaise: -3090,
        discountPaise: -155,
        taxablePaise: -2621,
        cgstPaise: -157,
        sgstPaise: -157,
        roundOffPaise: 35,
        totalPaise: -2900,
        status: 'paid',
        gstRegistered: true,
        docType: 'credit_note',
        refInvoiceId: 3,
      );
      final orig = inv.copyWith(id: 3, number: 'INV/26-27/00003', docType: 'invoice', createdAt: DateTime(2026, 11, 9, 10).toUtc().millisecondsSinceEpoch);
      const item = InvoiceItem(
        id: 20,
        invoiceId: 9,
        saleDate: '2026-11-11',
        lineNo: 1,
        productId: 1,
        batchId: 1,
        productName: 'Paracetamol 650 mg Tablet',
        salt: 'Paracetamol 650 mg',
        manufacturer: 'Northline',
        category: 'Tablet',
        hsn: '3004',
        schedule: '',
        batchNo: 'PCM2611',
        expiry: '2027-08',
        mrpPaise: 3090,
        gstRate: 12,
        packSize: 1,
        qty: -1,
        grossPaise: -3090,
        discountPaise: -155,
        taxablePaise: -2621,
        taxPaise: -314,
        netPaise: -2935,
        paymentMode: 'Cash',
      );
      final data = InvoiceData.fromDb(InvoiceWithItems(inv, [item], against: orig));
      expect(data.total, const Paise(2900));
      expect(data.roundOff, const Paise(-35));
      expect(data.items.single.qty, 1);
      final d = buildInvoiceDoc(data, store);
      expect(d.docTitle, 'CREDIT NOTE');
      expect(d.against, 'Against INV/26-27/00003 · ${formatDate(DateTime(2026, 11, 9, 10))}');
      expect(d.paymentLabel, 'Refund');
      expect(d.total, formatInr(const Paise(2900)));
      expect(d.roundOff, startsWith('−'));
      expect(d.lines.single.qty, '1');
      expect(d.saved, isNull);
      expect(d.upiId, isNull);
      expect(d.cancelled, isFalse);

      final billDoc = buildInvoiceDoc(InvoiceData.fromDb(InvoiceWithItems(orig.copyWith(status: 'part_returned'), const [])), store);
      expect(billDoc.docTitle, 'TAX INVOICE');
      expect(billDoc.against, isNull);
      expect(billDoc.paymentLabel, 'Payment');
      expect(billDoc.returnStatus, 'Part returned');
    });

    test('bill of supply hides GST and the GST column', () {
      final d = buildInvoiceDoc(sample(gst: false), store);
      expect(d.docTitle, 'BILL OF SUPPLY');
      expect(d.showTax, isFalse);
      expect(d.columns.gst, isFalse);
      expect(d.registrations, isNot(contains('GSTIN')));
    });

    test('round off, you saved, UPI link use stored amounts', () {
      final data = sample();
      final d = buildInvoiceDoc(data, store);
      expect(data.total.value % 100, 0);
      expect(d.total, formatInr(data.total));
      expect(d.saved, formatInr(data.discount));
      if (!data.roundOff.isZero) expect(d.roundOff, startsWith(data.roundOff.isNegative ? '−' : '+'));
      expect(d.upiUri, 'upi://pay?pa=zion%40upi&pn=Zion%20Medicos&am=${data.total.toInputString()}&cu=INR');
      expect(buildInvoiceDoc(sample(roundOff: false), store.copyWith(roundOff: false)).roundOff, isNull);
    });

    test('missing UPI id shows the placeholder but no QR link', () {
      final d = buildInvoiceDoc(sample(), store.copyWith(upiId: ''));
      expect(d.upiId, '[UPI ID]');
      expect(d.upiUri, isNull);
    });

    test('sample totals balance', () {
      final s = sample();
      final gross = s.items.fold<int>(0, (a, l) => a + l.gross.value);
      expect(s.subtotal.value, gross);
      expect(s.cgst + s.sgst, s.total - s.roundOff - s.taxable);
    });
  });

  group('PDF', () {
    final fonts = InvoiceFonts.fromDirectory('assets/fonts');
    final out = Platform.environment['RXDESK_PDF_OUT'];
    for (final p in InvoicePaper.values) {
      test('renders ${p.label}', () async {
        final doc = buildInvoiceDoc(sample(), store.copyWith(paper: p, showSalt: true));
        final bytes = await buildInvoicePdf(doc, fonts: fonts, accentArgb: 0xFF0F766E);
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(bytes.length, greaterThan(5000));
        if (out != null) File('$out/invoice-${p.code}.pdf').writeAsBytesSync(bytes);
      });
    }

    test('long bill paginates on A4', () async {
      final base = sample();
      final many = InvoiceData(
        number: base.number,
        createdAt: base.createdAt,
        customerName: base.customerName,
        paymentMode: base.paymentMode,
        gstRegistered: true,
        subtotal: base.subtotal,
        discount: base.discount,
        taxable: base.taxable,
        cgst: base.cgst,
        sgst: base.sgst,
        roundOff: base.roundOff,
        total: base.total,
        items: [for (var i = 0; i < 80; i++) base.items[i % 3]],
      );
      final bytes = await buildInvoicePdf(buildInvoiceDoc(many, store), fonts: fonts, accentArgb: 0xFF0F766E);
      expect(RegExp(r'/Type\s*/Page(?!s)').allMatches(String.fromCharCodes(bytes)).length, greaterThan(1));
    });
  });
}
