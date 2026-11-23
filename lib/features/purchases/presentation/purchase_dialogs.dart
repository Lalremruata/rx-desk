import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/catalog_dao.dart';
import '../../../core/db/daos/dues_dao.dart';
import '../../../core/db/daos/purchases_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/db/models.dart';
import '../../../core/money/paise.dart';
import '../../../core/purchases/dues_rules.dart';
import '../../../core/purchases/purchase_rules.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/pack.dart';
import '../../../core/widgets/widgets.dart';
import '../../inventory/application/inventory_providers.dart';
import '../../inventory/application/inventory_rules.dart';
import '../../inventory/data/inventory_repository.dart';
import '../../inventory/presentation/inventory_dialogs.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/guarded_actions.dart';
import '../../staff/application/session.dart';
import '../application/purchases_providers.dart';

Future<void> showNewOrderDialog(BuildContext context, {List<StockRow> products = const []}) =>
    showAppDialog<void>(context, maxWidth: 820, topPadding: 40, builder: (_) => NewOrderDialog(initialProducts: products));

/// Receive one stockist invoice, optionally against [orders].
Future<void> showReceiveInvoiceDialog(BuildContext context, {List<OrderRow> orders = const []}) =>
    showAppDialog<void>(context, maxWidth: 860, topPadding: 32, barrierDismissible: false, builder: (_) => ReceiveInvoiceDialog(orders: orders));

void toastPurchaseError(WidgetRef ref, Object e) {
  final msg = switch (e) {
    PurchaseException(:final message) => message,
    CatalogException(:final message) => message,
    PermissionDenied() => '$e',
    _ => 'Something went wrong: $e',
  };
  ref.read(toastsProvider.notifier).show(msg, warn: true);
}

class PurchaseDialogHeader extends StatelessWidget {
  const PurchaseDialogHeader({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppType.dialogTitle),
              if (subtitle != null) ...[const SizedBox(height: 4), Text(subtitle!, style: AppType.small.copyWith(color: AppColors.textSecondary))],
            ],
          ),
        ),
        IconButton(tooltip: 'Close', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded, size: 20)),
      ],
    );
  }
}

/// A date field that opens the date picker.
class PurchaseDateField extends StatelessWidget {
  const PurchaseDateField({super.key, required this.label, required this.value, required this.onChanged, this.fieldKey});

  final String label;

