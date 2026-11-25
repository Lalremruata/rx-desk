/// FTS5 search index over products (SPEC §3.2) and the extra indexes in §3.3
/// that Drift's table DSL can't express (partial indexes). Created in
/// onCreate and kept in sync by triggers.
library;

const String _refresh = '''
  INSERT INTO products_fts(rowid, name, salt, manufacturer, barcode, batch_nos, hsn, rack)
  SELECT p.id, p.name, p.salt, m.name, COALESCE(p.barcode, ''),
         COALESCE((SELECT group_concat(b.batch_no, ' ') FROM batches b WHERE b.product_id = p.id), ''),
         p.hsn, p.rack
  FROM products p JOIN manufacturers m ON m.id = p.manufacturer_id
''';

String _refreshProduct(String idExpr) => '''
  DELETE FROM products_fts WHERE rowid = $idExpr;
  $_refresh WHERE p.id = $idExpr;
''';

const List<String> ftsStatements = [
  '''
CREATE VIRTUAL TABLE IF NOT EXISTS products_fts USING fts5(
  name, salt, manufacturer, barcode, batch_nos, hsn, rack,
  tokenize = 'unicode61 remove_diacritics 2',
  prefix = '2 3 4'
)''',
  '''
CREATE TRIGGER IF NOT EXISTS products_fts_ai AFTER INSERT ON products BEGIN
  $_refresh WHERE p.id = NEW.id;
END''',
  '''
CREATE TRIGGER IF NOT EXISTS products_fts_au AFTER UPDATE OF name, salt, manufacturer_id, barcode, hsn, rack ON products BEGIN
  ${'DELETE FROM products_fts WHERE rowid = OLD.id;'}
  $_refresh WHERE p.id = NEW.id;
END''',
  '''
CREATE TRIGGER IF NOT EXISTS products_fts_ad AFTER DELETE ON products BEGIN
  DELETE FROM products_fts WHERE rowid = OLD.id;
END''',
  '''
CREATE TRIGGER IF NOT EXISTS batches_fts_ai AFTER INSERT ON batches BEGIN
  ${'DELETE FROM products_fts WHERE rowid = NEW.product_id;'}
  $_refresh WHERE p.id = NEW.product_id;
END''',
  '''
CREATE TRIGGER IF NOT EXISTS batches_fts_au AFTER UPDATE OF batch_no ON batches BEGIN
  ${'DELETE FROM products_fts WHERE rowid = NEW.product_id;'}
  $_refresh WHERE p.id = NEW.product_id;
END''',
  '''
CREATE TRIGGER IF NOT EXISTS batches_fts_ad AFTER DELETE ON batches BEGIN
  ${'DELETE FROM products_fts WHERE rowid = OLD.product_id;'}
  $_refresh WHERE p.id = OLD.product_id;
END''',
  '''
CREATE TRIGGER IF NOT EXISTS manufacturers_fts_au AFTER UPDATE OF name ON manufacturers BEGIN
  DELETE FROM products_fts WHERE rowid IN (SELECT id FROM products WHERE manufacturer_id = NEW.id);
  $_refresh WHERE p.manufacturer_id = NEW.id;
END''',
];

/// SPEC §3.3 indexes.
const List<String> indexStatements = [
  'CREATE INDEX IF NOT EXISTS idx_batches_product_expiry ON batches(product_id, expiry)',
  'CREATE INDEX IF NOT EXISTS idx_batches_expiry_instock ON batches(expiry) WHERE qty > 0',
  'CREATE INDEX IF NOT EXISTS idx_invoices_date_id ON invoices(sale_date, id)',
  'CREATE INDEX IF NOT EXISTS idx_invoices_phone ON invoices(customer_phone)',
  'CREATE INDEX IF NOT EXISTS idx_items_invoice ON invoice_items(invoice_id)',
  'CREATE INDEX IF NOT EXISTS idx_items_date_id ON invoice_items(sale_date, id)',
  'CREATE INDEX IF NOT EXISTS idx_items_product_date ON invoice_items(product_id, sale_date)',
  "CREATE INDEX IF NOT EXISTS idx_items_schedule_date ON invoice_items(schedule, sale_date) WHERE schedule <> ''",
  'CREATE INDEX IF NOT EXISTS idx_movements_batch_at ON stock_movements(batch_id, at)',
  'CREATE INDEX IF NOT EXISTS idx_customers_phone ON customers(phone)',
  'CREATE INDEX IF NOT EXISTS idx_products_category ON products(category)',
  'CREATE INDEX IF NOT EXISTS idx_products_manufacturer ON products(manufacturer_id)',
  ...purchaseIndexStatements,
  ...duesIndexStatements,
  ...returnsIndexStatements,
  ...creditIndexStatements,
  ...sourcesIndexStatements,
  ...cashIndexStatements,
  ...boxSizeIndexStatements,
];

