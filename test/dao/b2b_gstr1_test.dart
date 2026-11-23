import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/db/report_models.dart';
import 'package:rx_desk/core/db/seed/seed.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/sales/return_rules.dart';
import 'package:rx_desk/core/tax/gstr1.dart';

import '../helpers/test_db.dart';

/// B2B bills and GSTR-1 (SPEC §4.15).
void main() {
  const store = '15ABCDE1234F1Z5';
  const buyer = '15AAACM1234A1ZD';
  const rules = BillRules(storeGstin: store);

  group('B2B bills', () {
    late AppDatabase db;
    setUp(() => db = memoryDb());
    tearDown(() => db.close());

    SaveBillRequest req(int p, int b, {String gstin = buyer, String name = 'Hope Clinic', String? phone = '9800000001'}) =>
        SaveBillRequest(lines: [BillLineRequest(productId: p, batchId: b, qty: 2)], customerName: name, customerPhone: phone, buyerGstin: gstin);

    test('saves the buyer GSTIN and place of supply, remembers it on the customer; a return copies it', () async {
      final (p, b) = await addMed(db);
      final saved = await db.salesDao.saveBill(req(p, b, gstin: ' 15aaacm1234a1zd '), rules: rules, at: t0);
      final inv = (await db.salesDao.invoiceWithItems(saved.invoiceId))!.invoice;
      expect((inv.buyerGstin, inv.placeOfSupply), (buyer, '15'));
      expect((await db.select(db.customers).getSingle()).gstin, buyer);

      final item = (await db.salesDao.invoiceWithItems(saved.invoiceId))!.items.single;
      final cn = await db.salesDao.saveCreditNote(
        SaveCreditNoteRequest(invoiceId: saved.invoiceId, lines: [ReturnLineRequest(itemId: item.id, qty: 1)], refundMode: 'Cash'),
        rules: const ReturnRules(),
        at: t0,
      );
      final note = (await db.salesDao.invoiceWithItems(cn.creditNoteId))!.invoice;
      expect((note.buyerGstin, note.placeOfSupply), (buyer, '15'));
    });

    test('refused: another state, a bad GSTIN, no name, no store GSTIN, not registered', () async {
      final (p, b) = await addMed(db);
      Future<void> refused(SaveBillRequest r, BillRules rr, String msg) => expectLater(
            db.salesDao.saveBill(r, rules: rr, at: t0),
            throwsA(isA<BillException>().having((e) => e.message, 'message', contains(msg))),
          );
      await refused(req(p, b, gstin: '27AAPFU0939F1ZV'), rules, 'from Maharashtra');
      await refused(req(p, b, gstin: '15AAACM1234A1Z9'), rules, 'looks wrong');
      await refused(req(p, b, name: ''), rules, 'enter the buyer');
      await refused(req(p, b), const BillRules(), 'Settings');
      await refused(req(p, b), const BillRules(storeGstin: store, gstRegistered: false), 'bill of supply');
      expect(await countOf(db, 'invoices'), 0);
      expect(await qtyOf(db, b), 100);
    });

    test('a B2B bill without a phone saves without a customer record', () async {
      final (p, b) = await addMed(db);
      final saved = await db.salesDao.saveBill(req(p, b, phone: null), rules: rules, at: t0);
      expect((await db.salesDao.invoiceWithItems(saved.invoiceId))!.invoice.buyerGstin, buyer);
      expect(await countOf(db, 'customers'), 0);
    });
  });

  test('GSTR-1 of a seeded month reconciles with the Sales register', () async {
    final db = memoryDb();
    addTearDown(db.close);
    final now = DateTime(2026, 11, 9, 14);
    await seedDemoData(db, now: now);
    // A B2B bill and a B2B return in October.
    final p = (await db.select(db.products).get()).first;
    final b = (await db.catalogDao.batchesOf(p.id)).firstWhere((x) => x.qty > 5 && x.expiry.compareTo('2027-01') > 0);
    final oct = DateTime(2026, 10, 20, 11);
    final saved = await db.salesDao.saveBill(
      SaveBillRequest(lines: [BillLineRequest(productId: p.id, batchId: b.id, qty: 3)], customerName: 'Hope Clinic', buyerGstin: buyer),
      rules: rules,
      at: oct,
    );
    final it = (await db.salesDao.invoiceWithItems(saved.invoiceId))!.items.single;
    await db.salesDao.saveCreditNote(
      SaveCreditNoteRequest(invoiceId: saved.invoiceId, lines: [ReturnLineRequest(itemId: it.id, qty: 1)], refundMode: 'Cash'),
      rules: const ReturnRules(),
      at: oct,
    );

    final (docs, items) = await db.reportsDao.gstr1Source('2026-10-01', '2026-10-31');
    final r = buildGstr1(docs: docs, items: items, storeGstin: store);
    final reg = await db.reportsDao.registerTotals(const RegisterFilter(from: '2026-10-01', to: '2026-10-31'));
    expect(Paise(r.netTaxable), reg.taxable);
    expect(r.hsnTaxable, r.netTaxable);
    expect(r.b2b.single.doc.id, saved.invoiceId);
    // 1 of 3 units came back: about a third of the line's taxable value.
    expect(r.cdnr.single.taxablePaise, inInclusiveRange(it.taxablePaise ~/ 3 - 1, it.taxablePaise ~/ 3 + 1));
    final hsnTax = [...r.hsnB2b, ...r.hsnB2c].fold(0, (a, h) => a + h.cgstPaise + h.sgstPaise);
    expect(Paise(hsnTax), reg.tax);
    expect(r.docs.first.nature, 'Invoices for outward supply');
  });
}
