import 'package:drift/drift.dart';

import '../../inventory/stock_adjust.dart';
import '../../money/paise.dart';
import '../../utils/expiry.dart';
import '../../utils/pack.dart';
import '../app_database.dart';
import '../fts.dart';
import '../models.dart';

part 'catalog_dao.g.dart';

/// Thrown for invalid catalogue / stock operations.
class CatalogException implements Exception {
  const CatalogException(this.message);
  final String message;
  @override
  String toString() => 'CatalogException: $message';
}

/// Products, makers, batches, stock receipts and FTS search.
@DriftAccessor(tables: [Manufacturers, Products, Batches, StockMovements])
class CatalogDao extends DatabaseAccessor<AppDatabase> with _$CatalogDaoMixin {
  CatalogDao(super.attachedDatabase);

  // -------------------------------------------------------------------------
  // Derived stock, as correlated subqueries (SPEC §3.4). ?1 = current month,
  // ?2 = last month inside the expiry window.

  static const String _stockCols = '''
    p.id, p.name, p.salt, p.form, p.category, p.pack, p.units_per_pack, p.manufacturer_id, m.name AS maker,
    p.schedule, p.hsn, p.gst_rate, p.mrp_paise, p.reorder_level, p.rack, p.barcode,
    p.last_sold_at, p.created_at,
    (SELECT COALESCE(SUM(b.qty), 0) FROM batches b WHERE b.product_id = p.id AND b.expiry >= ?1) AS saleable,
    (SELECT MIN(b.expiry) FROM batches b WHERE b.product_id = p.id AND b.qty > 0 AND b.expiry >= ?1) AS nearest,
    (SELECT MIN(b.expiry) FROM batches b WHERE b.product_id = p.id) AS earliest,
    (SELECT COUNT(*) FROM batches b WHERE b.product_id = p.id AND b.qty > 0 AND b.expiry <= ?2) AS expiring,
    (SELECT COUNT(*) FROM batches b WHERE b.product_id = p.id) AS n_batches
  ''';

  static const String _from = 'FROM products p JOIN manufacturers m ON m.id = p.manufacturer_id';

  static StockRow _row(QueryRow r) => StockRow(
        id: r.read<int>('id'),
        name: r.read<String>('name'),
        salt: r.read<String>('salt'),
        form: r.read<String>('form'),
        category: r.read<String>('category'),
        pack: r.read<String>('pack'),
        packSize: r.read<int>('units_per_pack'),
        manufacturerId: r.read<int>('manufacturer_id'),
        maker: r.read<String>('maker'),
        schedule: r.read<String>('schedule'),
        hsn: r.read<String>('hsn'),
        gstRate: r.read<int>('gst_rate'),
        mrp: Paise(r.read<int>('mrp_paise')),
        reorderLevel: r.read<int>('reorder_level'),
        rack: r.read<String>('rack'),
        barcode: r.readNullable<String>('barcode'),
        lastSoldAt: r.readNullable<int>('last_sold_at'),
        createdAt: r.read<int>('created_at'),
        saleable: r.read<int>('saleable'),
        nearestExpiry: r.readNullable<String>('nearest'),
        earliestExpiry: r.readNullable<String>('earliest'),
        expiring: r.read<int>('expiring') > 0,
        batchCount: r.read<int>('n_batches'),
      );

  List<Variable<Object>> _stockVars(DateTime now, int expiryWindowMonths) => [
        Variable.withString(monthKey(now)),
        Variable.withString(addMonthsKey(now, expiryWindowMonths)),
      ];

  Set<ResultSetImplementation<dynamic, dynamic>> get _reads => {products, manufacturers, batches};

  // -------------------------------------------------------------------------
  // Makers

  Future<int> manufacturerIdFor(String name) async {
    final n = name.trim();
    if (n.isEmpty) throw const CatalogException('Enter the manufacturer');
    final existing = await (select(manufacturers)..where((m) => m.name.equals(n))).getSingleOrNull();
    if (existing != null) return existing.id;
    return into(manufacturers).insert(ManufacturersCompanion.insert(name: n));
  }

  Future<List<Manufacturer>> allManufacturers() =>
      (select(manufacturers)..orderBy([(m) => OrderingTerm.asc(m.name)])).get();

  Stream<List<Manufacturer>> watchManufacturers() =>
      (select(manufacturers)..orderBy([(m) => OrderingTerm.asc(m.name)])).watch();

