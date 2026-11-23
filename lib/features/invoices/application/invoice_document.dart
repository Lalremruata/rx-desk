import '../../../core/db/daos/sales_dao.dart';
import '../../../core/money/gst.dart';
import '../../../core/money/paise.dart';
import '../../../core/sales/bill_rules.dart';
import '../../../core/tax/gstin.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/pack.dart';
import '../../settings/application/app_settings.dart';

/// A bill as stored (snapshots), independent of Drift — the input to the
/// invoice document builder.
class InvoiceData {
  const InvoiceData({
    required this.number,
    required this.createdAt,
    required this.customerName,
    this.customerPhone,
    this.doctorName,
    required this.paymentMode,
    required this.gstRegistered,
    required this.subtotal,
    required this.discount,
    required this.taxable,
    required this.cgst,
    required this.sgst,
    required this.roundOff,
    required this.total,
    required this.items,
    this.status = 'paid',
    this.isCreditNote = false,
    this.againstNumber,
    this.againstDate,
    this.paidNow,
    this.duesAfter,
    this.buyerGstin,
    this.placeOfSupply,
  });

  /// Credit notes are stored negative; the document shows the refund as
  /// positive amounts.
  factory InvoiceData.fromDb(InvoiceWithItems w) {
    final i = w.invoice;
    final cn = i.docType == 'credit_note';
    final sign = cn ? -1 : 1;
    Paise m(int v) => Paise(v * sign);
    final against = w.against;
    return InvoiceData(
      number: i.number,
      createdAt: DateTime.fromMillisecondsSinceEpoch(i.createdAt, isUtc: true).toLocal(),
      customerName: i.customerName,
      customerPhone: i.customerPhone,
      doctorName: i.doctorName,
      paymentMode: i.paymentMode,
      gstRegistered: i.gstRegistered,
      buyerGstin: i.buyerGstin,
      placeOfSupply: i.placeOfSupply,
      subtotal: m(i.subtotalPaise),
      discount: m(i.discountPaise),
      taxable: m(i.taxablePaise),
      cgst: m(i.cgstPaise),
      sgst: m(i.sgstPaise),
      roundOff: m(i.roundOffPaise),
      total: m(i.totalPaise),
      status: i.status,
      isCreditNote: cn,
      againstNumber: against?.number,
      againstDate: against == null ? null : DateTime.fromMillisecondsSinceEpoch(against.createdAt, isUtc: true).toLocal(),
      paidNow: i.paidNowPaise == null ? null : Paise(i.paidNowPaise!),
      duesAfter: i.duesAfterPaise == null ? null : Paise(i.duesAfterPaise!),
      items: [
        for (final it in w.items)
          InvoiceDataLine(
            name: it.productName,
            salt: it.salt,
            batchNo: it.batchNo,
            expiry: it.expiry,
            hsn: it.hsn,
            qty: it.qty * sign,
            mrp: Paise(it.mrpPaise),
            gstRate: it.gstRate,
            gross: m(it.grossPaise),
            packSize: it.packSize,
            category: it.category,
          ),
      ],
    );
  }

  final String number;
  final DateTime createdAt;
  final String customerName;
  final String? customerPhone;
  final String? doctorName;
  final String paymentMode;
  final bool gstRegistered;
  final Paise subtotal;
  final Paise discount;
  final Paise taxable;
  final Paise cgst;
  final Paise sgst;
  final Paise roundOff;
  final Paise total;
  final List<InvoiceDataLine> items;
  final String status;

  /// Sales return (SPEC §4.5): amounts here are the refund, positive.
  final bool isCreditNote;

  /// Credit note → the original invoice's number and date.
  final String? againstNumber;

  /// Credit bills (SPEC §4.10): paid at the counter, and the customer's
  /// total dues right after the bill (snapshots).
  final Paise? paidNow;
  final Paise? duesAfter;

  /// B2B bills (SPEC §4.15): the buyer's GSTIN and place of supply code.
  final String? buyerGstin;
  final String? placeOfSupply;
  final DateTime? againstDate;
}

