import 'package:printing/printing.dart';
import 'package:rx_desk/features/invoices/application/invoice_document.dart';
import 'package:rx_desk/features/invoices/application/invoice_printer.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';

/// Records print requests instead of calling the printing plugin.
class FakeInvoicePrinter extends InvoicePrinter {
  FakeInvoicePrinter(super.ref);

  final List<(int, int)> printed = [];
  final List<String> printedData = [];

  @override
  Future<void> printSaved(int invoiceId, {int copies = 1}) async => printed.add((invoiceId, copies));

  @override
  Future<void> printData(InvoiceData data, {int copies = 1, AppSettings? settings}) async => printedData.add(data.number);

  @override
  Future<void> printWithDialog(int invoiceId) async => printed.add((invoiceId, 1));

  @override
  Future<String?> savePdf(int invoiceId) async => '/tmp/$invoiceId.pdf';

  @override
  Future<List<Printer>> printers() async => const [];
}

final fakePrinterOverride = invoicePrinterProvider.overrideWith(FakeInvoicePrinter.new);
