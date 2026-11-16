import 'package:drift/drift.dart';

import '../../fy/fy.dart';
import '../../money/gst.dart';
import '../../money/paise.dart';
import '../../sales/bill_rules.dart';
import '../../sales/credit_rules.dart';
import '../../sales/return_rules.dart';
import '../../utils/expiry.dart';
import '../app_database.dart';

part 'sales_dao.g.dart';

/// Input for [SalesDao.saveBill].
class SaveBillRequest {
  const SaveBillRequest({
    required this.lines,
    this.customerName = '',
    this.customerPhone,
    this.doctorName,
    this.paymentMode = 'Cash',
    this.discountPct = 0,
    this.staffId,
    this.note,
    this.paidNow = Paise.zero,
    this.paidNowMode = 'Cash',
    this.overrideCreditLimit = false,
  });

  final List<BillLineRequest> lines;
  final String customerName;
  final String? customerPhone;
  final String? doctorName;
  final String paymentMode;
  final int discountPct;
  final int? staffId;
  final String? note;

  /// Credit bills (SPEC §4.10): taken at the counter, and how.
  final Paise paidNow;
  final String paidNowMode;

  /// The Owner allowed going past the customer's credit limit.
  final bool overrideCreditLimit;
}

class SavedBill {
  const SavedBill({required this.invoiceId, required this.number, required this.totals, required this.at, this.duesAfter});

  final int invoiceId;
  final String number;
  final BillTotals totals;
  final DateTime at;

  /// Credit bills: the customer's dues after this bill.
  final Paise? duesAfter;
}

/// An invoice with its lines. For a credit note, [against] is the invoice
/// it returns against.
class InvoiceWithItems {
  const InvoiceWithItems(this.invoice, this.items, {this.against});
  final Invoice invoice;
  final List<InvoiceItem> items;
  final Invoice? against;
}

/// Keyset cursor on (sale_date, id), newest first.
class InvoiceCursor {
  const InvoiceCursor(this.saleDate, this.id);
  final String saleDate;
  final int id;
}

class InvoiceListFilter {
  const InvoiceListFilter({required this.from, required this.to, this.search = '', this.paymentMode});

  /// Inclusive 'YYYY-MM-DD'.
  final String from;
  final String to;
  final String search;
  final String? paymentMode;
}

class InvoiceListPage {
  const InvoiceListPage({required this.rows, required this.hasOlder, required this.hasNewer});
  final List<Invoice> rows;
  final bool hasOlder;
  final bool hasNewer;
}

class InvoiceListSummary {
  const InvoiceListSummary({required this.count, required this.total});
  final int count;
  final Paise total;
}

/// Input for [SalesDao.saveCreditNote] (SPEC §4.5).
class SaveCreditNoteRequest {
  const SaveCreditNoteRequest({
    required this.invoiceId,
    required this.lines,
    required this.refundMode,
    this.reason,
    this.staffId,
  });

  /// The original tax invoice.
  final int invoiceId;
  final List<ReturnLineRequest> lines;

  /// 'Cash' | 'UPI' | 'Card', or 'Credit' = adjust in the customer's dues.
  final String refundMode;
  final String? reason;
  final int? staffId;
}

class SavedCreditNote {
  const SavedCreditNote({required this.creditNoteId, required this.number, required this.totals, required this.at});

  final int creditNoteId;
  final String number;

  /// Refund totals, positive.
  final BillTotals totals;
  final DateTime at;
}

/// An invoice with what can still be returned from it.
class ReturnContext {
  const ReturnContext({required this.invoice, required this.items, required this.sold, required this.prior});

  final Invoice invoice;
  final List<InvoiceItem> items;

  /// Original lines keyed by item id.
  final Map<int, SoldLine> sold;

  /// Earlier returns keyed by original item id.
  final Map<int, PriorReturn> prior;
}

class QuickAddItem {
  const QuickAddItem({required this.productId, required this.name, required this.units});
  final int productId;
  final String name;
  final int units;
}

/// Invoices: save (one transaction), cancel, look-ups.
@DriftAccessor(
  tables: [Invoices, InvoiceItems, InvoiceSeq, Batches, Products, StockMovements, DailySalesSummary, Customers],
)
class SalesDao extends DatabaseAccessor<AppDatabase> with _$SalesDaoMixin {
  SalesDao(super.attachedDatabase);

