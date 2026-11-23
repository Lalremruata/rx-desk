import 'package:drift/drift.dart';

// SPEC §3.1. Money is INTEGER paise; timestamps are UTC epoch ms; sale_date
// is the local 'YYYY-MM-DD'; expiry is 'YYYY-MM'.

class Manufacturers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
}

class Products extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get salt => text().withDefault(const Constant(''))();

  /// Dosage form as sold: Tablet, Capsule, Syrup, Cream…
  TextColumn get form => text().withDefault(const Constant(''))();

  /// Tablet | Capsule | Syrup | Injection | Topical | OTC
  TextColumn get category => text()();
  TextColumn get pack => text().withDefault(const Constant(''))();

  /// v6: units (tablets) in one pack (strip). Stock, bill and movement
  /// quantities are in these units; MRP is per pack. 1 = not sold loose.
  IntColumn get unitsPerPack => integer().withDefault(const Constant(1))();

  /// v11: packs (strips) in one stockist box, for receiving "10 Box".
  /// Null = not known yet (asked on the receive line, then remembered).
  IntColumn get packsPerBox => integer().nullable()();
  IntColumn get manufacturerId => integer().references(Manufacturers, #id)();

  /// '' | 'H' | 'H1' | 'X'
  TextColumn get schedule => text().withDefault(const Constant(''))();
  TextColumn get hsn => text().withDefault(const Constant(''))();

  /// 0 | 5 | 12 | 18
  IntColumn get gstRate => integer()();
  IntColumn get mrpPaise => integer()();
  /// In packs (strips), not units.
  IntColumn get reorderLevel => integer().withDefault(const Constant(20))();
  TextColumn get rack => text().withDefault(const Constant(''))();
  TextColumn get barcode => text().nullable().unique()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  IntColumn get lastSoldAt => integer().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
}

@DataClassName('StockBatch')
class Batches extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productId => integer().references(Products, #id)();
  TextColumn get batchNo => text()();
  TextColumn get expiry => text()();
  IntColumn get qty => integer()();
  IntColumn get purchaseRatePaise => integer().nullable()();

  /// v12: the MRP printed on this batch, per pack (SPEC §4.5). Batches of one
  /// medicine can carry different MRPs; each sells at its own. Set on every
  /// insert (0 only in old test fixtures; billing refuses it).
  IntColumn get mrpPaise => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {productId, batchNo},
      ];
}

class Customers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
  IntColumn get createdAt => integer()();

  /// v7: credit limit for udhaar (SPEC §4.10); null = the Settings default,
  /// 0 = no limit.
  IntColumn get creditLimitPaise => integer().nullable()();
  TextColumn get address => text().withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();

  /// v15: GSTIN of a business customer (clinic, hospital) for B2B bills.
  TextColumn get gstin => text().nullable()();
}

class Doctors extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get regNo => text().nullable()();
}

@DataClassName('StaffMember')
class Staff extends Table {
  @override
  String get tableName => 'staff';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();

  /// 'Owner' | 'Pharmacist' | 'Cashier'
  TextColumn get role => text()();
  TextColumn get pinHash => text()();
  TextColumn get pinSalt => text()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  IntColumn get createdAt => integer()();
}

@DataClassName('InvoiceSeqRow')
class InvoiceSeq extends Table {
  @override
  String get tableName => 'invoice_seq';

  /// FY label ('26-27'), or 'all' when the FY isn't part of the number.
  TextColumn get fy => text()();
  IntColumn get lastSeq => integer()();

  @override
  Set<Column> get primaryKey => {fy};
}

