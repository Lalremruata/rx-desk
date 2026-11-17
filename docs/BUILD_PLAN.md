# RxDesk — Build plan for Claude Code

Work through the phases in order, **one phase per Claude Code session**. Each phase has a
prompt you can paste as-is, and acceptance criteria Claude Code must check before saying done.

Before phase 0, put these in the repo:

```
CLAUDE.md
docs/SPEC.md
docs/BUILD_PLAN.md
design/rxdesk-design-reference.dc.html
design/tokens.json
```

Tip: start each session with `/clear`, then paste the phase prompt. Use plan mode
(Shift+Tab) for phases 1, 4 and 6 so you can review the plan before code is written.

---

## Phase 0 — Scaffold, theme, shell

**Prompt**

> Read CLAUDE.md, docs/SPEC.md §2, §8, §9 and design/tokens.json.
> Create the Flutter app `rxdesk` (org `in.rxdesk`, platforms windows + android).
> Add the stack packages from CLAUDE.md with `flutter pub add`. Bundle Inter and Space Grotesk
> as font assets. Set up the folder structure from CLAUDE.md, `analysis_options.yaml` with strict
> lints, `core/theme/tokens.dart` + `app_theme.dart` (accent comes from a provider, default
> #0F766E), go_router with a ShellRoute, and the responsive shell (sidebar ≥1100, rail 760–1099,
> bottom bar <760) with the 7 nav items, header, offline footer card and a toast host.
> Build the shared widgets in SPEC §8 with a `/_gallery` debug route that shows each one.
> Placeholder screens for every route. Window min size 1100×700 on Windows.

**Done when**: app runs on Windows and Android; nav works at all three widths; gallery shows
every shared widget; screen-enter, hover-lift and press animations match SPEC §9; analyze clean.

---

## Phase 1 — Database, money, seed

**Prompt**

> Implement SPEC §3 in Drift: all tables, indexes, the FTS5 table with sync triggers, and the
> derived-stock view/queries in §3.4. Add `core/money` (Paise extension type, en_IN formatting,
> GST line maths per SPEC §4.1) and `core/fy` (FY label, invoice number formatter per §4.2).
> Write DAOs per feature. Add a debug seed (`--dart-define=SEED=true`) that generates the
> catalogue and 11 months of sales like the prototype's `curated()`, `genCatalog()` and
> `genHistory()` — but writes through the same save-bill code path so summaries and sequences
> are correct. Add a `PERF_SEED=100k` variant.
> Unit-test money, FY numbering and GST with the cases in SPEC §4.1 and §11.

**Done when**: tests green; seed runs in < 30 s on desktop; FTS returns results for
"para 650", "amoxi", a barcode and a batch number.

---

## Phase 2 — Settings

**Prompt**

> Build Settings per SPEC §5.7 and §7: typed `AppSettings` (freezed) stored in the settings
> table, a `settingsProvider`, and the draft/save/discard flow with the sticky unsaved bar and
> sidebar dot. Six tabs exactly as in the prototype (read the Settings section of
> design/rxdesk-design-reference.dc.html for copy and layout). Accent previews live while on
> Settings. GSTIN and PIN validation. Logo picker copies the file into the app data folder.
> The Invoice tab preview can be a placeholder until phase 5 — leave a clear TODO.

**Done when**: every field persists across restarts; Discard reverts; Reset to defaults
works without touching data; widget test covers draft → save → discard.

---

## Phase 3 — Inventory

**Prompt**

> Build Inventory per SPEC §5.3 with saved-view tabs + counts, search via FTS, category and
> maker filters, sortable columns, pagination 25/50/100, expandable batch rows, and the
> Add medicine and Receive stock dialogs. All counts and the page come from SQL, not Dart loops.
> Every stock change writes `stock_movements`.

**Done when**: with the seed, any filter/sort/page change renders in < 50 ms; receive into a
new and an existing batch both work; DAO tests for receive + movements.

---

## Phase 4 — Billing (POS)

**Prompt**

