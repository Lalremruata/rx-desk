import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/db/daos/customers_dao.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/sales/return_rules.dart';
import 'package:rx_desk/features/customers/application/customer_statement.dart';
import 'package:rx_desk/features/invoices/application/invoice_document.dart';
import 'package:rx_desk/features/invoices/application/invoice_pdf.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';

import '../helpers/test_db.dart';

void main() {
  test('printed credit bill: payment “Credit” with paid / balance / total dues; credit note says adjusted', () async {
    final db = memoryDb();
    addTearDown(db.close);
    final (p, b) = await addMed(db);
    await db.customersDao.addCustomer(name: 'Mami', phone: '98', at: t0);
    await db.customersDao.setOpeningBalance(customerId: 1, date: '2026-04-01', amount: const Paise(100000), at: t0);
    final s = await db.salesDao.saveBill(
      SaveBillRequest(
        lines: [BillLineRequest(productId: p, batchId: b, qty: 10)],
        customerName: 'Mami',
        customerPhone: '98',
        paymentMode: 'Credit',
        paidNow: const Paise(10000),
      ),
      rules: const BillRules(),
      at: t0,
    );
    final doc = buildInvoiceDoc(InvoiceData.fromDb((await db.salesDao.invoiceWithItems(s.invoiceId))!), const AppSettings());
    expect(doc.payment, 'Credit');
    expect(doc.paymentSub, 'Paid ₹100.00 · Balance ₹209.00 · Total dues ₹1,209.00');

    final item = (await db.salesDao.invoiceWithItems(s.invoiceId))!.items.single;
    final cn = await db.salesDao.saveCreditNote(
      SaveCreditNoteRequest(invoiceId: s.invoiceId, lines: [ReturnLineRequest(itemId: item.id, qty: 1)], refundMode: 'Credit'),
      rules: const ReturnRules(),
      at: t0,
    );
    final cnDoc = buildInvoiceDoc(InvoiceData.fromDb((await db.salesDao.invoiceWithItems(cn.creditNoteId))!), const AppSettings());
    expect((cnDoc.payment, cnDoc.paymentSub), ('Adjusted in dues', null));

    // A cash bill has no credit line.
    final cash = await db.salesDao.saveBill(SaveBillRequest(lines: [BillLineRequest(productId: p, batchId: b, qty: 1)]), rules: const BillRules(), at: t0);
    expect(buildInvoiceDoc(InvoiceData.fromDb((await db.salesDao.invoiceWithItems(cash.invoiceId))!), const AppSettings()).paymentSub, isNull);

    // Statement: table rows match the ledger, and the A4 PDF renders.
    final rows = (await db.customersDao.statement(1)).rows;
    final data = CustomerStatementData(
      storeName: 'Zion Medicos',
      storeLines: const ['Main Road, Aizawl'],
      customer: await db.customersDao.customerDues(1, today: '2026-11-09'),
      rows: rows,
      generated: t0,
    );
    final table = customerStatementTable(data);
    expect(table.rows.map((r) => r[1]), ['Opening dues', 'Bill', 'Payment', 'Credit note']);
    expect(table.totals[5], (100000 + 30900 - 10000 - 3100) / 100);
    final bytes = await buildCustomerStatementPdf(data, fonts: InvoiceFonts.fromDirectory('assets/fonts'), accentArgb: 0xFF0F766E);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final out = Platform.environment['RXDESK_PDF_OUT'];
    if (out != null) File('$out/customer-statement.pdf').writeAsBytesSync(bytes);
    expect(data.customer, isA<CustomerDues>());
  });
}
