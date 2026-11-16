import 'package:drift/drift.dart';

import '../../purchases/purchase_rules.dart';
import '../app_database.dart';

part 'sources_dao.g.dart';

// ---------------------------------------------------------------------------
// Rows and inputs (SPEC §4.11).

/// One directory line: a medicine and a stockist it comes from.
class SourceRow {
  const SourceRow({
    required this.id,
    required this.supplierId,
    required this.supplierName,
    required this.phone,
    required this.otherPhones,
    required this.productId,
    required this.itemName,
    required this.mrName,
    required this.mrPhone,
    required this.note,
    required this.origin,
    required this.lastReceived,
  });

  final int id;
  final int supplierId;
  final String supplierName;
  final String phone;
  final String otherPhones;

  /// Null = free text, not linked to the catalogue.
  final int? productId;
  final String itemName;
  final String mrName;
  final String mrPhone;
  final String note;

  /// 'import' | 'manual' | 'receipt'
  final String origin;
  final String? lastReceived;

  /// "9862958415 / 0389-2323442".
  String get phones => [phone, otherPhones].where((p) => p.trim().isNotEmpty).join(' / ');

  /// "Tluangtea · 98…" or ''.
  String get mr => [mrName, mrPhone].where((p) => p.trim().isNotEmpty).join(' · ');
}

class SourceCursor {
  const SourceCursor(this.supplierName, this.itemName, this.id);
  final String supplierName;
  final String itemName;
  final int id;
}

class SourcePage {
  const SourcePage({required this.rows, required this.hasMore, required this.total, required this.ms});
  final List<SourceRow> rows;
  final bool hasMore;
  final int total;
  final double ms;
}

/// One row to import (already matched or not).
class DirectoryImportRow {
  const DirectoryImportRow({
    required this.supplierName,
    required this.itemName,
    this.productId,
    this.phones = const [],
    this.mrName = '',
  });

  final String supplierName;

  /// As written in the sheet.
  final String itemName;
  final int? productId;

  /// The stockist's numbers found in its block (first = main).
  final List<String> phones;
  final String mrName;
}

class DirectoryImportResult {
  const DirectoryImportResult({required this.stockistsAdded, required this.added, required this.skipped, required this.linked});
  final int stockistsAdded;

  /// New directory rows.
  final int added;

  /// Already there (same stockist + medicine / name).
  final int skipped;

  /// Of [added], linked to a catalogue medicine.
  final int linked;
}

// ---------------------------------------------------------------------------

/// Stockist directory: which stockist supplies which medicine, with phones
/// and the company's MR.
@DriftAccessor(tables: [Suppliers, ProductSources, Products])
class SourcesDao extends DatabaseAccessor<AppDatabase> with _$SourcesDaoMixin {
  SourcesDao(super.attachedDatabase);

  Set<ResultSetImplementation<dynamic, dynamic>> get _reads => {suppliers, productSources};

  static int _ts(DateTime at) => at.toUtc().millisecondsSinceEpoch;

  static const String _cols = '''
    ps.id, ps.supplier_id, s.name AS supplier_name, COALESCE(s.phone, '') AS phone, s.other_phones,
    ps.product_id, ps.item_name, ps.mr_name, ps.mr_phone, ps.note, ps.origin, ps.last_received
  ''';

  static SourceRow _row(QueryRow r) => SourceRow(
        id: r.read<int>('id'),
        supplierId: r.read<int>('supplier_id'),
        supplierName: r.read<String>('supplier_name'),
        phone: r.read<String>('phone'),
        otherPhones: r.read<String>('other_phones'),
        productId: r.readNullable<int>('product_id'),
        itemName: r.read<String>('item_name'),
        mrName: r.read<String>('mr_name'),
        mrPhone: r.read<String>('mr_phone'),
        note: r.read<String>('note'),
        origin: r.read<String>('origin'),
        lastReceived: r.readNullable<String>('last_received'),
      );

