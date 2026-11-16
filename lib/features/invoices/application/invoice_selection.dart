import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'invoice_selection.g.dart';

/// Invoice selected on the Invoices screen (set after saving a bill).
@Riverpod(keepAlive: true)
class SelectedInvoice extends _$SelectedInvoice {
  @override
  int? build() => null;

  // ignore: use_setters_to_change_properties
  void select(int? id) => state = id;
}