  // -------------------------------------------------------------------------
  // Products & batches

  /// Adds a medicine, optionally with a first batch of opening stock
  /// (movement reason 'opening').
  Future<int> addProduct(NewProduct np, {required DateTime at, int? staffId}) {
    return transaction(() async {
      _checkDetails(name: np.name, category: np.category, schedule: np.schedule, gstRate: np.gstRate, mrp: np.mrp);
      if (np.packSize < 1 || np.packSize > maxPackSize) throw const CatalogException('Units per pack must be 1–$maxPackSize');
      final barcode = await _freeBarcode(np.barcode);
      final mid = await manufacturerIdFor(np.maker);
      final ts = at.toUtc().millisecondsSinceEpoch;
      final pid = await into(products).insert(
        ProductsCompanion.insert(
          name: np.name.trim(),
          salt: Value(np.salt.trim()),
          form: Value(np.form.trim()),
          category: np.category,
          pack: Value(np.pack.trim()),
          unitsPerPack: Value(np.packSize),
          manufacturerId: mid,
          schedule: Value(np.schedule),
          hsn: Value(np.hsn.trim()),
          gstRate: np.gstRate,
          mrpPaise: np.mrp.value,
          reorderLevel: Value(np.reorderLevel),
          rack: Value(np.rack.trim()),
          barcode: Value(barcode.isEmpty ? null : barcode),
          createdAt: ts,
          updatedAt: ts,
        ),
      );
      final bno = (np.batchNo ?? '').trim().toUpperCase();
      if (bno.isNotEmpty) {
        final exp = np.expiry ?? '';
        if (!isValidExpiry(exp)) throw const CatalogException('Enter the first batch’s expiry month');
        if (np.openingQty < 0) throw const CatalogException('Opening quantity can’t be negative');
        final bid = await into(batches).insert(
          BatchesCompanion.insert(productId: pid, batchNo: bno, expiry: exp, qty: np.openingQty, createdAt: ts),
        );
        if (np.openingQty != 0) {
          await _movement(bid, np.openingQty, 'opening', at: at, staffId: staffId, refType: 'product', refId: pid);
        }
      }
      return pid;
    });
  }

  static void _checkDetails({
    required String name,
    required String category,
    required String schedule,
    required int gstRate,
    required Paise mrp,
  }) {
    if (name.trim().isEmpty) throw const CatalogException('Enter the medicine name');
    if (!productCategories.contains(category)) throw CatalogException('Unknown category $category');
    if (!drugSchedules.contains(schedule)) throw CatalogException('Unknown schedule $schedule');
    if (!gstRates.contains(gstRate)) throw const CatalogException('GST rate must be 0, 5, 12 or 18 %');
    if (mrp.value <= 0) throw const CatalogException('Enter the MRP');
  }

  /// The trimmed barcode ('' = none), unless another product already uses it.
  Future<String> _freeBarcode(String? raw, {int? exceptProductId}) async {
    final barcode = (raw ?? '').trim();
    if (barcode.isEmpty) return barcode;
    final dupe = await (select(products)..where((p) => p.barcode.equals(barcode))).getSingleOrNull();
    if (dupe != null && dupe.id != exceptProductId) throw CatalogException('Barcode $barcode is already used by ${dupe.name}');
    return barcode;
  }

  /// Edits a medicine's details (SPEC §5.3). Past bills keep their
  /// snapshots; new bills use the new MRP / GST / HSN. Units per pack is
  /// changed with [setPackSize]. Search follows via the FTS update trigger.
  Future<void> updateProduct(int productId, ProductEdit e, {required DateTime at}) {
    return transaction(() async {
      final p = await (select(products)..where((x) => x.id.equals(productId))).getSingleOrNull();
      if (p == null) throw const CatalogException('Medicine not found');
      _checkDetails(name: e.name, category: e.category, schedule: e.schedule, gstRate: e.gstRate, mrp: e.mrp);
      if (e.reorderLevel < 0) throw const CatalogException('Reorder level can’t be negative');
      final barcode = await _freeBarcode(e.barcode, exceptProductId: productId);
      final mid = await manufacturerIdFor(e.maker);
      await (update(products)..where((x) => x.id.equals(productId))).write(
        ProductsCompanion(
          name: Value(e.name.trim()),
          salt: Value(e.salt.trim().isEmpty ? e.name.trim() : e.salt.trim()),
          category: Value(e.category),
          pack: Value(e.pack.trim().isEmpty ? 'Unit' : e.pack.trim()),
          manufacturerId: Value(mid),
          schedule: Value(e.schedule),
          hsn: Value(e.hsn.trim()),
          gstRate: Value(e.gstRate),
          mrpPaise: Value(e.mrp.value),
          reorderLevel: Value(e.reorderLevel),
          rack: Value(e.rack.trim()),
          barcode: Value(barcode.isEmpty ? null : barcode),
          updatedAt: Value(at.toUtc().millisecondsSinceEpoch),
        ),
      );
    });
  }

