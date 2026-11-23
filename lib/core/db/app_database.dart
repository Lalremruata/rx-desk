import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'daos/backup_dao.dart';
import 'daos/catalog_dao.dart';
import 'daos/customers_dao.dart';
import 'daos/dues_dao.dart';
import 'daos/held_bills_dao.dart';
import 'daos/purchases_dao.dart';
import 'daos/reports_dao.dart';
import 'daos/sales_dao.dart';
import 'daos/settings_dao.dart';
import 'daos/sources_dao.dart';
import 'daos/staff_dao.dart';
import 'fts.dart';
import 'migrations.dart';
import 'tables.dart';

export 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Manufacturers,
    Products,
    Batches,
    Customers,
    Doctors,
    Staff,
    InvoiceSeq,
    Invoices,
    InvoiceItems,
    StockMovements,
    DailySalesSummary,
    SettingsEntries,
    BackupLog,
    Suppliers,
    OrderLines,
    PurchaseReceipts,
    ReceiptLines,
    SupplierLedger,
    LedgerAllocations,
    ReturnLines,
    CustomerLedger,
    CustomerAllocations,
    ProductSources,
    HeldBills,
  ],
  daos: [CatalogDao, SalesDao, ReportsDao, SettingsDao, StaffDao, BackupDao, PurchasesDao, DuesDao, CustomersDao, SourcesDao, HeldBillsDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// The on-device database file (single SQLite file, CLAUDE.md).
  static Future<String> defaultPath() async {
    final dir = await getApplicationSupportDirectory();
    await Directory(dir.path).create(recursive: true);
    return p.join(dir.path, 'rxdesk.sqlite');
  }

  /// Opens the app database in a background isolate.
  factory AppDatabase.open({String? path}) => AppDatabase(
        driftDatabase(
          name: 'rxdesk',
          native: DriftNativeOptions(
            databasePath: path == null ? defaultPath : () async => path,
            shareAcrossIsolates: true,
          ),
        ),
      );

  /// Bump with a migration step in migrations.dart + a migration test
  /// (CLAUDE.md rule 10).
  @override
  int get schemaVersion => latestSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await createExtras(this);
        },
        onUpgrade: (m, from, to) => runMigrations(this, m, from, to),
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// FTS table, triggers and partial indexes (SPEC §3.2–3.3).
  static Future<void> createExtras(GeneratedDatabase db) async {
    for (final s in [...ftsStatements, ...indexStatements]) {
      await db.customStatement(s);
    }
  }

  /// Rebuilds the search index from scratch.
  Future<void> rebuildSearchIndex() => customStatement(ftsRebuild);
}