  /// Directory lines by stockist then medicine; keyset paged. [search]
  /// matches medicine, stockist, MR and phone.
  Future<SourcePage> page({String search = '', int? supplierId, SourceCursor? after, int limit = 50}) async {
    final sw = Stopwatch()..start();
    final q = search.trim().toLowerCase();
    final vars = <Variable<Object>>[
      Variable.withString(q),
      Variable.withString('%$q%'),
      Variable.withInt(supplierId ?? 0),
    ];
    const where = '''
      (?1 = '' OR lower(ps.item_name) LIKE ?2 OR lower(s.name) LIKE ?2 OR lower(ps.mr_name) LIKE ?2
         OR COALESCE(s.phone, '') LIKE ?2 OR s.other_phones LIKE ?2)
      AND (?3 = 0 OR ps.supplier_id = ?3)
    ''';
    final total = (await customSelect(
      'SELECT COUNT(*) AS c FROM product_sources ps JOIN suppliers s ON s.id = ps.supplier_id WHERE $where',
      variables: vars,
      readsFrom: _reads,
    ).getSingle())
        .read<int>('c');
    var cursor = '';
    if (after != null) {
      vars
        ..add(Variable.withString(after.supplierName.toLowerCase()))
        ..add(Variable.withString(after.itemName.toLowerCase()))
        ..add(Variable.withInt(after.id));
      cursor = 'AND (lower(s.name), lower(ps.item_name), ps.id) > (?4, ?5, ?6)';
    }
    vars.add(Variable.withInt(limit + 1));
    final rows = await customSelect(
      '''
      SELECT $_cols FROM product_sources ps JOIN suppliers s ON s.id = ps.supplier_id
      WHERE $where $cursor
      ORDER BY lower(s.name), lower(ps.item_name), ps.id LIMIT ?${vars.length}
      ''',
      variables: vars,
      readsFrom: _reads,
    ).get();
    return SourcePage(
      rows: rows.take(limit).map(_row).toList(),
      hasMore: rows.length > limit,
      total: total,
      ms: sw.elapsedMicroseconds / 1000,
    );
  }

  /// Where to get [productId]: most recently supplied first.
  Future<List<SourceRow>> sourcesFor(int productId) async {
    final rows = await customSelect(
      '''
      SELECT $_cols FROM product_sources ps JOIN suppliers s ON s.id = ps.supplier_id
      WHERE ps.product_id = ?1
      ORDER BY ps.last_received IS NULL, ps.last_received DESC, lower(s.name)
      ''',
      variables: [Variable.withInt(productId)],
      readsFrom: _reads,
    ).get();
    return rows.map(_row).toList();
  }

  /// The first source of each product (pending orders' "Get from").
  Future<Map<int, SourceRow>> firstSources(Iterable<int> productIds) async {
    final ids = productIds.toSet().toList();
    if (ids.isEmpty) return const {};
    final rows = await customSelect(
      '''
      SELECT $_cols FROM product_sources ps JOIN suppliers s ON s.id = ps.supplier_id
      WHERE ps.product_id IN (${List.filled(ids.length, '?').join(',')})
      ORDER BY ps.product_id, ps.last_received IS NULL, ps.last_received DESC, lower(s.name)
      ''',
      variables: [for (final id in ids) Variable.withInt(id)],
      readsFrom: _reads,
    ).get();
    final out = <int, SourceRow>{};
    for (final r in rows) {
      out.putIfAbsent(r.read<int>('product_id'), () => _row(r));
    }
    return out;
  }

  Future<List<Supplier>> stockists() => (select(suppliers)..orderBy([(s) => OrderingTerm.asc(s.name)])).get();

  // -------------------------------------------------------------------------
  // Writes — each one transaction (a savepoint inside a receive).

  Future<Product?> _product(int? id) async =>
      id == null ? null : (select(products)..where((p) => p.id.equals(id))).getSingleOrNull();

