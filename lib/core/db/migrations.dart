import 'dart:convert';

import 'package:drift/drift.dart';

import 'app_database.dart';
import 'fts.dart';

/// Current schema version. Every bump needs a step in [_steps] and a test in
/// test/dao/migration_test.dart (CLAUDE.md rule 10).
const int latestSchemaVersion = 16;

/// `_steps[v]` migrates schema v → v + 1.
final Map<int, Future<void> Function(AppDatabase db, Migrator m)> _steps = {
  // v1 → v2: backup_log.sha256 (checksum of each backup).
  1: (db, m) => m.addColumn(db.backupLog, db.backupLog.sha256),
  // v2 → v3: purchases — suppliers, order book, stockist receipts (SPEC §4.7).
  2: (db, m) async {
    await m.createTable(db.suppliers);
    await m.createTable(db.orderLines);
    await m.createTable(db.purchaseReceipts);
    await m.createTable(db.receiptLines);
    for (final s in purchaseIndexStatements) {
      await db.customStatement(s);
    }
  },
  // v3 → v4: stockist dues — credit days, bill totals + due dates, ledger,
  // allocations, returns (SPEC §4.8). Existing receipts become bills.
  3: (db, m) async {
    // A v2 database gets these tables from step 2 with today's columns.
    if (!await _hasColumn(db, 'suppliers', 'credit_days')) await m.addColumn(db.suppliers, db.suppliers.creditDays);
    if (!await _hasColumn(db, 'purchase_receipts', 'bill_total_paise')) {
      await m.addColumn(db.purchaseReceipts, db.purchaseReceipts.billTotalPaise);
    }
    if (!await _hasColumn(db, 'purchase_receipts', 'due_date')) await m.addColumn(db.purchaseReceipts, db.purchaseReceipts.dueDate);
    await db.customStatement(
      "UPDATE purchase_receipts SET bill_total_paise = total_paise, due_date = date(received_date, '+30 days')",
    );
    await m.createTable(db.supplierLedger);
    await m.createTable(db.ledgerAllocations);
    await m.createTable(db.returnLines);
    await db.customStatement('''
      INSERT INTO supplier_ledger(supplier_id, entry_date, kind, amount_paise, open_paise, receipt_id, due_date, reference, note, status, staff_id, created_at)
      SELECT supplier_id, received_date, 'bill', bill_total_paise, bill_total_paise, id, due_date, invoice_no, '', 'active', staff_id, created_at
      FROM purchase_receipts WHERE bill_total_paise > 0 ORDER BY received_date, id''');
    for (final s in duesIndexStatements) {
      await db.customStatement(s);
    }
  },
  // v4 → v5: sales returns as credit notes (SPEC §4.5) — invoices.doc_type /
  // ref_invoice_id, invoice_items.ref_item_id / restocked; Pharmacists get
  // the new "Accept returns" permission when roles were already customised.
  4: (db, m) async {
    if (!await _hasColumn(db, 'invoices', 'doc_type')) await m.addColumn(db.invoices, db.invoices.docType);
    if (!await _hasColumn(db, 'invoices', 'ref_invoice_id')) await m.addColumn(db.invoices, db.invoices.refInvoiceId);
    if (!await _hasColumn(db, 'invoice_items', 'ref_item_id')) {
      await m.addColumn(db.invoiceItems, db.invoiceItems.refItemId);
    }
    if (!await _hasColumn(db, 'invoice_items', 'restocked')) await m.addColumn(db.invoiceItems, db.invoiceItems.restocked);
    for (final s in returnsIndexStatements) {
      await db.customStatement(s);
    }
    await grantPharmacistReturns(db);
  },
  // v5 → v6: loose selling (SPEC §4.9) — products.units_per_pack and the
  // invoice_items.pack_size snapshot. Everything starts at 1, so existing
  // quantities (packs) keep their meaning until the owner sets a size.
  5: (db, m) async {
    if (!await _hasColumn(db, 'products', 'units_per_pack')) await m.addColumn(db.products, db.products.unitsPerPack);
    if (!await _hasColumn(db, 'invoice_items', 'pack_size')) await m.addColumn(db.invoiceItems, db.invoiceItems.packSize);
  },
  // v6 → v7: customer credit / udhaar (SPEC §4.10) — customers.credit_limit,
  // address, note; invoices.paid_now / dues_after snapshots; the customer
  // ledger + allocations. Customised roles get the new permissions.
  6: (db, m) async {
    if (!await _hasColumn(db, 'customers', 'credit_limit_paise')) await m.addColumn(db.customers, db.customers.creditLimitPaise);
    if (!await _hasColumn(db, 'customers', 'address')) await m.addColumn(db.customers, db.customers.address);
    if (!await _hasColumn(db, 'customers', 'note')) await m.addColumn(db.customers, db.customers.note);
    if (!await _hasColumn(db, 'invoices', 'paid_now_paise')) await m.addColumn(db.invoices, db.invoices.paidNowPaise);
    if (!await _hasColumn(db, 'invoices', 'dues_after_paise')) await m.addColumn(db.invoices, db.invoices.duesAfterPaise);
    await m.createTable(db.customerLedger);
    await m.createTable(db.customerAllocations);
    for (final s in creditIndexStatements) {
      await db.customStatement(s);
    }
    await grantRolePermissions(db, const {
      'Pharmacist': ['sellOnCredit', 'collectPayments'],
      'Cashier': ['collectPayments'],
    });
  },
  // v7 → v8: stockist directory (SPEC §4.11) — suppliers.other_phones / note,
  // product_sources seeded from what each stockist has already supplied.
  7: (db, m) async {
    if (!await _hasColumn(db, 'suppliers', 'other_phones')) await m.addColumn(db.suppliers, db.suppliers.otherPhones);
    if (!await _hasColumn(db, 'suppliers', 'note')) await m.addColumn(db.suppliers, db.suppliers.note);
    await m.createTable(db.productSources);
    for (final s in sourcesIndexStatements) {
      await db.customStatement(s);
    }
    await db.customStatement('''
      INSERT OR IGNORE INTO product_sources(supplier_id, product_id, item_name, origin, last_received, created_at, updated_at)
      SELECT r.supplier_id, l.product_id, p.name, 'receipt', MAX(r.received_date), MAX(r.created_at), MAX(r.created_at)
      FROM receipt_lines l JOIN purchase_receipts r ON r.id = l.receipt_id JOIN products p ON p.id = l.product_id
      GROUP BY r.supplier_id, l.product_id''');
  },
  // v8 → v9: editable inventory (SPEC §5.3) — reason note on stock corrections.
  8: (db, m) async {
    if (!await _hasColumn(db, 'stock_movements', 'note')) await m.addColumn(db.stockMovements, db.stockMovements.note);
  },
  // v9 → v10: flat ₹ bill discounts (SPEC §4.6) — invoices.discount_flat_paise.
  // Existing bills stay percentage bills (null).
  9: (db, m) async {
    if (!await _hasColumn(db, 'invoices', 'discount_flat_paise')) await m.addColumn(db.invoices, db.invoices.discountFlatPaise);
  },
  // v10 → v11: strips per stockist box (SPEC §4.7) — products.packs_per_box.
  // Existing medicines start unknown (null) and are asked on the next Box receipt.
  10: (db, m) async {
    if (!await _hasColumn(db, 'products', 'packs_per_box')) await m.addColumn(db.products, db.products.packsPerBox);
  },
  // v11 → v12: batch-wise MRP and purchase rate details (SPEC §4.5, §4.7).
  // Every existing batch takes its medicine's current MRP.
  11: (db, m) async {
    if (!await _hasColumn(db, 'batches', 'mrp_paise')) await m.addColumn(db.batches, db.batches.mrpPaise);
    await db.customStatement('UPDATE batches SET mrp_paise = (SELECT p.mrp_paise FROM products p WHERE p.id = batches.product_id) WHERE mrp_paise = 0');
    for (final c in [db.receiptLines.freeQty, db.receiptLines.ratePaise, db.receiptLines.discBp, db.receiptLines.gstRate, db.receiptLines.mrpPaise]) {
      if (!await _hasColumn(db, 'receipt_lines', c.name)) await m.addColumn(db.receiptLines, c);
    }
  },
  // v12 → v13: held (parked) bills at the counter (SPEC §5.2).
  12: (db, m) async {
    if (!await _hasTable(db, 'held_bills')) await m.createTable(db.heldBills);
  },
  // v13 → v14: day-end cash closing (SPEC §4.14) — paid-outs, closings, and
  // the new cashClose permission for Pharmacists and Cashiers.
  13: (db, m) async {
    if (!await _hasTable(db, 'cash_paid_out')) await m.createTable(db.cashPaidOuts);
    if (!await _hasTable(db, 'cash_closings')) await m.createTable(db.cashClosings);
    for (final s in cashIndexStatements) {
      await db.customStatement(s);
    }
    await grantRolePermissions(db, const {
      'Pharmacist': ['cashClose'],
      'Cashier': ['cashClose'],
    });
  },
  // v14 → v15: B2B bills (SPEC §4.15) — customer GSTIN, buyer GSTIN and
  // place of supply on invoices. Existing bills stay B2C (null).
  14: (db, m) async {
    if (!await _hasColumn(db, 'customers', 'gstin')) await m.addColumn(db.customers, db.customers.gstin);
    if (!await _hasColumn(db, 'invoices', 'buyer_gstin')) await m.addColumn(db.invoices, db.invoices.buyerGstin);
    if (!await _hasColumn(db, 'invoices', 'place_of_supply')) await m.addColumn(db.invoices, db.invoices.placeOfSupply);
  },
  // v15 → v16: box size per stockist (SPEC §4.7) — strips per box on each
  // Box receipt line. Not backfilled: old stock units may have been typed
  // by hand (short boxes), so the medicine's own number stays the fallback.
  15: (db, m) async {
    if (!await _hasColumn(db, 'receipt_lines', 'packs_per_box')) await m.addColumn(db.receiptLines, db.receiptLines.packsPerBox);
    for (final s in boxSizeIndexStatements) {
      await db.customStatement(s);
    }
  },
};