  /// 'YYYY-MM-DD'.
  final String value;
  final ValueChanged<String> onChanged;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppType.label),
        const SizedBox(height: 6),
        AppButton.secondary(
          key: fieldKey,
          label: dayLabel(value),
          icon: Icons.calendar_today_rounded,
          onPressed: () async {
            final d = parseDateKey(value);
            final picked = await showDatePicker(context: context, initialDate: d, firstDate: DateTime(2020), lastDate: DateTime(2100));
            if (picked != null) onChanged(dateKey(picked));
          },
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

/// Catalog search with a short result list. Optional actions for free text
/// and adding a new medicine.
class ProductPicker extends ConsumerStatefulWidget {
  const ProductPicker({
    super.key,
    required this.onPicked,
    this.label = 'Find medicine',
    this.hint = 'Name, salt, batch or barcode…',
    this.onFreeText,
    this.allowAddMedicine = false,
    this.autofocus = false,
    this.fieldKey,
  });

  final ValueChanged<StockRow> onPicked;
  final String label;
  final String hint;

  /// Shown as "Add "…" as free text" when non-null.
  final ValueChanged<String>? onFreeText;

  /// Offers "Add new medicine" (opens the Add medicine dialog).
  final bool allowAddMedicine;
  final bool autofocus;
  final Key? fieldKey;

  @override
  ConsumerState<ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends ConsumerState<ProductPicker> {
  String query = '';
  List<StockRow> results = const [];
  Timer? _debounce;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() => query = v);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () async {
      final seq = ++_seq;
      final r = v.trim().isEmpty ? SearchResults.empty : await ref.read(inventoryRepositoryProvider).search(v, limit: 6);
      if (mounted && seq == _seq) setState(() => results = r.rows);
    });
  }

  void _reset() => setState(() {
    query = '';
    results = const [];
    _seq++;
  });

  void _pick(StockRow r) {
    widget.onPicked(r);
    _reset();
  }

  Future<void> _addMedicine() async {
    // Called from a stockist receipt: the receipt line adds the stock, so
    // no opening-stock fields (they would count it twice).
    final id = await showAddMedicineDialog(context, initialName: query.trim(), showInInventory: false, allowOpeningStock: false);
    if (id == null || !mounted) return;
    final row = await ref.read(inventoryRepositoryProvider).stockRow(id);
    if (row != null && mounted) _pick(row);
  }

  @override
  Widget build(BuildContext context) {
    final q = query.trim();
    final canEdit = ref.watch(canProvider(Permission.changeStock));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        AppTextField(
          fieldKey: widget.fieldKey,
          label: widget.label,
          hint: widget.hint,
          value: query,
          autofocus: widget.autofocus,
          prefixIcon: Icons.search_rounded,
          onChanged: _onChanged,
          onSubmitted: (_) {
            if (results.isNotEmpty) {
              _pick(results.first);
            } else if (q.isNotEmpty && widget.onFreeText != null) {
              widget.onFreeText!(q);
              _reset();
            }
          },
        ),
        if (q.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
              borderRadius: AppRadius.controlAll,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final r in results)
                  InkWell(
                    key: ValueKey('pick-${r.id}'),
                    onTap: () => _pick(r),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: AppSizes.controlMin),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(r.name, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis),
                                Text('${r.salt} · ${r.pack} · ${r.maker}', style: AppType.caption, overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                          const SizedBox(width: AppSpace.sm),
                          StatusBadge.tag(
                            '${formatCount(r.saleable)} in stock',
                            tone: r.isOut
                                ? StatusTone.danger
                                : r.isLow
                                ? StatusTone.warning
                                : StatusTone.neutral,
                          ),
                        ],
                      ),
                    ),
                  ),
                if (results.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Text('No medicine matches “$q”.', style: AppType.small.copyWith(color: AppColors.textSecondary)),
                  ),
                if (widget.onFreeText != null || (widget.allowAddMedicine && canEdit))
                  Container(
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: AppColors.divider)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Wrap(
                      spacing: AppSpace.sm,
                      children: [
                        if (widget.onFreeText != null)
                          TextButton.icon(
                            key: const ValueKey('pick-free-text'),
                            onPressed: () {
                              widget.onFreeText!(q);
                              _reset();
                            },
                            icon: const Icon(Icons.edit_note_rounded, size: 18),
                            label: Text('Add “$q” as free text'),
                          ),
                        if (widget.allowAddMedicine && canEdit)
                          TextButton.icon(
                            key: const ValueKey('pick-add-medicine'),
                            onPressed: _addMedicine,
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('Add new medicine'),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// New order

class _DraftOrderLine {
  _DraftOrderLine({this.productId, required this.name, this.qty = '', this.unit = 'Box'});

  final int key = _nextKey++;
  static int _nextKey = 0;

  final int? productId;
  final String name;
  String qty;
  String unit;
  String note = '';
}

/// New order (SPEC §5.9): a day's list of items to order.
class NewOrderDialog extends ConsumerStatefulWidget {
  const NewOrderDialog({super.key, this.initialProducts = const []});

  final List<StockRow> initialProducts;

  @override
  ConsumerState<NewOrderDialog> createState() => _NewOrderDialogState();
}

class _NewOrderDialogState extends ConsumerState<NewOrderDialog> {
  late String date = dateKey(ref.read(nowProvider)());
  late final List<_DraftOrderLine> lines = [for (final p in widget.initialProducts) _fromProduct(p)];
  Set<int> errors = const {};
  bool saving = false;
  bool loadingLow = false;

  _DraftOrderLine _fromProduct(StockRow p) => _DraftOrderLine(
    productId: p.id,
    name: p.name,
    unit: defaultUnitFor(p.category),
    qty: p.isLow ? '${suggestedOrderQty(saleable: p.saleablePacks, reorderLevel: p.reorderLevel)}' : '',
  );

  void _add(StockRow p) {
    if (lines.any((l) => l.productId == p.id)) {
      ref.read(toastsProvider.notifier).show('${p.name} is already on this order');
      return;
    }
    setState(() => lines.add(_fromProduct(p)));
  }

  Future<void> _addLowStock() async {
    setState(() => loadingLow = true);
    try {
      final low = await ref.read(inventoryRepositoryProvider).reorderSoon(limit: 50);
      final have = {for (final l in lines) l.productId};
      final fresh = [
        for (final p in low)
          if (!have.contains(p.id)) _fromProduct(p),
      ];
      setState(() => lines.addAll(fresh));
      ref.read(toastsProvider.notifier).show(fresh.isEmpty ? 'No more low-stock items to add' : '${fresh.length} low-stock items added');
    } finally {
      if (mounted) setState(() => loadingLow = false);
    }
  }

  Future<void> _save() async {
    final bad = {
      for (final l in lines)
        if ((int.tryParse(l.qty) ?? 0) < 1) l.key,
    };
    setState(() => errors = bad);
    if (lines.isEmpty) {
      ref.read(toastsProvider.notifier).show('Add at least one item', warn: true);
      return;
    }
    if (bad.isNotEmpty) return;
    setState(() => saving = true);
    try {
      final ids = await ref.read(guardedActionsProvider).placeOrder(date, [
        for (final l in lines) NewOrderLine(productId: l.productId, itemName: l.name, qty: int.parse(l.qty), unit: l.unit, note: l.note),
      ]);
      ref.read(toastsProvider.notifier).show('${ids.length} ${ids.length == 1 ? 'item' : 'items'} added to the order for ${dayLabel(date)}');
      ref.read(bookDayProvider.notifier).set(date);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      toastPurchaseError(ref, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppDialogPanel(
      semanticLabel: 'New order',
      children: [
        const PurchaseDialogHeader(title: 'New order', subtitle: 'What you are ordering today. The stockist is recorded when the goods arrive.'),
        LayoutBuilder(
          builder: (context, c) {
            final date = SizedBox(
              width: 220,
              child: PurchaseDateField(
                fieldKey: const ValueKey('order-date'),
                label: 'Order date',
                value: this.date,
                onChanged: (v) => setState(() => this.date = v),
              ),
            );
            final picker = ProductPicker(
              fieldKey: const ValueKey('order-search'),
              label: 'Add item',
              autofocus: true,
              onPicked: _add,
              onFreeText: (t) => setState(() => lines.add(_DraftOrderLine(name: t))),
            );
            if (c.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  date,
                  const SizedBox(height: AppSpace.md),
                  picker,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                date,
                const SizedBox(width: AppSpace.lg),
                Expanded(child: picker),
              ],
            );
          },
        ),
        Row(
          children: [
            Expanded(child: Text('${lines.length} ${lines.length == 1 ? 'item' : 'items'}', style: AppType.bodyStrong)),
            AppButton.secondary(
              key: const ValueKey('order-add-low'),
              label: loadingLow ? 'Adding…' : 'Add low-stock items',
              icon: Icons.playlist_add_rounded,
              height: 36,
              onPressed: loadingLow ? null : _addLowStock,
            ),
          ],
        ),
        if (lines.isEmpty)
          const EmptyState(title: 'No items yet', message: 'Search the catalogue, type a name as free text, or add low-stock items.')
        else
          Column(
            children: [
              for (final (i, l) in lines.indexed) ...[
                if (i > 0) const Divider(height: 1),
                _OrderLineEditor(
                  key: ValueKey('order-line-${l.key}'),
                  index: i,
                  line: l,
                  error: errors.contains(l.key),
                  onChanged: () => setState(() {}),
                  onRemove: () => setState(() => lines.remove(l)),
                ),
              ],
            ],
          ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(key: const ValueKey('order-save'), label: saving ? 'Saving…' : 'Save order', onPressed: saving ? null : _save),
          ],
        ),
      ],
    );
  }
}

class _OrderLineEditor extends StatelessWidget {
  const _OrderLineEditor({super.key, required this.index, required this.line, required this.error, required this.onChanged, required this.onRemove});

  final int index;
  final _DraftOrderLine line;
  final bool error;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final name = Row(
      children: [
        SizedBox(width: 28, child: Text('${index + 1}', style: AppType.caption)),
        Flexible(
          child: Text(line.name, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis),
        ),
        if (line.productId == null) ...[const SizedBox(width: 6), const StatusBadge.tag('Free text')],
      ],
    );
    final qty = SizedBox(
      width: 84,
      child: AppTextField(
        fieldKey: ValueKey('order-qty-$index'),
        label: '',
        hint: 'Qty',
        value: line.qty,
        error: error ? 'Qty' : null,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (v) {
          line.qty = v;
          onChanged();
        },
      ),
    );
    final unit = AppDropdown<String>(
      value: line.unit,
      width: 112,
      semanticLabel: 'Unit',
      options: [for (final u in purchaseUnits) DropdownOption(u, u)],
      onChanged: (v) {
        line.unit = v;
        onChanged();
      },
    );
    final note = AppTextField(
      label: '',
      hint: 'Note (e.g. 32x15)',
      value: line.note,
      onChanged: (v) {
        line.note = v;
        onChanged();
      },
    );
    final remove = IconButton(
      tooltip: 'Remove ${line.name}',
      onPressed: onRemove,
      icon: const Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.textMuted),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth < 620) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: name),
                    remove,
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    qty,
                    const SizedBox(width: AppSpace.sm),
                    unit,
                    const SizedBox(width: AppSpace.sm),
                    Expanded(child: note),
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: name),
              const SizedBox(width: AppSpace.sm),
              qty,
              const SizedBox(width: AppSpace.sm),
              unit,
              const SizedBox(width: AppSpace.sm),
              SizedBox(width: 170, child: note),
              remove,
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Receive invoice

class _DraftReceiveLine {
  _DraftReceiveLine({this.order, StockRow? product, required this.qty, required this.unit, required this.moreExpected}) {
    setProduct(product);
  }

  final int key = _nextKey++;
  static int _nextKey = 0;

  final OrderRow? order;
  StockRow? product;
  String qty;
  String unit;

  /// Packs (strips) in one box — asked when [unit] is Box; prefilled from
  /// the medicine and saved back on it with the receipt.
  String packsPerBox = '';
  String batch = '';
  String expiry = '';

  /// In packs (strips); × units per pack on save.
  String stockUnits = '';
  bool stockUnitsEdited = false;
  String amount = '';
  bool moreExpected;

  bool get needsPacksPerBox => unitNeedsPacksPerBox(unit);

  /// Sets the medicine, taking its remembered strips per box.
  void setProduct(StockRow? p) {
    product = p;
    if (p?.packsPerBox case final n?) packsPerBox = '$n';
    recomputeStock();
  }

  /// "Add to stock" follows qty × strips per box until the user types it.
  void recomputeStock() {
    if (stockUnitsEdited) return;
    final n = defaultStockPacks(qty: int.tryParse(qty) ?? 0, unit: unit, packsPerBox: int.tryParse(packsPerBox));
    stockUnits = n == null ? '' : '$n';
  }
}

/// Receive one stockist invoice (SPEC §4.7 / §5.9).
class ReceiveInvoiceDialog extends ConsumerStatefulWidget {
  const ReceiveInvoiceDialog({super.key, this.orders = const []});

  final List<OrderRow> orders;

  @override
  ConsumerState<ReceiveInvoiceDialog> createState() => _ReceiveInvoiceDialogState();
}

class _ReceiveInvoiceDialogState extends ConsumerState<ReceiveInvoiceDialog> {
  String supplier = '', invoiceNo = '';
  late String date = dateKey(ref.read(nowProvider)());
  late final List<_DraftReceiveLine> lines = [
    for (final o in widget.orders) _DraftReceiveLine(order: o, qty: '${o.due > 0 ? o.due : o.qty}', unit: o.unit, moreExpected: false),
  ];
  Map<String, String> errors = const {};
  bool saving = false;

  // Bill & payment (SPEC §4.8).
  String billTotal = '';
  bool billTotalEdited = false;
  String? dueDate;
  String paidNow = '', paidMode = 'Cash', paidRef = '';

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  int _creditDays(List<Supplier> suppliers) {
    final n = supplier.trim().toLowerCase();
    for (final s in suppliers) {
      if (s.name.toLowerCase() == n) return s.creditDays;
    }
    return 30;
  }

  Paise? get _billTotal => billTotalEdited ? Paise.tryParse(billTotal) : _total;

  Future<void> _loadProducts() async {
    final repo = ref.read(inventoryRepositoryProvider);
    for (final l in lines) {
      final pid = l.order?.productId;
      if (pid == null) continue;
      final row = await repo.stockRow(pid);
      if (!mounted) return;
      setState(() => l.setProduct(row));
    }
  }

  Paise get _total => lines.map((l) => Paise.tryParse(l.amount) ?? Paise.zero).sum();

  Map<String, String> _validate(DateTime now, int window) {
    final e = <String, String>{
      if (supplier.trim().isEmpty) 'supplier': 'Enter the stockist',
      if (invoiceNo.trim().isEmpty) 'invoice': 'Enter their invoice number',
      if (_billTotal == null) 'bill': 'Amount, e.g. 10250.00',
      if (paidNow.trim().isNotEmpty && Paise.tryParse(paidNow) == null) 'paid': 'Amount',
      if (dueDate != null && dueDate!.compareTo(date) < 0) 'due': 'Before the date received',
    };
    for (final l in lines) {
      final k = l.key;
      if (l.product == null) e['$k-product'] = 'Pick the medicine this is';
      if ((int.tryParse(l.qty) ?? 0) < 1) e['$k-qty'] = 'Qty';
      if ((int.tryParse(l.stockUnits) ?? 0) < 1) e['$k-units'] = 'Units';
      if (l.product case final p? when l.needsPacksPerBox) {
        final n = int.tryParse(l.packsPerBox) ?? 0;
        if (n < 1 || n > maxPacksPerBox) {
          e['$k-perbox'] = l.packsPerBox.trim().isEmpty ? 'How many ${PackNouns.of(p.category).packs} in a box?' : '1–$maxPacksPerBox';
        }
      }
      if (l.batch.trim().isEmpty) e['$k-batch'] = 'Batch no.';
      if (l.amount.trim().isNotEmpty && Paise.tryParse(l.amount) == null) e['$k-amount'] = 'Amount';
      final batches = l.product == null ? null : ref.read(productBatchesProvider(l.product!.id)).value;
      final existing = _existingBatch(l, batches);
      final exp = existing?.expiry ?? parseExpiryInput(l.expiry);
      if (l.batch.trim().isNotEmpty && exp == null) {
        e['$k-expiry'] = 'MM/YYYY';
      } else if (exp != null && receiveExpiryCheck(exp, now, window) == ExpiryCheck.expired) {
        e['$k-expiry'] = 'Expired';
      }
    }
    return e;
  }

  static StockBatch? _existingBatch(_DraftReceiveLine l, List<StockBatch>? batches) {
    final b = l.batch.trim().toUpperCase();
    if (b.isEmpty || batches == null) return null;
    for (final x in batches) {
      if (x.batchNo == b) return x;
    }
    return null;
  }

  Future<void> _save() async {
    final now = ref.read(nowProvider)();
    final window = ref.read(settingsProvider).expiryWindowMonths;
    final e = _validate(now, window);
    setState(() => errors = e);
    if (lines.isEmpty) {
      ref.read(toastsProvider.notifier).show('Add at least one item received', warn: true);
      return;
    }
    if (e.isNotEmpty) {
      ref.read(toastsProvider.notifier).show('Check the highlighted fields', warn: true);
      return;
    }
    setState(() => saving = true);
    final paid = paidNow.trim().isEmpty ? null : Paise.tryParse(paidNow);
    try {
      final saved = await ref
          .read(guardedActionsProvider)
          .receivePurchase(
            ReceiveRequest(
              supplierName: supplier,
              invoiceNo: invoiceNo,
              receivedDate: date,
              lines: [
                for (final l in lines)
                  ReceiveLineInput(
                    orderLineId: l.order?.id,
                    productId: l.product!.id,
                    batchNo: l.batch,
                    expiry: parseExpiryInput(l.expiry),
                    qty: int.parse(l.qty),
                    unit: l.unit,
                    // Typed in packs for loose-sold medicines; stock is in units.
                    stockUnits: int.parse(l.stockUnits) * l.product!.packSize,
                    amount: Paise.tryParse(l.amount) ?? Paise.zero,
                    moreExpected: l.moreExpected,
                    packsPerBox: l.needsPacksPerBox ? int.tryParse(l.packsPerBox) : null,
                  ),
              ],
              billTotal: _billTotal,
              dueDate: dueDate,
              paidNow: paid == null || paid.value == 0 ? null : PaymentInput(amount: paid, mode: paidMode, reference: paidRef),
            ),
          );
      ref.read(selectedOrderLinesProvider.notifier).clear();
      ref
          .read(toastsProvider.notifier)
          .show(
            'Invoice ${invoiceNo.trim()} saved · ${saved.lines} ${saved.lines == 1 ? 'line' : 'lines'} · '
            '+${formatCount(saved.stockUnits)} units · ${formatInr(saved.billTotal)}'
            '${paid == null || paid.value == 0 ? '' : ' · ${formatInr(paid)} paid'}',
          );
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      toastPurchaseError(ref, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void _addExtra(StockRow p) => setState(() => lines.add(_DraftReceiveLine(product: p, qty: '', unit: defaultUnitFor(p.category), moreExpected: false)));

  @override
  Widget build(BuildContext context) {
    final suppliers = ref.watch(suppliersProvider).value ?? const <Supplier>[];
    final s = supplier.trim().toLowerCase();
    final suggestions = s.isEmpty
        ? const <Supplier>[]
        : [
            for (final x in suppliers)
              if (x.name.toLowerCase().contains(s) && x.name.toLowerCase() != s) x,
          ].take(5).toList();
    final window = ref.watch(settingsProvider.select((x) => x.expiryWindowMonths));
    final now = ref.watch(nowProvider)();

    return AppDialogPanel(
      semanticLabel: 'Receive invoice',
      children: [
        const PurchaseDialogHeader(title: 'Receive invoice', subtitle: 'One stockist invoice. Each line is added to batch stock when you save.'),
        FieldGrid(
          minColumnWidth: 220,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                AppTextField(
                  fieldKey: const ValueKey('recv-supplier'),
                  label: 'Stockist',
                  hint: 'e.g. Life Drugs Centre',
                  value: supplier,
                  autofocus: true,
                  error: errors['supplier'],
                  onChanged: (v) => setState(() => supplier = v),
                ),
                if (suggestions.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final x in suggestions)
                        ActionChip(key: ValueKey('supplier-${x.id}'), label: Text(x.name), onPressed: () => setState(() => supplier = x.name)),
                    ],
                  ),
                ],
              ],
            ),
            AppTextField(
              fieldKey: const ValueKey('recv-invoice'),
              label: 'Their invoice no.',
              hint: 'e.g. FP/401/26-27',
              value: invoiceNo,
              error: errors['invoice'],
              onChanged: (v) => setState(() => invoiceNo = v),
            ),
            PurchaseDateField(fieldKey: const ValueKey('recv-date'), label: 'Received on', value: date, onChanged: (v) => setState(() => date = v)),
          ],
        ),
        for (final (i, l) in lines.indexed)
          _ReceiveLineCard(
            key: ValueKey('recv-line-${l.key}'),
            index: i,
            line: l,
            errors: errors,
            now: now,
            window: window,
            onChanged: () => setState(() {}),
            onRemove: () => setState(() => lines.remove(l)),
          ),
        ProductPicker(
          fieldKey: const ValueKey('recv-add-item'),
          label: lines.isEmpty ? 'Add item received' : 'Add an item that wasn’t on the order',
          allowAddMedicine: true,
          onPicked: _addExtra,
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: const BoxDecoration(color: AppColors.surfaceAlt, borderRadius: AppRadius.controlAll),
          child: Row(
            children: [
              Expanded(child: Text('${lines.length} ${lines.length == 1 ? 'line' : 'lines'}', style: AppType.body)),
              Text('Lines total ', style: AppType.body),
              Text(
                formatInr(_total),
                key: const ValueKey('recv-total'),
                style: AppType.bodyStrong.copyWith(fontFeatures: AppType.tabular),
              ),
            ],
          ),
        ),
        _BillAndPayment(
          billTotal: billTotalEdited ? billTotal : _total.toInputString(),
          linesTotal: _total,
          billed: _billTotal,
          dueDate: dueDate ?? dueDateFor(date, _creditDays(suppliers)),
          creditDays: _creditDays(suppliers),
          receivedDate: date,
          paidNow: paidNow,
          paidMode: paidMode,
          paidRef: paidRef,
          errors: errors,
          canPay: ref.watch(canProvider(Permission.supplierPayments)),
          onBillTotal: (v) => setState(() {
            billTotal = v;
            billTotalEdited = true;
          }),
          onDueDate: (v) => setState(() => dueDate = v),
          onPaidNow: (v) => setState(() => paidNow = v),
          onPaidMode: (v) => setState(() => paidMode = v),
          onPaidRef: (v) => setState(() => paidRef = v),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(key: const ValueKey('recv-save-invoice'), label: saving ? 'Saving…' : 'Save and add to stock', onPressed: saving ? null : _save),
          ],
        ),
      ],
    );
  }
}

