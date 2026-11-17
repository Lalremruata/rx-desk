import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/purchases_dao.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/db/migrations.dart';
import 'package:rx_desk/core/inventory/stock_adjust.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/sales/return_rules.dart';
import 'package:rx_desk/features/backup/application/backup_format.dart';
import 'package:rx_desk/features/backup/application/backup_service.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';

import '../helpers/test_db.dart';

class _FileSwapper implements DatabaseSwapper {
  _FileSwapper(this.path);
  final String path;
  Uint8List? last;

  @override
  Future<void> replaceWith(Uint8List dbBytes) async {
    last = dbBytes;
    await File(path).writeAsBytes(dbBytes, flush: true);
  }
}

AppDatabase fileDb(String path) {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  return AppDatabase(NativeDatabase(File(path)));
}

Future<(int, int, int)> counts(AppDatabase db) async =>
    (await countOf(db, 'products'), await countOf(db, 'invoices'), await countOf(db, 'stock_movements'));

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('rxdesk-backup-test'));
  tearDown(() => dir.delete(recursive: true));

  BackupService service(AppDatabase db, DatabaseSwapper swapper) => BackupService(
        db,
        () => t0,
        () => AppSettings(backupFolder: '${dir.path}/backups'),
        () => swapper,
        iterations: 1000,
      );

  Future<AppDatabase> seeded(String path) async {
    final db = fileDb(path);
    final (p, b) = await addMed(db, qty: 50);
    await db.salesDao.saveBill(SaveBillRequest(lines: [BillLineRequest(productId: p, batchId: b, qty: 3)]), rules: const BillRules(), at: t0);
    return db;
  }

  for (final pw in [null, 'counter-2026']) {
    test('backup → wipe → restore ${pw == null ? 'plain' : 'encrypted'}', () async {
      final livePath = '${dir.path}/live.sqlite';
      final db = await seeded(livePath);
      final before = await counts(db);
      final swapper = _FileSwapper(livePath);
      final svc = service(db, swapper);

      final b = await svc.prepare(password: pw);
      expect(b.manifest.encrypted, pw != null);
      expect(b.manifest.counts.invoices, 1);
      final path = await svc.writeToFolder(b, kind: 'Manual');
      expect(File(path).existsSync(), isTrue);
      expect((await db.backupDao.latest())!.sha256, b.manifest.sha256);

      // Wipe: more sales after the backup.
      await db.customStatement('DELETE FROM stock_movements');
      expect((await counts(db)).$3, 0);

      await svc.restore(await File(path).readAsBytes(), password: pw);
      await db.close();

      final restored = fileDb(livePath);
      addTearDown(restored.close);
      expect(await counts(restored), before);
      // A safety copy was written first and stays in the history.
      final safety = await restored.backupDao.history(kind: 'Safety');
      expect(safety, hasLength(1));
      expect(File(safety.single.path).existsSync(), isTrue);
      expect((await restored.catalogDao.search('para', now: t0)).rows, isNotEmpty); // FTS restored
    });
  }

  test('wrong password fails cleanly and changes nothing', () async {
    final livePath = '${dir.path}/live.sqlite';
    final db = await seeded(livePath);
    addTearDown(db.close);
    final swapper = _FileSwapper('${dir.path}/never.sqlite');
    final svc = service(db, swapper);
    final b = await svc.prepare(password: 'right-one');
    await expectLater(svc.restore(b.bytes, password: 'wrong'), throwsA(isA<BackupException>()));
    expect(swapper.last, isNull);
    expect(await db.backupDao.history(kind: 'Safety'), isEmpty);
  });

  test('automatic backups: due rule and keep latest 30', () async {
    final db = await seeded('${dir.path}/live.sqlite');
    addTearDown(db.close);
    final svc = service(db, _FileSwapper('${dir.path}/x'));
    expect(await svc.runAutoIfDue(), isNotNull);
    expect(await svc.runAutoIfDue(), isNull); // already done today
    for (var i = 0; i < 31; i++) {
      await svc.runAutoIfDue(force: true);
    }
    expect(await db.backupDao.history(kind: 'Auto'), hasLength(BackupService.keepAuto));
  });

  test('migration v1 → latest adds backup_log.sha256; a v1 backup restores and migrates', () async {
    final v1Path = '${dir.path}/v1.sqlite';
    final db = await seeded(v1Path);
    // Turn it into a v1 database.
    await dropPurchaseTables(db);
    await db.customStatement('ALTER TABLE backup_log DROP COLUMN sha256');
    await dropCreditTables(db);
    await dropDirectoryTables(db);
    await db.customStatement('PRAGMA user_version = 1');
    await db.close();

    // Pack the v1 file as a backup and restore it into a new location.
    final v1Bytes = await File(v1Path).readAsBytes();
    final zip = await packBackup(dbBytes: v1Bytes, schemaVersion: 1, counts: const BackupCounts(), createdAt: t0, iterations: 1000);
    final (m, dbBytes) = await unpackBackup(zip, currentSchema: latestSchemaVersion);
    expect(m.schemaVersion, 1);
    final restoredPath = '${dir.path}/restored.sqlite';
    await File(restoredPath).writeAsBytes(dbBytes);

    final migrated = fileDb(restoredPath);
    addTearDown(migrated.close);
    final cols = await migrated.customSelect('PRAGMA table_info(backup_log)').get();
    expect(cols.map((c) => c.read<String>('name')), contains('sha256'));
    expect((await migrated.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), latestSchemaVersion);
    expect(await countOf(migrated, 'invoices'), 1);
    expect(await countOf(migrated, 'order_lines'), 0);
  });

  test('migration v2 → latest adds the purchases tables and indexes; data survives', () async {
    final v2Path = '${dir.path}/v2.sqlite';
    final db = await seeded(v2Path);
    await dropPurchaseTables(db);
    await dropCreditTables(db);
    await dropDirectoryTables(db);
    await db.customStatement('PRAGMA user_version = 2');
    await db.close();

    final migrated = fileDb(v2Path);
    addTearDown(migrated.close);
    expect(await countOf(migrated, 'invoices'), 1);
    expect((await migrated.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), latestSchemaVersion);
    for (final t in ['suppliers', 'order_lines', 'purchase_receipts', 'receipt_lines', 'supplier_ledger']) {
      expect(await countOf(migrated, t), 0, reason: t);
    }
    final idx = await migrated.customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_order_lines%'").get();
    expect(idx, hasLength(2));
    // Usable straight away.
    final pid = (await migrated.customSelect('SELECT id FROM products LIMIT 1').getSingle()).read<int>('id');
    final ids = await migrated.purchasesDao.addOrderLines('2026-11-09', [NewOrderLine(productId: pid, itemName: '', qty: 2, unit: 'Box')], at: t0);
    expect(ids, hasLength(1));
  });

  test('migration v3 → v4: existing receipts become bills due in 30 days', () async {
    final v3Path = '${dir.path}/v3.sqlite';
    final db = await seeded(v3Path);
    final (pid, _) = await addMed(db, name: 'Etodase TH-4', batch: 'ET01');
    await db.purchasesDao.receive(
      ReceiveRequest(
        supplierName: 'Life Drugs Centre',
        invoiceNo: '2600073',
        receivedDate: '2026-09-02',
        lines: [ReceiveLineInput(productId: pid, batchNo: 'ET01', qty: 2, unit: 'Box', stockUnits: 20, amount: const Paise(361200))],
      ),
      at: t0,
      now: t0,
    );
    await dropDuesTables(db);
    await dropCreditTables(db);
    await dropDirectoryTables(db);
    await db.customStatement('PRAGMA user_version = 3');
    await db.close();

    final migrated = fileDb(v3Path);
    addTearDown(migrated.close);
    expect((await migrated.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), latestSchemaVersion);
    final r = (await migrated.purchasesDao.receiptPage()).rows.single;
    expect(r.billTotal, const Paise(361200));
    expect(r.dueDate, '2026-10-02');
    expect(r.outstanding, const Paise(361200));
    final sid = (await migrated.purchasesDao.allSuppliers()).single.id;
    final d = await migrated.duesDao.supplierDues(sid, today: '2026-11-09');
    expect(d.creditDays, 30);
    expect(d.balance, const Paise(361200));
    expect(d.overdue, const Paise(361200));
  });

  test('migration v4 → v5: sales-return columns + indexes; Pharmacist gets Accept returns; returns work', () async {
    final v4Path = '${dir.path}/v4.sqlite';
    final db = await seeded(v4Path);
    // Customised roles saved before v5 (no acceptReturns yet).
    await db.customStatement(
      "INSERT INTO settings(key, value) VALUES ('rolePermissions', ?)",
      ['{"Pharmacist":["sellRx","editBills"],"Cashier":[]}'],
    );
    await dropPackColumns(db);
    await dropReturnColumns(db);
    await dropCreditTables(db);
    await dropDirectoryTables(db);
    await db.customStatement('PRAGMA user_version = 4');
    await db.close();

    final migrated = fileDb(v4Path);
    addTearDown(migrated.close);
    expect((await migrated.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), latestSchemaVersion);
    final inv = (await migrated.select(migrated.invoices).get()).single;
    expect(inv.docType, 'invoice');
    expect(inv.refInvoiceId, isNull);
    final idx = await migrated.customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND name IN ('idx_items_ref_item', 'idx_invoices_ref')").get();
    expect(idx, hasLength(2));
    final perms = await migrated.customSelect("SELECT value FROM settings WHERE key = 'rolePermissions'").getSingle();
    expect(perms.read<String>('value'), contains('acceptReturns'));

    // A pre-v5 bill can be returned straight away.
    final item = (await migrated.salesDao.invoiceWithItems(inv.id))!.items.single;
    final cn = await migrated.salesDao.saveCreditNote(
      SaveCreditNoteRequest(invoiceId: inv.id, lines: [ReturnLineRequest(itemId: item.id, qty: 1)], refundMode: 'Cash'),
      rules: const ReturnRules(),
      at: t0.add(const Duration(days: 1)),
    );
    expect(cn.number, 'CN/26-27/00001');
    expect((await migrated.salesDao.invoiceWithItems(inv.id))!.invoice.status, 'part_returned');
  });

  test('migration v5 → v6: units per pack and pack size default to 1; stock unchanged; loose selling works', () async {
    final v5Path = '${dir.path}/v5.sqlite';
    final db = await seeded(v5Path);
    await dropPackColumns(db);
    await dropCreditTables(db);
    await dropDirectoryTables(db);
    await db.customStatement('PRAGMA user_version = 5');
    await db.close();

    final migrated = fileDb(v5Path);
    addTearDown(migrated.close);
    expect((await migrated.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), latestSchemaVersion);
    final p = (await migrated.select(migrated.products).get()).single;
    expect(p.unitsPerPack, 1);
    final item = (await migrated.select(migrated.invoiceItems).get()).single;
    expect((item.packSize, item.qty), (1, 3));
    final b = (await migrated.catalogDao.batchesOf(p.id)).single;
    expect(b.qty, 47);

    // Owner sets 10 tabs per strip → 47 strips become 470 tabs.
    await migrated.catalogDao.setPackSize(p.id, 10, at: t0);
    expect((await migrated.catalogDao.batchesOf(p.id)).single.qty, 470);
  });

  test('migration v6 → v7: customer credit tables, columns, indexes and permissions; credit bills work', () async {
    final v6Path = '${dir.path}/v6.sqlite';
    final db = fileDb(v6Path);
    final (p, b) = await addMed(db, qty: 50);
    await db.salesDao.saveBill(
      SaveBillRequest(lines: [BillLineRequest(productId: p, batchId: b, qty: 3)], customerName: 'Mami', customerPhone: '9800000001'),
      rules: const BillRules(),
      at: t0,
    );
    await db.customStatement(
      "INSERT INTO settings(key, value) VALUES ('rolePermissions', ?)",
      ['{"Pharmacist":["sellRx"],"Cashier":[]}'],
    );
    await dropCreditTables(db);
    await dropDirectoryTables(db);
    await db.customStatement('PRAGMA user_version = 6');
    await db.close();

    final migrated = fileDb(v6Path);
    addTearDown(migrated.close);
    expect((await migrated.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), latestSchemaVersion);
    final c = (await migrated.select(migrated.customers).get()).single;
    expect((c.creditLimitPaise, c.address, c.note), (null, '', ''));
    final inv = (await migrated.select(migrated.invoices).get()).single;
    expect((inv.paidNowPaise, inv.duesAfterPaise), (null, null));
    expect(await countOf(migrated, 'customer_ledger'), 0);
    final idx = await migrated.customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_cledger%'").get();
    expect(idx, hasLength(3));
    final perms = (await migrated.customSelect("SELECT value FROM settings WHERE key = 'rolePermissions'").getSingle()).read<String>('value');
    expect(perms, contains('"Pharmacist":["sellRx","sellOnCredit","collectPayments"]'));
    expect(perms, contains('"Cashier":["collectPayments"]'));

    // The existing customer can buy on credit straight away.
    final s = await migrated.salesDao.saveBill(
      SaveBillRequest(
        lines: [BillLineRequest(productId: p, batchId: b, qty: 1)],
        customerName: 'Mami',
        customerPhone: '9800000001',
        paymentMode: 'Credit',
      ),
      rules: const BillRules(),
      at: t0,
    );
    expect(s.duesAfter, const Paise(3100));
    expect(await migrated.customersDao.currentDues(c.id), 3100);
  });

  test('migration v7 → v8: stockist directory learned from past receipts; phones columns; receiving keeps learning', () async {
    final v7Path = '${dir.path}/v7.sqlite';
    final db = fileDb(v7Path);
    final (p, _) = await addMed(db, qty: 50);
    await db.purchasesDao.receive(
      ReceiveRequest(
        supplierName: 'Life Drugs Centre',
        invoiceNo: 'A1',
        receivedDate: '2026-10-01',
        lines: [ReceiveLineInput(productId: p, batchNo: 'PCM2611', qty: 1, unit: 'Box', stockUnits: 10, amount: const Paise(30000))],
      ),
      at: t0,
      now: t0,
    );
    await dropDirectoryTables(db);
    await db.customStatement('PRAGMA user_version = 7');
    await db.close();

    final migrated = fileDb(v7Path);
    addTearDown(migrated.close);
    expect((await migrated.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), latestSchemaVersion);
    final s = (await migrated.select(migrated.suppliers).get()).single;
    expect((s.otherPhones, s.note), ('', ''));
    final src = await migrated.sourcesDao.sourcesFor(p);
    expect(src.single.supplierName, 'Life Drugs Centre');
    expect((src.single.origin, src.single.lastReceived), ('receipt', '2026-10-01'));
    final idx = await migrated.customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_sources%'").get();
    expect(idx, hasLength(3));
  });

  test('migration v8 → v9: stock movements get a note; old movements keep an empty note; corrections record theirs', () async {
    final v8Path = '${dir.path}/v8.sqlite';
    final db = fileDb(v8Path);
    final (_, b) = await addMed(db, qty: 50);
    await db.customStatement('ALTER TABLE stock_movements DROP COLUMN note');
    await db.customStatement('PRAGMA user_version = 8');
    await db.close();

    final migrated = fileDb(v8Path);
    addTearDown(migrated.close);
    expect((await migrated.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), latestSchemaVersion);
    expect((await migrated.catalogDao.movementsOf(b)).single.note, '');
    await migrated.catalogDao.editBatch(b, countedQty: 48, reason: StockAdjustReason.lost, at: t0);
    expect((await migrated.catalogDao.movementsOf(b)).last.note, 'Lost / theft');
  });
}

