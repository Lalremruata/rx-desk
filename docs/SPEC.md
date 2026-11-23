# RxDesk — Product & Technical Spec (Flutter)

Version 1.0 · Targets: Windows desktop (primary), Android tablet (secondary) · Offline only

Reference design: interactive prototype (Claude Design canvas) — source in
`design/rxdesk-design-reference.dc.html`, tokens in `design/tokens.json`.

---

## 1. Goals and scope

A pharmacist or cashier at the counter must be able to:

1. Bill a customer in seconds from the keyboard, barcode scanner or touch, picking the right batch.
2. See stock by batch and expiry, receive stock, and get warned before things run out or expire.
3. Print a correct GST tax invoice on A4, A5 or a thermal roll.
4. Look up any bill and any item sold, filter tens of thousands of lines, and export for GST filing.
5. Keep everything on the device, with backups they can take away and restore.

6. Keep a daily order book: what was ordered, and what each stockist actually supplied
   (invoice no, qty, amount), receiving it straight into batch stock (§4.7, §5.9).
7. Know what is owed to each stockist: bills, payments, credit notes and returns in one ledger
   per stockist, with credit days and overdue bills (§4.8, §5.9).
8. Take items back from a customer against their bill and issue a GST credit note, with stock,
   sales and GST reduced on the day of the return (§4.5, §5.4).
9. Sell tablets loose from a strip at pro-rata MRP, with stock kept by the tablet (§4.9).
10. Sell on credit (udhaar / khata) to regular customers: part payment at the counter, a credit
    limit the Owner can override, a ledger per customer with payments and statements, and
    returns adjusted in dues (§4.10, §5.10).
11. Know where to get each medicine — stockist, phone numbers and the company's MR — learned from
    invoices or imported from the store's "Damdawi lak na" sheet (§4.11, §5.9).