  /// Saves a bill — CLAUDE.md rule 3: insert invoice + items, decrement batch
  /// stock, write stock movements, update daily_sales_summary and bump the
  /// FY sequence, all in one transaction. The invoice number is assigned
  /// here (rule 7, gapless per FY).
  Future<SavedBill> saveBill(SaveBillRequest req, {required BillRules rules, required DateTime at}) {
    return transaction(() async {
      final facts = await _loadFacts(req.lines);
      validateBill(
        lines: req.lines,
        factsByBatch: {for (final e in facts.entries) e.key: e.value.facts},
        rules: rules,
        discountPct: req.discountPct,
        doctorName: req.doctorName,
        paymentMode: req.paymentMode,
        at: at,
      );
      for (final l in req.lines) {
        if (facts[l.batchId]!.productId != l.productId) {
          throw const BillException(BillError.notFound, 'Batch doesn’t belong to that medicine');
        }
      }

      final amounts = amountsFor(
        req.lines,
        {for (final e in facts.entries) e.key: e.value.facts},
        discountPct: req.discountPct,
        gstRegistered: rules.gstRegistered,
      );
      final totals = computeBill(
        [for (var i = 0; i < req.lines.length; i++) (amounts[i], req.lines[i].qty)],
        roundOff: rules.roundOff,
      );
      final credit = req.paymentMode == creditMode;
      if (credit) {
        validateCreditBill(
          canSellOnCredit: rules.canSellOnCredit,
          customerName: req.customerName,
          phone: req.customerPhone,
          total: totals.total.value,
          paidNow: req.paidNow.value,
          paidNowMode: req.paidNowMode,
        );
      }

      final fy = fyLabel(at);
      final (seq, number) = await _nextNumber(rules.numbering, fy);
      final ts = at.toUtc().millisecondsSinceEpoch;
      final day = dateKey(at);
      final doctor = (req.doctorName ?? '').trim();
      final phone = (req.customerPhone ?? '').trim();
      final name = req.customerName.trim().isEmpty ? walkInName : req.customerName.trim();
      final customerId = phone.isEmpty ? null : await _customerFor(name, phone, ts);
      if (credit) {
        // Inside the transaction, so two counters can't both slip under it.
        await attachedDatabase.customersDao.checkLimit(
          customerId: customerId!,
          adding: totals.total.value - req.paidNow.value,
          defaultLimit: rules.defaultCreditLimit,
          override: req.overrideCreditLimit,
        );
      }

      final invoiceId = await into(invoices).insert(
        InvoicesCompanion.insert(
          number: number,
          fy: fy,
          seq: seq,
          createdAt: ts,
          saleDate: day,
          customerId: Value(customerId),
          customerName: name,
          customerPhone: Value(phone.isEmpty ? null : phone),
          doctorName: Value(doctor.isEmpty ? null : doctor),
          paymentMode: req.paymentMode,
          discountPct: req.discountPct,
          subtotalPaise: totals.subtotal.value,
          discountPaise: totals.discount.value,
          taxablePaise: totals.taxable.value,
          cgstPaise: totals.cgst.value,
          sgstPaise: totals.sgst.value,
          roundOffPaise: totals.roundOff.value,
          totalPaise: totals.total.value,
          staffId: Value(req.staffId),
          note: Value(req.note),
          gstRegistered: Value(rules.gstRegistered),
          paidNowPaise: Value(credit ? req.paidNow.value : null),
        ),
      );

      final perProduct = <int, ({int units, int net, int tax})>{};
      final perBatch = <int, int>{};
      for (var i = 0; i < req.lines.length; i++) {
        final l = req.lines[i];
        final f = facts[l.batchId]!;
        final a = amounts[i];
        await into(invoiceItems).insert(
          InvoiceItemsCompanion.insert(
            invoiceId: invoiceId,
            saleDate: day,
            lineNo: i + 1,
            productId: l.productId,
            batchId: l.batchId,
            productName: f.facts.productName,
            salt: f.salt,
            manufacturer: f.maker,
            category: f.category,
            hsn: f.hsn,
            schedule: f.facts.schedule,
            batchNo: f.facts.batchNo,
            expiry: f.facts.expiry,
            mrpPaise: f.facts.mrp.value,
            gstRate: f.facts.gstRate,
            packSize: Value(f.facts.packSize),
            qty: l.qty,
            grossPaise: a.gross.value,
            discountPaise: a.discount.value,
            taxablePaise: a.taxable.value,
            taxPaise: a.tax.value,
            netPaise: a.net.value,
            paymentMode: req.paymentMode,
            doctorName: Value(doctor.isEmpty ? null : doctor),
          ),
        );
        perBatch[l.batchId] = (perBatch[l.batchId] ?? 0) + l.qty;
        final p = perProduct[l.productId];
        perProduct[l.productId] = (
          units: (p?.units ?? 0) + l.qty,
          net: (p?.net ?? 0) + a.net.value,
          tax: (p?.tax ?? 0) + a.tax.value,
        );
      }

      for (final e in perBatch.entries) {
        await customUpdate(
          'UPDATE batches SET qty = qty - ?1 WHERE id = ?2',
          variables: [Variable.withInt(e.value), Variable.withInt(e.key)],
          updates: {batches},
        );
        await into(stockMovements).insert(
          StockMovementsCompanion.insert(
            batchId: e.key,
            delta: -e.value,
            reason: 'sale',
            refType: const Value('invoice'),
            refId: Value(invoiceId),
            staffId: Value(req.staffId),
            at: ts,
          ),
        );
      }

      for (final e in perProduct.entries) {
        await _bumpSummary(day, e.key, units: e.value.units, bills: 1, net: e.value.net, tax: e.value.tax);
        await customUpdate(
          'UPDATE products SET last_sold_at = MAX(COALESCE(last_sold_at, 0), ?1) WHERE id = ?2',
          variables: [Variable.withInt(ts), Variable.withInt(e.key)],
          updates: {products},
        );
      }

      int? duesAfter;
      if (credit) {
        duesAfter = await attachedDatabase.customersDao.addBill(
          customerId: customerId!,
          invoiceId: invoiceId,
          invoiceNo: number,
          date: day,
          total: totals.total,
          paidNow: req.paidNow,
          paidNowMode: req.paidNowMode,
          at: at,
          staffId: req.staffId,
        );
        await (update(invoices)..where((i) => i.id.equals(invoiceId))).write(InvoicesCompanion(duesAfterPaise: Value(duesAfter)));
      }

      return SavedBill(
        invoiceId: invoiceId,
        number: number,
        totals: totals,
        at: at,
        duesAfter: duesAfter == null ? null : Paise(duesAfter),
      );
    });
  }

