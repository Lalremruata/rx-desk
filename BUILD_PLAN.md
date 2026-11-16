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

### Manual release checklist

- [ ] Fresh install → Owner setup → store profile → first bill printed on A4 and thermal
- [ ] Barcode scanner bills an item without touching the mouse
- [ ] Expired batch cannot be sold; H/H1 needs doctor
- [ ] Bill numbers continue correctly after app restart and roll over on 1 April
- [ ] Backup to USB, restore on a second PC, data identical
- [ ] Register "GST summary by HSN" matches the sum of invoices for the month
- [ ] Works with Windows display scaling 125 % and 150 %