12. See each month's day-by-day consumption per medicine with reorder level, minimum and buffer
    stock (the store's "Inventory Management Register"), and apply the reorder levels (§4.12).
13. Correct the catalogue and stock: edit a medicine's details, fix a batch number or expiry, set
    a batch to the counted quantity with a reason, and hide medicines no longer sold (§4.13, §5.3).

Out of scope for v1: online sync, e-invoicing / IRN, sending orders to suppliers
electronically, purchase GST input-credit reports, interest on late payment,
loyalty points, multi-store. Keep the schema open for them (nullable FKs,
`store_id` not needed yet).

## 2. Navigation and layout

Sidebar order (matches prototype):

| # | Item | Route | Notes |
|---|---|---|---|
| 1 | Dashboard | `/dashboard` | |
| 2 | Billing | `/billing` | Badge: units in the current bill |
| 3 | Inventory | `/inventory` | Badge: low/out-of-stock count (hideable in settings) |
| 4 | Purchases | `/purchases` | Badge: open order lines (pending + part supplied) |
| 5 | Invoices | `/invoices` | |
| 6 | Sales register | `/register` | |
| 7 | Backup & restore | `/backup` | |
| 8 | Settings | `/settings/:tab` | Amber dot when there are unsaved settings |

Sidebar footer card: pulsing amber dot "Working offline", text "N medicines stored on this
device. Last backup: …", button "Back up now" → `/backup`.

Header (every screen): page title (Space Grotesk 26/700) + subtitle, chip "Local database",
date chip ("Mon, 9 Nov 2026"), primary button "New bill" → `/billing` with search focused.

**Responsive breakpoints**

| Width | Layout |
|---|---|
| ≥ 1100 | Full sidebar (236 px) + content |
| 760 – 1099 | Collapsed icon rail (72 px) with tooltips + content |
| < 760 | Top app bar + `NavigationBar` (5 items: Dashboard, Billing, Inventory, Invoices, More). "More" opens a sheet with Register, Backup, Settings |

Content max width: none (fluid). Card grids use `Wrap`/`LayoutBuilder` with min tile widths
from the prototype (`minmax(220px, 1fr)` → tiles ≥ 220 px).

Default start screen: Billing (configurable later).

## 3. Data model (Drift)

All money columns are `INTEGER` paise. All timestamps are UTC `INTEGER` epoch ms, plus a
local `sale_date TEXT 'YYYY-MM-DD'` where reports need day bucketing.
Expiry is stored as `TEXT 'YYYY-MM'` (pharma expiry is month-level; treat as last day of month).

### 3.1 Tables

```
manufacturers  id PK, name UNIQUE

products       id PK, name, salt, form, category, pack, manufacturer_id FK,
               schedule TEXT ('', 'H', 'H1', 'X'), hsn, gst_rate INT (0|5|12|18),
               mrp_paise INT (per pack), reorder_level INT (packs), rack, barcode UNIQUE NULL,
               units_per_pack INT DEFAULT 1                                     -- v6
               packs_per_box INT NULL  (strips in one stockist box; NULL = unknown) -- v11
               is_active BOOL, last_sold_at INT NULL, created_at, updated_at
               category ∈ Tablet | Capsule | Syrup | Injection | Topical | OTC

batches        id PK, product_id FK, batch_no, expiry TEXT 'YYYY-MM', qty INT,
               purchase_rate_paise INT NULL, created_at,
               mrp_paise INT (per pack, as printed on the batch)                -- v12
               UNIQUE(product_id, batch_no)

customers      id PK, name, phone NULL UNIQUE-ish (index), created_at
doctors        id PK, name, reg_no NULL

staff          id PK, name, role ('Owner'|'Pharmacist'|'Cashier'), pin_hash, pin_salt,
               active BOOL, created_at

invoice_seq    fy TEXT PK ('26-27'; 'all' without FY; credit notes 'CN:26-27' / 'CN:all'),
               last_seq INT

invoices       id PK, number TEXT UNIQUE, fy, seq INT, created_at INT, sale_date TEXT,
               customer_id NULL, customer_name, customer_phone NULL,
               doctor_name NULL, payment_mode ('Cash'|'UPI'|'Card'),
               discount_pct INT, subtotal_paise, discount_paise, taxable_paise,
               cgst_paise, sgst_paise, round_off_paise (signed), total_paise,
               staff_id FK, status ('paid'|'part_returned'|'returned'|'cancelled'), note NULL,
               gst_registered BOOL,
               discount_flat_paise INT NULL (flat ₹ bill discount; discount_pct
                 is then 0; NULL = percentage bill; credit notes NULL)          -- v10
               doc_type ('invoice'|'credit_note') DEFAULT 'invoice'              -- v5
               ref_invoice_id FK NULL (credit note → original invoice)          -- v5

invoice_items  id PK, invoice_id FK, sale_date TEXT (denormalised), line_no,
               product_id FK, batch_id FK,
               -- snapshots:
               product_name, salt, manufacturer, category, hsn, schedule,
               batch_no, expiry, mrp_paise, gst_rate,
               qty INT (units), pack_size INT DEFAULT 1 (snapshot)               -- v6
               gross_paise, discount_paise, taxable_paise, tax_paise, net_paise,
               payment_mode, doctor_name (denormalised for register filters),
               ref_item_id FK NULL (credit-note line → original line)           -- v5
               restocked BOOL NULL (credit-note lines: back to stock or written off) -- v5

stock_movements id PK, batch_id FK, delta INT, reason ('sale'|'receive'|'adjust'|'return'|
               'cancel'|'restore'|'opening'|'supplier_return'|'write_off'|'repack'), ref_type, ref_id,
               staff_id, at INT, note TEXT DEFAULT '' (v9: stock-correction reason)

daily_sales_summary  sale_date TEXT, product_id INT, units INT, bills INT, net_paise INT,
               tax_paise INT, PRIMARY KEY (sale_date, product_id)

settings       key TEXT PK, value TEXT (JSON)      -- see §7
backup_log     id PK, file_name, path, size_bytes, kind ('Manual'|'Auto'|'Safety'),
               encrypted BOOL, created_at, sha256 NULL                      -- v2

-- v3: purchases (§4.7)
suppliers      id PK, name UNIQUE COLLATE NOCASE, phone NULL, gstin NULL, created_at
order_lines    id PK, order_date TEXT 'YYYY-MM-DD', product_id FK NULL,
               item_name (snapshot, or free text when product_id is NULL),
               qty INT, unit TEXT, note TEXT, status ('pending'|'part'|'received'|'closed'|
               'cancelled'), staff_id NULL, created_at, updated_at
purchase_receipts id PK, supplier_id FK, invoice_no, received_date TEXT 'YYYY-MM-DD',
               total_paise INT, staff_id NULL, created_at   UNIQUE(supplier_id, invoice_no)
receipt_lines  id PK, receipt_id FK, line_no, order_line_id FK NULL, product_id FK,
               batch_id FK, item_name, batch_no, expiry (snapshots), qty INT, unit TEXT,
               stock_units INT, amount_paise INT,
               free_qty INT DEFAULT 0, rate_paise INT NULL, disc_bp INT DEFAULT 0,  -- v12
               gst_rate INT NULL, mrp_paise INT NULL (batch MRP snapshot)

-- v4: stockist dues (§4.8)
suppliers          + credit_days INT DEFAULT 30
purchase_receipts  + bill_total_paise INT (as billed — the payable), + due_date TEXT
supplier_ledger    id PK, supplier_id FK, entry_date TEXT, kind ('opening'|'bill'|'payment'|
                   'credit_note'|'return'), amount_paise INT (> 0; kind gives the sign),
                   open_paise INT (amount − allocations; 0 when void — kept in step in
                   the same transaction so dues read only open rows),
                   receipt_id FK NULL, due_date TEXT NULL, mode NULL ('Cash'|'UPI'|'Cheque'|
                   'NEFT'), reference TEXT, note TEXT, status ('active'|'void'), void_reason NULL,
                   staff_id NULL, created_at
ledger_allocations id PK, credit_id FK, debit_id FK, amount_paise INT
return_lines       id PK, ledger_id FK, product_id FK, batch_id FK, item_name, batch_no, expiry,
                   qty INT

-- v7: customer credit / udhaar (§4.10)
customers          + credit_limit_paise INT NULL (NULL = Settings default, 0 = no limit),
                   + address TEXT, + note TEXT
invoices           + paid_now_paise INT NULL, + dues_after_paise INT NULL (Credit bills only;
                   print snapshots)
customer_ledger    id PK, customer_id FK, entry_date TEXT, kind ('opening'|'bill'|'payment'|
                   'credit_note'), amount_paise INT (> 0; kind gives the sign), open_paise INT
                   (amount − allocations; 0 when void), invoice_id FK NULL (bill → its invoice;
                   credit_note → the credit note; payment taken with a bill → that bill),
                   mode NULL ('Cash'|'UPI'|'Card'), reference, note, status ('active'|'void'),
                   void_reason NULL, staff_id NULL, created_at
customer_allocations id PK, credit_id FK, debit_id FK, amount_paise INT

-- v8: stockist directory (§4.11)
suppliers          + other_phones TEXT ('' — "0389-2323442 / 9862958415"), + note TEXT
product_sources    id PK, supplier_id FK, product_id FK NULL (NULL = name not in the catalogue),
                   item_name, mr_name, mr_phone, note, origin ('import'|'manual'|'receipt'),
                   last_received TEXT NULL, created_at, updated_at

-- v9: editable inventory (§4.13)
stock_movements    + note TEXT DEFAULT '' ("Damaged: 2 strips crushed")
```

### 3.2 Full-text search

`products_fts` — FTS5 virtual table (`content=''`, contentless, or external-content on
products) with columns: `name, salt, manufacturer, barcode, batch_nos, hsn, rack`.
Keep it in sync with triggers on `products`, `batches`, `manufacturers`.
Use the `unicode61 remove_diacritics 2` tokenizer with `prefix='2 3 4'` for fast prefix search.

### 3.3 Indexes

```
batches(product_id, expiry)
batches(expiry) WHERE qty > 0
invoices(sale_date, id)
invoices(customer_phone)
invoice_items(invoice_id)
invoice_items(sale_date, id)
invoice_items(product_id, sale_date)
invoice_items(schedule, sale_date) WHERE schedule <> ''
stock_movements(batch_id, at)
order_lines(status, order_date)
order_lines(order_date, id)
receipt_lines(order_line_id)
receipt_lines(receipt_id)
purchase_receipts(received_date, id)
purchase_receipts(due_date)
supplier_ledger(supplier_id, entry_date, id)
supplier_ledger(supplier_id, due_date) WHERE status = 'active' AND open_paise > 0
ledger_allocations(debit_id)
ledger_allocations(credit_id)
invoice_items(ref_item_id) WHERE ref_item_id IS NOT NULL                    -- v5
invoices(ref_invoice_id) WHERE ref_invoice_id IS NOT NULL                   -- v5
customer_ledger(customer_id, entry_date, id)                                -- v7
customer_ledger(invoice_id) WHERE invoice_id IS NOT NULL                    -- v7
customer_ledger(customer_id, entry_date) WHERE status = 'active' AND open_paise > 0  -- v7
customer_allocations(debit_id), customer_allocations(credit_id)             -- v7
customers(name COLLATE NOCASE)                                              -- v7
product_sources(supplier_id, product_id) UNIQUE WHERE product_id IS NOT NULL -- v8
product_sources(product_id) WHERE product_id IS NOT NULL                    -- v8
product_sources(supplier_id, item_name COLLATE NOCASE)                      -- v8
```

### 3.4 Derived values (computed, not stored)

- **Saleable stock** of a product = Σ batch.qty where batch not expired.
- **Nearest expiry** = min expiry among batches with qty > 0 and not expired.
- **Low stock** = saleable ≤ reorder_level. **Out** = saleable = 0.
- **Expiring** = any batch with qty > 0 and months-left ≤ `expiryWindowMonths` (default 3).
- **Dead stock** = saleable > 0 and `last_sold_at` older than `deadStockDays` (default 90).

Expose these through a Drift view or a DAO query, so inventory lists don't compute them in Dart
for thousands of rows.

## 4. Business rules

### 4.1 GST maths (MRP is tax-inclusive)

For each line:

```
gross    = mrp × qty                                   // whole packs
gross    = floor(mrp × units ÷ units_per_pack)         // loose units (§4.9)
discount = round(gross × discount_pct / 100)          // bill-level %, applied per line
discount = share of a flat ₹ amount (§4.6)            // flat bills: by largest remainder
net      = gross − discount
taxable  = round(net × 100 / (100 + gst_rate))
tax      = net − taxable
```

Bill totals = sums of line values. `cgst = tax ÷ 2` (floor), `sgst = tax − cgst`.
If `roundOff` is on: `total = round(Σnet to nearest 100 paise)`, `round_off = total − Σnet`
(signed, shown as "Round off ±₹0.40"). Otherwise `total = Σnet`.

If the store is **not GST registered** (setting): print "BILL OF SUPPLY", hide taxable/CGST/SGST
and the GST column; still store tax as 0.

Intra-state only in v1 (CGST + SGST). Leave an `igst_paise` column nullable for later.

Unit tests must cover: 0/5/12/18 % rates, discounts 0–20 %, odd-paisa split, round-off both
directions, a 1-paisa line.

### 4.2 Invoice numbering

- Financial year runs 1 April – 31 March. FY label `'26-27'` for 1 Apr 2026 – 31 Mar 2027.
- Number = `prefix` + `sep` + (`fy` if `fyInNumber`) + `sep` + zero-padded `seq` (`digits`).
  Separator `/`, `-` or none. Examples: `INV/26-27/00412`, `INV-26-27-0412`, `INV00412`.
- `seq` comes from `invoice_seq` for the current FY, incremented **inside** the save
  transaction. Restarts at 1 each FY when the FY is part of the number; otherwise continues.
- Changing the format in settings only affects new bills.

Reference: `fmtNo()` in the prototype.

### 4.3 Batch selection (FEFO)

When a product is picked at billing:

1. Saleable batches = qty − qty already in this bill > 0, and not expired. Sort by expiry asc.
2. None, and saleable stock is 0 → show **substitutes**: other active products with the same
   `salt` (exact match on the normalised salt + strength string), saleable > 0, sorted by MRP asc,
   max 6.
3. Exactly one → add it directly.
4. More than one → open the **batch picker** with the first row highlighted and tagged
   "FEFO · sell first". Expired batches are listed at the bottom, greyed, tagged
   "Expired · blocked", not selectable.

Adding the same batch again increments qty, capped at the batch's qty (toast if capped).

### 4.4 Prescription rules

- If the bill contains any item with schedule `H` or `H1` and setting `requireDoctorForRx` is on,
  the doctor field turns required (label + red border) and saving is blocked with a toast.
- Schedule `X` is out of scope for v1: block sale with a message.
- The Sales register "Schedule H / H1 register" report lists date, bill no, patient name,
  doctor, medicine, batch, qty. Keep records for the legally required period (check current
  Drugs and Cosmetics Rules; H1 is commonly 3 years). Never auto-purge.

### 4.5 Stock

- **MRP is per batch** (v12). Batches of one medicine can carry different printed MRPs (price
  revisions); each sells at its own, and selling an old batch above its printed MRP is never
  possible. `products.mrp_paise` is the medicine's latest MRP: new batches start from it, and it
  **follows the newest batch** — receiving a new batch at a different MRP updates it (older
  batches keep theirs). One batch number has one MRP: receiving into an existing batch at a
  different MRP is refused ("needs its own batch number"). Billing search and Inventory show the
  MRP of the batch FEFO sells first, with an "N MRPs" hint when saleable batches differ; the
  batch picker shows each batch's MRP. Stock value = Σ qty × batch MRP. A batch with MRP 0
  (only possible in old test data) can't be billed.
- Receive stock: into an existing batch (adds qty) or a new batch (needs batch no + expiry +
  MRP, prefilled with the medicine's).
- Every change writes a `stock_movements` row. Saleable stock is always derivable from batches;
  movements are the audit trail.
- Cancelling an invoice restores stock to the same batches (`reason='cancel'`) and sets status.
  A bill with returns, and a credit note, can't be cancelled.

### 4.5a Sales returns (credit notes)

- A return is a **credit note** against one tax invoice: a row in `invoices` with
  `doc_type='credit_note'`, `ref_invoice_id` = the bill, and **negative** qty and amounts in
  `invoices` / `invoice_items`. Lines copy the original line's snapshot (rule 8) and set
  `ref_item_id`. `sale_date` is the **return day**: sales, GST, the register, the HSN summary,
  `daily_sales_summary` (units/net/tax down, bills unchanged) and the dashboard all fall on the
  day the credit note is issued; the original bill and the months already filed never change.
- Numbering: own gapless series per FY, `creditNotePrefix` + the invoice separator, digits and
  FY switch (`CN/26-27/00001`), assigned inside the save transaction from `invoice_seq` key
  `CN:<fy>`.
- Amounts: §4.1 maths on `mrp × qty returned` with the original bill's discount % (a flat-₹
  bill: the line's stored discount × qty returned ÷ qty sold, rounded); when a
  return takes a line's last units, each column is original − earlier returns, so a fully
  returned line reconciles to the paisa. Credit-note totals use the same CGST/SGST split
  (odd paisa on SGST) and round-off as bills. A bill of supply stays tax 0.
- Each line is either **back to stock** (`+qty` on the same batch, movement `return`) or
  **damaged** (movement `return` then `write_off`, so stock is unchanged and the audit trail
  shows both). `restocked` records which.
- Limits: qty ≤ sold − already returned; only tax invoices that are `paid` or `part_returned`;
  **Schedule H / H1 lines can't be returned**; bills older than `returnWindowDays` (0 = no
  limit) can only be returned by the Owner; permission `acceptReturns`.
- Status of the original: `part_returned`, or `returned` when every line is fully returned.
- Refund mode Cash / UPI / Card (defaults to the bill's) is stored in `payment_mode`; an
  optional reason in `note`. One Drift transaction for all of it (rule 3).

### 4.6 Discounts

- Bill-level percentage chips: 0, 5, 10, 15, 20, filtered to ≤ `maxDiscountPct` (setting),
  plus **Custom**: the cashier types either a whole % (0 … `maxDiscountPct`) or a flat ₹
  amount off the bill.
- A flat ₹ amount is split across the lines in proportion to their gross (MRP value):
  each line gets floor(amount × gross ÷ Σgross); the leftover paise go one each to the
  lines with the largest remainders (earlier line on a tie). The shares sum to the amount
  exactly; GST is then worked backwards per line as in §4.1.
- Limits apply to the effective %: a flat amount must be ≤ `maxDiscountPct` % of the MRP
  subtotal (integer check `amount × 100 ≤ max × subtotal`).
- Discounts above 5 % (effective, for ₹) need permission `giveHighDiscount` (staff roles, §7.6).
- The typed value shows its limit / effective % live and the problem inline; save refuses it.

### 4.7 Purchases (order book)

- An **order line** is one item ordered on a day: catalog product *or* free text, qty + pack
  unit (Box, Strip, Nos, Bottle, Vial, Amp, Tube, Pcs, Sachet) + optional note. The stockist
  is not chosen at order time — whoever supplies it is recorded on receipt.
- A **receipt** is one stockist invoice (stockist, invoice no, received date) with one or more
  lines. Each line: product, qty + unit received, batch no (existing or new), expiry (new batch
  only), **MRP** (new batch only, prefilled with the medicine's; §4.5), **stock units** (sale
  units added to the batch, prefilled from qty + free) and the amount as on the stockist's
  invoice. Lines need not come from an order (unordered extras).
- **Rate details** (v12, optional): **Free** qty (scheme goods, same unit; added to stock, no
  cost, not counted against the order), **Rate** per unit before GST (PTR), **Disc %** (up to two
  decimals, stored in basis points) and **GST %** (prefilled from the medicine). With a rate the
  amount is prefilled as rate × qty − disc + GST, each step rounded to the paisa, and stays
  editable to match their bill (a difference is shown).
- **Boxes → strips.** For a line in unit **Box** the line also asks *Strips per box* (packs per
  box; "Packs per box" for non-tablets), prefilled from `products.packs_per_box`. Stock units
  are prefilled as qty × strips per box (e.g. 10 Box × 15 = 150 strips) and stay editable; a
  Box line can't be saved without it (1–500). Saving the receipt stores the number on the
  medicine (same transaction) so the next Box receipt is prefilled. Other units are 1 pack
  each. It can also be set or corrected in Add / Edit medicine (blank = ask on receipt).
- Saving a receipt is **one transaction**: upsert stockist, insert receipt + lines, add stock
  per §4.5 (movement `reason='receive'`, `ref_type='purchase'`, `ref_id`=receipt), update
  order-line statuses. Duplicate (stockist, invoice no) is rejected.
- Expiry already past → blocked (rule: expired stock is never sold, so never received).
  Inside the expiry window → allowed with a warning.
- **Purchase amounts are stored as entered** (paise); the rate details only prefill them, and
  the bill total is still "as billed" (§4.8). No input-tax-credit reports (out of scope). For a
  new batch, `purchase_rate_paise` = amount ÷ stock units (free goods included), rounded to the
  paisa — the cost per unit.
- Order-line status: `cancelled` / `closed` are manual and final. Otherwise, from receipt lines
  in the **same unit**: none → `pending`, Σ qty < ordered → `part`, ≥ ordered → `received`
  (over-supply is allowed and shown as "Over"). A receipt in a different unit (ordered 1 Box,
  got 10 Strip) marks the line `received` unless "still expecting more" is ticked → `part`.
- `part` lines can be **closed short** (supplier won't send the rest); `pending` lines can be
  **cancelled**. Order lines and receipts are never hard-deleted.
- A free-text line must be linked to a catalog product (or a new medicine added) before it can
  be received; the link is saved on the order line. Add medicine opened from a receipt has no
  first batch / opening qty fields — the receipt line adds the stock (no double count).
- Permission: `changeStock` to place, receive, close or cancel. Everyone can view.

### 4.8 Stockist dues (ledger)

- One ledger per stockist. **Debits** (we owe more): `opening` balance, `bill` (one per received
  invoice, amount = the invoice's grand total *as billed*, which may differ from the sum of line
  amounts by GST / discount / round-off). **Credits** (we owe less): `payment` (Cash, UPI, Cheque,
  NEFT + reference), `credit_note`, `return` (stock sent back). Amounts are entered as printed on
  the stockist's documents — **no GST maths**.
- Balance = Σ active debits − Σ active credits; negative = advance with the stockist.
- Credits are **allocated** to debits: oldest due date first, or only the bills the user ticks.
  Whatever is left stays on account and is applied (oldest credit first) to the next debit.
  Debit outstanding = amount − allocations; bill status Paid / Part paid / Unpaid.
- Due date = received date + the stockist's credit days (default 30, editable per bill).
  **Overdue** = outstanding > 0 and due date before today.
- Opening balance: one active entry per stockist; to change it, void and re-enter.
- **Returns to stockist**: lines pick a batch and qty; batch qty decreases (movement
  `reason='supplier_return'`, `ref_type='supplier_ledger'`). Qty can't exceed the batch's qty,
  whatever `allowNegativeStock` says. Expired batches can be returned.
- Mistakes: payments, credit notes and opening balances can be **voided** with a reason (the row
  stays, its allocations are released and other credit re-applied). Bills and returns can't be
  voided (they moved stock). Nothing is hard-deleted.
- Every ledger write (with its allocations and stock changes) is one transaction.
- Permission `supplierPayments` ("Record supplier payments", Owner only by default) for payments,
  credit notes, opening balances, voids, stockist terms and pay-on-delivery. Returns also need
  `changeStock`. Everyone can view dues.

### 4.9 Loose selling (tablets from a strip)

- Every quantity in the database is in the **smallest unit**: batch qty, stock movements, bill
  and credit-note lines, receipt stock units, returns to stockist. `products.units_per_pack`
  says how many make a pack (strip); 1 = sold whole only. MRP stays **per pack**;
  `reorder_level` stays **in packs** (low = saleable ≤ reorder_level × units_per_pack).
- Price of a loose quantity = `floor(MRP × units ÷ units_per_pack)` to the paisa — never above
  pro-rata MRP; a whole number of packs is exact. Discount, GST and round-off then work as in
  §4.1. Bill lines snapshot `pack_size` (rule 8), so returns and reports keep the size they
  were sold at.
- Any product with `units_per_pack` > 1 can be sold loose. New products: Add medicine has
  "Tablets per strip" (prefilled from "Strip of 10" for tablets / capsules); opening qty and
  reorder level are typed in strips. Existing products start at 1 — nothing changes until the
  owner sets a size (Inventory › batches › "Sell loose…"). Changing the size converts each
  batch's whole packs (12 strips × 10 = 120 tabs) with a `repack` movement and rescales the
  purchase rate; it is refused while any batch holds loose units. Permission `changeStock`.
- Billing: a loose-sellable line starts as 1 strip (or loose if less than a strip is left) and
  shows a **Strip | Tab** switch next to qty (also `S` / `T` in the qty field). Strip → Tab keeps
  the tablets; Tab → Strip rounds down to whole strips (at least 1). Qty is capped at the batch.
- Display: "12 strips + 4 tabs" (inventory, receive, returns); compact "1 + 5 tab" on invoices,
  the register and pickers (a plain number = whole packs, since MRP is per pack). Receiving
  (Inventory and Purchases) is typed in strips. Capsules say "caps"; other categories
  "packs" / "units".
- `daily_sales_summary.units` and register unit totals are in units; quick-add ranks by
  units ÷ units_per_pack.

### 4.10 Customer credit (udhaar)

- Bills get a fourth payment mode, **Credit** (F8 cycles Cash → UPI → Card → Credit). A Credit
  bill needs a customer name (not "Walk-in") and phone; the phone finds or creates the customer.
  The bill itself is an ordinary tax invoice — GST, stock, the register and the daily summary
  count it on the bill date like any other sale.
- **Paid now**: part of a Credit bill can be paid at the counter (Cash / UPI / Card); it must be
  less than the bill total (all of it = not a Credit bill). The bill is a ledger **debit** of the
  full total and paid-now is a **payment** applied to that bill first.
- **Ledger** per customer, like the stockist ledger (§4.8) with the signs reversed: debits
  `opening` (dues before RxDesk; one active per customer), `bill`; credits `payment`,
  `credit_note`. Dues = Σ open debits − Σ open credits (negative = advance). Credits are
  allocated oldest bill first, or only the ticked bills; what's left stays as an advance and
  pays the next bill. `open_paise` is kept in step in every transaction.
- **Credit limit**: the customer's own (`credit_limit_paise`; 0 = none) or the Settings default
  (`defaultCreditLimitPaise`; 0 = none). If dues + (total − paid now) would exceed it, saving is
  **blocked** — checked inside the save transaction. The Owner can allow that bill: an Owner at
  the counter confirms; anyone else needs an active Owner's PIN.
- **Cancel** a Credit bill: its debit and its paid-now payment are voided (the money goes back,
  as with a cash bill); other payments are re-applied to the remaining bills or kept as advance.
- **Returns** (§4.5a): refund mode **Adjust in dues** (stored as `Credit`) is offered when the
  bill has a customer and is the default for Credit bills; Cash / UPI / Card stay available. The
  credit note becomes a `credit_note` ledger credit, applied to the original bill first, then the
  oldest dues.
- **Voids**: payments (not ones taken with a bill — cancel the bill) and opening dues can be
  voided with a reason; the row stays, allocations are released and credit re-applied. Bills and
  credit notes can't be voided (they are GST documents).
- **Aging** of a customer's dues = age of the oldest open debit: 0–30, 31–60, 61–90, 90+ days.
- Permissions: `sellOnCredit` (bill on Credit), `collectPayments` (receive payments, add / edit
  customers), `manageCustomerCredit` (credit limits, opening dues, voids).
- Printing: a Credit bill shows "Payment: Credit" and "Paid ₹X · Balance ₹Y · Total dues ₹Z"
  (from the invoice snapshots); a credit note adjusted in dues shows "Refund: Adjusted in dues".

### 4.11 Stockist directory ("Damdawi lak na")

- `product_sources` says which stockist(s) a medicine comes from, with the company's MR (name,
  phone) and a note. A line is linked to a catalogue product, or kept as free text (a name not
  in the catalogue yet). One line per (stockist, product); one per (stockist, name) for text.
- **Learned from invoices**: receiving a stockist invoice adds / updates (stockist, product)
  with `last_received` (the later date wins), linking a matching free-text line instead of
  adding a second one. The v8 migration fills it from past receipts.
- **Import** of the store's sheet (Sl.No · Dawr Hming · Damdawi hming · Phone numb · MR Hming):
  the header row is found by those names; the stockist and phone cells are filled only on some
  rows, so each row belongs to the stockist above it and the phone numbers in its block
  ("9862958415", "or", "0389-2323442") are that stockist's — the first becomes `phone`, the
  rest `other_phones`. Medicine names are matched to the catalogue after dropping form words
  (Tab./Syp./Syr./Cap./Inj./Susp./Syrup/Tablet…), punctuation and spacing: an exact match, or a
  single catalogue name that only adds a strength, links automatically; the rest are reviewed
  (link to a medicine, keep as text — the default — or skip). Stockists are matched by name
  (case-insensitive) or added. Re-importing adds nothing twice and only appends new numbers.
  The workbook is read from its XML directly (the `excel` package rejects files that redefine
  built-in number formats, which Excel writes).
- Directory lines aren't records and can be removed. Edits need `changeStock`.

### 4.12 Monthly consumption register

The store's "Inventory Management Register" sheet, computed from `daily_sales_summary` (units
net of returns, by day; current product names). For each medicine in a month:
- Total = Σ daily; **Average daily = total ÷ days with sales** (the sheet's Excel `AVERAGE`
  skips blank days); Max daily = the largest day.
- Reorder level = max daily × `maxLeadTimeDays`; Minimum stock = reorder level − average daily ×
  `avgLeadTimeDays`; Buffer stock = (max daily − average daily) × `avgLeadTimeDays`.
- A month without sales is all zeros (never `#DIV/0!`). Quantities are tablets for medicines sold
  loose, else packs; the figures are decimals of quantities, never money.
- Suggested reorder level (packs) = ⌈reorder level ÷ units_per_pack⌉. "Apply" (permission
  `changeStock`) sets `reorder_level` for the ticked medicines in one transaction.

### 4.13 Editing inventory

All of these need `changeStock` and run in one transaction each.
- **Edit medicine**: every Add-medicine field except the first batch and units per pack (that
  stays with "Sell loose…", §4.9). Same validation; the barcode may not belong to another
  medicine. Saved bills keep their snapshots (rule 8); a new GST rate / HSN applies to new
  bills only. Search follows the change (FTS triggers). The MRP field is the **MRP for new
  batches**; when it changes, a toggle (on by default) "Also change the N batches at ₹old"
  reprices batches still at the old MRP — for fixing a wrong MRP. Off: batches on the shelf
  keep their printed MRP.
- **Price changed during a bill**: each bill line sends the MRP and GST rate the counter showed.
  If the batch's MRP or the medicine's GST changed since, saving is refused (`priceChanged`,
  keyed by batch), the bill's lines take the current MRP / GST, and the cashier checks the new
  total and saves again — the amount collected always equals the amount saved.
- **Edit batch**: batch number (upper-cased, unique per medicine), **MRP** (to fix a typo; writes
  a zero-quantity `mrp` movement "MRP ₹old → ₹new"), expiry, and the quantity
  counted on the shelf. **An expired batch's expiry can't be changed** (rule 5: expired stock
  can never be sold); its quantity can still be corrected (e.g. to 0 when disposed of).
  A quantity change needs a reason — Count correction, Damaged, Lost / theft, Other (Other needs
  a note) — and writes an `adjust` movement for the difference with `note` = "Reason[: note]".
  The counted quantity is never negative, whatever `allowNegativeStock` says.
- **Hide medicine** (`is_active = 0`): it leaves search, billing, the stock views, low-stock /
  expiry counts and stock value; nothing is deleted. Inventory's **Hidden** view lists hidden
  medicines with **Unhide**. Billing a hidden medicine is refused (`inactiveProduct`).

## 5. Screens

Copy, layout and states follow the prototype. Highlights:

### 5.1 Dashboard

- KPI row (4 tiles, min 220 px): Today's sales (₹, "N invoices · avg ₹X"), Stock value
  (Σ saleable × MRP), Low/out of stock (tap → Inventory "Low stock", sorted by stock asc),
  Expiring ≤ N days (tap → Inventory "Expiring", sorted by expiry asc).
- Sales overview bar chart: segmented 7D / 30D / 12M. Reads `daily_sales_summary`
  (never raw lines). Last bar = today (accent colour), others accent at 42 %. Hover/long-press
  tooltip "Mon 3 Nov · ₹6,120". Y axis 4 dashed gridlines with short labels (₹8k, ₹2.5L).
  Header shows Total · Avg · Peak.
- Sales by category: donut of this month's net by category; hovering a legend row dims the
  other slices and shows the % in the centre (centre default = month total, "Sales this month").
- Bottom row: Reorder soon (top 4 by stock/reorder ratio, progress bars), Expiring batches
  (top 4, red badge ≤ 1 month, amber otherwise), Recent invoices (5, tap → invoice), Stockist
  dues (total owed, overdue, top 4 stockists by overdue; tap → Purchases › Dues).

### 5.2 Billing (keyboard-first)

Layout: left 3/5 (search, quick add, bill grid, shortcut hints), right 2/5 "Bill details".

- **Search box** (autofocus on open, 56 px tall, F3 focuses). Debounce 120 ms, FTS5 query with
  prefix tokens, AND across words, limit 12. Rank: name starts with first token → salt starts
  with first token → others; in-stock before out-of-stock; then shorter name.
  Header line "Top 12 of 86 matches — keep typing to narrow" and "Searched 1,649 items in 3.2 ms".
- Exact barcode match (scanner input ends with Enter) selects immediately.
- Result row: name + Rx badge (H/H1), "salt · maker · pack", rack, stock (green number,
  amber "N left" when low, red "Out"), MRP.
- Keys in the list: ↑ ↓ move, Enter select, Esc closes the batch picker / substitutes,
  or clears the query.
- **Quick add** chips: 8 most-sold items in the last 30 days (from summary table).
- **Bill grid** columns: # · Item (name, Rx badge, salt · maker) · Batch · Exp (amber when
  ≤ window) · Qty (number field, 1…batch qty) · MRP · Amount · delete. New rows slide in;
  the row just added flashes amber for 1.4 s. Empty state: "Bill is empty".