> Build Billing per SPEC §5.2 and rules §4.1, §4.3, §4.4, §4.6. Keyboard-first: autofocus
> search, ↑ ↓ Enter Esc in the results, batch picker with FEFO and blocked expired batches,
> substitutes for out-of-stock, barcode exact match, quick-add chips, editable qty grid,
> discount chips limited by settings, doctor required for H/H1, payment modes,
> F2/F3/F4/F8/F10 via Shortcuts/Actions scoped to this route. Saving is one Drift transaction
> (CLAUDE.md rule 3) and assigns the invoice number. Port behaviour from the prototype's
> `search`, `selectProduct`, `validBatches`, `subsFor`, `addLine`, `checkout`.

**Done when**: the widget test "type → ↓ → Enter → batch → Enter → F10" passes; DAO test
proves stock, movements, summary and sequence update atomically; Rx rule blocks saving;
search keystroke < 30 ms on the seed.

---

## Phase 5 — Invoices and printing

**Prompt**

> Build the invoice document per SPEC §6 as a pure builder used by both the on-screen preview
> and printing, for A4, A5, roll 80 and roll 58, with all show/hide settings, round-off,
> "You saved", UPI QR (real QR) and signature block. Build the Invoices screen per §5.4 with
> keyset paging. Wire Print, Download PDF, auto-print on save with copies, and the Settings ›
> Invoice live preview + Test print. Port `invView` and `fmtNo` from the prototype.

**Done when**: PDFs for all four paper sizes look right (add golden tests for the PDF
widgets if practical); preview updates instantly from the settings draft; printing works
with a Windows printer driver.

---

## Phase 6 — Sales register and reports

**Prompt**

> Build the Sales register per SPEC §5.5: date presets incl. custom range, all filters,
> group-by options, totals bar from one aggregate query, lines view with keyset paging,
> grouped view, sort options, the five saved reports, and Excel export (in an isolate) with a
> header block and totals row. Show the computed-in time in the footer.

**Done when**: FY totals + first page on the 100k-line perf seed < 150 ms; register totals
equal the sum of invoice totals for the same range (DAO test); export opens in Excel.

---

## Phase 7 — Dashboard

**Prompt**

> Build the Dashboard per SPEC §5.1 with fl_chart: KPI tiles (tap-through filters), sales bar
> chart 7D/30D/12M from `daily_sales_summary` with grow animation and tooltips, category donut
> with hover-dim, reorder list, expiring batches, recent invoices. Live-update after a sale.

**Done when**: loads < 100 ms; numbers match register totals for the same ranges.

---

## Phase 8 — Backup and restore

**Prompt**

> Build Backup & restore per SPEC §5.6: `VACUUM INTO` snapshot, zip with manifest, optional
> AES-256-GCM encryption with a PBKDF2 key, progress UI, history from `backup_log`, restore
> with safety backup + checksum + password + migration, and automatic backups (on close and
> on first launch of the day when overdue; keep latest 30). All file work in an isolate.

**Done when**: round-trip test (backup → wipe → restore) passes with and without
encryption; a wrong password fails cleanly; restore of an older schema migrates.

---

## Phase 9 — Staff, PIN login, permissions

**Prompt**

> Build staff accounts and PIN login per SPEC §5.8 and §7.6: first-run Owner setup, lock
> screen with PIN pad, auto-lock, salted PBKDF2 PIN hashes, role permissions enforced in
> application services (not just hidden buttons), `staff_id` on invoices and movements.

**Done when**: a Cashier cannot sell H/H1, give > 5 %, open Settings or restore backups;
tests cover each permission.

---

## Phase 10 — Polish and release

**Prompt**

> Go screen by screen against the prototype and SPEC §8–§9: spacing, type, colours, motion,
> empty states, error states, focus order, tooltips/semantics, contrast. Check tablet layouts
> (800×1280 and 1280×800) and touch targets. Run the perf suite. Produce release builds for
> Windows (MSIX or installer) and Android (APK/AAB) with app icons.

**Done when**: perf budgets met; no analyzer warnings; manual checklist in this file ticked.

---

## Phase 11 — Purchases (order book)

**Prompt**

