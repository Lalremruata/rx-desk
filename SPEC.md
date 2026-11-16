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

Out of scope for v1: online sync, e-invoicing / IRN, purchase orders to suppliers, supplier
credit ledgers, loyalty points, multi-store. Keep the schema open for them (nullable FKs,
`store_id` not needed yet).

## 2. Navigation and layout

Sidebar order (matches prototype):

| # | Item | Route | Notes |
|---|---|---|---|
| 1 | Dashboard | `/dashboard` | |
| 2 | Billing | `/billing` | Badge: units in the current bill |
| 3 | Inventory | `/inventory` | Badge: low/out-of-stock count (hideable in settings) |
| 4 | Invoices | `/invoices` | |
| 5 | Sales register | `/register` | |
| 6 | Backup & restore | `/backup` | |
| 7 | Settings | `/settings/:tab` | Amber dot when there are unsaved settings |

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
               mrp_paise INT, reorder_level INT, rack, barcode UNIQUE NULL,
               is_active BOOL, last_sold_at INT NULL, created_at, updated_at
               category ∈ Tablet | Capsule | Syrup | Injection | Topical | OTC

batches        id PK, product_id FK, batch_no, expiry TEXT 'YYYY-MM', qty INT,
               purchase_rate_paise INT NULL, created_at
               UNIQUE(product_id, batch_no)

customers      id PK, name, phone NULL UNIQUE-ish (index), created_at
doctors        id PK, name, reg_no NULL

staff          id PK, name, role ('Owner'|'Pharmacist'|'Cashier'), pin_hash, pin_salt,
               active BOOL, created_at

invoice_seq    fy TEXT PK ('26-27'), last_seq INT

invoices       id PK, number TEXT UNIQUE, fy, seq INT, created_at INT, sale_date TEXT,
               customer_id NULL, customer_name, customer_phone NULL,
               doctor_name NULL, payment_mode ('Cash'|'UPI'|'Card'),
               discount_pct INT, subtotal_paise, discount_paise, taxable_paise,
               cgst_paise, sgst_paise, round_off_paise (signed), total_paise,
               staff_id FK, status ('paid'|'cancelled'|'returned'), note NULL

invoice_items  id PK, invoice_id FK, sale_date TEXT (denormalised), line_no,
               product_id FK, batch_id FK,
               -- snapshots:
               product_name, salt, manufacturer, category, hsn, schedule,
               batch_no, expiry, mrp_paise, gst_rate,
               qty INT, gross_paise, discount_paise, taxable_paise, tax_paise, net_paise,
               payment_mode, doctor_name (denormalised for register filters)

stock_movements id PK, batch_id FK, delta INT, reason ('sale'|'receive'|'adjust'|'return'|
               'cancel'|'restore'|'opening'), ref_type, ref_id, staff_id, at INT

daily_sales_summary  sale_date TEXT, product_id INT, units INT, bills INT, net_paise INT,
               tax_paise INT, PRIMARY KEY (sale_date, product_id)

settings       key TEXT PK, value TEXT (JSON)      -- see §7
backup_log     id PK, file_name, path, size_bytes, kind ('Manual'|'Auto'|'Safety'),
               encrypted BOOL, created_at
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
gross    = mrp × qty
discount = round(gross × discount_pct / 100)          // bill-level %, applied per line
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

- Receive stock: into an existing batch (adds qty) or a new batch (needs batch no + expiry).
- Every change writes a `stock_movements` row. Saleable stock is always derivable from batches;
  movements are the audit trail.
- Cancelling an invoice restores stock to the same batches (`reason='cancel'`) and sets status.
- Returns (v1.1): partial return creates a negative invoice line set; keep the model ready.

### 4.6 Discounts

- Bill-level percentage chips: 0, 5, 10, 15, 20, filtered to ≤ `maxDiscountPct` (setting).
- Discounts above 5 % need permission `giveHighDiscount` (staff roles, §7.6).

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
  (top 4, red badge ≤ 1 month, amber otherwise), Recent invoices (5, tap → invoice).

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
  discount chips, totals card (items/units, subtotal, discount, taxable, CGST+SGST incl.,
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
  expiry month, opening qty, reorder level, MRP incl. GST, GST rate, rack) and
  **Receive stock** (batch no — existing or new, expiry for new, qty, quick +10/25/50/100).

### 5.4 Invoices

- Left list: date presets (Today, Yesterday, Last 7 days, This month, Last month), search
  (bill no, customer, phone), payment filter, "N bills · range · Total ₹X", 30 per page with
  "‹ Newer / Older ›" (keyset on `(sale_date, id)`).
- Right: invoice preview identical to the printed layout (§6) + Print, Download PDF.
  v1.1: Cancel bill (permission `editBills`), Return items.

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
`allowNegativeStock` false.

### 7.4 Inventory
`expiryWindowMonths` 1|2|3|6 (3) · `deadStockDays` 60|90|180 (90) · `defaultReorderLevel` 20 ·
`suggestFefo` true · `showLowStockBadge` true.

### 7.5 Appearance
`accent` Teal #0F766E | Blue #2563EB | Violet #7C3AED | Cyan #0E7490 | Rose #BE123C |
Slate #334155 · `showKeyHints` true · `autoLockMinutes` 15.

### 7.6 Staff & permissions
Roles: Owner (all, locked), Pharmacist, Cashier. Permissions and defaults
(Pharmacist / Cashier): sell Schedule H/H1 (✓/✗), give > 5 % discount (✓/✗),
edit or cancel bills (✓/✗), change stock/prices/batches (✓/✗), see register & reports (✓/✗),
export/restore backups (✗/✗), change settings (✗/✗).
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