- **Bill details**: customer name (F4 focuses), phone, doctor (becomes required with Rx items),
  discount chips + Custom (% / ₹ field, §4.6), totals card (items/units, subtotal, discount, taxable, CGST+SGST incl.,
  net payable 26 px), payment mode (Cash / UPI / Card, F8 cycles), primary
  "Save & print invoice  F10".
- Shortcuts (window-level `Shortcuts` scoped to the billing route, not global OS hooks):
  F2 new bill · F3 search · F4 customer · F8 payment mode · F10 save & print · Esc close list.
- After save: toast "INV/26-27/00412 saved · ₹1,234.00 · printing 1 copy", navigate to
  Invoices with that bill selected, reset bill to defaults (payment = default mode).

### 5.3 Inventory

- Saved-view tabs with counts: All · Low stock · Expiring ≤ Nd · Out of stock · Dead stock.
- Toolbar: search (name, salt, batch, barcode, HSN) · Category · Maker · Export · Add medicine.
- Grid columns: expand chevron · Medicine (name, Rx badge, "salt · pack · N batches") · Maker ·
  Category · Nearest expiry (red ≤ 1 mo, amber ≤ window) · Saleable stock (bar + number) ·
  MRP · Rack · Status badge · "Receive".
- Sortable: Medicine, Nearest expiry, Saleable stock, MRP (toggle asc/desc, arrow shown).
- Pagination: 25 / 50 / 100 rows, page numbers with ellipsis, "1–50 of 1,649".
  Implement with SQL `LIMIT/OFFSET` here (≤ few thousand rows is fine) **or** keyset.
