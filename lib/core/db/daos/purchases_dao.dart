import 'package:drift/drift.dart';

import '../../money/paise.dart';
import '../../purchases/dues_rules.dart';
import '../../purchases/purchase_rules.dart';
import '../../utils/expiry.dart';
import '../../utils/pack.dart';
import '../app_database.dart';
import 'dues_dao.dart';

part 'purchases_dao.g.dart';

// ---------------------------------------------------------------------------
// Inputs and rows (SPEC §4.7, §5.9).

class NewOrderLine {
  const NewOrderLine({this.productId, required this.itemName, required this.qty, required this.unit, this.note = ''});

  final int? productId;
  final String itemName;
  final int qty;
  final String unit;
  final String note;
}

class ReceiveLineInput {
  const ReceiveLineInput({
    this.orderLineId,
    required this.productId,
    required this.batchNo,
    this.expiry,
    required this.qty,
    required this.unit,
    required this.stockUnits,
    required this.amount,
    this.moreExpected = false,
    this.packsPerBox,
    this.freeQty = 0,
    this.rate,
    this.discBp = 0,
    this.gstRate,
    this.mrp,
  });

  /// Null for an item that wasn't on an order.
  final int? orderLineId;
  final int productId;
  final String batchNo;

  /// Required for a new batch; ignored for an existing one.
  final String? expiry;
  final int qty;
  final String unit;
  final int stockUnits;
  final Paise amount;

  /// Packs (strips) per box for a Box line; kept on the receipt line (the
  /// stockist's box size, v16) and saved on the medicine so the next Box
  /// receipt is prefilled. Null = leave the medicine as it is.
  final int? packsPerBox;

  /// "Still expecting more" for a short line.
  final bool moreExpected;

  /// Free / scheme quantity in [unit]; already included in [stockUnits].
  final int freeQty;

  /// Rate per [unit] before discount and GST (PTR); null = not given.
  final Paise? rate;

  /// Trade discount in basis points.
  final int discBp;

  /// GST % on their line; null = not given.
  final int? gstRate;

  /// MRP printed on the batch. A new batch takes it (else the medicine's);
  /// an existing batch must match.
  final Paise? mrp;
}

class ReceiveRequest {
  const ReceiveRequest({
    required this.supplierName,
    required this.invoiceNo,
    required this.receivedDate,
    required this.lines,
    this.billTotal,
    this.dueDate,
    this.paidNow,
  });

  final String supplierName;
  final String invoiceNo;

  /// 'YYYY-MM-DD'.
  final String receivedDate;
  final List<ReceiveLineInput> lines;

  /// Grand total as billed (what is owed); defaults to Σ line amounts.
  final Paise? billTotal;

  /// Defaults to received date + the stockist's credit days.
  final String? dueDate;

  /// Paid on delivery, applied to this bill.
  final PaymentInput? paidNow;
}

class SavedReceipt {
  const SavedReceipt({
    required this.receiptId,
    required this.total,
    required this.billTotal,
    required this.lines,
    required this.stockUnits,
    required this.dueDate,
  });
  final int receiptId;

  /// Σ line amounts.
  final Paise total;
  final Paise billTotal;
  final int lines;
  final int stockUnits;
  final String dueDate;
}

/// An order line with what has come in against it.
class OrderRow {
  const OrderRow({
    required this.id,
    required this.orderDate,
    required this.productId,
    required this.itemName,
    required this.qty,
    required this.unit,
    required this.note,
    required this.status,
    required this.receivedSameUnit,
    required this.receivedOther,
    required this.amount,
    required this.suppliers,
    required this.invoiceNos,
    required this.lastReceived,
  });

  final int id;
  final String orderDate;
  final int? productId;
  final String itemName;
  final int qty;
  final String unit;
  final String note;
  final OrderStatus status;

  /// Σ received in [unit].
  final int receivedSameUnit;

  /// Receipts in other units, e.g. "10 Strip" (empty when none).
  final String receivedOther;
  final Paise amount;
  final String suppliers;
  final String invoiceNos;
  final String? lastReceived;

  int get due => dueQty(qty, receivedSameUnit);
  SupplyTag get tag => supplyTag(status: status, orderedQty: qty, receivedSameUnit: receivedSameUnit);