  /// Takes a medicine off sale (hidden from search, billing and inventory
  /// views) or puts it back. Never deletes anything.
  Future<void> setProductActive(int productId, bool active, {required DateTime at}) async {
    final n = await (update(products)..where((x) => x.id.equals(productId))).write(
      ProductsCompanion(isActive: Value(active), updatedAt: Value(at.toUtc().millisecondsSinceEpoch)),
    );
    if (n == 0) throw const CatalogException('Medicine not found');
  }

  /// Corrects a batch (SPEC §5.3): its number, its expiry and/or the
  /// quantity counted on the shelf. An expired batch's expiry is locked
  /// (rule 5). A quantity change needs a [reason] and writes an 'adjust'
  /// movement with the note. One transaction.
  Future<StockBatch> editBatch(
    int batchId, {
    String? batchNo,
    String? expiry,
    int? countedQty,
    StockAdjustReason? reason,
    String note = '',
    required DateTime at,
    int? staffId,
  }) {
    return transaction(() async {
      final b = await (select(batches)..where((x) => x.id.equals(batchId))).getSingleOrNull();
      if (b == null) throw const CatalogException('Batch not found');
      final bno = batchNo?.trim().toUpperCase();
      final changeNo = bno != null && bno != b.batchNo;
      final changeExpiry = expiry != null && expiry != b.expiry;
      final changeQty = countedQty != null && countedQty != b.qty;
      if (!changeNo && !changeExpiry && !changeQty) throw const CatalogException('Nothing to change');

      if (changeNo) {
        if (bno.isEmpty) throw const CatalogException('Enter the batch number');
        final clash = await (select(batches)
              ..where((x) => x.productId.equals(b.productId) & x.batchNo.equals(bno) & x.id.equals(batchId).not()))
            .getSingleOrNull();
        if (clash != null) throw CatalogException('Batch $bno already exists for this medicine');
      }
      if (changeExpiry) {
        if (!isValidExpiry(expiry)) throw const CatalogException('Expiry must be a month, e.g. 08/2027');
        if (isExpired(b.expiry, at)) {
          throw CatalogException('Batch ${b.batchNo} expired ${formatExpiry(b.expiry)} — its expiry can’t be changed');
        }
      }
      if (changeQty) {
        if (countedQty < 0) throw const CatalogException('Counted quantity can’t be negative');
        if (reason == null) throw const CatalogException('Pick a reason for the stock correction');
        if (reason.needsNote && note.trim().isEmpty) throw const CatalogException('Add a note saying why');
      }

      await (update(batches)..where((x) => x.id.equals(batchId))).write(
        BatchesCompanion(
          batchNo: changeNo ? Value(bno) : const Value.absent(),
          expiry: changeExpiry ? Value(expiry) : const Value.absent(),
          qty: changeQty ? Value(countedQty) : const Value.absent(),
        ),
      );
      if (changeQty) {
        await _movement(batchId, countedQty - b.qty, 'adjust',
            at: at, staffId: staffId, refType: 'batch', refId: batchId, note: adjustNote(reason!, note));
      }
      await (update(products)..where((x) => x.id.equals(b.productId)))
          .write(ProductsCompanion(updatedAt: Value(at.toUtc().millisecondsSinceEpoch)));
      return (select(batches)..where((x) => x.id.equals(batchId))).getSingle();
    });
  }

  Future<void> _movement(
    int batchId,
    int delta,
    String reason, {
    required DateTime at,
    int? staffId,
    String? refType,
    int? refId,
    String note = '',
  }) =>
      into(stockMovements).insert(
        StockMovementsCompanion.insert(
          batchId: batchId,
          delta: delta,
          reason: reason,
          refType: Value(refType),
          refId: Value(refId),
          staffId: Value(staffId),
          at: at.toUtc().millisecondsSinceEpoch,
          note: Value(note),
        ),
      );