- Expanded row: batch table (Batch · Expiry · Qty · MRP · Note: "Sell first (FEFO)",
  "Near expiry", "Expired · return to supplier", "Sold out", "OK"), then barcode, HSN, GST,
  reorder level, last sold.
- Dialogs: **Add medicine** (name, salt, maker, pack, category, schedule, barcode, first batch,
  expiry month, opening qty, reorder level, MRP incl. GST, GST rate, rack, strips per box) and
  **Receive stock** (batch no — existing or new, expiry for new, qty, quick +10/25/50/100).
- Editing (§4.13, permission `changeStock`): the expanded row has **Edit medicine** and
  **Hide medicine** buttons and an edit icon on every batch row. **Edit batch** dialog: batch
  no., expiry (locked with a note when expired), counted quantity (strips + loose tabs for
  medicines sold loose), a "Stock 40 → 36 (−4)" preview, reason pills + note when the quantity
  changes, and the batch's 5 most recent stock movements. Hiding asks for confirmation and says
  how much stock remains. A **Hidden** tab (with count) appears once something is hidden; its
  rows show a "Hidden" badge and **Unhide** in place of Receive.

### 5.4 Invoices

- Left list: date presets (Today, Yesterday, Last 7 days, This month, Last month), search
  (bill no, customer, phone), payment filter, "N bills · range · Total ₹X", 30 per page with
  "‹ Newer / Older ›" (keyset on `(sale_date, id)`).
