import 'dart:typed_data';

import 'package:printing/printing.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/save_file.dart';
import '../../../core/widgets/widgets.dart';
import '../../billing/data/sales_repository.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import 'invoice_document.dart';
import 'invoice_pdf.dart';

part 'invoice_printer.g.dart';

/// Builds invoice PDFs and sends them to the printer or a file.
///
/// Every print call passes `dynamicLayout: false`. With dynamic layout the
/// macOS plugin blocks the main thread waiting for Dart to re-lay out the
/// PDF, but Dart runs on that same thread, so the app deadlocks the moment
/// the print panel opens. The bytes are pre-built anyway.
class InvoicePrinter {
  InvoicePrinter(this._ref);

  final Ref _ref;

  AppSettings get _settings => _ref.read(settingsProvider);

  Future<InvoiceData?> _load(int invoiceId) async {
    final w = await _ref.read(salesRepositoryProvider).invoice(invoiceId);
    return w == null ? null : InvoiceData.fromDb(w);
  }

  Future<Uint8List> pdfFor(InvoiceData data, {AppSettings? settings}) async {
    final s = settings ?? _settings;
    final doc = buildInvoiceDoc(data, s);
    return buildInvoicePdf(doc, fonts: await InvoiceFonts.load(), accentArgb: colorFromHex(s.accent).toARGB32());
  }

  /// Auto-print after saving: the default printer without a dialog, or the
  /// system print dialog when no printer is set. Errors become a toast —
  /// the bill is already saved.
  Future<void> printSaved(int invoiceId, {int copies = 1}) async {
    try {
      final data = await _load(invoiceId);
      if (data == null) return;
      await printData(data, copies: copies);
    } on Object catch (e) {
      _ref.read(toastsProvider.notifier).show('Printing failed: $e', warn: true);
    }
  }

  Future<void> printData(InvoiceData data, {int copies = 1, AppSettings? settings}) async {
    final s = settings ?? _settings;
    final bytes = await pdfFor(data, settings: s);
    final format = pageFormatFor(s.paper);
    final printer = s.defaultPrinter.isEmpty ? null : Printer(url: s.defaultPrinter);
    if (printer == null) {
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: data.number, format: format, dynamicLayout: false);
      return;
    }
    for (var i = 0; i < copies.clamp(1, 3); i++) {
      await Printing.directPrintPdf(printer: printer, onLayout: (_) async => bytes, name: data.number, format: format, dynamicLayout: false);
    }
  }

  /// Print button on the Invoices screen (shows the system dialog).
  Future<void> printWithDialog(int invoiceId) async {
    final data = await _load(invoiceId);
    if (data == null) return;
    final bytes = await pdfFor(data);
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: data.number, format: pageFormatFor(_settings.paper), dynamicLayout: false);
  }

  /// Download PDF. Returns the saved path or null.
  Future<String?> savePdf(int invoiceId) async {
    final data = await _load(invoiceId);
    if (data == null) return null;
    final bytes = await pdfFor(data);
    return saveBytesAs('${data.number.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '-')}.pdf', bytes);
  }

  Future<List<Printer>> printers() => Printing.listPrinters();
}

@Riverpod(keepAlive: true)
InvoicePrinter invoicePrinter(Ref ref) => InvoicePrinter(ref);
