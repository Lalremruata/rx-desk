import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/tax/gstin.dart';
import 'package:rx_desk/core/tax/gstr1.dart';

/// B2B bills and GSTR-1 (SPEC §4.15).
void main() {
  const store = '15ABCDE1234F1Z5'; // Mizoram
  const buyer = '15AAACM1234A1ZD';

  group('GSTIN', () {
    test('check character (GSTN sample) and validity', () {
      expect(isValidGstin('27AAPFU0939F1ZV'), isTrue);
      expect(isValidGstin(' 27aapfu0939f1zv '), isTrue);
      expect(isValidGstin('27AAPFU0939F1ZX'), isFalse); // wrong check character
      expect(isValidGstin('99AAPFU0939F1ZV'), isFalse); // no such state
      expect(isValidGstin('27AAPFU0939F1Z'), isFalse);
      expect(gstinCheckChar('15AAACM1234A1Z'), 'D');
      expect(placeOfSupplyLabel(gstinState(store)), '15-Mizoram');
    });

    test('same state only; the store needs its own GSTIN', () {
      expect(buyerGstinProblem('', storeGstin: store, gstRegistered: true), isNull);
      expect(buyerGstinProblem(buyer, storeGstin: store, gstRegistered: true), isNull);
      expect(buyerGstinProblem('27AAPFU0939F1ZV', storeGstin: store, gstRegistered: true), 'This GSTIN is from Maharashtra — inter-state (IGST) bills aren’t supported');
      expect(buyerGstinProblem('15AAACM1234A1Z9', storeGstin: store, gstRegistered: true), contains('looks wrong'));
      expect(buyerGstinProblem(buyer, storeGstin: '', gstRegistered: true), contains('Settings'));
      expect(buyerGstinProblem(buyer, storeGstin: store, gstRegistered: false), contains('bill of supply'));
    });
  });

  group('GSTR-1', () {
    Gstr1Doc doc(int id, {String type = 'invoice', String? gstin, String status = 'paid', int total = 0, int seq = 0, bool registered = true}) => Gstr1Doc(
          id: id,
          docType: type,
          number: '${type == 'invoice' ? 'INV' : 'CN'}/26-27/${seq.toString().padLeft(5, '0')}',
          seq: seq,
          fy: '26-27',
          saleDate: '2026-10-${(id + 1).toString().padLeft(2, '0')}',
          status: status,
          customerName: gstin == null ? 'Walk-in customer' : 'Hope Clinic',
          totalPaise: total,
          buyerGstin: gstin,
          placeOfSupply: gstin == null ? null : '15',
          gstRegistered: registered,
        );
    Gstr1Item item(int docId, {int rate = 12, required int taxable, required int tax, String hsn = '3004', int qty = 1, int pack = 1}) => Gstr1Item(
          docId: docId,
          hsn: hsn,
          description: 'Medicine',
          qty: qty,
          packSize: pack,
          gstRate: rate,
          taxablePaise: taxable,
          taxPaise: tax,
          netPaise: taxable + tax,
        );

    final r = buildGstr1(
      storeGstin: store,
      docs: [
        doc(1, gstin: buyer, total: 16200, seq: 1), // B2B, two rates
        doc(2, total: 11200, seq: 2), // B2C
        doc(3, total: 5600, seq: 3, status: 'cancelled'), // drops out, counted in docs
        doc(4, type: 'credit_note', total: -5600, seq: 1), // B2C return
        doc(5, type: 'credit_note', gstin: buyer, total: -1050, seq: 2), // B2B return
        doc(6, total: 1000, seq: 4, registered: false), // bill of supply
      ],
      items: [
        item(1, taxable: 10000, tax: 1201),
        item(1, rate: 5, taxable: 5000, tax: 250, hsn: '3003'),
        item(2, taxable: 10000, tax: 1200, qty: 25, pack: 10),
        item(3, taxable: 5000, tax: 600),
        item(4, taxable: -5000, tax: -600, qty: -5, pack: 10),
        item(5, rate: 5, taxable: -1000, tax: -50, hsn: '3003', qty: -1),
        item(6, taxable: 1000, tax: 0),
      ],
    );

    test('b2b per invoice × rate, b2cs net of B2C returns, cdnr positive', () {
      expect(r.b2b.map((x) => (x.doc.id, x.rate, x.taxablePaise)), [(1, 5, 5000), (1, 12, 10000)]);
      expect(r.b2cs.map((x) => (x.rate, x.taxablePaise, x.taxPaise)), [(12, 5000, 600)]);
      expect(r.cdnr.map((x) => (x.doc.id, x.rate, x.taxablePaise)), [(5, 5, 1000)]);
      expect(r.netTaxable, 15000 + 5000 - 1000);
      expect(r.hsnTaxable, r.netTaxable);
      expect(r.storeState, '15');
    });

    test('hsn split B2B / B2C, quantity in packs, odd paisa on SGST', () {
      expect(r.hsnB2b.map((h) => (h.hsn, h.rate, h.taxablePaise, h.cgstPaise, h.sgstPaise)), [('3003', 5, 4000, 100, 100), ('3004', 12, 10000, 600, 601)]);
      final b2c = r.hsnB2c.single;
      expect((b2c.hsn, b2c.qty, b2c.taxablePaise, b2c.valuePaise), ('3004', 2.0, 5000, 5600)); // 2.5 − 0.5 packs
    });

    test('documents issued: number ranges and cancelled count', () {
      expect(r.docs.map((d) => (d.nature, d.from, d.to, d.total, d.cancelled)), [
        ('Invoices for outward supply', 'INV/26-27/00001', 'INV/26-27/00003', 3, 1),
        ('Credit Note', 'CN/26-27/00001', 'CN/26-27/00002', 2, 0),
      ]);
      expect(gstr1Date('2026-11-09'), '09-Nov-2026');
    });
  });
}