- Right: invoice preview identical to the printed layout (§6) + Print, Download PDF.
  Cancel bill (permission `editBills`; only `paid` bills with no returns).
  **Return items** (permission `acceptReturns`; disabled with a tooltip outside the return window
  unless Owner): one row per line — sold, already returned, a − / + qty stepper, "Damaged — don't
  restock"; H/H1 lines locked "Rx — can't return"; refund mode pills, optional reason, live refund
  total (units · taxable · GST · round off); **Save & print credit note** (prints when `autoPrint`).
  The list badges credit notes, "Part returned" and "Returned"; the preview links a bill to its
  credit notes and a credit note back to its bill. The list total is net of refunds.
- Credit note print: title "CREDIT NOTE", "Against INV/… · date" under the number, "Refund"
  instead of "Payment", amounts positive, no UPI QR or "You saved".

### 5.5 Sales register

One row per item sold. Defaults to **This month**.

- Saved reports (one click): Daily sales · Top sellers this month · GST summary by HSN
  (last month) · Schedule H / H1 register · Maker-wise sales (FY).
- Date presets: Today, Yesterday, Last 7 days, This month, Last month, This FY, Custom (from/to).
- Filters: search (medicine, salt, batch, bill no, customer), maker, category, schedule
  (All, H+H1, H, H1, Non-Rx), payment, doctor. "Clear filters".