/// Invoice total as billed, due date and pay-on-delivery (SPEC §4.8).
class _BillAndPayment extends StatelessWidget {
  const _BillAndPayment({
    required this.billTotal,
    required this.linesTotal,
    required this.billed,
    required this.dueDate,
    required this.creditDays,
    required this.receivedDate,
    required this.paidNow,
    required this.paidMode,
    required this.paidRef,
    required this.errors,
    required this.canPay,
    required this.onBillTotal,
    required this.onDueDate,
    required this.onPaidNow,
    required this.onPaidMode,
    required this.onPaidRef,
  });

  final String billTotal;
  final Paise linesTotal;
  final Paise? billed;
  final String dueDate;
  final int creditDays;
  final String receivedDate;
  final String paidNow;
  final String paidMode;
  final String paidRef;
  final Map<String, String> errors;
  final bool canPay;
  final ValueChanged<String> onBillTotal;
  final ValueChanged<String> onDueDate;
  final ValueChanged<String> onPaidNow;
  final ValueChanged<String> onPaidMode;
  final ValueChanged<String> onPaidRef;

  @override
  Widget build(BuildContext context) {
    final money = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];
    const kb = TextInputType.numberWithOptions(decimal: true);
    final diff = billed == null ? null : billed! - linesTotal;
    final paid = Paise.tryParse(paidNow) ?? Paise.zero;
    final owed = billed == null ? null : billed! - paid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldGrid(
          minColumnWidth: 220,
          children: [
            AppTextField(
              fieldKey: const ValueKey('recv-bill-total'),
              label: 'Invoice total (as billed, ₹)',
              hint: '0.00',
              value: billTotal,
              error: errors['bill'],
              keyboardType: kb,
              inputFormatters: money,
              onChanged: onBillTotal,
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                PurchaseDateField(fieldKey: const ValueKey('recv-due'), label: 'Due date ($creditDays days credit)', value: dueDate, onChanged: onDueDate),
                if (errors['due'] case final e?) Text(e, style: AppType.caption.copyWith(color: StatusTone.danger.colors.fg)),
              ],
            ),
          ],
        ),
        if (diff != null && diff.value != 0) ...[
          const SizedBox(height: 6),
          Text('Lines ${formatInr(linesTotal)} · difference ${formatInr(diff)} (GST / discount / round-off on their bill)', style: AppType.caption),
        ],
        if (canPay) ...[
          const SizedBox(height: AppSpace.md),
          Text('Paid on delivery (optional)', style: AppType.label),
          const SizedBox(height: 6),
          FieldGrid(
            minColumnWidth: 200,
            children: [
              AppTextField(
                fieldKey: const ValueKey('recv-paid'),
                label: 'Amount paid now (₹)',
                hint: '0.00',
                value: paidNow,
                error: errors['paid'],
                keyboardType: kb,
                inputFormatters: money,
                onChanged: onPaidNow,
              ),
              FieldSpan(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Paid by', style: AppType.label),
                    const SizedBox(height: 6),
                    SegmentedPills<String>(
                      semanticLabel: 'Paid by',
                      options: [for (final m in paymentModes) PillOption(m, m)],
                      selected: paidMode,
                      onChanged: onPaidMode,
                    ),
                  ],
                ),
              ),
              AppTextField(label: 'Reference', hint: 'Cheque no / UTR', value: paidRef, onChanged: onPaidRef),
            ],
          ),
        ],
        if (owed != null) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            owed.value > 0
                ? '${formatInr(owed)} will be owed to the stockist, due ${dayLabel(dueDate)}.'
                : owed.value < 0
                ? '${formatInr(-owed)} more than the bill — kept on account.'
                : 'Fully paid.',
            key: const ValueKey('recv-owed'),
            style: AppType.smallStrong,
          ),
        ],
      ],
    );
  }
}