> Build Purchases per SPEC §4.7 and §5.9, modelled on the store's "Order & Received" workbook:
> schema v3 (suppliers, order_lines, purchase_receipts, receipt_lines) with a migration and
> migration test; New order and Receive invoice dialogs; Pending · Order book · Receipts tabs;
> receipts add stock through the §4.5 receive path in one transaction; Excel export in the
> workbook's layout.

**Done when**: an order of 5 lines, received on one stockist invoice (one line short), raises
batch stock by the stock units with `receive` movements; the short line can be closed; the
Order book day view and its Total match the spreadsheet layout; a bad receipt line rolls the
whole receipt back; Pending/Order book pages load in < 50 ms with 50k order lines.

---

## Phase 12 — Stockist dues

**Prompt**

> Build the stockist ledger per SPEC §4.8 / §5.9: schema v4 (credit days, bill totals and due
> dates, supplier_ledger, ledger_allocations, return_lines) with migration + test; bills from
> receipts, payments (FIFO or picked bills, remainder on account), credit notes, returns to
> stockist (stock out), opening balance, voids; Dues tab, statement, dashboard card; permission
> `supplierPayments`.

**Done when**: an invoice billed ₹10,000 with ₹2,000 paid on delivery shows ₹8,000 outstanding
due in 30 days; a ₹5,000 payment makes it Part paid; returning 2 units of an expired batch on a
₹300 credit note lowers the batch by 2 and the outstanding to ₹2,700; past the due date it shows
Overdue and on the dashboard; a Pharmacist can't record payments; the statement balance equals
the Dues balance; dues/statement pages < 50 ms with 20k bills.

---

## Phase 13 — Sales returns (credit notes)

**Prompt**

> Build customer returns per SPEC §4.5a / §5.4: schema v5 (invoices.doc_type, ref_invoice_id;
> invoice_items.ref_item_id, restocked) with migration + test; pure return rules (amounts that
> reconcile, window, Rx block, qty caps); `saveCreditNote` in one transaction (own gapless FY
> series, restock or write-off, summary on the return day, original status); register,
> dashboard and invoice list net out refunds; Return items dialog, credit-note print; settings
> `creditNotePrefix`, `returnWindowDays`; permission `acceptReturns`.

**Done when**: returning 1 of 3 strips from a 5 %-off bill issues `CN/26-27/00001` for the
right refund, puts 1 back in the same batch, marks the bill Part returned and prints a credit
note; a damaged line leaves stock unchanged with `return` + `write_off` movements; returning a
line bit by bit sums exactly to the original line; the register and dashboard for the return
day show the refund as negative sales; an H1 item, an over-return, a cancelled bill and (for
staff) a bill past the window are refused; a Cashier sees no Return button; a bill with returns
can't be cancelled.

---

## Phase 14 — Loose selling

**Prompt**

> Build loose (per-tablet) selling per SPEC §4.9: schema v6 (products.units_per_pack,
> invoice_items.pack_size) with migration + test; stock in units everywhere; pro-rata price
> rounded down; Strip | Tab switch on bill lines; "Tablets per strip" on Add medicine and a
> converting "Sell loose…" action in Inventory; strip-based receiving, reorder and displays.

**Done when**: a ₹30.90 strip of 10 sells 5 tabs for ₹15.45 and stock drops by 5 tabs; 10 tabs
cost exactly ₹30.90; a batch with 7 tabs starts loose and can't be billed as a strip; setting
10 tabs/strip turns 12 strips into 120 tabs with a `repack` movement and is refused while loose
tabs remain; low stock compares against strips; the invoice prints "5 tab"; returning loose tabs
reconciles to the paisa using the sold pack size.

---

## Phase 15 — Customer credit (udhaar)

**Prompt**

> Build customer credit per SPEC §4.10 / §5.10: schema v7 (customers.credit_limit_paise,
> address, note; invoices.paid_now_paise, dues_after_paise; customer_ledger,
> customer_allocations) with migration + test; ledger allocation shared with the stockist
> ledger; Credit payment mode with paid-now and a limit check inside `saveBill`; cancel voids the
> bill's ledger rows; returns can be adjusted in dues; Customers screen with statement, receive
> payment, opening dues, voids, statement PDF and export; dashboard card; permissions
> `sellOnCredit`, `collectPayments`, `manageCustomerCredit`; setting `defaultCreditLimitPaise`.