/// v16: box size per stockist (SPEC §4.7) — a medicine's receipt lines.
const List<String> boxSizeIndexStatements = [
  'CREATE INDEX IF NOT EXISTS idx_receipt_lines_product_box ON receipt_lines(product_id, receipt_id) WHERE packs_per_box IS NOT NULL',
];

/// v14: day-end cash closing (SPEC §4.14) — the day's cash, by date.
const List<String> cashIndexStatements = [
  "CREATE INDEX IF NOT EXISTS idx_cash_cledger_payment ON customer_ledger(entry_date) WHERE kind = 'payment'",
  "CREATE INDEX IF NOT EXISTS idx_cash_sledger_payment ON supplier_ledger(entry_date) WHERE kind = 'payment'",
  'CREATE INDEX IF NOT EXISTS idx_cash_paidout_date ON cash_paid_out(entry_date)',
  'CREATE INDEX IF NOT EXISTS idx_cash_closings_date ON cash_closings(close_date, id)',
];

/// Stockist directory indexes (schema v8, SPEC §3.3).
const List<String> sourcesIndexStatements = [
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_sources_supplier_product ON product_sources(supplier_id, product_id) WHERE product_id IS NOT NULL',
  'CREATE INDEX IF NOT EXISTS idx_sources_product ON product_sources(product_id) WHERE product_id IS NOT NULL',
  'CREATE INDEX IF NOT EXISTS idx_sources_supplier_name ON product_sources(supplier_id, item_name COLLATE NOCASE)',
];

/// Customer credit indexes (schema v7, SPEC §3.3).
const List<String> creditIndexStatements = [
  'CREATE INDEX IF NOT EXISTS idx_cledger_customer_date ON customer_ledger(customer_id, entry_date, id)',
  'CREATE INDEX IF NOT EXISTS idx_cledger_invoice ON customer_ledger(invoice_id) WHERE invoice_id IS NOT NULL',
  "CREATE INDEX IF NOT EXISTS idx_cledger_open ON customer_ledger(customer_id, entry_date) WHERE status = 'active' AND open_paise > 0",
  'CREATE INDEX IF NOT EXISTS idx_calloc_debit ON customer_allocations(debit_id)',
  'CREATE INDEX IF NOT EXISTS idx_calloc_credit ON customer_allocations(credit_id)',
  'CREATE INDEX IF NOT EXISTS idx_customers_name ON customers(name COLLATE NOCASE)',
];

/// Sales returns indexes (schema v5, SPEC §3.3).
const List<String> returnsIndexStatements = [
  'CREATE INDEX IF NOT EXISTS idx_items_ref_item ON invoice_items(ref_item_id) WHERE ref_item_id IS NOT NULL',
  'CREATE INDEX IF NOT EXISTS idx_invoices_ref ON invoices(ref_invoice_id) WHERE ref_invoice_id IS NOT NULL',
];

/// Purchases indexes (schema v3, SPEC §3.3).
const List<String> purchaseIndexStatements = [
  'CREATE INDEX IF NOT EXISTS idx_order_lines_status_date ON order_lines(status, order_date)',
  'CREATE INDEX IF NOT EXISTS idx_order_lines_date_id ON order_lines(order_date, id)',
  'CREATE INDEX IF NOT EXISTS idx_receipt_lines_order ON receipt_lines(order_line_id)',
  'CREATE INDEX IF NOT EXISTS idx_receipt_lines_receipt ON receipt_lines(receipt_id)',
  'CREATE INDEX IF NOT EXISTS idx_receipts_date_id ON purchase_receipts(received_date, id)',
];

/// Stockist dues indexes (schema v4, SPEC §3.3).
const List<String> duesIndexStatements = [
  'CREATE INDEX IF NOT EXISTS idx_receipts_due ON purchase_receipts(due_date)',
  'CREATE INDEX IF NOT EXISTS idx_ledger_supplier_date ON supplier_ledger(supplier_id, entry_date, id)',
  'CREATE INDEX IF NOT EXISTS idx_alloc_debit ON ledger_allocations(debit_id)',
  'CREATE INDEX IF NOT EXISTS idx_alloc_credit ON ledger_allocations(credit_id)',
  "CREATE INDEX IF NOT EXISTS idx_ledger_open ON supplier_ledger(supplier_id, due_date) WHERE status = 'active' AND open_paise > 0",
];

/// Rebuilds the whole FTS index (after restore or bulk import).
const String ftsRebuild = 'DELETE FROM products_fts; $_refresh';

/// Turns free text into an FTS5 MATCH expression: every word becomes a
/// quoted prefix term, ANDed. `para 650` → `"para"* "650"*`.
/// Returns null when there is nothing searchable.
String? ftsQuery(String input) {
  final words = input
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return null;
  return words.map((w) => '"$w"*').join(' ');
}

/// Exposed for tests.
String refreshProductSql(String idExpr) => _refreshProduct(idExpr);