  /// "20 Box", "20 Box + 10 Strip", "" when nothing came.
  String get receivedLabel => [
        if (receivedSameUnit > 0) qtyLabel(receivedSameUnit, unit),
        if (receivedOther.isNotEmpty) receivedOther,
      ].join(' + ');
}

/// One row of the order book: an order line, or a received item that was
/// never ordered ([order] null).
class BookRow {
  const BookRow.ordered(OrderRow this.order)
      : itemName = '',
        receivedQty = 0,
        receivedUnit = '',
        extraAmount = Paise.zero,
        extraSupplier = '',
        extraInvoice = '',
        extraDate = '';

  const BookRow.extra({
    required this.itemName,
    required this.receivedQty,
    required this.receivedUnit,
    required this.extraAmount,
    required this.extraSupplier,
    required this.extraInvoice,
    required this.extraDate,
  }) : order = null;

  final OrderRow? order;
  final String itemName;
  final int receivedQty;
  final String receivedUnit;
  final Paise extraAmount;
  final String extraSupplier;
  final String extraInvoice;
  final String extraDate;

  String get item => order?.itemName ?? itemName;
  String? get orderDate => order?.orderDate;
  String get orderedLabel => order == null ? '' : qtyLabel(order!.qty, order!.unit);
  String get stockist => order?.suppliers ?? extraSupplier;
  String? get receivedDate => order == null ? extraDate : order!.lastReceived;
  String get invoiceNo => order?.invoiceNos ?? extraInvoice;
  String get receivedLabel => order?.receivedLabel ?? qtyLabel(receivedQty, receivedUnit);
  Paise get amount => order?.amount ?? extraAmount;
  SupplyTag get tag => order?.tag ?? SupplyTag.notOrdered;
}

/// Keyset cursor on (date, id).
class PurchaseCursor {
  const PurchaseCursor(this.date, this.id);
  final String date;
  final int id;
}

class OrderPage {
  const OrderPage({required this.rows, required this.hasMore, required this.ms});
  final List<OrderRow> rows;
  final bool hasMore;
  final double ms;
}

class ReceiptRow {
  const ReceiptRow({
    required this.id,
    required this.receivedDate,
    required this.supplier,
    required this.invoiceNo,
    required this.lines,
    required this.total,
    required this.billTotal,
    required this.dueDate,
    required this.outstanding,
  });

  final int id;
  final String receivedDate;
  final String supplier;
  final String invoiceNo;
  final int lines;

  /// Σ line amounts.
  final Paise total;
  final Paise billTotal;
  final String dueDate;
  final Paise outstanding;

  BillStatus get status => billStatus(amount: billTotal.value, outstanding: outstanding.value);
  bool overdueOn(String today) => isOverdue(dueDate: dueDate, outstanding: outstanding.value, today: today);
}

class ReceiptPage {
  const ReceiptPage({required this.rows, required this.hasMore});
  final List<ReceiptRow> rows;
  final bool hasMore;
}

class PurchaseKpis {
  const PurchaseKpis({this.open = 0, this.orderedThisMonth = 0, this.receivedThisMonth = Paise.zero, this.shortThisMonth = 0});
  final int open;
  final int orderedThisMonth;
  final Paise receivedThisMonth;
  final int shortThisMonth;
}

// ---------------------------------------------------------------------------

/// Order book and stockist receipts (SPEC §4.7).
@DriftAccessor(
  tables: [Suppliers, OrderLines, PurchaseReceipts, ReceiptLines, Products, Batches, StockMovements, SupplierLedger, LedgerAllocations],
)
class PurchasesDao extends DatabaseAccessor<AppDatabase> with _$PurchasesDaoMixin {
  PurchasesDao(super.attachedDatabase);

  Set<ResultSetImplementation<dynamic, dynamic>> get _reads =>
      {orderLines, receiptLines, purchaseReceipts, suppliers, supplierLedger, ledgerAllocations};

  static int _ts(DateTime at) => at.toUtc().millisecondsSinceEpoch;