/// Turns a current database back into v7: stockist directory gone.
/// Safe to call twice / after the suppliers table is gone.
Future<void> dropDirectoryTables(AppDatabase db) async {
  await db.customStatement('DROP TABLE IF EXISTS product_sources');
  final cols = {for (final r in await db.customSelect('PRAGMA table_info(suppliers)').get()) r.read<String>('name')};
  for (final c in ['other_phones', 'note']) {
    if (cols.contains(c)) await db.customStatement('ALTER TABLE suppliers DROP COLUMN $c');
  }
}

/// Turns a current database back into v6: customer-credit tables and
/// columns gone.
Future<void> dropCreditTables(AppDatabase db) async {
  for (final t in ['customer_allocations', 'customer_ledger']) {
    await db.customStatement('DROP TABLE $t');
  }
  await db.customStatement('DROP INDEX IF EXISTS idx_customers_name');
  for (final c in ['credit_limit_paise', 'address', 'note']) {
    await db.customStatement('ALTER TABLE customers DROP COLUMN $c');
  }
  for (final c in ['paid_now_paise', 'dues_after_paise']) {
    await db.customStatement('ALTER TABLE invoices DROP COLUMN $c');
  }
}

/// Turns a current database back into v5: loose-selling columns gone.
Future<void> dropPackColumns(AppDatabase db) async {
  await db.customStatement('ALTER TABLE products DROP COLUMN units_per_pack');
  await db.customStatement('ALTER TABLE invoice_items DROP COLUMN pack_size');
}

