import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/cash/cash_rules.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/daos/cash_dao.dart';
import 'package:rx_desk/core/db/daos/customers_dao.dart';
import 'package:rx_desk/core/db/daos/dues_dao.dart';
import 'package:rx_desk/core/db/daos/purchases_dao.dart';
import 'package:rx_desk/core/db/daos/sales_dao.dart';
import 'package:rx_desk/core/money/paise.dart';
import 'package:rx_desk/core/sales/bill_rules.dart';
import 'package:rx_desk/core/sales/return_rules.dart';

import '../helpers/test_db.dart';

/// Day-end cash closing (SPEC §4.14).
void main() {
  late AppDatabase db;
  setUp(() => db = memoryDb());
  tearDown(() => db.close());

  const day = '2026-11-09'; // t0
  CashDao cash() => db.cashDao;

  Future<SavedBill> bill(int pid, int bid, {String pay = 'Cash', String? customer, Paise paidNow = Paise.zero}) =>
      db.salesDao.saveBill(
        SaveBillRequest(
          lines: [BillLineRequest(productId: pid, batchId: bid, qty: 2)],
          paymentMode: pay,
          customerName: customer ?? '',
          customerPhone: customer == null ? null : '9800000000',
          paidNow: paidNow,
        ),
        rules: const BillRules(),
        at: t0,
      );

  test('the day’s cash: cash bills, cash refunds, dues collected and stockists paid in cash, paid-outs', () async {
    final (pid, bid) = await addMed(db); // ₹30.90, 100 in stock
    final cashBill = await bill(pid, bid); // 61.80 → 62.00
    await bill(pid, bid, pay: 'UPI'); // not cash
    final cancelled = await bill(pid, bid);
    await db.salesDao.cancelInvoice(cancelled.invoiceId, at: t0); // drops out
    await bill(pid, bid, pay: 'Credit', customer: 'Mawii', paidNow: const Paise(2000)); // 20 paid now in cash

    // Return 1 of the cash bill, refunded in cash.
    final item = await (db.select(db.invoiceItems)..where((i) => i.invoiceId.equals(cashBill.invoiceId))).getSingle();
    final cn = await db.salesDao.saveCreditNote(
      SaveCreditNoteRequest(invoiceId: cashBill.invoiceId, lines: [ReturnLineRequest(itemId: item.id, qty: 1)], refundMode: 'Cash'),
      rules: const ReturnRules(),
      at: t0,
    );

    // A dues payment in cash and one by UPI.
    final mawii = (await db.select(db.customers).get()).single.id;
    await db.customersDao.recordPayment(customerId: mawii, date: day, payment: const CustomerPaymentInput(amount: Paise(5000), mode: 'Cash'), at: t0);
    await db.customersDao.recordPayment(customerId: mawii, date: day, payment: const CustomerPaymentInput(amount: Paise(700), mode: 'UPI'), at: t0);

    // Stockist: paid ₹100 cash on delivery; a ₹30 cash payment voided.
    await db.purchasesDao.receive(
      ReceiveRequest(
        supplierName: 'Life Drugs Centre',
        invoiceNo: 'INV1',
        receivedDate: day,
        lines: [ReceiveLineInput(productId: pid, batchNo: 'PCM2611', qty: 1, unit: 'Strip', stockUnits: 1, amount: const Paise(25000))],
        paidNow: const PaymentInput(amount: Paise(10000), mode: 'Cash'),
      ),
      at: t0,
      now: t0,
    );
    final supplier = (await db.select(db.suppliers).get()).single.id;
    final pay = await db.duesDao.recordPayment(supplierId: supplier, date: day, payment: const PaymentInput(amount: Paise(3000), mode: 'Cash'), at: t0);
    await db.duesDao.voidEntry(pay, reason: 'Entered twice', at: t0);

    // Paid-outs: tea ₹15 and auto ₹25 (voided).
    await cash().addPaidOut(date: day, amount: const Paise(1500), note: 'Tea', at: t0);
    final auto = await cash().addPaidOut(date: day, amount: const Paise(2500), note: 'Auto', at: t0);
    await cash().voidPaidOut(auto, reason: 'Paid by UPI');

    final f = await cash().figures(day);
    expect(f.cashSales, cashBill.totals.total);
    expect(f.cashRefunds, cn.totals.total);
    expect((f.duesCollected, f.stockistsPaid, f.paidOuts), (const Paise(7000), const Paise(10000), const Paise(1500)));
    expect(f.expected(const Paise(200000)).value, 200000 + cashBill.totals.total.value - cn.totals.total.value + 7000 - 10000 - 1500);
    expect(await cash().figures('2026-11-10'), const CashFigures());
  });

  test('close, see changes after closing, close again; the next day opens with counted − handed over', () async {
    final (pid, bid) = await addMed(db);
    await bill(pid, bid); // 62.00
    final first = await cash().closeDay(date: day, opening: const Paise(200000), counted: const Paise(206000), handedOver: const Paise(100000), at: t0);
    expect((first.expectedPaise, first.countedPaise, first.differencePaise), (206200, 206000, -200));
    expect(closingFigures(first), await cash().figures(day));

    await bill(pid, bid); // a late sale
    expect(closingFigures(first) == await cash().figures(day), isFalse);
    final again = await cash().closeDay(date: day, opening: const Paise(200000), counted: const Paise(212400), at: t0);
    expect(again.differencePaise, 0);
    expect((await cash().closingOf(day))!.id, again.id);
    expect(await cash().closingsOf(day), hasLength(2));

    final prev = await cash().watchPreviousClosing('2026-11-10').first;
    expect(openingFrom(counted: Paise(prev!.countedPaise), handedOver: Paise(prev.handedOverPaise)), const Paise(212400));
    expect(await cash().watchPreviousClosing(day).first, isNull);
  });

  test('bad input is refused', () async {
    await expectLater(cash().addPaidOut(date: day, amount: Paise.zero, note: 'x', at: t0), throwsA(isA<CashException>()));
    await expectLater(cash().addPaidOut(date: day, amount: const Paise(100), note: ' ', at: t0), throwsA(isA<CashException>()));
    await expectLater(
      cash().closeDay(date: day, opening: Paise.zero, counted: const Paise(100), handedOver: const Paise(200), at: t0),
      throwsA(isA<CashException>()),
    );
    final id = await cash().addPaidOut(date: day, amount: const Paise(100), note: 'Tea', at: t0);
    await cash().voidPaidOut(id, reason: 'Mistake');
    await expectLater(cash().voidPaidOut(id, reason: 'Again'), throwsA(isA<CashException>()));
  });

  test('cash rules: notes add up; opening carries over', () {
    expect(countedFromNotes({500: 4, 100: 12, 10: 3}, coins: const Paise(700)), const Paise(323700));
    expect(countedFromNotes({500: -1}), isNull);
    expect(openingFrom(counted: const Paise(500000), handedOver: const Paise(300000)), const Paise(200000));
    const f = CashFigures(cashSales: Paise(1000), cashRefunds: Paise(100), duesCollected: Paise(50), stockistsPaid: Paise(200), paidOuts: Paise(25));
    expect(f.expected(const Paise(500)), const Paise(1225));
  });
}