  Future<ProductSource?> _existing(int supplierId, int? productId, String itemName) async {
    if (productId != null) {
      final linked = await (select(productSources)..where((x) => x.supplierId.equals(supplierId) & x.productId.equals(productId)))
          .getSingleOrNull();
      if (linked != null) return linked;
    }
    final rows = await customSelect(
      'SELECT id FROM product_sources WHERE supplier_id = ?1 AND item_name = ?2 COLLATE NOCASE AND product_id IS NULL LIMIT 1',
      variables: [Variable.withInt(supplierId), Variable.withString(itemName.trim())],
      readsFrom: {productSources},
    ).get();
    if (rows.isEmpty) return null;
    return (select(productSources)..where((x) => x.id.equals(rows.single.read<int>('id')))).getSingle();
  }

  /// Adds a line by hand. The stockist is found by name or created.
  Future<int> add({
    required String supplierName,
    int? productId,
    String itemName = '',
    String mrName = '',
    String mrPhone = '',
    String note = '',
    required DateTime at,
  }) {
    return transaction(() async {
      final p = await _product(productId);
      if (productId != null && p == null) throw const PurchaseException('Medicine not found');
      final name = p?.name ?? itemName.trim();
      if (name.isEmpty) throw const PurchaseException('Enter the medicine');
      final sid = await attachedDatabase.purchasesDao.supplierIdFor(supplierName, at: at);
      if (await _existing(sid, productId, name) != null) throw PurchaseException('$name is already listed for this stockist');
      return into(productSources).insert(
        ProductSourcesCompanion.insert(
          supplierId: sid,
          productId: Value(productId),
          itemName: name,
          mrName: Value(mrName.trim()),
          mrPhone: Value(mrPhone.trim()),
          note: Value(note.trim()),
          origin: 'manual',
          createdAt: _ts(at),
          updatedAt: _ts(at),
        ),
      );
    });
  }

  /// Edits a line: link / relink the medicine, MR, note.
  Future<void> updateSource(int id, {int? productId, required String itemName, String mrName = '', String mrPhone = '', String note = '', required DateTime at}) {
    return transaction(() async {
      final row = await (select(productSources)..where((x) => x.id.equals(id))).getSingleOrNull();
      if (row == null) throw const PurchaseException('Line not found');
      final p = await _product(productId);
      if (productId != null && p == null) throw const PurchaseException('Medicine not found');
      final name = p?.name ?? itemName.trim();
      if (name.isEmpty) throw const PurchaseException('Enter the medicine');
      final clash = await _existing(row.supplierId, productId, name);
      if (clash != null && clash.id != id) throw PurchaseException('$name is already listed for this stockist');
      await (update(productSources)..where((x) => x.id.equals(id))).write(
        ProductSourcesCompanion(
          productId: Value(productId),
          itemName: Value(name),
          mrName: Value(mrName.trim()),
          mrPhone: Value(mrPhone.trim()),
          note: Value(note.trim()),
          updatedAt: Value(_ts(at)),
        ),
      );
    });
  }

  /// Directory lines aren't records — they can be removed.
  Future<void> remove(int id) => (delete(productSources)..where((x) => x.id.equals(id))).go();

  /// Stockist phones and note.
  Future<void> setStockistContact(int supplierId, {required String phone, String otherPhones = '', String note = ''}) =>
      (update(suppliers)..where((s) => s.id.equals(supplierId))).write(
        SuppliersCompanion(
          phone: Value(phone.trim().isEmpty ? null : phone.trim()),
          otherPhones: Value(otherPhones.trim()),
          note: Value(note.trim()),
        ),
      );