  /// Receive stock (SPEC §4.5): into an existing batch (adds qty) or a new
  /// batch (needs [expiry]). Always writes a 'receive' movement, referencing
  /// the batch unless [refType]/[refId] are given (e.g. a purchase receipt).
  /// Safe to call inside an outer transaction (runs as a savepoint).
  Future<ReceiveResult> receiveStock({
    required int productId,
    required String batchNo,
    String? expiry,
    required int qty,
    required DateTime at,
    int? staffId,
    Paise? purchaseRate,
    String? refType,
    int? refId,
  }) {
    return transaction(() async {
      final bno = batchNo.trim().toUpperCase();
      if (bno.isEmpty) throw const CatalogException('Enter the batch number');
      if (qty < 1) throw const CatalogException('Enter the quantity received');
      final product = await (select(products)..where((p) => p.id.equals(productId))).getSingleOrNull();
      if (product == null) throw const CatalogException('Medicine not found');
      final existing = await (select(batches)
            ..where((b) => b.productId.equals(productId) & b.batchNo.equals(bno)))
          .getSingleOrNull();
      final ts = at.toUtc().millisecondsSinceEpoch;
      int bid;
      int newQty;
      if (existing != null) {
        bid = existing.id;
        newQty = existing.qty + qty;
        await (update(batches)..where((b) => b.id.equals(bid))).write(BatchesCompanion(qty: Value(newQty)));
      } else {
        if (expiry == null || !isValidExpiry(expiry)) throw const CatalogException('New batch — enter its expiry');
        newQty = qty;
        bid = await into(batches).insert(
          BatchesCompanion.insert(
            productId: productId,
            batchNo: bno,
            expiry: expiry,
            qty: qty,
            purchaseRatePaise: Value(purchaseRate?.value),
            createdAt: ts,
          ),
        );
      }
      await _movement(bid, qty, 'receive', at: at, staffId: staffId, refType: refType ?? 'batch', refId: refType == null ? bid : refId);
      await (update(products)..where((p) => p.id.equals(productId))).write(ProductsCompanion(updatedAt: Value(ts)));
      return ReceiveResult(batchId: bid, newBatch: existing == null, newQty: newQty);
    });
  }

  /// Manual stock correction (reason 'adjust').
  Future<void> adjustStock({
    required int batchId,
    required int delta,
    required DateTime at,
    int? staffId,
    bool allowNegative = false,
  }) {
    return transaction(() async {
      final b = await (select(batches)..where((x) => x.id.equals(batchId))).getSingle();
      if (!allowNegative && b.qty + delta < 0) throw CatalogException('Batch ${b.batchNo} has only ${b.qty}');
      await (update(batches)..where((x) => x.id.equals(batchId))).write(BatchesCompanion(qty: Value(b.qty + delta)));
      await _movement(batchId, delta, 'adjust', at: at, staffId: staffId, refType: 'batch', refId: batchId);
    });
  }

  /// Takes [qty] out of a batch for [reason] (e.g. 'supplier_return'). Never
  /// below zero, whatever `allowNegativeStock` says. Safe inside an outer
  /// transaction.
  Future<StockBatch> takeOutStock({
    required int batchId,
    required int qty,
    required String reason,
    required DateTime at,
    int? staffId,
    String? refType,
    int? refId,
  }) {
    return transaction(() async {
      if (qty < 1) throw const CatalogException('Enter the quantity');
      final b = await (select(batches)..where((x) => x.id.equals(batchId))).getSingleOrNull();
      if (b == null) throw const CatalogException('Batch not found');
      if (b.qty < qty) throw CatalogException('Batch ${b.batchNo} has only ${b.qty}');
      await (update(batches)..where((x) => x.id.equals(batchId))).write(BatchesCompanion(qty: Value(b.qty - qty)));
      await _movement(batchId, -qty, reason, at: at, staffId: staffId, refType: refType, refId: refId);
      return b;
    });
  }

  Future<List<StockBatch>> batchesOf(int productId) =>
      (select(batches)
            ..where((b) => b.productId.equals(productId))
            ..orderBy([(b) => OrderingTerm.asc(b.expiry), (b) => OrderingTerm.asc(b.batchNo)]))
          .get();