  Future<Map<int, _Facts>> _loadFacts(List<BillLineRequest> lines) async {
    final ids = lines.map((l) => l.batchId).toSet().toList();
    if (ids.isEmpty) return const {};
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await customSelect(
      '''
      SELECT b.id, b.product_id, b.batch_no, b.expiry, b.qty,
             p.name, p.salt, p.category, p.hsn, p.schedule, p.gst_rate, p.mrp_paise, p.is_active, p.units_per_pack,
             m.name AS maker
      FROM batches b JOIN products p ON p.id = b.product_id JOIN manufacturers m ON m.id = p.manufacturer_id
      WHERE b.id IN ($marks)
      ''',
      variables: [for (final id in ids) Variable.withInt(id)],
      readsFrom: {batches, products},
    ).get();
    return {
      for (final r in rows)
        r.read<int>('id'): _Facts(
          productId: r.read<int>('product_id'),
          salt: r.read<String>('salt'),
          category: r.read<String>('category'),
          hsn: r.read<String>('hsn'),
          maker: r.read<String>('maker'),
          facts: LineFacts(
            productName: r.read<String>('name'),
            schedule: r.read<String>('schedule'),
            isActive: r.read<bool>('is_active'),
            batchNo: r.read<String>('batch_no'),
            expiry: r.read<String>('expiry'),
            batchQty: r.read<int>('qty'),
            mrp: Paise(r.read<int>('mrp_paise')),
            gstRate: r.read<int>('gst_rate'),
            packSize: r.read<int>('units_per_pack'),
          ),
        ),
    };
  }