  /// A stockist invoice brought [productId]: remember where it came from.
  /// Links a matching free-text line instead of adding a second one.
  Future<void> learnFromReceipt({required int supplierId, required int productId, required String date, required DateTime at}) {
    return transaction(() async {
      final p = (await _product(productId))!;
      final row = await _existing(supplierId, productId, p.name);
      if (row == null) {
        await into(productSources).insert(
          ProductSourcesCompanion.insert(
            supplierId: supplierId,
            productId: Value(productId),
            itemName: p.name,
            origin: 'receipt',
            lastReceived: Value(date),
            createdAt: _ts(at),
            updatedAt: _ts(at),
          ),
        );
        return;
      }
      final last = row.lastReceived == null || row.lastReceived!.compareTo(date) < 0 ? date : row.lastReceived!;
      await (update(productSources)..where((x) => x.id.equals(row.id))).write(
        ProductSourcesCompanion(productId: Value(productId), itemName: Value(p.name), lastReceived: Value(last), updatedAt: Value(_ts(at))),
      );
    });
  }

  /// Imports the "Damdawi lak na" sheet (SPEC §4.11) in one transaction.
  /// Re-importing adds nothing twice; empty stockist phones are filled and
  /// new numbers appended.
  Future<DirectoryImportResult> importRows(List<DirectoryImportRow> rows, {required DateTime at}) {
    return transaction(() async {
      final before = (await customSelect('SELECT COUNT(*) AS c FROM suppliers', readsFrom: {suppliers}).getSingle()).read<int>('c');
      final ids = <String, int>{};
      var added = 0, skipped = 0, linked = 0;
      for (final r in rows) {
        final key = r.supplierName.trim().toLowerCase();
        if (key.isEmpty || r.itemName.trim().isEmpty) {
          skipped++;
          continue;
        }
        final sid = ids[key] ??= await attachedDatabase.purchasesDao.supplierIdFor(r.supplierName, at: at);
        if (r.phones.isNotEmpty) await _mergePhones(sid, r.phones);
        final p = await _product(r.productId);
        final name = p?.name ?? r.itemName.trim();
        final existing = await _existing(sid, p?.id, name);
        if (existing != null) {
          if (existing.mrName.isEmpty && r.mrName.trim().isNotEmpty) {
            await (update(productSources)..where((x) => x.id.equals(existing.id)))
                .write(ProductSourcesCompanion(mrName: Value(r.mrName.trim()), updatedAt: Value(_ts(at))));
          }
          skipped++;
          continue;
        }
        await into(productSources).insert(
          ProductSourcesCompanion.insert(
            supplierId: sid,
            productId: Value(p?.id),
            itemName: name,
            mrName: Value(r.mrName.trim()),
            note: Value(p == null || name == r.itemName.trim() ? '' : 'Sheet: ${r.itemName.trim()}'),
            origin: 'import',
            createdAt: _ts(at),
            updatedAt: _ts(at),
          ),
        );
        added++;
        if (p != null) linked++;
      }
      final after = (await customSelect('SELECT COUNT(*) AS c FROM suppliers', readsFrom: {suppliers}).getSingle()).read<int>('c');
      return DirectoryImportResult(stockistsAdded: after - before, added: added, skipped: skipped, linked: linked);
    });
  }

  Future<void> _mergePhones(int supplierId, List<String> phones) async {
    final s = await (select(suppliers)..where((x) => x.id.equals(supplierId))).getSingle();
    String digits(String p) => p.replaceAll(RegExp(r'\D'), '');
    final have = [if ((s.phone ?? '').isNotEmpty) s.phone!, ...s.otherPhones.split('/').map((p) => p.trim()).where((p) => p.isNotEmpty)];
    final known = have.map(digits).toSet();
    final fresh = [for (final p in phones) if (known.add(digits(p))) p.trim()];
    if (fresh.isEmpty) return;
    final all = [...have, ...fresh];
    await (update(suppliers)..where((x) => x.id.equals(supplierId))).write(
      SuppliersCompanion(phone: Value(all.first), otherPhones: Value(all.skip(1).join(' / '))),
    );
  }
}
