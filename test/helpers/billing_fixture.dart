import 'package:rx_desk/core/db/app_database.dart';

import 'test_db.dart';

/// Small catalogue for billing tests (dates relative to 9 Nov 2026).
Future<void> billingFixture(AppDatabase db) async {
  final (para650, _) = await addMed(db, batch: 'PCM2540', expiry: '2027-02', qty: 50, barcode: '8904021650153');
  await db.catalogDao.receiveStock(productId: para650, batchNo: 'PCM2611', expiry: '2027-08', qty: 92, at: t0);
  await db.catalogDao.receiveStock(productId: para650, batchNo: 'PCM1111', expiry: '2026-09', qty: 5, at: t0);
  await addMed(db, name: 'Paracetamol 500 mg Tablet', salt: 'Paracetamol 500 mg', batch: 'PCM5001', qty: 3, mrp: 1800);
  await addMed(db, name: 'Crocin Advance', maker: 'Kestrel Healthcare', batch: 'CRO77', mrp: 2500, qty: 40);
  await addMed(db, name: 'Amoxicillin 500 mg Capsule', salt: 'Amoxicillin 500 mg', maker: 'Aurelis Labs', schedule: 'H', batch: 'AMX0942', qty: 18, category: 'Capsule', mrp: 9850);
  await addMed(db, name: 'Ibuprofen 400 mg Tablet', salt: 'Ibuprofen 400 mg', batch: 'IBU6650', qty: 0, mrp: 3800);
  await addMed(db, name: 'Brufen 400', salt: 'Ibuprofen 400 mg', maker: 'Saffron Labs', batch: 'BRU1', qty: 12, mrp: 3200);
}