  Future<List<StockMovement>> movementsOf(int batchId) =>
      (select(stockMovements)
            ..where((m) => m.batchId.equals(batchId))
            ..orderBy([(m) => OrderingTerm.asc(m.at), (m) => OrderingTerm.asc(m.id)]))
          .get();

  /// The batch's newest movements first (Edit batch history).
  Stream<List<StockMovement>> watchRecentMovements(int batchId, {int limit = 5}) =>
      (select(stockMovements)
            ..where((m) => m.batchId.equals(batchId))
            ..orderBy([(m) => OrderingTerm.desc(m.at), (m) => OrderingTerm.desc(m.id)])
            ..limit(limit))
          .watch();

  Future<StockRow?> stockRow(int productId, {required DateTime now, int expiryWindowMonths = 3}) async {
    final rows = await customSelect(
      'SELECT $_stockCols $_from WHERE p.id = ?3',
      variables: [..._stockVars(now, expiryWindowMonths), Variable.withInt(productId)],
      readsFrom: _reads,
    ).get();
    return rows.isEmpty ? null : _row(rows.first);
  }

  Future<List<StockRow>> stockRows(List<int> ids, {required DateTime now, int expiryWindowMonths = 3}) async {
    if (ids.isEmpty) return const [];
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await customSelect(
      'SELECT $_stockCols $_from WHERE p.id IN ($marks)',
      variables: [..._stockVars(now, expiryWindowMonths), for (final id in ids) Variable.withInt(id)],
      readsFrom: _reads,
    ).get();
    final byId = {for (final r in rows.map(_row)) r.id: r};
    return [for (final id in ids) ?byId[id]];
  }

  /// Medicines whose name matches [name] ignoring case and outer spaces,
  /// hidden ones included (flagged), active first. [exceptProductId] is the
  /// medicine being edited.
  Future<List<SameNameProduct>> productsNamed(String name, {int? exceptProductId, int limit = 5}) async {
    final n = name.trim();
    if (n.isEmpty) return const [];
    final rows = await customSelect(
      'SELECT p.id, p.name, p.salt, p.pack, p.is_active, m.name AS maker '
      'FROM products p JOIN manufacturers m ON m.id = p.manufacturer_id '
      'WHERE lower(trim(p.name)) = lower(?1) AND p.id != ?2 '
      'ORDER BY p.is_active DESC, p.id LIMIT ?3',
      variables: [Variable.withString(n), Variable.withInt(exceptProductId ?? -1), Variable.withInt(limit)],
      readsFrom: {products, manufacturers},
    ).get();
    return [
      for (final r in rows)
        SameNameProduct(
          id: r.read<int>('id'),
          name: r.read<String>('name'),
          salt: r.read<String>('salt'),
          maker: r.read<String>('maker'),
          pack: r.read<String>('pack'),
          isActive: r.read<bool>('is_active'),
        ),
    ];
  }

  Future<int> productCount() async {
    final r = await customSelect('SELECT COUNT(*) AS c FROM products WHERE is_active = 1', readsFrom: {products}).getSingle();
    return r.read<int>('c');
  }

  Stream<int> watchProductCount() => customSelect(
        'SELECT COUNT(*) AS c FROM products WHERE is_active = 1',
        readsFrom: {products},
      ).watchSingle().map((r) => r.read<int>('c'));

  // -------------------------------------------------------------------------
  // Search (SPEC §5.2)