class _ReceiveLineCard extends ConsumerWidget {
  const _ReceiveLineCard({
    super.key,
    required this.index,
    required this.line,
    required this.errors,
    required this.now,
    required this.window,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final _DraftReceiveLine line;
  final Map<String, String> errors;
  final DateTime now;
  final int window;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  /// Applies [f]; when qty or unit changed ([recompute]) resets "still
  /// expecting more" to its default for the new quantity.
  void _set(void Function() f, {bool recompute = false}) {
    f();
    final o = line.order;
    if (recompute && o != null) {
      line.moreExpected = defaultMoreExpected(
        orderedQty: o.qty,
        orderedUnit: o.unit,
        alreadyReceivedSameUnit: o.receivedSameUnit,
        qty: int.tryParse(line.qty) ?? 0,
        unit: line.unit,
      );
    }
    onChanged();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final k = line.key;
    final o = line.order;
    final p = line.product;
    final batches = p == null ? null : ref.watch(productBatchesProvider(p.id)).value;
    final existing = _ReceiveInvoiceDialogState._existingBatch(line, batches);
    final exp = existing?.expiry ?? parseExpiryInput(line.expiry);
    final check = exp == null ? null : receiveExpiryCheck(exp, now, window);
    final digits = [FilteringTextInputFormatter.digitsOnly];
    final short = o != null && line.unit == o.unit && o.receivedSameUnit + (int.tryParse(line.qty) ?? 0) < o.qty;
    final otherUnit = o != null && line.unit != o.unit;
    final nouns = PackNouns.of(p?.category ?? '');
    final boxQty = int.tryParse(line.qty) ?? 0;
    final perBox = int.tryParse(line.packsPerBox) ?? 0;
    final boxMaths = p == null || !line.needsPacksPerBox || boxQty < 1 || perBox < 1 || perBox > maxPacksPerBox
        ? null
        : '${qtyLabel(boxQty, line.unit)} × $perBox = ${formatCount(boxQty * perBox)} ${nouns.packWord(boxQty * perBox)}'
              '${p.packsPerBox == perBox ? '' : ' · $perBox per box will be remembered for ${p.name}'}';

    final batchHint = p == null
        ? null
        : existing != null
        ? 'Adding to batch ${existing.batchNo} (exp ${formatExpiry(existing.expiry)}).'
        : line.batch.trim().isEmpty
        ? (batches == null || batches.isEmpty ? 'No batches yet.' : 'Existing: ${batches.map((b) => b.batchNo).join(', ')}')
        : 'New batch — enter its expiry.';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(width: 26, child: Text('${index + 1}', style: AppType.caption)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p?.name ?? o?.itemName ?? '', style: AppType.bodyStrong, overflow: TextOverflow.ellipsis),
                    Text(
                      o == null
                          ? 'Not on an order${p == null ? '' : ' · ${p.pack}'}'
                          : 'Ordered ${qtyLabel(o.qty, o.unit)} on ${dayLabel(o.orderDate)}'
                                '${o.receivedLabel.isEmpty ? '' : ' · ${o.receivedLabel} already in'}'
                                '${p == null ? '' : ' · pack ${p.pack}'}',
                      style: AppType.caption,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remove line',
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          if (p == null) ...[
            Text(
              '“${o?.itemName}” was ordered as free text. Pick the medicine it is, or add it to the catalogue.',
              style: AppType.small.copyWith(color: StatusTone.warning.colors.fg),
            ),
            const SizedBox(height: AppSpace.sm),
            ProductPicker(
              fieldKey: ValueKey('recv-link-$index'),
              label: 'Medicine',
              allowAddMedicine: true,
              onPicked: (r) => _set(() => line.setProduct(r)),
            ),
            if (errors['$k-product'] case final e?) ...[
              const SizedBox(height: 4),
              Text(e, style: AppType.caption.copyWith(color: StatusTone.danger.colors.fg)),
            ],
          ] else ...[
            FieldGrid(
              minColumnWidth: 130,
              gap: AppSpace.md,
              children: [
                AppTextField(
                  fieldKey: ValueKey('recv-qty-$index'),
                  label: 'Qty received',
                  hint: '0',
                  value: line.qty,
                  error: errors['$k-qty'],
                  keyboardType: TextInputType.number,
                  inputFormatters: digits,
                  onChanged: (v) => _set(recompute: true, () {
                    line.qty = v;
                    line.recomputeStock();
                  }),
                ),
                AppDropdown<String>(
                  label: 'Unit',
                  labelAbove: true,
                  value: line.unit,
                  options: [for (final u in purchaseUnits) DropdownOption(u, u)],
                  onChanged: (v) => _set(recompute: true, () {
                    line.unit = v;
                    line.recomputeStock();
                  }),
                ),
                if (line.needsPacksPerBox)
                  AppTextField(
                    fieldKey: ValueKey('recv-perbox-$index'),
                    label: nouns.perBoxLabel,
                    hint: p.packsPerBox == null ? 'e.g. 10' : '${p.packsPerBox}',
                    value: line.packsPerBox,
                    error: errors['$k-perbox'],
                    keyboardType: TextInputType.number,
                    inputFormatters: digits,
                    onChanged: (v) => _set(() {
                      line.packsPerBox = v;
                      line.recomputeStock();
                    }),
                  ),
                AppTextField(
                  fieldKey: ValueKey('recv-batch-$index'),
                  label: 'Batch no.',
                  hint: 'New or existing',
                  value: line.batch,
                  error: errors['$k-batch'],
                  onChanged: (v) => _set(() => line.batch = v.toUpperCase()),
                ),
                AppTextField(
                  fieldKey: ValueKey('recv-expiry-$index'),
                  label: 'Expiry',
                  hint: existing != null ? formatExpiry(existing.expiry) : 'MM/YYYY',
                  value: existing != null ? expiryToInput(existing.expiry) : line.expiry,
                  enabled: existing == null,
                  error: errors['$k-expiry'],
                  keyboardType: TextInputType.datetime,
                  onChanged: (v) => _set(() => line.expiry = v),
                ),
                AppTextField(
                  fieldKey: ValueKey('recv-units-$index'),
                  label: p.sellsLoose ? 'Add to stock (${nouns.packs} of ${p.packSize})' : 'Add to stock (${nouns.packs})',
                  hint: '0',
                  value: line.stockUnits,
                  error: errors['$k-units'],
                  keyboardType: TextInputType.number,
                  inputFormatters: digits,
                  onChanged: (v) => _set(() {
                    line.stockUnits = v;
                    line.stockUnitsEdited = true;
                  }),
                ),
                AppTextField(
                  fieldKey: ValueKey('recv-amount-$index'),
                  label: 'Amount (₹)',
                  hint: 'As on their invoice',
                  value: line.amount,
                  error: errors['$k-amount'],
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  onChanged: (v) => _set(() => line.amount = v),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.lg,
              runSpacing: 4,
              children: [
                if (boxMaths != null) Text(boxMaths, key: ValueKey('recv-boxmaths-$index'), style: AppType.smallStrong),
                if (batchHint != null) Text(batchHint, style: AppType.caption),
                if (check == ExpiryCheck.near)
                  Text(
                    'Expires ${formatExpiry(exp!)} — inside your $window-month expiry window.',
                    style: AppType.caption.copyWith(color: StatusTone.warning.colors.fg),
                  ),
                if (check == ExpiryCheck.expired)
                  Text('Expired ${formatExpiry(exp!)} — expired stock can’t be received.', style: AppType.caption.copyWith(color: StatusTone.danger.colors.fg)),
                Text('Stock is counted in sale units (pack: ${p.pack}).', style: AppType.caption),
              ],
            ),
            if (o != null && (short || otherUnit)) ...[
              const SizedBox(height: AppSpace.sm),
              ToggleRow(
                label: 'Still expecting more from this order',
                help: short
                    ? 'Off: the rest isn’t coming — the line is closed short.'
                    : 'Received in a different unit from the order. Off: the line is complete.',
                value: line.moreExpected,
                onChanged: (v) => _set(() => line.moreExpected = v),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