- Group by: none (lines) · day · medicine · maker · category · HSN + rate · GST rate ·
  payment · doctor.
- Totals bar for the **whole filtered set**: bills, units, gross, discount, taxable, CGST,
  SGST, net. One aggregate SQL query (`SUM`, `COUNT(DISTINCT invoice_id)`).
- Lines view columns: Date·time · Bill no (link) · Medicine (+ salt, Rx badge) · Maker · Batch ·
  Qty · MRP · Disc · Taxable · GST% · Net. Sort: date, qty, net.
- Grouped view columns: Group · Bills · Units · Gross · Taxable · GST · Net · Share bar + %.
  Sort: group key, units, net.
- Paging: 50 rows, keyset for lines; grouped results are small enough for LIMIT/OFFSET.
- Footer: "1–50 of 23,914 item lines · computed in 18.4 ms".
- **Export Excel**: exactly what's on screen (filters + grouping) with a totals row and a
  header block (store name, GSTIN, range). Write in an isolate.

**Inventory Management Register** (`/register/consumption`, permission `viewReports`; from the
saved-reports row and Inventory): month ‹ ›, search, Sold this month | All medicines. Grid with
the medicine name fixed and days 1–N · Total · Avg/day · Max/day · Reorder · Min stock · Buffer ·
Stock now · Reorder now · Suggested scrolling sideways; tick boxes + "Apply N reorder levels".
50 per page. Export to Excel in the sheet's layout (header block with lead times, store and
month; S.No · Name of Medicine · 1–31 · the six figures; blank cells for days without sales;
day totals row).

### 5.6 Backup & restore

- Status tiles: Storage "On this device", Records "N medicines · N invoices", Last backup.
- **Export**: progress bar, file `rxdesk-backup-YYYY-MM-DD-HHMM.rxbak`; "Encrypt with password"
  switch (on by default; when off the zip is stored unencrypted, same extension).
