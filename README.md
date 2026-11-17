# RxDesk

Offline-first pharmacy management for India — billing (POS), batch-wise inventory,
GST invoices, sales register, dashboard, backup/restore, staff PINs. Flutter; Windows
desktop first, Android tablet second. No network calls.

- **`docs/user-guide/`** — the user guide for store staff (start at `docs/user-guide/README.md`)
- `CLAUDE.md` — working rules · `docs/SPEC.md` — product spec (source of truth)
- `docs/BUILD_PLAN.md` — phases · `design/` — prototype source + tokens

## Status

All BUILD_PLAN phases (0–17, incl. Purchases / order book, stockist dues, sales returns / credit notes, loose selling, customer credit / udhaar, the stockist directory, the monthly consumption register and editable inventory) are implemented with tests. Still to verify on real
hardware: Windows build + printer driver, Android tablet, barcode scanner, and the
manual release checklist at the end of `docs/BUILD_PLAN.md`.

## Develop

Requires Flutter ≥ 3.47 (Dart ≥ 3.13).

```bash
flutter pub get
dart run build_runner build          # generated *.g.dart / *.freezed.dart (not committed)
flutter analyze
flutter test                         # unit + DAO + widget + perf (perf is tagged)
flutter test --exclude-tags perf     # faster
flutter run -d windows               # or -d macos for local dev; -d <android-id>
flutter run -d windows --dart-define=SEED=true          # demo data (~1,600 items, 11 months)
flutter run -d windows --dart-define=PERF_SEED=100k     # ~100k invoice lines
```

First launch asks for the Owner's name and a 4-digit PIN. Debug builds show a
**Widget gallery** (last sidebar item).

## Release builds

```bash
flutter build windows --release      # on Windows → build/windows/x64/runner/Release/
flutter build apk --release          # Android (sign with your own key, see android/app/build.gradle.kts)
flutter build appbundle --release
```

For a Windows installer, package `build/windows/x64/runner/Release/` with MSIX
(`dart run msix:create` after adding the `msix` package) or Inno Setup. App icons are
generated from `assets/icon/` with `dart run flutter_launcher_icons`.

## Data

- One SQLite file in the app-support folder (`rxdesk.sqlite`). Schema migrations live in
  `lib/core/db/migrations.dart` (current: v8) with tests in `test/dao/backup_restore_test.dart`.
- Backups: `.rxbak` = zip of `manifest.json` + the database (AES-256-GCM with a
  PBKDF2 key when a password is set). Automatic backups go to `Documents/RxDesk/Backups`
  (latest 30 kept) and are **not** password-protected.

## Layout

```
lib/
  core/      db (Drift tables, DAOs, FTS, seed), money, fy, sales rules, theme, router, widgets, utils
  features/  shell, dashboard, billing, inventory, invoices, sales_register, backup, settings, staff
             each: data/ (repositories) · application/ (providers, pure services) · presentation/
test/        unit · dao · widget · perf (tag: perf) · helpers
```

Fonts (Inter, Space Grotesk) are bundled in `assets/fonts` under the SIL OFL.