  /// Next (seq, number). Bumps `invoice_seq` inside the caller's transaction.
  Future<(int, String)> _nextNumber(InvoiceNumberFormat fmt, String fy) async {
    final key = fmt.seqKey(fy);
    final row = await (select(invoiceSeq)..where((s) => s.fy.equals(key))).getSingleOrNull();
    var seq = (row?.lastSeq ?? 0) + 1;
    var number = fmt.format(fy: fy, seq: seq);
    // A format change could make a new number collide with an old one; skip
    // forward rather than fail the sale.
    while (await (select(invoices)..where((i) => i.number.equals(number))).getSingleOrNull() != null) {
      seq++;
      number = fmt.format(fy: fy, seq: seq);
    }
    await into(invoiceSeq).insertOnConflictUpdate(InvoiceSeqCompanion.insert(fy: key, lastSeq: seq));
    return (seq, number);
  }

  /// Number the next bill will get (display only — the real one is assigned
  /// when saving).
  Future<String> peekNextNumber(InvoiceNumberFormat fmt, DateTime at) async {
    final fy = fyLabel(at);
    final row = await (select(invoiceSeq)..where((s) => s.fy.equals(fmt.seqKey(fy)))).getSingleOrNull();
    return fmt.format(fy: fy, seq: (row?.lastSeq ?? 0) + 1);
  }

  /// Sets the sequence (e.g. continuing numbering from an earlier system).
  Future<void> setSequence(String key, int lastSeq) =>
      into(invoiceSeq).insertOnConflictUpdate(InvoiceSeqCompanion.insert(fy: key, lastSeq: lastSeq));

  Future<int> _customerFor(String name, String phone, int ts) async {
    final c = await (select(customers)..where((x) => x.phone.equals(phone))).getSingleOrNull();
    if (c != null) {
      if (name != 'Walk-in customer' && c.name != name) {
        await (update(customers)..where((x) => x.id.equals(c.id))).write(CustomersCompanion(name: Value(name)));
      }
      return c.id;
    }
    return into(customers).insert(CustomersCompanion.insert(name: name, phone: Value(phone), createdAt: ts));
  }

  Future<void> _bumpSummary(String day, int productId, {required int units, required int bills, required int net, required int tax}) =>
      customInsert(
        '''
        INSERT INTO daily_sales_summary(sale_date, product_id, units, bills, net_paise, tax_paise)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(sale_date, product_id) DO UPDATE SET
          units = units + excluded.units,
          bills = bills + excluded.bills,
          net_paise = net_paise + excluded.net_paise,
          tax_paise = tax_paise + excluded.tax_paise
        ''',
        variables: [
          Variable.withString(day),
          Variable.withInt(productId),
          Variable.withInt(units),
          Variable.withInt(bills),
          Variable.withInt(net),
          Variable.withInt(tax),
        ],
        updates: {dailySalesSummary},
      );

  /// Cancels a paid bill (CLAUDE.md rule 6 — never hard-deleted): restores
  /// stock to the same batches with 'cancel' movements, reverses the daily
  /// summary and sets status. The invoice number stays used. Credit notes and
  /// bills with returns can't be cancelled.
  Future<void> cancelInvoice(int invoiceId, {required DateTime at, int? staffId, String? reason}) {
    return transaction(() async {
      final inv = await (select(invoices)..where((i) => i.id.equals(invoiceId))).getSingleOrNull();
      if (inv == null) throw const BillException(BillError.notFound, 'Invoice not found');
      if (inv.docType != 'invoice') {
        throw BillException(BillError.notReturnable, '${inv.number} is a credit note — it can’t be cancelled');
      }
      if (inv.status == 'part_returned' || inv.status == 'returned') {
        throw BillException(BillError.notReturnable, 'Items on ${inv.number} were returned — it can’t be cancelled');
      }
      if (inv.status != 'paid') throw BillException(BillError.notFound, '${inv.number} is already ${inv.status}');
      final items = await (select(invoiceItems)..where((i) => i.invoiceId.equals(invoiceId))).get();
      final ts = at.toUtc().millisecondsSinceEpoch;
      final perProduct = <int, ({int units, int net, int tax})>{};
      for (final it in items) {
        await customUpdate(
          'UPDATE batches SET qty = qty + ?1 WHERE id = ?2',
          variables: [Variable.withInt(it.qty), Variable.withInt(it.batchId)],
          updates: {batches},
        );
        await into(stockMovements).insert(
          StockMovementsCompanion.insert(
            batchId: it.batchId,
            delta: it.qty,
            reason: 'cancel',
            refType: const Value('invoice'),
            refId: Value(invoiceId),
            staffId: Value(staffId),
            at: ts,
          ),
        );
        final p = perProduct[it.productId];
        perProduct[it.productId] = (
          units: (p?.units ?? 0) + it.qty,
          net: (p?.net ?? 0) + it.netPaise,
          tax: (p?.tax ?? 0) + it.taxPaise,
        );
      }
      for (final e in perProduct.entries) {
        await _bumpSummary(inv.saleDate, e.key, units: -e.value.units, bills: -1, net: -e.value.net, tax: -e.value.tax);
      }
      await (update(invoices)..where((i) => i.id.equals(invoiceId))).write(
        InvoicesCompanion(
          status: const Value('cancelled'),
          note: Value([if (inv.note != null) inv.note!, 'Cancelled${reason == null ? '' : ': $reason'}'].join(' · ')),
        ),
      );
      if (inv.paymentMode == creditMode) {
        await attachedDatabase.customersDao.voidForInvoice(
          invoiceId,
          reason: 'Bill ${inv.number} cancelled${reason == null ? '' : ': $reason'}',
        );
      }
    });
  }