- **Import**: pick file → confirm dialog ("will replace current data; a safety copy is saved
  first") → progress → app restarts the DB connection.
- **Automatic backup**: switch, Daily / Weekly / Monthly, folder (default
  `Documents/RxDesk/Backups`), keep latest 30. Runs on app close and at first launch of the day
  if overdue (no background service needed).
- History table: file, created, size, type (Manual / Auto / Safety), Restore.

**Backup file format** (`.rxbak` = zip):

```
manifest.json   { app: "RxDesk", schemaVersion, createdAt, counts{products,batches,invoices,items},
                  encrypted: bool, kdf: {alg:"PBKDF2-SHA256", iterations, salt}, sha256 }
db.sqlite       // from `VACUUM INTO` — consistent snapshot while the app runs
                // (db.sqlite.enc when encrypted: AES-256-GCM, nonce in manifest)
```

Restore checks: manifest present, `schemaVersion` ≤ current (run migrations after restore),
SHA-256 matches, password correct. Always write a Safety backup first.

### 5.7 Settings

Draft-and-save: edits go to a draft; a dark sticky bar slides up — "N unsaved changes — the rest
of the app updates when you save" · Discard · Save changes. Sidebar shows an amber dot while dirty.
The brand colour previews live while on Settings.

Tabs: Store profile · Invoice · Billing & tax · Inventory · Staff & roles · Appearance. Fields and
defaults in §7. The Invoice tab has a **live preview** on the right that re-renders the sample
bill with the draft settings and animates width when paper size changes. "Test print" prints the
sample.

### 5.8 Staff login (phase 9)

- First run: create Owner (name + 4-digit PIN).
- Lock screen with staff tiles + PIN pad (also keyboard digits). Auto-lock after N minutes idle
  (setting, default 15). Bills record `staff_id`.

### 5.9 Purchases

- KPI row: Open lines (pending + part) · Received this month (₹) · Owed to stockists (₹, caption
  overdue → Dues) · Short this month (lines closed short or still part).
- Tabs (SegmentedPills): **Pending · Order book · Receipts · Dues**.
  - *Pending*: open lines oldest first — Order date · Item · Ordered · Received · Due · Status ·
    actions (Receive, Close short / Cancel). Tick lines → "Receive selected" opens one receipt
    with those lines. Keyset paged on `(order_date, id)`.
  - *Order book*: one day at a time (‹ prev / date / next ›), the spreadsheet's columns:
    S/N · Date of order · Item · Qty · Stockist · Received · Inv. no · Qty received · Amount,
    day Total. Short lines tagged "Short", over-supplied "Over", unsupplied "Pending".
    Export the day or the month to Excel in the same layout.
  - *Receipts*: one row per stockist invoice (Date · Stockist · Invoice no · Lines · Bill total ·
    Due · Outstanding · status), newest first, search by stockist / invoice no; expand to see
    its lines.
  - *Dues*: one row per stockist (Stockist · Credit days · Open bills · Outstanding · Overdue ·
    Oldest due · Pay · Statement), most overdue first, search by name.
  - *Statement* (dialog): balance / overdue / advance, terms (edit), opening balance; ledger rows
    Date · Type · Ref · Debit · Credit · Balance (keyset paged), void action; actions Record
    payment, Return / credit note; export to Excel.
  - *Record payment*: date, amount, mode, reference, note; open bills with tick boxes and a live
    allocation preview (oldest first or ticked only) and what stays on account.
  - *Return / credit note*: date, credit note no, amount; for a return, lines (medicine → batch
    with stock → qty).
- Receive invoice also has: Invoice total (as billed, prefilled with Σ lines, difference shown),
  Due date, and Paid now (amount, mode, reference — needs `supplierPayments`).
- Toolbar: **New order** (date, lines by catalog search or free text, qty + unit, note; "Add
  low-stock items" pre-fills from reorder-soon) and **Receive invoice** (empty receipt).
- *Stockists* tab (§4.11): Medicine (badge "Not in catalogue") · Stockist + phones · MR · Last
  received · Source (Imported / Added / From invoices) · edit, stockist phones, remove; search
  (medicine, stockist, MR, phone), stockist filter, keyset paged. **Add**, **Import from Excel**
  (review dialog: counts, Not in catalogue / Found / All, per row Linked · Text · Skip and "link
  to a medicine", Skip all not found / Keep all), **Export** in the sheet's layout.
- Pending lines show "Get from <stockist> · <phone>"; Inventory's batch panel lists "Get from"
  (stockist · phones · MR · last received).

### 5.10 Customers

- Sidebar item after Invoices (in "More" on compact widths).
- KPI row: Customer dues (₹) · Customers with dues · Unpaid 90+ days (₹, customers).
- Toolbar: search (name or phone), **With dues | All customers**, Add customer, Export dues
  (Excel / CSV).
- List (50 per page): Customer (open bills / advance) · Phone · Dues · Oldest unpaid (aging badge)
  · Limit · Last payment · Receive / Statement. With dues: largest first; all: by name.
- *Statement* (dialog): dues, advance, open bills, aging, limit; actions Receive payment, Edit,
  Opening dues, **Print statement** (A4 PDF), Export; ledger rows Date · Type · Reference · Debit ·
  Credit · Balance (keyset paged) with void.
- *Receive payment*: date, amount ("All dues"), mode, reference, note; open bills with tick boxes
  and a live allocation preview; what stays as advance.
- Billing (§5.2): choosing Credit marks Customer and Phone required and shows a credit box — who
  it is and what they owe, the limit, Paid now (+ mode), "Adds ₹X to dues → ₹Y" and an over-limit
  warning.
- Dashboard: a "Customer dues" card (total, 90+ days, top 4 → statement).

## 6. Invoice layout and printing

Built once as a **pure function** `InvoiceDocument build(InvoiceData, Settings, PaperSize)`
that produces a `pw.Document` (PDF). The on-screen preview renders the same PDF with
`PdfPreview` **or** a matching Flutter widget fed by the same view-model. Reference: `invView()`.

Header: logo / initials tile (accent) · store name · address (line1, line2, city, state – PIN) ·
"Ph …, email" · "GSTIN … · DL 20B … · 21B …"; right: "TAX INVOICE" / "BILL OF SUPPLY",
number, date · time. Info strip: Billed to · Prescribed by (if enabled and present) · Payment.

Item table columns, by setting and paper:

| Column | A4 | A5 | Roll 80 | Roll 58 |
|---|---|---|---|---|
| # · Item · Qty · MRP · Amount | ✓ | ✓ | ✓ | ✓ |
| Salt under item | setting | setting | setting | setting |
| Batch | setting | setting | — | — |
| Expiry | setting | setting | setting | — |
| HSN | setting | setting | — | — |
| GST % | if registered | if registered | — | — |

Totals: Subtotal (MRP), Discount, Taxable, CGST, SGST (if registered), Round off (if on),
Grand total. "You saved ₹X on MRP" pill when discount > 0 and enabled. UPI QR (if enabled):
real QR from `upi://pay?pa=<upi>&pn=<store>&am=<total>&cu=INR` using `barcode` / `qr` package.
Footer note (pre-line, ≤ 240 chars) and signature block: line, signature label
(+ pharmacist name and reg. no. when set), "for <store name>".

Paper: A4 (210 mm), A5 (148 mm), roll 80 mm (72 mm printable), roll 58 mm (48 mm printable).
Use `PdfPageFormat.roll80` / `roll57` for thermal; let the Windows printer driver handle it.
Copies 1–3. "Print automatically on save" uses `Printing.directPrintPdf` with the saved default
printer (pick it once in Settings › Invoice).

## 7. Settings (keys, defaults)

Stored as JSON in `settings` and exposed via a typed `AppSettings` freezed class.

### 7.1 Store profile
`name` "[Your Pharmacy Name]" · `legalName` · `phone` · `email` · `addr1` · `addr2` · `city` ·
`state` · `pin` (6 digits) · `gstin` (15 chars, uppercase, validate format) · `dl20b` · `dl21b` ·
`pharmacistName` · `pharmacistRegNo` · `logoPath` (copied into app data dir).

### 7.2 Invoice
`prefix` "INV" (A–Z0–9, ≤ 8) · `separator` "/" | "-" | "none" · `digits` 4|5|6 (5) ·
`fyInNumber` true · `paper` A4|A5|T80|T58 (A4) · `copies` 1–3 (1) · `autoPrint` true ·
`defaultPrinter` · `showSalt` false · `showBatch` true · `showExpiry` true · `showHsn` false ·
`showDoctor` true · `showSaved` true · `showUpiQr` true · `upiId` · `footer` (default
"Prices are MRP inclusive of GST. Goods once sold will not be taken back without the bill.
Get well soon.") · `signatureLabel` "Registered Pharmacist".

### 7.3 Billing & tax
`gstRegistered` true · `mrpIncludesGst` true (locked) · `roundOff` true · `maxDiscountPct` 15 ·
`defaultPayment` Cash · `requireDoctorForRx` true · `blockExpired` true (locked) ·
`allowNegativeStock` false · `creditNotePrefix` "CN" (A–Z0–9, ≤ 8, required, ≠ `prefix`) ·
`returnWindowDays` 7|15|30|90|0 (30; 0 = no limit) · `defaultCreditLimitPaise` (0 = no limit;
typed in whole rupees).

### 7.4 Inventory
`expiryWindowMonths` 1|2|3|6 (3) · `deadStockDays` 60|90|180 (90) · `defaultReorderLevel` 20 ·
`suggestFefo` true · `showLowStockBadge` true · `avgLeadTimeDays` 1 · `maxLeadTimeDays` 2
(1–60, max ≥ average; consumption register §4.12).

### 7.5 Appearance
`accent` Teal #0F766E | Blue #2563EB | Violet #7C3AED | Cyan #0E7490 | Rose #BE123C |
Slate #334155 · `showKeyHints` true · `autoLockMinutes` 15.

### 7.6 Staff & permissions
Roles: Owner (all, locked), Pharmacist, Cashier. Permissions and defaults
(Pharmacist / Cashier): sell Schedule H/H1 (✓/✗), give > 5 % discount (✓/✗),
edit or cancel bills (✓/✗), change stock/prices/batches (✓/✗), see register & reports (✓/✗),
export/restore backups (✗/✗), change settings (✗/✗). Purchases (place, receive, close,
cancel) use "change stock/prices/batches". Record supplier payments (✗/✗) covers payments,
credit notes, opening balances, voids and stockist terms; returns to stockist need it and
"change stock". Accept returns / issue credit notes (✓/✗); the return window can be overridden
by the Owner only. Sell on credit (✓/✗), collect customer payments (✓/✓), set credit limits /
opening dues / void payments (✗/✗); a bill over a credit limit needs the Owner (PIN).
"Reset to defaults" restores §7 defaults but never touches data or staff.

## 8. Design system

Tokens are in `design/tokens.json`; generate `core/theme/tokens.dart` from it (by hand is fine).

**Colour**: background #F3F5F8 · surface #FFFFFF · border #E5EAF0 · divider #F1F4F8 ·
input border #D7DEE6 · text #0F172A · text-secondary #5B6472 · text-muted #64748B ·
label #475569 · accent (setting) · accentSoft = 12 % accent over white.
Status: warning bg #FEF3C7 / fg #92400E · danger #FEE2E2 / #B91C1C · success #D1FAE5 / #047857 ·
info #E0E7FF / #4338CA · Rx badge #FFE4E6 / #9F1239 · neutral chip #F1F4F8 / #475569.
Toast: #0F172A with success icon #10B981 or warning icon #D97706.
Category chart colours: Tablets #0F766E, Capsules #5EEAD4, Syrups #D97706, Injections #4338CA,
OTC #F9A8D4, Topical #94A3B8.

**Type**: Inter 400/500/600/700 body 14; Space Grotesk 500/600/700 for headings and numbers.
Page title 26/700, card title 17/600, KPI 28/700, totals 26/700, labels 12/600, captions 12/400,
badges 11/700. Monospace (batch, bill no): platform mono.

**Shape & spacing**: card radius 16 · input/button radius 10 · small radius 6–8 · pill 999.
Card padding 18–22 · page padding 22×28 · gaps 8 / 10 / 12 / 14 / 16 / 20.
Control min height 44 (search 56, primary CTA 52). Sidebar 236.

**Shared widgets** (`core/widgets`): `AppCard`, `KpiTile` (tap-able variant),
`SegmentedPills`, `FilterChipRow`, `ToggleRow` (label + help + switch), `StatusBadge`,
`RxBadge`, `StockBar`, `DataGrid` (header + rows, horizontal scroll under min width),
`Pager`, `AppToast` (overlay, queue, 2.8 s), `ConfirmDialog`, `PageEnter`
(fade + rise, staggered children), `KeyHint` (kbd chip), `EmptyState`.

## 9. Motion

Use `flutter_animate` or implicit animations; curve = `Cubic(0.2, 0.8, 0.2, 1)` ("emphasised").

| Element | Animation |
|---|---|
| Screen enter | fade 0→1 + translateY 12→0, 500 ms; child cards stagger 50 ms |
| Card / KPI hover (desktop) | translateY −2, shadow `0 14 34 −16 rgba(15,23,42,.22)`, 250 ms |
| Button press | scale 0.97, 150 ms |
| Chart bars | grow from 0 height, 700 ms, stagger 50 ms (15 ms on 30-day view); height changes animate 550 ms |
| Search dropdown | fade + translateY −6→0, 180 ms |
| New bill line | slide in from x +18, 320 ms; amber #FEF3C7 flash fading over 1.4 s |
| Inventory row expand | chevron rotates 90°, 200 ms; batch panel fades + drops in, 220 ms |
| Dialog | barrier fade 200 ms; panel scale 0.95→1 + translateY 10→0, 320 ms |
| Toast | slide up 24 px + scale 0.97→1, 380 ms; auto-dismiss 2.8 s |
| Switch knob | 250 ms emphasised |
| Progress bars | width tween 180 ms linear |
| Offline dot / unsaved dot | pulsing ring, 2.2 s loop |
| Invoice preview paper change | max-width tween 350 ms |

All of the above are skipped or shortened to ≤ 1 frame when animations are disabled.

## 10. Performance budgets (with seed data)

Seed (debug only, `--dart-define=SEED=true`): ~1,600 products (16 makers × ~110 variants),
1–3 batches each, 11 months of sales (~12k bills / ~25k lines). For perf tests also a
**100k-line** seed.

| Action | Budget (mid-range Windows PC) |
|---|---|
| Billing search keystroke → results | < 30 ms query, < 1 frame render |
| Save bill (transaction) | < 50 ms |
| Inventory page (50 rows, any filter/sort) | < 50 ms |
| Sales register FY totals + first page, 100k lines | < 150 ms |
| Dashboard load | < 100 ms (summary table only) |
| Backup of 100k-line DB | < 3 s, off the UI isolate |

Heavy work (export, backup, restore, seed) runs in a background isolate. Drift: use
`driftDatabase(native: DriftNativeOptions(shareAcrossIsolates: true))` or a background
connection.

## 11. Testing

- **Unit**: GST maths (§4.1 cases), numbering + FY rollover (31 Mar → 1 Apr), FEFO selection,
  substitute matching, search ranking, settings serialisation, backup manifest/crypto round trip.
- **DAO** (in-memory Drift): save-bill transaction (stock, movements, summary, sequence),
  cancel restores stock, receive into new/existing batch, register aggregates equal sum of lines.
- **Migration**: each schema version → next, with data.
- **Widget**: billing keyboard flow (type → ↓ → Enter → batch picker → Enter → F10),
  Rx doctor required, settings draft/save/discard.
- **Perf** (`test/perf`, tagged): budgets in §10 on the 100k seed.

## 12. Legal / compliance notes (verify before release)

Not legal advice — confirm with a CA / the State Drugs Control office:
GST tax-invoice mandatory fields; HSN digits required for your turnover; Schedule H/H1 register
fields and retention; drug licence numbers on bills; pharmacist details. Keep these
configurable rather than hardcoded.