**Done when**: a ₹309 Credit bill with ₹100 paid by UPI leaves ₹209 on the bill and prints
"Paid ₹100.00 · Balance ₹209.00 · Total dues …"; a Credit bill without a name and phone is
refused; a bill past the limit is blocked and rolled back (no number used) until the Owner
allows it (PIN for staff); cancelling a Credit bill voids its debit and paid-now payment and
re-applies later payments; a return adjusted in dues reduces the original bill first; a payment
can be applied oldest-first or to ticked bills and an overpayment pays the next bill; voiding a
payment re-opens what it paid; a Cashier can collect payments but can't bill on Credit; the
customer list, totals and statement stay under 50 ms with 20k customers / 105k ledger rows.

---

## Phase 16 — Stockist directory + monthly consumption register

From the store's `docs/Daily Sales.xlsx`.

**Prompt**

> Build SPEC §4.11 / §4.12: schema v8 (suppliers.other_phones, note; product_sources) with
> migration (seeded from past receipts) + test; learn sources on receive; Purchases › Stockists
> tab with add / edit / remove, import of the "Damdawi lak na" sheet with catalogue matching and
> a review dialog, export in the sheet's layout; "Get from" on Pending lines and in Inventory's
> batch panel. Monthly Inventory Management Register at `/register/consumption` from
> `daily_sales_summary` with the sheet's formulas, lead-time settings, Apply suggested reorder
> levels, Excel export in the sheet's layout.

**Done when**: the January sheet's rows reproduce exactly (Syr. Moxcad Forte → 24 / 2.4 / 5 /
10 / 7.6 / 2.6); a month without sales shows zeros; returns count on their day; applying the
suggested level updates low-stock alerts; importing `docs/Daily Sales.xlsx` reads 318 medicines
with EMY PHARMACY's two numbers and RB PAHRMACY's MR "Tluangtea", links catalogue matches, keeps
or skips the rest and adds nothing on a second import; receiving an invoice lists the stockist
under the medicine; register and directory pages stay under 50 ms on the perf seeds.

## Phase 17 — Editable inventory

**Prompt**

> Build SPEC §4.13 / §5.3 editing: schema v9 (stock_movements.note) with migration + test; Edit
> medicine (Add-medicine form without first batch / units per pack); Edit batch (batch no.,
> expiry locked once expired, counted quantity with a reason → `adjust` movement with note,
> recent movements); Hide / Unhide with a Hidden view; refuse saving a bill whose MRP / GST
> changed after the items were added and refresh its lines.

**Done when**: renaming a medicine keeps old bills' names and makes the new name searchable;
an expired batch's expiry can't be changed but its quantity can be set to 0; a count correction
shows "Damaged: …" in the batch's movements; a hidden medicine disappears from search, billing
and counts and comes back from the Hidden tab; editing the MRP while it's on an open bill blocks
the save once and the next save charges the new MRP.

### Manual release checklist

- [ ] Fresh install → Owner setup → store profile → first bill printed on A4 and thermal
- [ ] Barcode scanner bills an item without touching the mouse
- [ ] Expired batch cannot be sold; H/H1 needs doctor
- [ ] Bill numbers continue correctly after app restart and roll over on 1 April
- [ ] Backup to USB, restore on a second PC, data identical
- [ ] Register "GST summary by HSN" matches the sum of invoices for the month
- [ ] Return 1 strip from a bill → credit note prints on A4 and thermal; stock +1
- [ ] Set 10 tabs/strip on a medicine, sell 5 tabs by keyboard (T in qty), print on thermal
- [ ] Edit a medicine's MRP while it's on an open bill → save refused once, new total, saves
- [ ] Correct a batch's count with a reason; hide and unhide a medicine
- [ ] Works with Windows display scaling 125 % and 150 %