/// Turns a current database back into v4 as far as SQLite allows: the
/// sales-return indexes and the plain v5 columns go (foreign-key columns
/// can't be dropped — the migration's column checks cover that case).
Future<void> dropReturnColumns(AppDatabase db) async {
  await db.customStatement('DROP INDEX IF EXISTS idx_items_ref_item');
  await db.customStatement('DROP INDEX IF EXISTS idx_invoices_ref');
  await db.customStatement('ALTER TABLE invoices DROP COLUMN doc_type');
  await db.customStatement('ALTER TABLE invoice_items DROP COLUMN restocked');
}

/// Drops everything added in v3 and v4.
Future<void> dropPurchaseTables(AppDatabase db) async {
  await dropDirectoryTables(db);
  await dropDuesTables(db);
  for (final t in ['receipt_lines', 'purchase_receipts', 'order_lines', 'suppliers']) {
    await db.customStatement('DROP TABLE $t');
  }
}

/// Turns a current database back into v3: v4 tables and columns gone.
Future<void> dropDuesTables(AppDatabase db) async {
  for (final t in ['return_lines', 'ledger_allocations', 'supplier_ledger']) {
    await db.customStatement('DROP TABLE $t');
  }
  await db.customStatement('DROP INDEX IF EXISTS idx_receipts_due');
  await db.customStatement('ALTER TABLE suppliers DROP COLUMN credit_days');
  await db.customStatement('ALTER TABLE purchase_receipts DROP COLUMN bill_total_paise');
  await db.customStatement('ALTER TABLE purchase_receipts DROP COLUMN due_date');
}