  /// FTS5 prefix search, ANDed words, ranked: name starts with first word →
  /// salt starts with first word → others; in stock before out; shorter name.
  /// An exact barcode match returns just that product.
  Future<SearchResults> search(String input, {required DateTime now, int limit = 12, int expiryWindowMonths = 3}) async {
    final sw = Stopwatch()..start();
    final q = input.trim();
    if (q.isEmpty) return SearchResults.empty;

    // Exact barcode (scanner input).
    if (RegExp(r'^\d{6,14}$').hasMatch(q)) {
      final rows = await customSelect(
        'SELECT $_stockCols $_from WHERE p.is_active = 1 AND p.barcode = ?3',
        variables: [..._stockVars(now, expiryWindowMonths), Variable.withString(q)],
        readsFrom: _reads,
      ).get();
      if (rows.isNotEmpty) {
        return SearchResults(rows: rows.map(_row).toList(), total: rows.length, ms: _ms(sw), exactBarcode: true);
      }
    }

    final match = ftsQuery(q);
    if (match == null) return SearchResults.empty;
    final first = '${q.toLowerCase().split(RegExp(r'\s+')).first}%';
    final vars = [
      ..._stockVars(now, expiryWindowMonths),
      Variable.withString(match),
      Variable.withString(first),
      Variable.withInt(limit),
    ];
    const ids = 'p.id IN (SELECT rowid FROM products_fts WHERE products_fts MATCH ?3)';
    final rows = await customSelect(
      '''
      SELECT * FROM (SELECT $_stockCols $_from WHERE p.is_active = 1 AND $ids)
      ORDER BY (CASE WHEN lower(name) LIKE ?4 THEN 0 WHEN lower(salt) LIKE ?4 THEN 1 ELSE 2 END) * 10
               + (CASE WHEN saleable <= 0 THEN 5 ELSE 0 END),
               length(name), name
      LIMIT ?5
      ''',
      variables: vars,
      readsFrom: _reads,
    ).get();
    final total = await customSelect(
      'SELECT COUNT(*) AS c FROM products p WHERE p.is_active = 1 AND p.id IN (SELECT rowid FROM products_fts WHERE products_fts MATCH ?1)',
      variables: [Variable.withString(match)],
      readsFrom: _reads,
    ).getSingle();
    return SearchResults(rows: rows.map(_row).toList(), total: total.read<int>('c'), ms: _ms(sw));
  }

  static double _ms(Stopwatch sw) => sw.elapsedMicroseconds / 1000;

  /// Other active products with the same normalised salt and saleable stock,
  /// cheapest first, max 6 (SPEC §4.3).
  Future<List<StockRow>> substitutes(int productId, {required DateTime now, int expiryWindowMonths = 3}) async {
    final rows = await customSelect(
      '''
      SELECT * FROM (SELECT $_stockCols $_from
        WHERE p.is_active = 1 AND p.id <> ?3
          AND lower(trim(p.salt)) = (SELECT lower(trim(salt)) FROM products WHERE id = ?3)
          AND trim(p.salt) <> '')
      WHERE saleable > 0
      ORDER BY mrp_paise, name
      LIMIT 6
      ''',
      variables: [..._stockVars(now, expiryWindowMonths), Variable.withInt(productId)],
      readsFrom: _reads,
    ).get();
    return rows.map(_row).toList();
  }

  // -------------------------------------------------------------------------
  // Inventory views (SPEC §5.3) — counts and pages come from SQL.

  String _viewWhere(InventoryView v) => switch (v) {
        InventoryView.all => '1',
        InventoryView.low => 'saleable <= reorder_level * units_per_pack',
        InventoryView.out => 'saleable <= 0',
        InventoryView.expiring => 'expiring > 0',
        InventoryView.dead => 'saleable > 0 AND COALESCE(last_sold_at, created_at) < ?3',
        InventoryView.hidden => '1',
      };

  Future<InventoryCounts> inventoryCounts({
    required DateTime now,
    int expiryWindowMonths = 3,
    int deadStockDays = 90,
  }) =>
      _countsQuery(now, expiryWindowMonths, deadStockDays).getSingle().then(_counts);

  /// Re-emits whenever products or batches change.
  Stream<InventoryCounts> watchInventoryCounts({
    required DateTime now,
    int expiryWindowMonths = 3,
    int deadStockDays = 90,
  }) =>
      _countsQuery(now, expiryWindowMonths, deadStockDays).watchSingle().map(_counts);

  Selectable<QueryRow> _countsQuery(DateTime now, int expiryWindowMonths, int deadStockDays) {
    return customSelect(
      '''
      SELECT COUNT(*) AS all_n,
        SUM(CASE WHEN saleable <= reorder_level * units_per_pack THEN 1 ELSE 0 END) AS low_n,
        SUM(CASE WHEN saleable <= 0 THEN 1 ELSE 0 END) AS out_n,
        SUM(CASE WHEN expiring > 0 THEN 1 ELSE 0 END) AS exp_n,
        SUM(CASE WHEN saleable > 0 AND COALESCE(last_sold_at, created_at) < ?3 THEN 1 ELSE 0 END) AS dead_n,
        (SELECT COUNT(*) FROM products WHERE is_active = 0) AS hidden_n
      FROM (SELECT $_stockCols $_from WHERE p.is_active = 1)
      ''',
      variables: [..._stockVars(now, expiryWindowMonths), Variable.withInt(_deadCutoff(now, deadStockDays))],
      readsFrom: _reads,
    );
  }

