/// GSTR-1 tables from a month's bills (SPEC §4.15). Pure Dart.
///
/// Built from invoice and credit-note snapshots (CLAUDE.md rule 8):
/// b2b (bills with a buyer GSTIN), b2cs (all other bills, net of their
/// credit notes), cdnr (credit notes against B2B bills), hsn (split B2B /
/// B2C) and docs (number ranges issued). Intra-state only: tax is CGST +
/// SGST, the odd paisa on SGST, per line as on the bill.
///
/// Column layouts follow the GST offline tool's Excel template; check them
/// against the current template with your CA before filing (SPEC §12).
library;

import 'gstin.dart';

/// One invoice or credit note of the period.
class Gstr1Doc {
  const Gstr1Doc({
    required this.id,
    required this.docType,
    required this.number,
    required this.seq,
    required this.fy,
    required this.saleDate,
    required this.status,
    required this.customerName,
    required this.totalPaise,
    this.buyerGstin,
    this.placeOfSupply,
    this.refNumber,
    this.refDate,
    this.gstRegistered = true,
  });

  final int id;

  /// 'invoice' | 'credit_note'
  final String docType;
  final String number;
  final int seq;
  final String fy;
  final String saleDate;
  final String status;
  final String customerName;

  /// Negative for a credit note (as stored).
  final int totalPaise;
  final String? buyerGstin;
  final String? placeOfSupply;

  /// Credit notes: the invoice they return against.
  final String? refNumber;
  final String? refDate;
  final bool gstRegistered;

  bool get isCreditNote => docType == 'credit_note';
  bool get isB2b => (buyerGstin ?? '').isNotEmpty;
  bool get counts => status != 'cancelled' && gstRegistered;
}

/// One line of a [Gstr1Doc] (amounts negative on credit notes).
class Gstr1Item {
  const Gstr1Item({
    required this.docId,
    required this.hsn,
    required this.description,
    required this.qty,
    required this.packSize,
    required this.gstRate,
    required this.taxablePaise,
    required this.taxPaise,
    required this.netPaise,
  });

  final int docId;
  final String hsn;
  final String description;

  /// Units sold (tablets when loose); [packSize] units make one pack.
  final int qty;
  final int packSize;
  final int gstRate;
  final int taxablePaise;
  final int taxPaise;
  final int netPaise;

  /// CGST share of the line's tax (SGST takes the odd paisa).
  int get cgstPaise => taxPaise >= 0 ? taxPaise ~/ 2 : -((-taxPaise) ~/ 2);
  int get sgstPaise => taxPaise - cgstPaise;
}

class Gstr1B2b {
  const Gstr1B2b({required this.doc, required this.rate, required this.taxablePaise});
  final Gstr1Doc doc;
  final int rate;
  final int taxablePaise;
}

class Gstr1B2cs {
  const Gstr1B2cs({required this.rate, required this.taxablePaise, required this.taxPaise});
  final int rate;
  final int taxablePaise;
  final int taxPaise;
}

class Gstr1Hsn {
  Gstr1Hsn({required this.hsn, required this.description, required this.rate});
  final String hsn;
  final String description;
  final int rate;

  /// In packs (strips / bottles), to two decimals.
  double qty = 0;
  int valuePaise = 0;
  int taxablePaise = 0;
  int cgstPaise = 0;
  int sgstPaise = 0;
}

class Gstr1DocRange {
  const Gstr1DocRange({required this.nature, required this.from, required this.to, required this.total, required this.cancelled});
  final String nature;
  final String from;
  final String to;
  final int total;
  final int cancelled;
}

class Gstr1Report {
  const Gstr1Report({
    required this.b2b,
    required this.b2cs,
    required this.cdnr,
    required this.hsnB2b,
    required this.hsnB2c,
    required this.docs,
    required this.storeState,
  });

  final List<Gstr1B2b> b2b;
  final List<Gstr1B2cs> b2cs;
  final List<Gstr1B2b> cdnr;
  final List<Gstr1Hsn> hsnB2b;
  final List<Gstr1Hsn> hsnB2c;
  final List<Gstr1DocRange> docs;
  final String storeState;

  int get b2bTaxable => b2b.fold(0, (a, r) => a + r.taxablePaise);
  int get b2csTaxable => b2cs.fold(0, (a, r) => a + r.taxablePaise);
  int get cdnrTaxable => cdnr.fold(0, (a, r) => a + r.taxablePaise);