class InvoiceDataLine {
  const InvoiceDataLine({
    required this.name,
    required this.salt,
    required this.batchNo,
    required this.expiry,
    required this.hsn,
    required this.qty,
    required this.mrp,
    required this.gstRate,
    required this.gross,
    this.packSize = 1,
    this.category = '',
  });

  /// Units per pack when sold; [qty] is in units, [mrp] per pack.
  final int packSize;
  final String category;
  final String name;
  final String salt;
  final String batchNo;
  final String expiry;
  final String hsn;
  final int qty;
  final Paise mrp;
  final int gstRate;
  final Paise gross;
}

/// Which item-table columns appear (SPEC §6 table).
class InvoiceColumns {
  const InvoiceColumns({
    required this.batch,
    required this.expiry,
    required this.hsn,
    required this.gst,
    required this.salt,
    this.wideQty = false,
  });

  /// Some line is loose ("1 + 5 tab") — the Qty column needs more room.
  final bool wideQty;
  final bool batch;
  final bool expiry;
  final bool hsn;
  final bool gst;
  final bool salt;
}

class InvoiceDocLine {
  const InvoiceDocLine({
    required this.sl,
    required this.name,
    required this.salt,
    required this.batch,
    required this.expiry,
    required this.hsn,
    required this.qty,
    required this.mrp,
    required this.gst,
    required this.amount,
  });

  final int sl;
  final String name;
  final String salt;
  final String batch;
  final String expiry;
  final String hsn;
  final String qty;
  final String mrp;
  final String gst;
  final String amount;
}

/// Everything the printed / previewed invoice shows, as display strings.
/// One view-model feeds both the PDF and the on-screen paper (SPEC §6;
/// prototype `invView`).
class InvoiceDoc {
  const InvoiceDoc({
    required this.paper,
    required this.storeName,
    required this.initials,
    required this.logoPath,
    required this.address,
    required this.contact,
    required this.registrations,
    required this.docTitle,
    required this.number,
    required this.dateText,
    required this.timeText,
    required this.customer,
    required this.phone,
    required this.doctor,
    required this.payment,
    required this.columns,
    required this.lines,
    required this.subtotal,
    required this.discount,
    required this.showTax,
    required this.taxable,
    required this.cgst,
    required this.sgst,
    required this.roundOff,
    required this.total,
    required this.saved,
    required this.upiId,
    required this.upiUri,
    required this.footer,
    required this.signatureLabel,
    required this.forStore,
    required this.cancelled,
    this.paymentLabel = 'Payment',
    this.paymentSub,
    this.against,
    this.returnStatus,
  });

  final InvoicePaper paper;
  final String storeName;
  final String initials;
  final String logoPath;
  final String address;
  final String contact;
  final String registrations;

  /// "TAX INVOICE", "BILL OF SUPPLY" or "CREDIT NOTE".
  final String docTitle;
  final String number;
  final String dateText;
  final String timeText;
  final String customer;
  final String phone;

  /// Null when hidden or absent.
  final String? doctor;
  final String payment;
  final InvoiceColumns columns;
  final List<InvoiceDocLine> lines;
  final String subtotal;
  final String discount;
  final bool showTax;
  final String taxable;
  final String cgst;
  final String sgst;

  /// "+ ₹0.40" / "− ₹0.40", null when off or zero.
  final String? roundOff;
  final String total;

  /// "You saved ₹X on MRP" amount, null when hidden.
  final String? saved;

  /// UPI QR (null when off or no UPI id).
  final String? upiId;
  final String? upiUri;
  final String footer;

  /// "Registered Pharmacist · Name (Reg. 123)".
  final String signatureLabel;

  /// "for Store Name".
  final String forStore;
  final bool cancelled;

  /// "Payment" on invoices, "Refund" on credit notes.
  final String paymentLabel;

  /// Credit bills: "Paid ₹100.00 · Balance ₹209.00 · Total dues ₹1,250.00".
  final String? paymentSub;

  /// Credit note: "Against INV/26-27/00412 · 09 Nov 2026".
  final String? against;

