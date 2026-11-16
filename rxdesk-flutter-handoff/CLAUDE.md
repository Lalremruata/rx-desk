# CLAUDE.md — RxDesk (offline pharmacy management, Flutter)

You are building **RxDesk**, an offline-first pharmacy / drug-store app for India:
billing (POS), batch-wise inventory, GST invoices, sales register and reports,
dashboard, backup/restore, settings, staff roles.

Read these before writing code, and keep them open while you work:

- `docs/SPEC.md` — the product and technical spec. **Source of truth.**
- `docs/BUILD_PLAN.md` — the phases. Work one phase at a time, in order.
- `design/rxdesk-design-reference.dc.html` — the interactive prototype's source
  (HTML + a JS `Component` class). It will not render on its own; read it for
  layout, copy, colours, animation timings and the reference logic
  (`calc`, `invView`, `fmtNo`, `search`, `salesData`, `meta`). Port behaviour from it,
  not markup.
- `design/tokens.json` — colours, radii, spacing, type and motion tokens.

If the spec and the prototype disagree, the **spec wins**. If the spec is silent,
follow the prototype. If both are silent, ask before inventing behaviour that
touches money, stock, tax or legal records.

---

## Targets

- **Windows desktop** (primary: counter PC, keyboard + barcode scanner + printer)
- **Android tablet** (secondary: stock checks, billing by touch)
- Same codebase. No web build required.

## Stack (do not swap without asking)

| Concern | Choice |
|---|---|
| Language | Dart 3, null-safe, `flutter_lints` + stricter rules in `analysis_options.yaml` |
| State | `flutter_riverpod` + `riverpod_annotation` / `riverpod_generator` |
| Database | `drift` + `drift_flutter` (SQLite, FTS5) — single local file |
| Models | `freezed` + `json_serializable` for non-table DTOs |
| Routing | `go_router` with a `ShellRoute` for the sidebar layout |
| Charts | `fl_chart` |
| PDF / print | `pdf` + `printing` (A4, A5, roll 80 mm, roll 58 mm) |
| Excel export | `excel` (CSV fallback) |
| Files | `file_picker`, `path_provider` |
| Backup | `archive` (zip) + `cryptography` (AES-GCM, PBKDF2) |
| Desktop window | `window_manager` (min size 1100×700 on Windows) |
| Formatting | `intl` with locale `en_IN` (₹ and lakh grouping) |
| Fonts | Inter + Space Grotesk **bundled as assets** (no runtime font download) |

Add packages with `flutter pub add <name>` so you get the current stable version.
Do not pin old versions from memory.

## Commands

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # after changing tables/providers/freezed
dart run build_runner watch --delete-conflicting-outputs   # while developing
flutter analyze
flutter test
flutter run -d windows
flutter run -d <android-device-id>
flutter build windows --release
flutter build apk --release
```

Run `flutter analyze` and `flutter test` before you call any task done.

## Architecture

Feature-first folders. Widgets never talk to Drift directly.

```
lib/
  main.dart                  # bootstrap: window, db, ProviderScope
  app.dart                   # MaterialApp.router, theme, shortcuts
  core/
    db/                      # app_database.dart, tables/, daos/, migrations/, fts.dart, seed/
    money/                   # Paise type, GST math, round-off, en_IN formatting
    fy/                      # financial-year helpers + invoice numbering
    theme/                   # tokens.dart (from design/tokens.json), app_theme.dart
    router/                  # go_router config
    shortcuts/               # Intents/Actions for F2 F3 F4 F8 F10 Esc
    widgets/                 # shared UI kit (see SPEC §8)
    utils/
  features/
    shell/                   # sidebar, header, offline chip, toast host
    dashboard/
    billing/
    inventory/
    invoices/
    sales_register/
    backup/
    settings/
    staff/                   # PIN login, roles, permissions
  each feature/
    data/                    # repositories (wrap DAOs)
    application/             # Riverpod providers / notifiers, pure services
    presentation/            # screens + widgets
test/
  unit/ dao/ widget/ perf/
```

Layering: `presentation → application (providers) → data (repositories) → core/db (DAOs)`.
Business rules (GST, FEFO, numbering, stock checks) live in **pure Dart services** under
`application/` or `core/`, with unit tests. Never in widgets.

## Rules that must not be broken

1. **Money is integer paise** (`int`), wrapped in a `Paise` extension type. Never `double` for
   stored or summed money. Convert to rupees only when formatting.
2. **MRP includes GST.** Tax is worked backwards per line (SPEC §4.1). Round per line to the
   paise, then sum. CGST = SGST = tax ÷ 2 (put the odd paisa on SGST).
3. **Saving a bill is one Drift transaction**: insert invoice + items, decrement batch stock,
   write stock movements, update `daily_sales_summary`, bump the FY sequence. All or nothing.
4. **Stock never goes negative** unless the setting `allowNegativeStock` is on.
5. **Expired batches can never be sold.** No setting turns this off.
6. **Invoices are never hard-deleted.** Cancel or return them (status + reverse stock movement).
7. **Invoice numbers are gapless per financial year** (April–March) and assigned inside the
   save transaction.
8. **Snapshot on sale**: invoice items store product name, salt, maker, HSN, schedule, batch no,
   expiry, MRP and GST rate as they were. Reports read snapshots, not live product rows.
9. **No network calls.** The app works fully offline. No analytics, no crash upload, no Firebase.
10. **Schema changes need a Drift migration + a migration test.** Bump `schemaVersion`.
11. **Lists over ~200 rows are paged or lazily built** (`ListView.builder`, keyset pagination).
    Never load a full table into memory for a screen.
12. Settings are read through one `settingsProvider`. Don't scatter `SharedPreferences`.
13. Staff PINs are stored as salted hashes (PBKDF2), never plain text.

## UI rules

- All colours, radii, spacing, type and durations come from `core/theme/tokens.dart`.
  No hex literals in feature code.
- The brand accent is user-selectable (Settings › Appearance). Derive `accentSoft` from it
  (12% over white). Never hardcode teal.
- Body font Inter 14; headings and numbers Space Grotesk.
- Touch targets ≥ 44 px. Text contrast ≥ 4.5:1.
- Respect reduced motion: if `MediaQuery.disableAnimationsOf(context)` is true, skip
  non-essential animation.
- Every icon-only button has a `Tooltip` + semantics label.
- Use the shared widgets in `core/widgets` (KpiTile, AppCard, SegmentedPills, ToggleRow,
  StatusBadge, RxBadge, DataGrid, Pager, AppToast, PageEnter). Build them first (phase 0).

## Definition of done for any task

- Behaviour matches SPEC (and the prototype where SPEC is silent).
- `flutter analyze` clean, `flutter test` green, new logic has unit tests.
- Works on Windows at 1280×800 and on an Android tablet at 800×1280 (portrait) and 1280×800.
- No hardcoded colours or strings that belong in settings.
- Large-data check passes where relevant (SPEC §10).

## Working style

- One phase per session. At the start, restate the phase goal and the acceptance
  criteria from BUILD_PLAN, then plan, then build.
- Small commits with clear messages. Don't commit generated `*.g.dart` / `*.freezed.dart`
  unless the repo already does.
- When unsure about a tax or legal rule, stop and ask. Don't guess.