  // -------------------------------------------------------------------------
  // Sales returns (SPEC §4.5)

  /// The invoice, its lines and what earlier credit notes took back.
  Future<ReturnContext?> returnContext(int invoiceId) async {
    final inv = await (select(invoices)..where((i) => i.id.equals(invoiceId))).getSingleOrNull();
    if (inv == null) return null;
    final items = await (select(invoiceItems)
          ..where((i) => i.invoiceId.equals(invoiceId))
          ..orderBy([(i) => OrderingTerm.asc(i.lineNo)]))
        .get();
    final rows = await customSelect(
      '''
      SELECT i.ref_item_id AS item, -SUM(i.qty) AS qty, -SUM(i.gross_paise) AS gross,
             -SUM(i.discount_paise) AS disc, -SUM(i.taxable_paise) AS taxable,
             -SUM(i.tax_paise) AS tax, -SUM(i.net_paise) AS net
      FROM invoice_items i JOIN invoices v ON v.id = i.invoice_id
      WHERE v.ref_invoice_id = ?1 AND v.doc_type = 'credit_note' AND v.status <> 'cancelled'
        AND i.ref_item_id IS NOT NULL
      GROUP BY i.ref_item_id
      ''',
      variables: [Variable.withInt(invoiceId)],
      readsFrom: {invoices, invoiceItems},
    ).get();
    return ReturnContext(
      invoice: inv,
      items: items,
      sold: {
        for (final it in items)
          it.id: SoldLine(
            itemId: it.id,
            productName: it.productName,
            schedule: it.schedule,
            qty: it.qty,
            mrp: Paise(it.mrpPaise),
            gstRate: it.gstRate,
            packSize: it.packSize,
            amounts: LineAmounts(
              gross: Paise(it.grossPaise),
              discount: Paise(it.discountPaise),
              net: Paise(it.netPaise),
              taxable: Paise(it.taxablePaise),
              tax: Paise(it.taxPaise),
            ),
          ),
      },
      prior: {
        for (final r in rows)
          r.read<int>('item'): PriorReturn(
            qty: r.read<int>('qty'),
            gross: Paise(r.read<int>('gross')),
            discount: Paise(r.read<int>('disc')),
            taxable: Paise(r.read<int>('taxable')),
            tax: Paise(r.read<int>('tax')),
            net: Paise(r.read<int>('net')),
          ),
      },
    );
  }