  static InventoryCounts _counts(QueryRow r) {
    return InventoryCounts(
      all: r.read<int>('all_n'),
      low: r.readNullable<int>('low_n') ?? 0,
      out: r.readNullable<int>('out_n') ?? 0,
      expiring: r.readNullable<int>('exp_n') ?? 0,
      dead: r.readNullable<int>('dead_n') ?? 0,
      hidden: r.readNullable<int>('hidden_n') ?? 0,
    );
  }

  static int _deadCutoff(DateTime now, int days) =>
      now.subtract(Duration(days: days)).toUtc().millisecondsSinceEpoch;

  Future<InventoryPage> inventoryPage(
    InventoryQuery q, {
    required DateTime now,
    int expiryWindowMonths = 3,
    int deadStockDays = 90,
  }) async {
    final sw = Stopwatch()..start();
    final vars = <Variable<Object>>[
      ..._stockVars(now, expiryWindowMonths),
      Variable.withInt(_deadCutoff(now, deadStockDays)),
    ];
    // `?3 IS NOT NULL` keeps the dead-stock cutoff bound in every view.
    final active = q.view == InventoryView.hidden ? 0 : 1;
    final inner = StringBuffer('SELECT $_stockCols $_from WHERE p.is_active = $active AND ?3 IS NOT NULL');
    final match = ftsQuery(q.search);
    if (match != null) {
      vars.add(Variable.withString(match));
      inner.write(' AND p.id IN (SELECT rowid FROM products_fts WHERE products_fts MATCH ?${vars.length})');
    }
    if (q.category != null) {
      vars.add(Variable.withString(q.category!));
      inner.write(' AND p.category = ?${vars.length}');
    }
    if (q.manufacturerId != null) {
      vars.add(Variable.withInt(q.manufacturerId!));
      inner.write(' AND p.manufacturer_id = ?${vars.length}');
    }
    final where = 'FROM ($inner) WHERE ${_viewWhere(q.view)}';
    final dir = q.ascending ? 'ASC' : 'DESC';
    final order = switch (q.sort) {
      InventorySort.name => 'lower(name) $dir',
      InventorySort.expiry => "COALESCE(nearest, earliest, '9999-12') $dir",
      InventorySort.stock => 'saleable $dir',
      InventorySort.mrp => 'mrp_paise $dir',
    };
    final total = (await customSelect('SELECT COUNT(*) AS c $where', variables: vars, readsFrom: _reads).getSingle())
        .read<int>('c');
    final size = q.pageSize.clamp(1, 500);
    final pages = total == 0 ? 1 : (total + size - 1) ~/ size;
    final page = q.page.clamp(1, pages);
    final rows = await customSelect(
      'SELECT * $where ORDER BY $order, id $dir LIMIT ?${vars.length + 1} OFFSET ?${vars.length + 2}',
      variables: [...vars, Variable.withInt(size), Variable.withInt((page - 1) * size)],
      readsFrom: _reads,
    ).get();
    return InventoryPage(rows: rows.map(_row).toList(), total: total, ms: _ms(sw));
  }

  /// Σ saleable × MRP over active products (MRP is per pack of
  /// units_per_pack units).
  Future<Paise> stockValue({required DateTime now}) async {
    final r = await customSelect(
      '''
      SELECT COALESCE(SUM(b.qty * p.mrp_paise / p.units_per_pack), 0) AS v
      FROM batches b JOIN products p ON p.id = b.product_id
      WHERE p.is_active = 1 AND b.qty > 0 AND b.expiry >= ?1
      ''',
      variables: [Variable.withString(monthKey(now))],
      readsFrom: _reads,
    ).getSingle();
    return Paise(r.read<int>('v'));
  }

  /// Products to reorder: lowest stock / reorder ratio first.
  Future<List<StockRow>> reorderSoon({required DateTime now, int limit = 4}) async {
    final rows = await customSelect(
      '''
      SELECT * FROM (SELECT $_stockCols $_from WHERE p.is_active = 1)
      WHERE saleable <= reorder_level * units_per_pack
      ORDER BY CAST(saleable AS REAL) / MAX(reorder_level * units_per_pack, 1), name
      LIMIT ?3
      ''',
      variables: [..._stockVars(now, 3), Variable.withInt(limit)],
      readsFrom: _reads,
    ).get();
    return rows.map(_row).toList();
  }