class Invoices extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get number => text().unique()();
  TextColumn get fy => text()();
  IntColumn get seq => integer()();
  IntColumn get createdAt => integer()();
  TextColumn get saleDate => text()();
  IntColumn get customerId => integer().nullable().references(Customers, #id)();
  TextColumn get customerName => text()();
  TextColumn get customerPhone => text().nullable()();
  TextColumn get doctorName => text().nullable()();

  /// 'Cash' | 'UPI' | 'Card'
  TextColumn get paymentMode => text()();
  IntColumn get discountPct => integer()();

  /// v10: a flat ₹ bill discount (SPEC §4.6), split across the lines by
  /// MRP value; [discountPct] is then 0. Null = percentage discount.
  IntColumn get discountFlatPaise => integer().nullable()();
  IntColumn get subtotalPaise => integer()();
  IntColumn get discountPaise => integer()();
  IntColumn get taxablePaise => integer()();
  IntColumn get cgstPaise => integer()();
  IntColumn get sgstPaise => integer()();

  /// Inter-state, for later (v1 is intra-state only).
  IntColumn get igstPaise => integer().nullable()();
  IntColumn get roundOffPaise => integer()();
  IntColumn get totalPaise => integer()();
  IntColumn get staffId => integer().nullable().references(Staff, #id)();

  /// Invoice: 'paid' | 'part_returned' | 'returned' | 'cancelled'.
  /// Credit note: 'paid' (issued).
  TextColumn get status => text().withDefault(const Constant('paid'))();
  TextColumn get note => text().nullable()();

  /// Bill of supply (store not GST registered at time of sale).
  BoolColumn get gstRegistered => boolean().withDefault(const Constant(true))();

  /// v5: 'invoice' | 'credit_note'. A credit note (sales return) stores
  /// negative amounts and is dated on the return day (SPEC §4.5).
  TextColumn get docType => text().withDefault(const Constant('invoice'))();

  /// v5: credit note → the invoice it returns against.
  IntColumn get refInvoiceId => integer().nullable().references(Invoices, #id)();

  /// v7, Credit bills only (SPEC §4.10): paid at the counter, and the
  /// customer's total dues right after this bill — snapshots for printing.
  IntColumn get paidNowPaise => integer().nullable()();
  IntColumn get duesAfterPaise => integer().nullable()();

  /// v15: B2B bills (SPEC §4.15) — the buyer's GSTIN and the place of
  /// supply (state code) as billed. Null = B2C. Credit notes copy them.
  TextColumn get buyerGstin => text().nullable()();
  TextColumn get placeOfSupply => text().nullable()();
}

class InvoiceItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get invoiceId => integer().references(Invoices, #id)();
  TextColumn get saleDate => text()();
  IntColumn get lineNo => integer()();
  IntColumn get productId => integer().references(Products, #id)();
  IntColumn get batchId => integer().references(Batches, #id)();
  // Snapshots (CLAUDE.md rule 8).
  TextColumn get productName => text()();
  TextColumn get salt => text()();
  TextColumn get manufacturer => text()();
  TextColumn get category => text()();
  TextColumn get hsn => text()();
  TextColumn get schedule => text()();
  TextColumn get batchNo => text()();
  TextColumn get expiry => text()();
  IntColumn get mrpPaise => integer()();
  IntColumn get gstRate => integer()();

  /// In units; with [packSize] > 1 a loose sale (MRP is per pack).
  IntColumn get qty => integer()();

  /// v6 snapshot: units per pack when sold (1 = whole packs only).
  IntColumn get packSize => integer().withDefault(const Constant(1))();
  IntColumn get grossPaise => integer()();
  IntColumn get discountPaise => integer()();
  IntColumn get taxablePaise => integer()();
  IntColumn get taxPaise => integer()();
  IntColumn get netPaise => integer()();
  // Denormalised for register filters.
  TextColumn get paymentMode => text()();
  TextColumn get doctorName => text().nullable()();

  /// v5: credit note line → the original invoice line it returns.
  IntColumn get refItemId => integer().nullable().references(InvoiceItems, #id)();

  /// v5: credit note lines only — true when the units went back into stock,
  /// false when written off as damaged.
  BoolColumn get restocked => boolean().nullable()();
}

class StockMovements extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get batchId => integer().references(Batches, #id)();
  IntColumn get delta => integer()();

  /// 'sale' | 'receive' | 'adjust' | 'return' | 'cancel' | 'restore' | 'opening' | 'supplier_return'
  /// | 'write_off' (v5: damaged sales return) | 'repack' (v6: units-per-pack change)
  TextColumn get reason => text()();
  TextColumn get refType => text().nullable()();
  IntColumn get refId => integer().nullable()();
  IntColumn get staffId => integer().nullable()();
  IntColumn get at => integer()();

  /// v9: why a manual correction was made — "Damaged: 2 strips broken".
  TextColumn get note => text().withDefault(const Constant(''))();
}

@DataClassName('DailySale')
class DailySalesSummary extends Table {
  @override
  String get tableName => 'daily_sales_summary';

  TextColumn get saleDate => text()();
  IntColumn get productId => integer()();
  IntColumn get units => integer()();
  IntColumn get bills => integer()();
  IntColumn get netPaise => integer()();
  IntColumn get taxPaise => integer()();

  @override
  Set<Column> get primaryKey => {saleDate, productId};
}

@DataClassName('SettingRow')
class SettingsEntries extends Table {
  @override
  String get tableName => 'settings';

  TextColumn get key => text()();

  /// JSON-encoded value.
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DataClassName('BackupEntry')
class BackupLog extends Table {
  @override
  String get tableName => 'backup_log';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get fileName => text()();
  TextColumn get path => text()();
  IntColumn get sizeBytes => integer()();

  /// 'Manual' | 'Auto' | 'Safety'
  TextColumn get kind => text()();
  BoolColumn get encrypted => boolean()();
  IntColumn get createdAt => integer()();

  /// SHA-256 of the backed-up database (schema v2).
  TextColumn get sha256 => text().nullable()();
}

// ---------------------------------------------------------------------------
// Purchases (SPEC §4.7, schema v3).

/// Stockists / distributors who supply the store.
class Suppliers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().customConstraint('NOT NULL UNIQUE COLLATE NOCASE')();
  TextColumn get phone => text().nullable()();
  TextColumn get gstin => text().nullable()();
  IntColumn get createdAt => integer()();

  /// Credit terms: bills fall due this many days after receipt (v4).
  IntColumn get creditDays => integer().withDefault(const Constant(30))();

  /// v8 (SPEC §4.11): more numbers ("0389-2323442 / 9862958415"), note.
  TextColumn get otherPhones => text().withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();
}

/// One item ordered on a day. The stockist is only known on receipt.
class OrderLines extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get orderDate => text()();

  /// Null for a free-text line not yet linked to a product.
  IntColumn get productId => integer().nullable().references(Products, #id)();

  /// Product name snapshot, or the free text.
  TextColumn get itemName => text()();
  IntColumn get qty => integer()();
  TextColumn get unit => text()();
  TextColumn get note => text().withDefault(const Constant(''))();

  /// 'pending' | 'part' | 'received' | 'closed' | 'cancelled'
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get staffId => integer().nullable().references(Staff, #id)();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
}

/// One stockist invoice received.
class PurchaseReceipts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get supplierId => integer().references(Suppliers, #id)();
  TextColumn get invoiceNo => text()();
  TextColumn get receivedDate => text()();

  /// Σ line amounts.
  IntColumn get totalPaise => integer()();

  /// Grand total as billed by the stockist — what is owed (v4).
  IntColumn get billTotalPaise => integer().withDefault(const Constant(0))();

  /// 'YYYY-MM-DD' (v4).
  TextColumn get dueDate => text().withDefault(const Constant(''))();
  IntColumn get staffId => integer().nullable().references(Staff, #id)();
  IntColumn get createdAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {supplierId, invoiceNo},
      ];
}

/// One line of a stockist invoice, received into a batch.
class ReceiptLines extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get receiptId => integer().references(PurchaseReceipts, #id)();
  IntColumn get lineNo => integer()();
  IntColumn get orderLineId => integer().nullable().references(OrderLines, #id)();
  IntColumn get productId => integer().references(Products, #id)();
  IntColumn get batchId => integer().references(Batches, #id)();
  // Snapshots.
  TextColumn get itemName => text()();
  TextColumn get batchNo => text()();
  TextColumn get expiry => text()();

  /// Received, in [unit] (as on the stockist's invoice).
  IntColumn get qty => integer()();
  TextColumn get unit => text()();

  /// Sale units added to the batch.
  IntColumn get stockUnits => integer()();

  /// Line amount as on the stockist's invoice: worked out from rate, disc
  /// and GST when given (SPEC §4.7), but stored as entered.
  IntColumn get amountPaise => integer()();

  /// v12 (SPEC §4.7): free / scheme quantity in [unit] (stock, no cost).
  IntColumn get freeQty => integer().withDefault(const Constant(0))();

  /// v12: rate per [unit] before discount and GST (PTR). Null = not given.
  IntColumn get ratePaise => integer().nullable()();

  /// v12: trade discount in basis points (7.5 % = 750).
  IntColumn get discBp => integer().withDefault(const Constant(0))();

  /// v12: GST % on the stockist's line. Null = not given.
  IntColumn get gstRate => integer().nullable()();

  /// v12: the batch's MRP at receipt (snapshot).
  IntColumn get mrpPaise => integer().nullable()();
}

// ---------------------------------------------------------------------------
// Stockist dues (SPEC §4.8, schema v4).

/// One entry in a stockist's ledger. Debits: 'opening', 'bill'. Credits:
/// 'payment', 'credit_note', 'return'. [amountPaise] is always > 0.
@DataClassName('LedgerEntry')
class SupplierLedger extends Table {
  @override
  String get tableName => 'supplier_ledger';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get supplierId => integer().references(Suppliers, #id)();
  TextColumn get entryDate => text()();
  TextColumn get kind => text()();
  IntColumn get amountPaise => integer()();

  /// Still owed (debits) / not yet applied (credits): amount − allocations;
  /// 0 once void. Kept in step with ledger_allocations in each transaction.
  IntColumn get openPaise => integer().withDefault(const Constant(0))();
  IntColumn get receiptId => integer().nullable().references(PurchaseReceipts, #id)();

  /// Debits only.
  TextColumn get dueDate => text().nullable()();

  /// Payments: 'Cash' | 'UPI' | 'Cheque' | 'NEFT'.
  TextColumn get mode => text().nullable()();

  /// Cheque no, UTR, credit note no…
  TextColumn get reference => text().withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();

  /// 'active' | 'void'
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get voidReason => text().nullable()();
  IntColumn get staffId => integer().nullable().references(Staff, #id)();
  IntColumn get createdAt => integer()();
}

/// How much of a credit entry pays off a debit entry.
class LedgerAllocations extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get creditId => integer().references(SupplierLedger, #id)();
  IntColumn get debitId => integer().references(SupplierLedger, #id)();
  IntColumn get amountPaise => integer()();
}

/// Stock sent back to a stockist on a 'return' ledger entry.
class ReturnLines extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get ledgerId => integer().references(SupplierLedger, #id)();
  IntColumn get productId => integer().references(Products, #id)();
  IntColumn get batchId => integer().references(Batches, #id)();
  TextColumn get itemName => text()();
  TextColumn get batchNo => text()();
  TextColumn get expiry => text()();
  IntColumn get qty => integer()();
}

// ---------------------------------------------------------------------------
// v7: customer credit (udhaar), SPEC §4.10.

/// One ledger per customer. Debits (customer owes more): opening, bill.
/// Credits (owes less): payment, credit_note.
class CustomerLedger extends Table {
  @override
  String get tableName => 'customer_ledger';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get customerId => integer().references(Customers, #id)();
  TextColumn get entryDate => text()();

  /// 'opening' | 'bill' | 'payment' | 'credit_note'
  TextColumn get kind => text()();

  /// > 0; [kind] gives the sign.
  IntColumn get amountPaise => integer()();

  /// amount − allocations; 0 once void. Kept in step with
  /// customer_allocations in each transaction.
  IntColumn get openPaise => integer().withDefault(const Constant(0))();

  /// bill → its invoice; credit_note → the credit note; payment taken at
  /// the counter → the bill it came with.
  IntColumn get invoiceId => integer().nullable().references(Invoices, #id)();

  /// Payments: 'Cash' | 'UPI' | 'Card'.
  TextColumn get mode => text().nullable()();
  TextColumn get reference => text().withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();

  /// 'active' | 'void'
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get voidReason => text().nullable()();
  IntColumn get staffId => integer().nullable().references(Staff, #id)();
  IntColumn get createdAt => integer()();
}

/// How much of a customer credit pays off a customer debit.
class CustomerAllocations extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get creditId => integer().references(CustomerLedger, #id)();
  IntColumn get debitId => integer().references(CustomerLedger, #id)();
  IntColumn get amountPaise => integer()();
}

// ---------------------------------------------------------------------------
// v8: stockist directory, "where to get this medicine" (SPEC §4.11).

/// A medicine (or a free-text name) and a stockist it comes from, with the
/// company's MR. Learned from receipts, imported, or added by hand.
class ProductSources extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get supplierId => integer().references(Suppliers, #id)();

  /// Null = a name not (yet) linked to the catalogue.
  IntColumn get productId => integer().nullable().references(Products, #id)();

  /// Product name when linked, else the text as written.
  TextColumn get itemName => text()();
  TextColumn get mrName => text().withDefault(const Constant(''))();
  TextColumn get mrPhone => text().withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();

  /// 'import' | 'manual' | 'receipt'
  TextColumn get origin => text()();

  /// Last stockist invoice with this medicine ('YYYY-MM-DD').
  TextColumn get lastReceived => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
}

/// v13: bills parked at the counter (SPEC §5.2 "Hold"). Not invoices — no
/// number, no stock taken; deleted when recalled or discarded.
class HeldBills extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The customer, else "Walk-in · first item".
  TextColumn get label => text()();

  /// JSON of HeldBillData (lines, customer, discount, payment).
  TextColumn get payload => text()();
  IntColumn get itemCount => integer()();

  /// Net payable when held (for the list only; recomputed on recall).
  IntColumn get totalPaise => integer()();
  IntColumn get staffId => integer().nullable().references(Staff, #id)();
  IntColumn get heldAt => integer()();
}

/// v14: cash paid out of the drawer for shop expenses (SPEC §4.14). Never
/// deleted — a mistake is voided with a reason.
class CashPaidOuts extends Table {
  @override
  String get tableName => 'cash_paid_out';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get entryDate => text()();
  IntColumn get amountPaise => integer()();

  /// What it was for ("Tea", "Auto fare").
  TextColumn get note => text()();

  /// 'active' | 'void'
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get voidReason => text().nullable()();
  IntColumn get staffId => integer().nullable().references(Staff, #id)();
  IntColumn get createdAt => integer()();
}

/// v14: a day's cash closing (SPEC §4.14). Closing again adds a row; the
/// latest row for a date is the closing, earlier ones are history. Figures
/// are snapshots of what RxDesk knew at closing time.
class CashClosings extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get closeDate => text()();
  IntColumn get openingPaise => integer()();
  IntColumn get cashSalesPaise => integer()();
  IntColumn get cashRefundsPaise => integer()();
  IntColumn get duesCollectedPaise => integer()();
  IntColumn get stockistsPaidPaise => integer()();
  IntColumn get paidOutsPaise => integer()();
  IntColumn get expectedPaise => integer()();
  IntColumn get countedPaise => integer()();

  /// counted − expected (negative = short).
  IntColumn get differencePaise => integer()();

  /// Taken out of the drawer after counting (to the bank / the Owner).
  IntColumn get handedOverPaise => integer().withDefault(const Constant(0))();
  TextColumn get note => text().withDefault(const Constant(''))();
  IntColumn get staffId => integer().nullable().references(Staff, #id)();
  IntColumn get closedAt => integer()();
}
