import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/models.dart';
import 'package:rx_desk/core/money/paise.dart';

AppDatabase memoryDb() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  return AppDatabase(NativeDatabase.memory());
}

final DateTime t0 = DateTime(2026, 11, 9, 10);

/// Adds a product with one batch; returns (productId, batchId).
Future<(int, int)> addMed(
  AppDatabase db, {
  String name = 'Paracetamol 650 mg Tablet',
  String salt = 'Paracetamol 650 mg',
  String maker = 'Northline Pharma',
  String schedule = '',
  int mrp = 3090,
  int gst = 12,
  String batch = 'PCM2611',
  String expiry = '2027-08',
  int qty = 100,
  String? barcode,
  String category = 'Tablet',

  /// Units per pack; [qty] is in units.
  int packSize = 1,
}) async {
  final pid = await db.catalogDao.addProduct(
    NewProduct(
      name: name,
      salt: salt,
      maker: maker,
      category: category,
      schedule: schedule,
      gstRate: gst,
      mrp: Paise(mrp),
      barcode: barcode,
      batchNo: batch,
      expiry: expiry,
      openingQty: qty,
      packSize: packSize,
    ),
    at: t0.subtract(const Duration(days: 30)),
  );
  final b = await db.catalogDao.batchesOf(pid);
  return (pid, b.first.id);
}

Future<int> qtyOf(AppDatabase db, int batchId) async =>
    (await (db.select(db.batches)..where((b) => b.id.equals(batchId))).getSingle()).qty;

Future<int> countOf(AppDatabase db, String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle()).read<int>('c');