  /// Net taxable value of the period: B2B + B2C (net) − B2B credit notes.
  int get netTaxable => b2bTaxable + b2csTaxable - cdnrTaxable;

  int get hsnTaxable => [...hsnB2b, ...hsnB2c].fold(0, (a, h) => a + h.taxablePaise);
}

/// Builds the GSTR-1 tables. [storeGstin] gives the place of supply for
/// B2C supplies.
Gstr1Report buildGstr1({required List<Gstr1Doc> docs, required List<Gstr1Item> items, required String storeGstin}) {
  final byId = {for (final d in docs) d.id: d};
  final storeState = isValidGstin(storeGstin) ? gstinState(storeGstin) : '';

  final b2bKey = <(int, int), int>{};
  final cdnrKey = <(int, int), int>{};
  final b2cs = <int, (int, int)>{};
  final hsn = <(bool, String, int), Gstr1Hsn>{};
  for (final it in items) {
    final d = byId[it.docId];
    if (d == null || !d.counts) continue;
    if (d.isB2b && !d.isCreditNote) {
      b2bKey[(d.id, it.gstRate)] = (b2bKey[(d.id, it.gstRate)] ?? 0) + it.taxablePaise;
    } else if (d.isB2b) {
      cdnrKey[(d.id, it.gstRate)] = (cdnrKey[(d.id, it.gstRate)] ?? 0) - it.taxablePaise; // a note shows positive
    } else {
      final (t, x) = b2cs[it.gstRate] ?? (0, 0);
      b2cs[it.gstRate] = (t + it.taxablePaise, x + it.taxPaise);
    }
    final h = hsn.putIfAbsent((d.isB2b, it.hsn, it.gstRate), () => Gstr1Hsn(hsn: it.hsn, description: it.description, rate: it.gstRate));
    h
      ..qty += it.qty / (it.packSize < 1 ? 1 : it.packSize)
      ..valuePaise += it.netPaise
      ..taxablePaise += it.taxablePaise
      ..cgstPaise += it.cgstPaise
      ..sgstPaise += it.sgstPaise;
  }

  List<Gstr1B2b> rows(Map<(int, int), int> m) => [
        for (final e in m.entries) Gstr1B2b(doc: byId[e.key.$1]!, rate: e.key.$2, taxablePaise: e.value),
      ]..sort((a, b) => a.doc.seq != b.doc.seq ? a.doc.seq.compareTo(b.doc.seq) : a.rate.compareTo(b.rate));

  List<Gstr1Hsn> hsnOf(bool b2b) {
    final l = [for (final e in hsn.entries) if (e.key.$1 == b2b) e.value];
    for (final h in l) {
      h.qty = double.parse(h.qty.toStringAsFixed(2));
    }
    return l..sort((a, b) => a.hsn != b.hsn ? a.hsn.compareTo(b.hsn) : a.rate.compareTo(b.rate));
  }

  final ranges = <Gstr1DocRange>[];
  for (final (nature, type) in [('Invoices for outward supply', 'invoice'), ('Credit Note', 'credit_note')]) {
    final ds = [for (final d in docs) if (d.docType == type && d.gstRegistered) d]..sort((a, b) => a.seq.compareTo(b.seq));
    if (ds.isEmpty) continue;
    ranges.add(
      Gstr1DocRange(
        nature: nature,
        from: ds.first.number,
        to: ds.last.number,
        total: ds.length,
        cancelled: ds.where((d) => d.status == 'cancelled').length,
      ),
    );
  }

  return Gstr1Report(
    b2b: rows(b2bKey),
    b2cs: [
      for (final e in (b2cs.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
        if (e.value.$1 != 0 || e.value.$2 != 0) Gstr1B2cs(rate: e.key, taxablePaise: e.value.$1, taxPaise: e.value.$2),
    ],
    cdnr: rows(cdnrKey),
    hsnB2b: hsnOf(true),
    hsnB2c: hsnOf(false),
    docs: ranges,
    storeState: storeState,
  );
}

/// 'YYYY-MM-DD' → '09-Nov-2026' (the offline tool's date format).
String gstr1Date(String dateKey) {
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final d = DateTime.parse(dateKey);
  return '${d.day.toString().padLeft(2, '0')}-${m[d.month - 1]}-${d.year}';
}