  /// Saves a sales return as a credit note — one transaction (CLAUDE.md
  /// rule 3): insert the credit note + negative lines (snapshots copied from
  /// the original lines), put units back into the same batches ('return'
  /// movements; damaged lines are then written off with 'write_off'), reduce
  /// the daily summary on the return day, number it in its own gapless FY
  /// series and mark the original part_returned / returned.
  Future<SavedCreditNote> saveCreditNote(SaveCreditNoteRequest req, {required ReturnRules rules, required DateTime at}) {
    return transaction(() async {
      final ctx = await returnContext(req.invoiceId);
      if (ctx == null) throw const BillException(BillError.notFound, 'Invoice not found');
      final inv = ctx.invoice;
      validateReturn(
        docType: inv.docType,
        status: inv.status,
        saleDate: inv.saleDate,
        lines: req.lines,
        sold: ctx.sold,
        prior: ctx.prior,
        rules: rules,
        paymentMode: req.refundMode,
        at: at,
        customerId: inv.customerId,
      );
      final lines = req.lines.where((l) => l.qty > 0).toList();
      final byId = {for (final it in ctx.items) it.id: it};
      final amounts = [
        for (final l in lines)
          returnAmounts(
            ctx.sold[l.itemId]!,
            l.qty,
            ctx.prior[l.itemId] ?? PriorReturn.none,
            discountPct: inv.discountPct,
            gstRegistered: inv.gstRegistered,
          ),
      ];
      final totals = computeBill(
        [for (var i = 0; i < lines.length; i++) (amounts[i], lines[i].qty)],
        roundOff: rules.roundOff,
      );

      final fy = fyLabel(at);
      final (seq, number) = await _nextNumber(rules.numbering, fy);
      final ts = at.toUtc().millisecondsSinceEpoch;
      final day = dateKey(at);
      final reason = (req.reason ?? '').trim();

      final cnId = await into(invoices).insert(
        InvoicesCompanion.insert(
          number: number,
          fy: fy,
          seq: seq,
          createdAt: ts,
          saleDate: day,
          customerId: Value(inv.customerId),
          customerName: inv.customerName,
          customerPhone: Value(inv.customerPhone),
          doctorName: Value(inv.doctorName),
          paymentMode: req.refundMode,
          discountPct: inv.discountPct,
          subtotalPaise: -totals.subtotal.value,
          discountPaise: -totals.discount.value,
          taxablePaise: -totals.taxable.value,
          cgstPaise: -totals.cgst.value,
          sgstPaise: -totals.sgst.value,
          roundOffPaise: -totals.roundOff.value,
          totalPaise: -totals.total.value,
          staffId: Value(req.staffId),
          note: Value(reason.isEmpty ? null : reason),
          gstRegistered: Value(inv.gstRegistered),
          docType: const Value('credit_note'),
          refInvoiceId: Value(inv.id),
        ),
      );

      final perProduct = <int, ({int units, int net, int tax})>{};
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        final o = byId[l.itemId]!;
        final a = amounts[i];
        await into(invoiceItems).insert(
          InvoiceItemsCompanion.insert(
            invoiceId: cnId,
            saleDate: day,
            lineNo: i + 1,
            productId: o.productId,
            batchId: o.batchId,
            productName: o.productName,
            salt: o.salt,
            manufacturer: o.manufacturer,
            category: o.category,
            hsn: o.hsn,
            schedule: o.schedule,
            batchNo: o.batchNo,
            expiry: o.expiry,
            mrpPaise: o.mrpPaise,
            gstRate: o.gstRate,
            packSize: Value(o.packSize),
            qty: -l.qty,
            grossPaise: -a.gross.value,
            discountPaise: -a.discount.value,
            taxablePaise: -a.taxable.value,
            taxPaise: -a.tax.value,
            netPaise: -a.net.value,
            paymentMode: req.refundMode,
            doctorName: Value(o.doctorName),
            refItemId: Value(o.id),
            restocked: Value(l.restock),
          ),
        );

        // Units come back into the same batch; damaged ones are written off
        // straight away so the audit trail shows both.
        await into(stockMovements).insert(
          StockMovementsCompanion.insert(
            batchId: o.batchId,
            delta: l.qty,
            reason: 'return',
            refType: const Value('invoice'),
            refId: Value(cnId),
            staffId: Value(req.staffId),
            at: ts,
          ),
        );
        if (l.restock) {
          await customUpdate(
            'UPDATE batches SET qty = qty + ?1 WHERE id = ?2',
            variables: [Variable.withInt(l.qty), Variable.withInt(o.batchId)],
            updates: {batches},
          );
        } else {
          await into(stockMovements).insert(
            StockMovementsCompanion.insert(
              batchId: o.batchId,
              delta: -l.qty,
              reason: 'write_off',
              refType: const Value('invoice'),
              refId: Value(cnId),
              staffId: Value(req.staffId),
              at: ts,
            ),
          );
        }

        final p = perProduct[o.productId];
        perProduct[o.productId] = (
          units: (p?.units ?? 0) + l.qty,
          net: (p?.net ?? 0) + a.net.value,
          tax: (p?.tax ?? 0) + a.tax.value,
        );
      }

      // Reported on the return day (credit-note date), not the bill's.
      for (final e in perProduct.entries) {
        await _bumpSummary(day, e.key, units: -e.value.units, bills: 0, net: -e.value.net, tax: -e.value.tax);
      }

      final returnedNow = {for (final l in lines) l.itemId: l.qty};
      final allBack = ctx.items.every(
        (it) => (ctx.prior[it.id]?.qty ?? 0) + (returnedNow[it.id] ?? 0) >= it.qty,
      );
      await (update(invoices)..where((i) => i.id.equals(inv.id))).write(
        InvoicesCompanion(status: Value(allBack ? 'returned' : 'part_returned')),
      );

      // Adjust in dues (SPEC §4.10): the credit goes to the original bill first.
      if (req.refundMode == creditMode && totals.total.value > 0) {
        await attachedDatabase.customersDao.addCreditNote(
          customerId: inv.customerId!,
          creditNoteId: cnId,
          number: number,
          againstInvoiceId: inv.id,
          date: day,
          amount: totals.total,
          at: at,
          staffId: req.staffId,
        );
      }

      return SavedCreditNote(creditNoteId: cnId, number: number, totals: totals, at: at);
    });
  }

  /// Credit notes issued against [invoiceId], oldest first.
  Future<List<Invoice>> creditNotesFor(int invoiceId) => (select(invoices)
        ..where((i) => i.refInvoiceId.equals(invoiceId) & i.docType.equals('credit_note'))
        ..orderBy([(i) => OrderingTerm.asc(i.id)]))
      .get();

  /// Number the next credit note will get (display only).
  Future<String> peekNextCreditNoteNumber(ReturnRules rules, DateTime at) => peekNextNumber(rules.numbering, at);

  // -------------------------------------------------------------------------
  // Look-ups

  Future<InvoiceWithItems?> invoiceWithItems(int id) async {
    final inv = await (select(invoices)..where((i) => i.id.equals(id))).getSingleOrNull();
    if (inv == null) return null;
    final items = await (select(invoiceItems)
          ..where((i) => i.invoiceId.equals(id))
          ..orderBy([(i) => OrderingTerm.asc(i.lineNo)]))
        .get();
    final ref = inv.refInvoiceId;
    final against = ref == null ? null : await (select(invoices)..where((i) => i.id.equals(ref))).getSingleOrNull();
    return InvoiceWithItems(inv, items, against: against);
  }

  Future<Invoice?> invoiceByNumber(String number) =>
      (select(invoices)..where((i) => i.number.equals(number))).getSingleOrNull();

  ({String sql, List<Variable<Object>> vars}) _listWhere(InvoiceListFilter f) {
    final vars = <Variable<Object>>[Variable.withString(f.from), Variable.withString(f.to)];
    final sb = StringBuffer('sale_date >= ?1 AND sale_date <= ?2');
    final q = f.search.trim().toLowerCase();
    if (q.isNotEmpty) {
      vars.add(Variable.withString('%$q%'));
      final n = vars.length;
      sb.write(" AND (lower(number) LIKE ?$n OR lower(customer_name) LIKE ?$n OR COALESCE(customer_phone, '') LIKE ?$n)");
    }
    if (f.paymentMode != null) {
      vars.add(Variable.withString(f.paymentMode!));
      sb.write(' AND payment_mode = ?${vars.length}');
    }
    return (sql: sb.toString(), vars: vars);
  }

  /// Keyset page on (sale_date, id), newest first (SPEC §5.4).
  /// [olderThan] → next page; [newerThan] → previous page.
  Future<InvoiceListPage> invoicePage(
    InvoiceListFilter f, {
    InvoiceCursor? olderThan,
    InvoiceCursor? newerThan,
    int limit = 30,
  }) async {
    final w = _listWhere(f);
    final vars = [...w.vars];
    var where = w.sql;
    var order = 'sale_date DESC, id DESC';
    if (olderThan != null) {
      vars
        ..add(Variable.withString(olderThan.saleDate))
        ..add(Variable.withInt(olderThan.id));
      where += ' AND (sale_date, id) < (?${vars.length - 1}, ?${vars.length})';
    } else if (newerThan != null) {
      vars
        ..add(Variable.withString(newerThan.saleDate))
        ..add(Variable.withInt(newerThan.id));
      where += ' AND (sale_date, id) > (?${vars.length - 1}, ?${vars.length})';
      order = 'sale_date ASC, id ASC';
    }
    vars.add(Variable.withInt(limit + 1));
    final rows = await customSelect(
      'SELECT * FROM invoices WHERE $where ORDER BY $order LIMIT ?${vars.length}',
      variables: vars,
      readsFrom: {invoices},
    ).map((r) => invoices.map(r.data)).get();
    final more = rows.length > limit;
    var page = more ? rows.sublist(0, limit) : rows;
    if (newerThan != null) page = page.reversed.toList();
    return InvoiceListPage(
      rows: page,
      hasOlder: newerThan != null || more,
      hasNewer: olderThan != null || (newerThan != null && more),
    );
  }

  /// Count of documents and net total matching [f]: cancelled bills are
  /// excluded from the total; credit notes (negative) net it down.
  Future<InvoiceListSummary> invoiceSummary(InvoiceListFilter f) async {
    final w = _listWhere(f);
    final r = await customSelect(
      "SELECT COUNT(*) AS c, COALESCE(SUM(CASE WHEN status <> 'cancelled' THEN total_paise ELSE 0 END), 0) AS t FROM invoices WHERE ${w.sql}",
      variables: w.vars,
      readsFrom: {invoices},
    ).getSingle();
    return InvoiceListSummary(count: r.read<int>('c'), total: Paise(r.read<int>('t')));
  }

  Stream<List<Invoice>> watchRecent({int limit = 5}) =>
      (select(invoices)
            ..orderBy([(i) => OrderingTerm.desc(i.createdAt), (i) => OrderingTerm.desc(i.id)])
            ..limit(limit))
          .watch();

  Future<int> invoiceCount() async =>
      (await customSelect('SELECT COUNT(*) AS c FROM invoices', readsFrom: {invoices}).getSingle()).read<int>('c');

  /// Most-sold products over the last [days] days (Quick add chips).
  Future<List<QuickAddItem>> topSellers({required DateTime now, int days = 30, int limit = 8}) async {
    final from = dateKey(now.subtract(Duration(days: days)));
    final rows = await customSelect(
      '''
      SELECT s.product_id, p.name, SUM(s.units) AS u, SUM(s.units) * 1.0 / p.units_per_pack AS packs
      FROM daily_sales_summary s JOIN products p ON p.id = s.product_id
      WHERE s.sale_date >= ?1 AND p.is_active = 1
      GROUP BY s.product_id ORDER BY packs DESC, p.name LIMIT ?2
      ''',
      variables: [Variable.withString(from), Variable.withInt(limit)],
      readsFrom: {dailySalesSummary, products},
    ).get();
    return [
      for (final r in rows)
        QuickAddItem(productId: r.read<int>('product_id'), name: r.read<String>('name'), units: r.read<int>('u')),
    ];
  }

  /// Distinct doctor names used before (autocomplete).
  Future<List<String>> knownDoctors({int limit = 200}) async {
    final rows = await customSelect(
      'SELECT doctor_name, COUNT(*) AS c FROM invoices WHERE doctor_name IS NOT NULL GROUP BY doctor_name ORDER BY c DESC LIMIT ?1',
      variables: [Variable.withInt(limit)],
      readsFrom: {invoices},
    ).get();
    return rows.map((r) => r.read<String>('doctor_name')).toList();
  }

  Future<Customer?> customerByPhone(String phone) =>
      (select(customers)..where((c) => c.phone.equals(phone.trim()))).getSingleOrNull();
}

class _Facts {
  const _Facts({
    required this.productId,
    required this.salt,
    required this.category,
    required this.hsn,
    required this.maker,
    required this.facts,
  });

  final int productId;
  final String salt;
  final String category;
  final String hsn;
  final String maker;
  final LineFacts facts;
}