/// Adds `acceptReturns` to a stored Pharmacist permission list (v5). Stores
/// still on the defaults pick it up from `defaultRolePermissions`.
Future<void> grantPharmacistReturns(GeneratedDatabase db) => grantRolePermissions(db, const {
      'Pharmacist': ['acceptReturns'],
    });

/// Adds [grants] to stored (customised) role permission lists. Stores still
/// on the defaults pick new permissions up from `defaultRolePermissions`.
Future<void> grantRolePermissions(GeneratedDatabase db, Map<String, List<String>> grants) async {
  final row = await db
      .customSelect("SELECT value FROM settings WHERE key = 'rolePermissions'")
      .getSingleOrNull();
  if (row == null) return;
  final Object? decoded;
  try {
    decoded = jsonDecode(row.read<String>('value'));
  } on FormatException {
    return;
  }
  if (decoded is! Map<String, dynamic>) return;
  var changed = false;
  for (final g in grants.entries) {
    final list = decoded[g.key];
    if (list is! List) continue;
    final add = g.value.where((p) => !list.contains(p)).toList();
    if (add.isEmpty) continue;
    decoded[g.key] = [...list, ...add];
    changed = true;
  }
  if (!changed) return;
  await db.customStatement(
    "UPDATE settings SET value = ? WHERE key = 'rolePermissions'",
    [jsonEncode(decoded)],
  );
}

Future<bool> _hasTable(AppDatabase db, String table) async =>
    (await db.customSelect("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1", variables: [Variable.withString(table)]).get())
        .isNotEmpty;

Future<bool> _hasColumn(AppDatabase db, String table, String column) async {
  final cols = await db.customSelect('PRAGMA table_info($table)').get();
  return cols.any((c) => c.read<String>('name') == column);
}

/// Runs each step from [from] up to [to].
Future<void> runMigrations(AppDatabase db, Migrator m, int from, int to) async {
  for (var v = from; v < to; v++) {
    final step = _steps[v];
    if (step == null) throw StateError('No migration from schema v$v');
    await step(db, m);
  }
}