  static bool _isDateKey(String s) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s);

  // -------------------------------------------------------------------------
  // Suppliers

  /// Existing stockist with this name (case-insensitive), or a new one.
  Future<int> supplierIdFor(String name, {required DateTime at}) async {
    final n = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (n.isEmpty) throw const PurchaseException('Enter the stockist');
    final existing = await customSelect(
      'SELECT id FROM suppliers WHERE name = ?1 COLLATE NOCASE',
      variables: [Variable.withString(n)],
      readsFrom: {suppliers},
    ).getSingleOrNull();
    if (existing != null) return existing.read<int>('id');
    return into(suppliers).insert(SuppliersCompanion.insert(name: n, createdAt: _ts(at)));
  }

  Future<List<Supplier>> allSuppliers() => (select(suppliers)..orderBy([(s) => OrderingTerm.asc(s.name)])).get();

  // -------------------------------------------------------------------------
  // Orders

  /// Adds the lines of one day's order; returns their ids.
  Future<List<int>> addOrderLines(String orderDate, List<NewOrderLine> lines, {required DateTime at, int? staffId}) {
    return transaction(() async {
      if (!_isDateKey(orderDate)) throw const PurchaseException('Pick the order date');
      if (lines.isEmpty) throw const PurchaseException('Add at least one item');
      final ts = _ts(at);
      final ids = <int>[];
      for (final l in lines) {
        var name = l.itemName.trim();
        if (l.productId != null) {
          final p = await (select(products)..where((p) => p.id.equals(l.productId!))).getSingleOrNull();
          if (p == null) throw const PurchaseException('Medicine not found');
          name = p.name;
        }
        if (name.isEmpty) throw const PurchaseException('Enter the item name');
        if (l.qty < 1) throw PurchaseException('$name — enter the quantity ordered');
        if (!purchaseUnits.contains(l.unit)) throw PurchaseException('Unknown unit ${l.unit}');
        ids.add(
          await into(orderLines).insert(
            OrderLinesCompanion.insert(
              orderDate: orderDate,
              productId: Value(l.productId),
              itemName: name,
              qty: l.qty,
              unit: l.unit,
              note: Value(l.note.trim()),
              staffId: Value(staffId),
              createdAt: ts,
              updatedAt: ts,
            ),
          ),
        );
      }
      return ids;
    });
  }

  Future<OrderLine> _orderLine(int id) async {
    final o = await (select(orderLines)..where((o) => o.id.equals(id))).getSingleOrNull();
    if (o == null) throw const PurchaseException('Order line not found');
    return o;
  }

  /// Links a free-text order line to a catalog product (needed before it can
  /// be received).
  Future<void> linkProduct(int orderLineId, int productId, {required DateTime at}) {
    return transaction(() async {
      final o = await _orderLine(orderLineId);
      if (!OrderStatus.parse(o.status).isOpen) throw const PurchaseException('That line is no longer open');
      final p = await (select(products)..where((p) => p.id.equals(productId))).getSingleOrNull();
      if (p == null) throw const PurchaseException('Medicine not found');
      await (update(orderLines)..where((x) => x.id.equals(orderLineId)))
          .write(OrderLinesCompanion(productId: Value(productId), updatedAt: Value(_ts(at))));
    });
  }

  /// A part-supplied line the supplier won't complete.
  Future<void> closeShort(int orderLineId, {required DateTime at}) => _setStatus(
        orderLineId,
        OrderStatus.closed,
        from: const {OrderStatus.part},
        error: 'Only a part-supplied line can be closed short',
        at: at,
      );

  /// A line nothing has been received against.
  Future<void> cancelOrderLine(int orderLineId, {required DateTime at}) => _setStatus(
        orderLineId,
        OrderStatus.cancelled,
        from: const {OrderStatus.pending},
        error: 'Only a pending line can be cancelled',
        at: at,
      );

  Future<void> _setStatus(int id, OrderStatus to, {required Set<OrderStatus> from, required String error, required DateTime at}) {
    return transaction(() async {
      final o = await _orderLine(id);
      if (!from.contains(OrderStatus.parse(o.status))) throw PurchaseException(error);
      await (update(orderLines)..where((x) => x.id.equals(id)))
          .write(OrderLinesCompanion(status: Value(to.name), updatedAt: Value(_ts(at))));
    });
  }

  // -------------------------------------------------------------------------
  // Receiving

  /// Saves one stockist invoice — all or nothing (SPEC §4.7): upsert the
  /// stockist, insert the receipt and its lines, add stock to each batch with
  /// a 'receive' movement (ref 'purchase' → receipt id), update the order
  /// lines' status.
  Future<SavedReceipt> receive(
    ReceiveRequest req, {
    required DateTime at,
    required DateTime now,
    int expiryWindowMonths = 3,
    int? staffId,
  }) {
    return transaction(() async {
      final invoiceNo = req.invoiceNo.trim();
      if (invoiceNo.isEmpty) throw const PurchaseException('Enter the stockist’s invoice number');
      if (!_isDateKey(req.receivedDate)) throw const PurchaseException('Pick the date received');
      if (req.lines.isEmpty) throw const PurchaseException('Add at least one item received');
      final seenOrders = <int>{};
      for (final l in req.lines) {
        if (l.orderLineId != null && !seenOrders.add(l.orderLineId!)) {
          throw const PurchaseException('The same order line is on this invoice twice');
        }
      }

      final supplierId = await supplierIdFor(req.supplierName, at: at);
      final dupe = await (select(purchaseReceipts)
            ..where((r) => r.supplierId.equals(supplierId) & r.invoiceNo.equals(invoiceNo)))
          .getSingleOrNull();
      if (dupe != null) throw PurchaseException('Invoice $invoiceNo from this stockist is already saved');

      final total = req.lines.map((l) => l.amount).sum();
      final billTotal = req.billTotal ?? total;
      if (billTotal.value < 0) throw const PurchaseException('Invoice total can’t be negative');
      final supplier = await (select(suppliers)..where((s) => s.id.equals(supplierId))).getSingle();
      final dueDate = req.dueDate ?? dueDateFor(req.receivedDate, supplier.creditDays);
      if (!_isDateKey(dueDate)) throw const PurchaseException('Pick the due date');
      if (dueDate.compareTo(req.receivedDate) < 0) throw const PurchaseException('Due date can’t be before the date received');
      final ts = _ts(at);
      final receiptId = await into(purchaseReceipts).insert(
        PurchaseReceiptsCompanion.insert(
          supplierId: supplierId,
          invoiceNo: invoiceNo,
          receivedDate: req.receivedDate,
          totalPaise: total.value,
          billTotalPaise: Value(billTotal.value),
          dueDate: Value(dueDate),
          staffId: Value(staffId),
          createdAt: ts,
        ),
      );

      var units = 0;
      final more = <int, bool>{};
      for (final (i, l) in req.lines.indexed) {
        final product = await (select(products)..where((p) => p.id.equals(l.productId))).getSingleOrNull();
        if (product == null) throw const PurchaseException('Medicine not found');
        final name = product.name;
        if (l.qty < 1) throw PurchaseException('$name — enter the quantity received');
        if (!purchaseUnits.contains(l.unit)) throw PurchaseException('$name — unknown unit ${l.unit}');
        if (l.stockUnits < 1) throw PurchaseException('$name — enter the units to add to stock');
        if (l.amount.value < 0) throw PurchaseException('$name — amount can’t be negative');
        if (l.freeQty < 0) throw PurchaseException('$name — free quantity can’t be negative');
        if (l.rate != null && l.rate!.value < 0) throw PurchaseException('$name — rate can’t be negative');
        if (l.discBp < 0 || l.discBp > maxDiscBp) throw PurchaseException('$name — discount must be 0–100 %');
        if (l.gstRate case final g? when !const [0, 5, 12, 18, 28].contains(g)) throw PurchaseException('$name — GST must be 0, 5, 12, 18 or 28 %');
        if (l.mrp case final m? when m.value <= 0) throw PurchaseException('$name — enter the MRP printed on the batch');
        if (l.packsPerBox case final n? when unitNeedsPacksPerBox(l.unit)) {
          if (n < 1 || n > maxPacksPerBox) throw PurchaseException('$name — strips per box must be 1–$maxPacksPerBox');
          if (n != product.packsPerBox) {
            await (update(products)..where((p) => p.id.equals(product.id)))
                .write(ProductsCompanion(packsPerBox: Value(n), updatedAt: Value(ts)));
          }
        }

        if (l.orderLineId != null) {
          final o = await _orderLine(l.orderLineId!);
          if (!OrderStatus.parse(o.status).isOpen) throw PurchaseException('${o.itemName} is no longer open on the order');
          if (o.productId != null && o.productId != l.productId) {
            throw PurchaseException('${o.itemName} was ordered as a different medicine');
          }
          if (o.productId == null) {
            await (update(orderLines)..where((x) => x.id.equals(o.id)))
                .write(OrderLinesCompanion(productId: Value(l.productId), updatedAt: Value(ts)));
          }
          more[o.id] = l.moreExpected;
        }

        final bno = l.batchNo.trim().toUpperCase();
        if (bno.isEmpty) throw PurchaseException('$name — enter the batch number');
        final existing = await (select(batches)..where((b) => b.productId.equals(l.productId) & b.batchNo.equals(bno)))
            .getSingleOrNull();
        final expiry = existing?.expiry ?? l.expiry;
        if (expiry == null || !isValidExpiry(expiry)) throw PurchaseException('$name — new batch $bno needs its expiry');
        if (receiveExpiryCheck(expiry, now, expiryWindowMonths) == ExpiryCheck.expired) {
          throw PurchaseException('$name batch $bno expired ${formatExpiry(expiry)} — expired stock can’t be received');
        }

        final r = await attachedDatabase.catalogDao.receiveStock(
          productId: l.productId,
          batchNo: bno,
          expiry: expiry,
          qty: l.stockUnits,
          at: at,
          staffId: staffId,
          purchaseRate: purchaseRate(l.amount, l.stockUnits),
          mrp: l.mrp,
          refType: 'purchase',
          refId: receiptId,
        );
        await into(receiptLines).insert(
          ReceiptLinesCompanion.insert(
            receiptId: receiptId,
            lineNo: i + 1,
            orderLineId: Value(l.orderLineId),
            productId: l.productId,
            batchId: r.batchId,
            itemName: name,
            batchNo: bno,
            expiry: expiry,
            qty: l.qty,
            unit: l.unit,
            stockUnits: l.stockUnits,
            amountPaise: l.amount.value,
            freeQty: Value(l.freeQty),
            ratePaise: Value(l.rate?.value),
            discBp: Value(l.discBp),
            gstRate: Value(l.gstRate),
            mrpPaise: Value((await (select(batches)..where((b) => b.id.equals(r.batchId))).getSingle()).mrpPaise),
            packsPerBox: Value(unitNeedsPacksPerBox(l.unit) ? l.packsPerBox : null),
          ),
        );
        // Stockist directory (SPEC §4.11): remember where it came from.
        await attachedDatabase.sourcesDao.learnFromReceipt(supplierId: supplierId, productId: l.productId, date: req.receivedDate, at: at);
        units += l.stockUnits;
      }

      for (final e in more.entries) {
        await _recomputeStatus(e.key, moreExpected: e.value, at: at);
      }

      // Dues (SPEC §4.8): the bill, then any payment made on delivery.
      final dues = attachedDatabase.duesDao;
      final billId = await dues.addBill(
        supplierId: supplierId,
        receiptId: receiptId,
        date: req.receivedDate,
        amount: billTotal,
        dueDate: dueDate,
        invoiceNo: invoiceNo,
        at: at,
        staffId: staffId,
      );
      final paid = req.paidNow;
      if (paid != null && paid.amount.value > 0) {
        await dues.recordPayment(
          supplierId: supplierId,
          date: req.receivedDate,
          payment: PaymentInput(
            amount: paid.amount,
            mode: paid.mode,
            reference: paid.reference,
            note: paid.note.isEmpty ? 'Paid on delivery · $invoiceNo' : paid.note,
          ),
          pickedDebitIds: billId == null ? const {} : {billId},
          at: at,
          staffId: staffId,
        );
      }
      return SavedReceipt(
        receiptId: receiptId,
        total: total,
        billTotal: billTotal,
        lines: req.lines.length,
        stockUnits: units,
        dueDate: dueDate,
      );
    });
  }

  Future<void> _recomputeStatus(int orderLineId, {required bool moreExpected, required DateTime at}) async {
    final o = await _orderLine(orderLineId);
    final r = await customSelect(
      '''
      SELECT COALESCE(SUM(CASE WHEN unit = ?2 THEN qty ELSE 0 END), 0) AS same,
             COALESCE(SUM(CASE WHEN unit <> ?2 THEN 1 ELSE 0 END), 0) AS other
      FROM receipt_lines WHERE order_line_id = ?1
      ''',
      variables: [Variable.withInt(orderLineId), Variable.withString(o.unit)],
      readsFrom: {receiptLines},
    ).getSingle();
    final next = statusAfterReceipt(
      current: OrderStatus.parse(o.status),
      orderedQty: o.qty,
      received: ReceivedSoFar(sameUnitQty: r.read<int>('same'), otherUnitLines: r.read<int>('other')),
      moreExpected: moreExpected,
    );
    await (update(orderLines)..where((x) => x.id.equals(orderLineId)))
        .write(OrderLinesCompanion(status: Value(next.name), updatedAt: Value(_ts(at))));
  }

  // -------------------------------------------------------------------------
  // Queries

  static const String _orderCols = '''
    o.id, o.order_date, o.product_id, o.item_name, o.qty, o.unit, o.note, o.status,
    COALESCE((SELECT SUM(rl.qty) FROM receipt_lines rl WHERE rl.order_line_id = o.id AND rl.unit = o.unit), 0) AS got_same,
    COALESCE((SELECT group_concat(rl.qty || ' ' || rl.unit, ' + ') FROM receipt_lines rl
              WHERE rl.order_line_id = o.id AND rl.unit <> o.unit), '') AS got_other,
    COALESCE((SELECT SUM(rl.amount_paise) FROM receipt_lines rl WHERE rl.order_line_id = o.id), 0) AS amount,
    COALESCE((SELECT group_concat(DISTINCT s.name) FROM receipt_lines rl
              JOIN purchase_receipts r ON r.id = rl.receipt_id JOIN suppliers s ON s.id = r.supplier_id
              WHERE rl.order_line_id = o.id), '') AS suppliers,
    COALESCE((SELECT group_concat(DISTINCT r.invoice_no) FROM receipt_lines rl
              JOIN purchase_receipts r ON r.id = rl.receipt_id WHERE rl.order_line_id = o.id), '') AS invoices,
    (SELECT MAX(r.received_date) FROM receipt_lines rl JOIN purchase_receipts r ON r.id = rl.receipt_id
     WHERE rl.order_line_id = o.id) AS last_received
  ''';

  static String _list(String s) => s.split(',').join(', ');

  static OrderRow _orderRow(QueryRow r) => OrderRow(
        id: r.read<int>('id'),
        orderDate: r.read<String>('order_date'),
        productId: r.readNullable<int>('product_id'),
        itemName: r.read<String>('item_name'),
        qty: r.read<int>('qty'),
        unit: r.read<String>('unit'),
        note: r.read<String>('note'),
        status: OrderStatus.parse(r.read<String>('status')),
        receivedSameUnit: r.read<int>('got_same'),
        receivedOther: r.read<String>('got_other'),
        amount: Paise(r.read<int>('amount')),
        suppliers: _list(r.read<String>('suppliers')),
        invoiceNos: _list(r.read<String>('invoices')),
        lastReceived: r.readNullable<String>('last_received'),
      );

  /// Open lines (pending + part), oldest first, keyset on (order_date, id).
  Future<OrderPage> openPage({PurchaseCursor? after, String search = '', int limit = 50}) async {
    final sw = Stopwatch()..start();
    final vars = <Variable<Object>>[];
    final where = StringBuffer("o.status IN ('pending', 'part')");
    if (after != null) {
      vars
        ..add(Variable.withString(after.date))
        ..add(Variable.withInt(after.id));
      where.write(' AND (o.order_date, o.id) > (?1, ?2)');
    }
    final q = search.trim().toLowerCase();
    if (q.isNotEmpty) {
      vars.add(Variable.withString('%$q%'));
      where.write(' AND lower(o.item_name) LIKE ?${vars.length}');
    }
    vars.add(Variable.withInt(limit + 1));
    final rows = await customSelect(
      'SELECT $_orderCols FROM order_lines o WHERE $where ORDER BY o.order_date, o.id LIMIT ?${vars.length}',
      variables: vars,
      readsFrom: _reads,
    ).get();
    final list = rows.take(limit).map(_orderRow).toList();
    return OrderPage(rows: list, hasMore: rows.length > limit, ms: sw.elapsedMicroseconds / 1000);
  }

  Future<List<OrderRow>> orderRows(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final marks = [for (var i = 1; i <= ids.length; i++) '?$i'].join(',');
    final rows = await customSelect(
      'SELECT $_orderCols FROM order_lines o WHERE o.id IN ($marks)',
      variables: [for (final id in ids) Variable.withInt(id)],
      readsFrom: _reads,
    ).get();
    final byId = {for (final r in rows.map(_orderRow)) r.id: r};
    return [for (final id in ids) ?byId[id]];
  }

  /// The order book for an inclusive date range, in the workbook's layout:
  /// lines ordered in the range (by order date, then entry order), then items
  /// received in the range that were never ordered.
  Future<List<BookRow>> book(String from, String to) async {
    final ordered = await customSelect(
      'SELECT $_orderCols FROM order_lines o WHERE o.order_date BETWEEN ?1 AND ?2 ORDER BY o.order_date, o.id',
      variables: [Variable.withString(from), Variable.withString(to)],
      readsFrom: _reads,
    ).get();
    final extras = await customSelect(
      '''
      SELECT rl.item_name, rl.qty, rl.unit, rl.amount_paise, s.name AS supplier, r.invoice_no, r.received_date
      FROM receipt_lines rl
      JOIN purchase_receipts r ON r.id = rl.receipt_id JOIN suppliers s ON s.id = r.supplier_id
      WHERE rl.order_line_id IS NULL AND r.received_date BETWEEN ?1 AND ?2
      ORDER BY r.received_date, r.id, rl.line_no
      ''',
      variables: [Variable.withString(from), Variable.withString(to)],
      readsFrom: _reads,
    ).get();
    return [
      for (final r in ordered) BookRow.ordered(_orderRow(r)),
      for (final r in extras)
        BookRow.extra(
          itemName: r.read<String>('item_name'),
          receivedQty: r.read<int>('qty'),
          receivedUnit: r.read<String>('unit'),
          extraAmount: Paise(r.read<int>('amount_paise')),
          extraSupplier: r.read<String>('supplier'),
          extraInvoice: r.read<String>('invoice_no'),
          extraDate: r.read<String>('received_date'),
        ),
    ];
  }

  /// Nearest day before/after [date] with any orders or receipts, or null.
  Future<String?> adjacentDay(String date, {required bool forward}) async {
    final cmp = forward ? '>' : '<';
    final agg = forward ? 'MIN' : 'MAX';
    final r = await customSelect(
      '''
      SELECT $agg(d) AS d FROM (
        SELECT $agg(order_date) AS d FROM order_lines WHERE order_date $cmp ?1
        UNION ALL
        SELECT $agg(received_date) FROM purchase_receipts WHERE received_date $cmp ?1
      )
      ''',
      variables: [Variable.withString(date)],
      readsFrom: _reads,
    ).getSingle();
    return r.readNullable<String>('d');
  }

  /// Stockist invoices, newest first, keyset on (received_date, id).
  Future<ReceiptPage> receiptPage({PurchaseCursor? before, String search = '', int limit = 30}) async {
    final vars = <Variable<Object>>[];
    final where = StringBuffer('1');
    if (before != null) {
      vars
        ..add(Variable.withString(before.date))
        ..add(Variable.withInt(before.id));
      where.write(' AND (r.received_date, r.id) < (?1, ?2)');
    }
    final q = search.trim().toLowerCase();
    if (q.isNotEmpty) {
      vars.add(Variable.withString('%$q%'));
      where.write(' AND (lower(s.name) LIKE ?${vars.length} OR lower(r.invoice_no) LIKE ?${vars.length})');
    }
    vars.add(Variable.withInt(limit + 1));
    final rows = await customSelect(
      '''
      SELECT r.id, r.received_date, s.name AS supplier, r.invoice_no, r.total_paise, r.bill_total_paise, r.due_date,
             (SELECT COUNT(*) FROM receipt_lines rl WHERE rl.receipt_id = r.id) AS n,
             COALESCE((SELECT SUM(l.open_paise) FROM supplier_ledger l WHERE l.receipt_id = r.id AND l.status = 'active'), 0) AS open
      FROM purchase_receipts r JOIN suppliers s ON s.id = r.supplier_id
      WHERE $where
      ORDER BY r.received_date DESC, r.id DESC
      LIMIT ?${vars.length}
      ''',
      variables: vars,
      readsFrom: _reads,
    ).get();
    return ReceiptPage(
      rows: [
        for (final r in rows.take(limit))
          ReceiptRow(
            id: r.read<int>('id'),
            receivedDate: r.read<String>('received_date'),
            supplier: r.read<String>('supplier'),
            invoiceNo: r.read<String>('invoice_no'),
            lines: r.read<int>('n'),
            total: Paise(r.read<int>('total_paise')),
            billTotal: Paise(r.read<int>('bill_total_paise')),
            dueDate: r.read<String>('due_date'),
            outstanding: Paise(r.read<int>('open')),
          ),
      ],
      hasMore: rows.length > limit,
    );
  }

  /// Box sizes a medicine came in, one per stockist (their latest Box
  /// receipt line), newest first (SPEC §4.7).
  Future<List<BoxSizeSeen>> boxSizeHistory(int productId) async {
    final rows = await customSelect(
      '''
      SELECT supplier_id, supplier, packs_per_box, received_date FROM (
        SELECT r.supplier_id, s.name AS supplier, rl.packs_per_box, r.received_date,
               ROW_NUMBER() OVER (PARTITION BY r.supplier_id ORDER BY r.received_date DESC, r.id DESC, rl.line_no DESC) AS rn
        FROM receipt_lines rl
        JOIN purchase_receipts r ON r.id = rl.receipt_id JOIN suppliers s ON s.id = r.supplier_id
        WHERE rl.product_id = ?1 AND rl.packs_per_box IS NOT NULL
      ) WHERE rn = 1
      ORDER BY received_date DESC, supplier
      ''',
      variables: [Variable.withInt(productId)],
      readsFrom: _reads,
    ).get();
    return [
      for (final r in rows)
        BoxSizeSeen(
          supplierId: r.read<int>('supplier_id'),
          supplierName: r.read<String>('supplier'),
          packsPerBox: r.read<int>('packs_per_box'),
          receivedDate: r.read<String>('received_date'),
        ),
    ];
  }

  Future<List<ReceiptLine>> linesOf(int receiptId) =>
      (select(receiptLines)
            ..where((l) => l.receiptId.equals(receiptId))
            ..orderBy([(l) => OrderingTerm.asc(l.lineNo)]))
          .get();

  Future<PurchaseKpis> kpis({required DateTime now}) async {
    final from = '${monthKey(now)}-01';
    final to = '${monthKey(now)}-31';
    final r = await customSelect(
      '''
      SELECT
        (SELECT COUNT(*) FROM order_lines WHERE status IN ('pending', 'part')) AS open_n,
        (SELECT COUNT(*) FROM order_lines WHERE order_date BETWEEN ?1 AND ?2) AS ordered_n,
        (SELECT COALESCE(SUM(bill_total_paise), 0) FROM purchase_receipts WHERE received_date BETWEEN ?1 AND ?2) AS received_p,
        (SELECT COUNT(*) FROM order_lines WHERE order_date BETWEEN ?1 AND ?2 AND status IN ('part', 'closed')) AS short_n
      ''',
      variables: [Variable.withString(from), Variable.withString(to)],
      readsFrom: _reads,
    ).getSingle();
    return PurchaseKpis(
      open: r.read<int>('open_n'),
      orderedThisMonth: r.read<int>('ordered_n'),
      receivedThisMonth: Paise(r.read<int>('received_p')),
      shortThisMonth: r.read<int>('short_n'),
    );
  }

  /// Open lines count (nav badge).
  Stream<int> watchOpenCount() => customSelect(
        "SELECT COUNT(*) AS c FROM order_lines WHERE status IN ('pending', 'part')",
        readsFrom: {orderLines},
      ).watchSingle().map((r) => r.read<int>('c'));
}