  /// Invoice with returns: "Part returned" / "Returned" (on-screen only).
  final String? returnStatus;

  bool get thermal => paper.isThermal;
}

/// The money line under "Payment" on a Credit bill (SPEC §4.10).
String? creditPaymentLine(InvoiceData d) {
  if (d.isCreditNote || d.paymentMode != creditMode) return null;
  final paid = d.paidNow ?? Paise.zero;
  return _join([
    if (paid.value > 0) 'Paid ${formatInr(paid)}',
    'Balance ${formatInr(d.total - paid)}',
    if (d.duesAfter != null) 'Total dues ${formatInr(d.duesAfter!)}',
  ], ' · ');
}

String _join(Iterable<String?> parts, String sep) =>
    parts.map((p) => (p ?? '').trim()).where((p) => p.isNotEmpty).join(sep);

/// UPI deep link for the bill amount (SPEC §6).
String upiPayUri({required String upiId, required String payee, required Paise amount}) {
  final am = amount.toInputString();
  return 'upi://pay?pa=${Uri.encodeComponent(upiId)}&pn=${Uri.encodeComponent(payee)}&am=$am&cu=INR';
}

/// Builds the invoice view-model for [paper] with the layout switches in
/// [s]. Money comes from the stored bill (snapshots), never recomputed.
InvoiceDoc buildInvoiceDoc(InvoiceData d, AppSettings s, {InvoicePaper? paperOverride}) {
  final paper = paperOverride ?? s.paper;
  final thermal = paper.isThermal;
  final name = s.name.trim().isEmpty ? '[Your Pharmacy Name]' : s.name.trim();
  final place = _join([_join([s.city, s.state], ', '), s.pin], ' – ');
  final cols = InvoiceColumns(
    batch: s.showBatch && !thermal,
    expiry: s.showExpiry && paper != InvoicePaper.t58,
    hsn: s.showHsn && !thermal,
    gst: d.gstRegistered && !thermal,
    salt: s.showSalt,
    wideQty: d.items.any((l) => l.packSize > 1 && l.qty % l.packSize != 0),
  );
  final doctor = (d.doctorName ?? '').trim();
  final upi = s.upiId.trim();
  return InvoiceDoc(
    paper: paper,
    storeName: name,
    initials: s.initials,
    logoPath: s.logoPath,
    address: _join([s.addr1, s.addr2, place], ', ').isEmpty ? '[Address]' : _join([s.addr1, s.addr2, place], ', '),
    contact: _join([if (s.phone.trim().isNotEmpty) 'Ph ${s.phone.trim()}', s.email], ' · '),
    registrations: _join([
      if (d.gstRegistered && s.gstin.isNotEmpty) 'GSTIN ${s.gstin}',
      if (s.dl20b.isNotEmpty) 'DL 20B ${s.dl20b}',
      if (s.dl21b.isNotEmpty) '21B ${s.dl21b}',
    ], ' · '),
    docTitle: d.isCreditNote ? 'CREDIT NOTE' : (d.gstRegistered ? 'TAX INVOICE' : 'BILL OF SUPPLY'),
    number: d.number,
    dateText: formatDate(d.createdAt),
    timeText: formatTime(d.createdAt),
    customer: d.customerName,
    phone: _billedToSub(d),
    doctor: s.showDoctor && doctor.isNotEmpty ? doctor : null,
    payment: d.paymentMode == creditMode ? (d.isCreditNote ? 'Adjusted in dues' : 'Credit') : d.paymentMode,
    paymentSub: creditPaymentLine(d),
    columns: cols,
    lines: [
      for (final (i, l) in d.items.indexed)
        InvoiceDocLine(
          sl: i + 1,
          name: l.name,
          salt: l.salt,
          batch: l.batchNo,
          expiry: formatExpiry(l.expiry),
          hsn: l.hsn,
          qty: compactPackQty(l.qty, l.packSize, l.category),
          mrp: formatInr(l.mrp),
          gst: '${l.gstRate}%',
          amount: formatInr(l.gross),
        ),
    ],
    subtotal: formatInr(d.subtotal),
    discount: formatInr(d.discount),
    showTax: d.gstRegistered,
    taxable: formatInr(d.taxable),
    cgst: formatInr(d.cgst),
    sgst: formatInr(d.sgst),
    roundOff: s.roundOff && !d.roundOff.isZero
        ? '${d.roundOff.isNegative ? '−' : '+'} ${formatInr(d.roundOff.abs())}'
        : null,
    total: formatInr(d.total),
    saved: !d.isCreditNote && s.showSaved && d.discount.value > 0 ? formatInr(d.discount) : null,
    upiId: !d.isCreditNote && s.showUpiQr ? (upi.isEmpty ? '[UPI ID]' : upi) : null,
    upiUri: !d.isCreditNote && s.showUpiQr && upi.isNotEmpty ? upiPayUri(upiId: upi, payee: name, amount: d.total) : null,
    footer: s.footer,
    signatureLabel: _join([
      s.signatureLabel.trim().isEmpty ? 'Authorised signatory' : s.signatureLabel.trim(),
      _join([s.pharmacistName, if (s.pharmacistRegNo.isNotEmpty) '(Reg. ${s.pharmacistRegNo})'], ' '),
    ], ' · '),
    forStore: 'for $name',
    cancelled: d.status == 'cancelled',
    paymentLabel: d.isCreditNote ? 'Refund' : 'Payment',
    against: d.isCreditNote && d.againstNumber != null
        ? _join(['Against ${d.againstNumber}', if (d.againstDate != null) formatDate(d.againstDate!)], ' · ')
        : null,
    returnStatus: switch (d.status) {
      'part_returned' => 'Part returned',
      'returned' => 'Returned',
      _ => null,
    },
  );
}