  /// Batches with stock expiring within the window (incl. already expired),
  /// soonest first.
  Future<List<ExpiringBatch>> expiringBatches({required DateTime now, int expiryWindowMonths = 3, int limit = 4}) async {
    final rows = await customSelect(
      '''
      SELECT b.id, b.batch_no, b.expiry, b.qty, p.id AS product_id, p.name, p.units_per_pack, p.category
      FROM batches b JOIN products p ON p.id = b.product_id
      WHERE p.is_active = 1 AND b.qty > 0 AND b.expiry <= ?1
      ORDER BY b.expiry, p.name
      LIMIT ?2
      ''',
      variables: [Variable.withString(addMonthsKey(now, expiryWindowMonths)), Variable.withInt(limit)],
      readsFrom: _reads,
    ).get();
    return [
      for (final r in rows)
        ExpiringBatch(
          batchId: r.read<int>('id'),
          batchNo: r.read<String>('batch_no'),
          expiry: r.read<String>('expiry'),
          qty: r.read<int>('qty'),
          productId: r.read<int>('product_id'),
          productName: r.read<String>('name'),
          packSize: r.read<int>('units_per_pack'),
          category: r.read<String>('category'),
        ),
    ];
  }

  /// Changes how many units make one pack (SPEC §4.9). Batches are kept in
  /// units, so each one is converted: whole packs × new size. Every batch
  /// must hold whole packs (sell or adjust loose units first). Writes a
  /// 'repack' movement per converted batch and rescales purchase rates.
  /// Sets reorder levels (packs) for several products in one transaction —
  /// "Apply suggested reorder levels" in the consumption register.
  Future<int> setReorderLevels(Map<int, int> levels, {required DateTime at}) {
    return transaction(() async {
      var n = 0;
      for (final e in levels.entries) {
        if (e.value < 0) throw const CatalogException('Reorder level can’t be negative');
        n += await (update(products)..where((p) => p.id.equals(e.key))).write(
          ProductsCompanion(reorderLevel: Value(e.value), updatedAt: Value(at.toUtc().millisecondsSinceEpoch)),
        );
      }
      return n;
    });
  }

  Future<void> setPackSize(int productId, int newSize, {required DateTime at, int? staffId}) {
    return transaction(() async {
      if (newSize < 1 || newSize > maxPackSize) throw const CatalogException('Units per pack must be 1–$maxPackSize');
      final p = await (select(products)..where((x) => x.id.equals(productId))).getSingleOrNull();
      if (p == null) throw const CatalogException('Medicine not found');
      final old = p.unitsPerPack;
      if (old == newSize) return;
      final bs = await batchesOf(productId);
      for (final b in bs) {
        if (b.qty % old != 0) {
          throw CatalogException(
            'Batch ${b.batchNo} has ${b.qty % old} loose — sell, return or adjust it to whole packs first',
          );
        }
      }
      for (final b in bs) {
        final qty = b.qty ~/ old * newSize;
        final rate = b.purchaseRatePaise;
        await (update(batches)..where((x) => x.id.equals(b.id))).write(
          BatchesCompanion(
            qty: Value(qty),
            purchaseRatePaise: Value(rate == null ? null : (rate * old * 2 + newSize) ~/ (newSize * 2)),
          ),
        );
        if (qty != b.qty) {
          await _movement(b.id, qty - b.qty, 'repack', at: at, staffId: staffId, refType: 'product', refId: productId);
        }
      }
      await (update(products)..where((x) => x.id.equals(productId))).write(
        ProductsCompanion(unitsPerPack: Value(newSize), updatedAt: Value(at.toUtc().millisecondsSinceEpoch)),
      );
    });
  }
}

class ExpiringBatch {
  const ExpiringBatch({
    required this.batchId,
    required this.batchNo,
    required this.expiry,
    required this.qty,
    required this.productId,
    required this.productName,
    this.packSize = 1,
    this.category = '',
  });

  final int packSize;
  final String category;
  final int batchId;
  final String batchNo;
  final String expiry;
  final int qty;
  final int productId;
  final String productName;
}