/// A sample bill for the Settings › Invoice preview and Test print.
InvoiceData sampleInvoice({required String number, required DateTime at, required bool gstRegistered, required bool roundOff}) {
  const lines = [
    ('Paracetamol 650 mg Tablet', 'Paracetamol 650 mg', 'PCM2611', '2027-08', 2, 3090, 12),
    ('Cetirizine 10 mg Tablet', 'Cetirizine 10 mg', 'CTZ1180', '2028-02', 1, 2200, 12),
    ('Oral Rehydration Salts 21 g Sachet', 'Oral Rehydration Salts 21 g', 'ORS2209', '2027-09', 4, 2100, 5),
  ];
  final amounts = [
    for (final l in lines) (computeLine(mrp: Paise(l.$6), qty: l.$5, discountPct: 5, gstRate: l.$7, gstRegistered: gstRegistered), l.$5),
  ];
  final t = computeBill(amounts, roundOff: roundOff);
  final items = [
    for (final l in lines)
      InvoiceDataLine(name: l.$1, salt: l.$2, batchNo: l.$3, expiry: l.$4, hsn: '3004', qty: l.$5, mrp: Paise(l.$6), gstRate: l.$7, gross: Paise(l.$6 * l.$5)),
  ];
  return InvoiceData(
    number: number,
    createdAt: at,
    customerName: 'Esther Zothanpari',
    customerPhone: '98XXXXXX01',
    doctorName: 'Dr. K. Lalnunmawii',
    paymentMode: 'UPI',
    gstRegistered: gstRegistered,
    subtotal: t.subtotal,
    discount: t.discount,
    taxable: t.taxable,
    cgst: t.cgst,
    sgst: t.sgst,
    roundOff: t.roundOff,
    total: t.total,
    items: items,
  );
}

/// Under "Billed to": the phone, and for a B2B bill the buyer's GSTIN and
/// the place of supply (SPEC §4.15).
String _billedToSub(InvoiceData d) {
  final phone = (d.customerPhone ?? '').isEmpty ? '—' : d.customerPhone!;
  final g = d.buyerGstin;
  if (g == null || g.isEmpty) return phone;
  final b2b = 'GSTIN $g · Place of supply ${placeOfSupplyLabel(d.placeOfSupply ?? gstinState(g))}';
  return phone == '—' ? b2b : '$phone\n$b2b';
}
