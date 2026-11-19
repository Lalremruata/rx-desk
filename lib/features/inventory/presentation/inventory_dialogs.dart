import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/catalog_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/db/models.dart';
import '../../../core/inventory/stock_adjust.dart';
import '../../../core/money/paise.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/pack.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/guarded_actions.dart';
import '../../staff/application/session.dart';
import '../application/inventory_providers.dart';
import '../application/inventory_rules.dart';
import '../data/inventory_repository.dart';

/// Resolves to the new product's id, or null if cancelled.
Future<int?> showAddMedicineDialog(BuildContext context, {String initialName = '', bool showInInventory = true}) => showAppDialog<int>(
      context,
      maxWidth: 640,
      topPadding: 48,
      builder: (_) => AddMedicineDialog(initialName: initialName, showInInventory: showInInventory),
    );

/// Edit medicine (SPEC §5.3): the Add medicine form without first-batch
/// fields.
Future<void> showEditMedicineDialog(BuildContext context, {required StockRow product}) => showAppDialog<void>(
      context,
      maxWidth: 640,
      topPadding: 48,
      builder: (_) => AddMedicineDialog(editing: product, showInInventory: false),
    );

Future<void> showReceiveDialog(BuildContext context, {required StockRow product}) =>
    showAppDialog<void>(context, maxWidth: 480, topPadding: 90, builder: (_) => ReceiveStockDialog(product: product));

Future<void> showPackSizeDialog(BuildContext context, {required StockRow product}) =>
    showAppDialog<void>(context, maxWidth: 480, topPadding: 90, builder: (_) => PackSizeDialog(product: product));

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.title, this.subtitle});

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
        IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded, size: 20),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

/// Add medicine (SPEC §5.3); with [editing], Edit medicine.
class AddMedicineDialog extends ConsumerStatefulWidget {
  const AddMedicineDialog({super.key, this.initialName = '', this.showInInventory = true, this.editing});

  /// The medicine being edited; null = adding a new one.
  final StockRow? editing;

  /// Prefills the name (e.g. a free-text order line).
  final String initialName;

  /// Filter Inventory to the new medicine after saving.
  final bool showInInventory;

  @override
  ConsumerState<AddMedicineDialog> createState() => _AddMedicineDialogState();
}

class _AddMedicineDialogState extends ConsumerState<AddMedicineDialog> {
  StockRow? get _e => widget.editing;
  bool get _editing => _e != null;

  late String name = _e?.name ?? widget.initialName;
  late String salt = _e?.salt ?? '', maker = _e?.maker ?? '', pack = _e?.pack ?? '';
  late String category = _e?.category ?? 'Tablet', schedule = _e?.schedule ?? '';
  late String barcode = _e?.barcode ?? '', mrp = _e?.mrp.toInputString() ?? '', rack = _e?.rack ?? '', hsn = _e?.hsn ?? '3004';
  String batch = '', expiry = '', qty = '';
  late String reorder = '${_e?.reorderLevel ?? ref.read(settingsProvider).defaultReorderLevel}';
  late String size = '${_e?.packSize ?? 1}';
  late bool sizeEdited = _editing;
  late int gst = _e?.gstRate ?? 12;

  int get _size => int.tryParse(size) ?? 1;

  /// Prefills units per pack from "Strip of 10" until the user types one.
  void _suggestSize() {
    if (!sizeEdited) size = '${suggestPackSize(pack, category)}';
  }
  Map<String, String> errors = const {};
  bool saving = false;
  final _nameFocus = FocusNode();

  @override
  void dispose() {
    _nameFocus.dispose();
    super.dispose();
  }

  /// Same names are allowed (one brand, several compositions) but the
  /// user confirms. Checked when adding, or when an edit changes the name.
  Future<bool> _confirmSameName() async {
    final n = name.trim();
    if (_e case final p? when p.name.trim().toLowerCase() == n.toLowerCase()) return true;
    final matches = await ref.read(inventoryRepositoryProvider).productsNamed(n, exceptProductId: _e?.id);
    final msg = sameNameWarning(n, salt, matches);
    if (msg == null || !mounted) return true;
    final ok = await showConfirmDialog(
      context,
      title: 'Medicine name already exists',
      message: msg,
      confirmLabel: 'Save anyway',
      icon: Icons.content_copy_rounded,
    );
    if (!ok) _nameFocus.requestFocus();
    return ok;
  }

  Map<String, String> _validate() => {
        if (name.trim().isEmpty) 'name': 'Enter the medicine name',
        if (maker.trim().isEmpty) 'maker': 'Enter the manufacturer',
        if (Paise.tryParse(mrp) case final m when m == null || m.value <= 0) 'mrp': 'Enter the MRP (incl. GST)',
        if (batch.trim().isNotEmpty && parseExpiryInput(expiry) == null) 'expiry': 'Month and year, e.g. 08/2027',
        if (batch.trim().isEmpty && (int.tryParse(qty) ?? 0) > 0) 'batch': 'Opening stock needs a batch number',
        if (qty.isNotEmpty && int.tryParse(qty) == null) 'qty': 'Whole number',
        if (int.tryParse(reorder) == null) 'reorder': 'Whole number',
        if ((int.tryParse(size) ?? 0) < 1 || (int.tryParse(size) ?? 0) > maxPackSize) 'size': '1–$maxPackSize',
      };

  Future<void> _save() async {
    final e = _validate();
    setState(() => errors = e);
    if (e.isNotEmpty) return;
    setState(() => saving = true);
    if (!await _confirmSameName()) {
      if (mounted) setState(() => saving = false);
      return;
    }
    if (_e case final p?) return _saveEdit(p);
    try {
      final id = await ref.read(guardedActionsProvider).addMedicine(
            NewProduct(
              name: name.trim(),
              salt: salt.trim().isEmpty ? name.trim() : salt.trim(),
              maker: maker.trim(),
              pack: pack.trim().isEmpty ? 'Unit' : pack.trim(),
              packSize: _size,
              category: category,
              schedule: schedule,
              barcode: barcode.trim().isEmpty ? null : barcode.trim(),
              hsn: hsn.trim(),
              gstRate: gst,
              mrp: Paise.tryParse(mrp)!,
              reorderLevel: int.parse(reorder),
              rack: rack.trim(),
              batchNo: batch.trim().isEmpty ? null : batch.trim(),
              expiry: parseExpiryInput(expiry),
              // Opening qty is typed in packs; stock is kept in units.
              openingQty: (int.tryParse(qty) ?? 0) * _size,
            ),
          );
      if (widget.showInInventory) {
        ref.read(inventoryFilterProvider.notifier).showProduct(name.trim());
        ref.read(expandedProductsProvider.notifier).open(id);
      }
      ref.read(toastsProvider.notifier).show('${name.trim()} added to inventory');
      if (mounted) Navigator.of(context).pop(id);
    } on CatalogException catch (e) {
      ref.read(toastsProvider.notifier).show(e.message, warn: true);
    } on PermissionDenied catch (e) {
      ref.read(toastsProvider.notifier).show('$e', warn: true);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _saveEdit(StockRow p) async {
    try {
      await ref.read(guardedActionsProvider).updateMedicine(
            p.id,
            ProductEdit(
              name: name.trim(),
              salt: salt.trim(),
              maker: maker.trim(),
              pack: pack.trim(),
              category: category,
              schedule: schedule,
              barcode: barcode.trim().isEmpty ? null : barcode.trim(),
              hsn: hsn.trim(),
              gstRate: gst,
              mrp: Paise.tryParse(mrp)!,
              reorderLevel: int.parse(reorder),
              rack: rack.trim(),
            ),
          );
      final filter = ref.read(inventoryFilterProvider);
      if (filter.search == p.name && name.trim() != p.name) ref.read(inventoryFilterProvider.notifier).setSearch(name.trim());
      ref.read(toastsProvider.notifier).show('${name.trim()} updated');
      if (mounted) Navigator.of(context).pop();
    } on CatalogException catch (e) {
      ref.read(toastsProvider.notifier).show(e.message, warn: true);
    } on PermissionDenied catch (e) {
      ref.read(toastsProvider.notifier).show('$e', warn: true);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.digitsOnly];
    final e = _e;
    final priceChanged = e != null && (Paise.tryParse(mrp) != e.mrp || gst != e.gstRate || hsn.trim() != e.hsn);
    Widget f(String key, String label, String hint, String value, ValueChanged<String> set,
            {List<TextInputFormatter>? fmt, TextInputType? kb, bool autofocus = false, FocusNode? focus}) =>
        AppTextField(
          key: ValueKey('add-$key'),
          focusNode: focus,
          label: label,
          hint: hint,
          value: value,
          error: errors[key],
          autofocus: autofocus,
          inputFormatters: fmt,
          keyboardType: kb,
          onChanged: (v) => setState(() => set(v)),
        );

    return AppDialogPanel(
      semanticLabel: _editing ? 'Edit medicine' : 'Add medicine',
      gap: 18,
      children: [
        _DialogHeader(
          title: _editing ? 'Edit medicine' : 'Add medicine',
          subtitle: e == null ? null : '${e.name} · ${formatPackQty(e.saleable, e.packSize, e.category)} saleable',
        ),
        FieldGrid(
          minColumnWidth: 220,
          children: [
            FieldSpan(child: f('name', 'Medicine name', 'e.g. Paracetamol 500 mg Tablet', name, (v) => name = v, autofocus: true, focus: _nameFocus)),
            f('salt', 'Salt / composition', 'Paracetamol 500 mg', salt, (v) => salt = v),
            f('maker', 'Manufacturer', 'Maker name', maker, (v) => maker = v),
            f('pack', 'Pack', 'Strip of 10', pack, (v) {
              pack = v;
              _suggestSize();
            }),
            AppDropdown<String>(
              label: 'Category',
              labelAbove: true,
              value: category,
              options: [for (final c in productCategories) DropdownOption(c, c)],
              onChanged: (v) => setState(() {
                category = v;
                _suggestSize();
              }),
            ),
            if (!_editing)
              AppTextField(
                key: const ValueKey('add-size'),
                label: PackNouns.of(category).sizeLabel,
                hint: '1 = sold whole only',
                value: size,
                error: errors['size'],
                keyboardType: TextInputType.number,
                inputFormatters: digits,
                onChanged: (v) => setState(() {
                  size = v;
                  sizeEdited = true;
                }),
              ),
            _Pills<String>(
              label: 'Schedule',
              options: const [PillOption('', 'None'), PillOption('H', 'H'), PillOption('H1', 'H1')],
              value: schedule,
              onChanged: (v) => setState(() => schedule = v),
            ),
            f('barcode', 'Barcode', 'Scan or type', barcode, (v) => barcode = v, fmt: digits, kb: TextInputType.number),
            if (!_editing) ...[
              f('batch', 'First batch no.', 'B12345', batch, (v) => batch = v.toUpperCase()),
              f('expiry', 'Expiry', 'MM/YYYY', expiry, (v) => expiry = v, kb: TextInputType.datetime),
              f('qty', _size > 1 ? 'Opening qty (${PackNouns.of(category).packs})' : 'Opening qty', '0', qty, (v) => qty = v,
                  fmt: digits, kb: TextInputType.number),
            ],
            f('reorder', _size > 1 ? 'Reorder level (${PackNouns.of(category).packs})' : 'Reorder level', '20', reorder,
                (v) => reorder = v,
                fmt: digits, kb: TextInputType.number),
            f('mrp', 'MRP (₹, incl. GST)', '0.00', mrp, (v) => mrp = v,
                fmt: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))], kb: const TextInputType.numberWithOptions(decimal: true)),
            _Pills<int>(
              label: 'GST rate',
              options: const [PillOption(0, '0%'), PillOption(5, '5%'), PillOption(12, '12%'), PillOption(18, '18%')],
              value: gst,
              onChanged: (v) => setState(() => gst = v),
            ),
            f('hsn', 'HSN code', '3004', hsn, (v) => hsn = v, fmt: digits, kb: TextInputType.number),
            f('rack', 'Rack / shelf', 'A1', rack, (v) => rack = v),
          ],
        ),
        if (e != null)
          Text(
            priceChanged
                ? 'New MRP / GST / HSN applies to new bills only — bills already saved keep what they were sold at.'
                : '${PackNouns.of(e.category).sizeLabel} is changed with “Sell loose…” in the batch panel.',
            key: const ValueKey('edit-medicine-note'),
            style: AppType.caption,
          ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(
              key: const ValueKey('save-medicine'),
              label: saving ? 'Saving…' : (_editing ? 'Save changes' : 'Save medicine'),
              onPressed: saving ? null : _save,
            ),
          ],
        ),
      ],
    );
  }
}

class _Pills<T> extends StatelessWidget {
  const _Pills({required this.label, required this.options, required this.value, required this.onChanged});

  final String label;
  final List<PillOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: AppType.label),
          const SizedBox(height: 6),
          SegmentedPills<T>(semanticLabel: label, options: options, selected: value, onChanged: onChanged),
        ],
      );
}

// ---------------------------------------------------------------------------

/// Receive stock (SPEC §5.3): existing batch adds qty; a new batch needs expiry.
class ReceiveStockDialog extends ConsumerStatefulWidget {
  const ReceiveStockDialog({super.key, required this.product});

  final StockRow product;

  @override
  ConsumerState<ReceiveStockDialog> createState() => _ReceiveStockDialogState();
}

class _ReceiveStockDialogState extends ConsumerState<ReceiveStockDialog> {
  String batch = '', expiry = '', qty = '';
  Map<String, String> errors = const {};
  bool saving = false;

  StockRow get _p => widget.product;

  StockBatch? _existing(List<StockBatch> batches) {
    final b = batch.trim().toUpperCase();
    for (final x in batches) {
      if (x.batchNo == b) return x;
    }
    return null;
  }

  Future<void> _save(List<StockBatch> batches) async {
    final existing = _existing(batches);
    final e = {
      if (batch.trim().isEmpty) 'batch': 'Enter the batch number',
      if ((int.tryParse(qty) ?? 0) < 1) 'qty': 'Enter the quantity received',
      if (batch.trim().isNotEmpty && existing == null && parseExpiryInput(expiry) == null) 'expiry': 'New batch — enter its expiry (MM/YYYY)',
    };
    setState(() => errors = e);
    if (e.isNotEmpty) return;
    setState(() => saving = true);
    try {
      // Typed in packs (strips); stock is kept in units.
      final n = int.parse(qty) * _p.packSize;
      await ref.read(guardedActionsProvider).receiveStock(
            productId: widget.product.id,
            batchNo: batch,
            expiry: existing == null ? parseExpiryInput(expiry) : null,
            qty: n,
          );
      ref.read(expandedProductsProvider.notifier).open(widget.product.id);
      ref
          .read(toastsProvider.notifier)
          .show('+${formatPackQty(n, _p.packSize, _p.category)} received into batch ${batch.trim().toUpperCase()}');
      if (mounted) Navigator.of(context).pop();
    } on CatalogException catch (e) {
      ref.read(toastsProvider.notifier).show(e.message, warn: true);
    } on PermissionDenied catch (e) {
      ref.read(toastsProvider.notifier).show('$e', warn: true);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final batches = ref.watch(productBatchesProvider(widget.product.id)).value ?? const <StockBatch>[];
    final existing = _existing(batches);
    final hint = batch.trim().isEmpty
        ? (batches.isEmpty ? 'No batches yet — the batch number creates a new batch.' : 'Existing batches: ${batches.map((b) => b.batchNo).join(', ')}. A new batch number creates a new batch.')
        : existing != null
            ? 'Adding to existing batch ${existing.batchNo} (exp ${formatExpiry(existing.expiry)}).'
            : 'New batch ${batch.trim().toUpperCase()} — enter its expiry.';

    return AppDialogPanel(
      semanticLabel: 'Receive stock',
      children: [
        _DialogHeader(
          title: 'Receive stock',
          subtitle: '${widget.product.name} · ${formatPackQty(_p.saleable, _p.packSize, _p.category)} saleable now',
        ),
        FieldGrid(
          minColumnWidth: 180,
          children: [
            AppTextField(
              key: const ValueKey('recv-batch'),
              label: 'Batch no.',
              hint: 'New or existing',
              value: batch,
              autofocus: true,
              error: errors['batch'],
              onChanged: (v) => setState(() => batch = v.toUpperCase()),
            ),
            AppTextField(
              key: const ValueKey('recv-expiry'),
              label: 'Expiry',
              hint: existing != null ? formatExpiry(existing.expiry) : 'MM/YYYY',
              value: existing != null ? expiryToInput(existing.expiry) : expiry,
              enabled: existing == null,
              error: errors['expiry'],
              onChanged: (v) => setState(() => expiry = v),
            ),
            FieldSpan(
              child: AppTextField(
                key: const ValueKey('recv-qty'),
                label: _p.sellsLoose ? 'Quantity received (${PackNouns.of(_p.category).packs} of ${_p.packSize})' : 'Quantity received',
                hint: 'e.g. 50',
                value: qty,
                error: errors['qty'],
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (v) => setState(() => qty = v),
                onSubmitted: (_) => _save(batches),
              ),
            ),
          ],
        ),
        Text(hint, style: AppType.caption),
        Wrap(
          spacing: AppSpace.sm,
          children: [
            for (final n in const [10, 25, 50, 100])
              AppButton.secondary(label: '+$n', height: 36, onPressed: () => setState(() => qty = '$n')),
          ],
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(key: const ValueKey('recv-save'), label: saving ? 'Saving…' : 'Add to stock', onPressed: saving ? null : () => _save(batches)),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

/// Units per pack (SPEC §4.9): "Tablets per strip". Stock is converted to
/// the new size; every batch must hold whole packs.
class PackSizeDialog extends ConsumerStatefulWidget {
  const PackSizeDialog({super.key, required this.product});

  final StockRow product;

  @override
  ConsumerState<PackSizeDialog> createState() => _PackSizeDialogState();
}

class _PackSizeDialogState extends ConsumerState<PackSizeDialog> {
  late String size = '${widget.product.packSize > 1 ? widget.product.packSize : suggestPackSize(widget.product.pack, widget.product.category)}';
  String? error;
  bool saving = false;

  Future<void> _save() async {
    final n = int.tryParse(size) ?? 0;
    if (n < 1 || n > maxPackSize) {
      setState(() => error = 'Enter 1–$maxPackSize');
      return;
    }
    setState(() {
      error = null;
      saving = true;
    });
    try {
      final p = widget.product;
      await ref.read(guardedActionsProvider).setPackSize(p.id, n);
      final w = PackNouns.of(p.category);
      ref.read(toastsProvider.notifier).show(
            n > 1 ? '${p.name}: $n ${w.units} per ${w.pack} — can be sold loose' : '${p.name}: sold whole only',
          );
      if (mounted) Navigator.of(context).pop();
    } on CatalogException catch (e) {
      ref.read(toastsProvider.notifier).show(e.message, warn: true);
    } on PermissionDenied catch (e) {
      ref.read(toastsProvider.notifier).show('$e', warn: true);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final w = PackNouns.of(p.category);
    final n = int.tryParse(size) ?? 0;
    final packs = p.packSize <= 1 ? p.saleable : p.saleable ~/ p.packSize;
    final preview = n < 1
        ? ''
        : n == p.packSize
            ? 'No change.'
            : 'Stock becomes ${formatPackQty(packs * n, n, p.category)}'
                '${n > 1 ? ' (${packs * n} ${w.unitWord(packs * n)})' : ''}. MRP stays ${formatInr(p.mrp)} per ${w.pack}.';
    return AppDialogPanel(
      semanticLabel: w.sizeLabel,
      children: [
        _DialogHeader(title: 'Sell loose', subtitle: '${p.name} · ${p.pack}'),
        Text(
          'MRP is per ${w.pack}. Loose ${w.units} are charged pro-rata (MRP × ${w.units} ÷ ${w.units} per ${w.pack}, rounded down to the paisa). '
          'Set 1 to sell whole ${w.packs} only.',
          style: AppType.caption,
        ),
        AppTextField(
          key: const ValueKey('pack-size'),
          label: w.sizeLabel,
          hint: '10',
          value: size,
          autofocus: true,
          error: error,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (v) => setState(() => size = v),
          onSubmitted: (_) => _save(),
        ),
        if (preview.isNotEmpty) Text(preview, key: const ValueKey('pack-size-preview'), style: AppType.small),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(key: const ValueKey('pack-size-save'), label: saving ? 'Saving…' : 'Save', onPressed: saving ? null : _save),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

Future<void> showEditBatchDialog(BuildContext context, {required StockRow product, required StockBatch batch}) =>
    showAppDialog<void>(context, maxWidth: 640, topPadding: 64, builder: (_) => EditBatchDialog(product: product, batch: batch));

/// Edit batch (SPEC §5.3): fix the batch number or expiry, or set the
/// quantity counted on the shelf with a reason. An expired batch's expiry
/// is locked — expired stock can never be sold (rule 5).
class EditBatchDialog extends ConsumerStatefulWidget {
  const EditBatchDialog({super.key, required this.product, required this.batch});

  final StockRow product;
  final StockBatch batch;

  @override
  ConsumerState<EditBatchDialog> createState() => _EditBatchDialogState();
}

class _EditBatchDialogState extends ConsumerState<EditBatchDialog> {
  StockRow get _p => widget.product;
  StockBatch get _b => widget.batch;

  late String batchNo = _b.batchNo;
  late String expiry = expiryToInput(_b.expiry);
  late String packs = _b.qty < 0 ? '0' : '${splitPack(_b.qty, _p.packSize).$1}';
  late String loose = _b.qty < 0 ? '0' : '${splitPack(_b.qty, _p.packSize).$2}';
  StockAdjustReason? reason;
  String note = '';
  Map<String, String> errors = const {};
  bool saving = false;

  /// The counted quantity in units, or null if the fields don't add up.
  int? get _counted => unitsFrom(
        packs: int.tryParse(packs.isEmpty ? '0' : packs) ?? -1,
        loose: int.tryParse(loose.isEmpty ? '0' : loose) ?? -1,
        packSize: _p.packSize,
      );

  bool get _qtyChanged => _counted != null && _counted != _b.qty;

  Future<void> _save(bool expired) async {
    final no = batchNo.trim().toUpperCase();
    final exp = expired ? _b.expiry : parseExpiryInput(expiry);
    final counted = _counted;
    final e = {
      if (no.isEmpty) 'batch': 'Enter the batch number',
      if (exp == null) 'expiry': 'Month and year, e.g. 08/2027',
      if (counted == null)
        'qty': _p.sellsLoose ? 'Whole numbers; loose ${PackNouns.of(_p.category).units} fewer than ${_p.packSize}' : 'Whole number',
      if (_qtyChanged && reason == null) 'reason': 'Pick a reason',
      if (_qtyChanged && (reason?.needsNote ?? false) && note.trim().isEmpty) 'note': 'Say why',
    };
    setState(() => errors = e);
    if (e.isNotEmpty) return;
    if (no == _b.batchNo && exp == _b.expiry && !_qtyChanged) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => saving = true);
    try {
      await ref.read(guardedActionsProvider).editBatch(
            _b.id,
            batchNo: no,
            expiry: exp,
            countedQty: _qtyChanged ? counted : null,
            reason: _qtyChanged ? reason : null,
            note: note,
          );
      final qtyPart = _qtyChanged
          ? ' · stock ${formatPackQty(_b.qty, _p.packSize, _p.category)} → ${formatPackQty(counted!, _p.packSize, _p.category)}'
          : '';
      ref.read(toastsProvider.notifier).show('Batch $no updated$qtyPart');
      if (mounted) Navigator.of(context).pop();
    } on CatalogException catch (e) {
      ref.read(toastsProvider.notifier).show(e.message, warn: true);
    } on PermissionDenied catch (e) {
      ref.read(toastsProvider.notifier).show('$e', warn: true);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(nowProvider)();
    final expired = isExpired(_b.expiry, now);
    final w = PackNouns.of(_p.category);
    final digits = [FilteringTextInputFormatter.digitsOnly];
    final counted = _counted;
    final history = ref.watch(batchMovementsProvider(_b.id)).value;

    return AppDialogPanel(
      semanticLabel: 'Edit batch',
      children: [
        _DialogHeader(
          title: 'Edit batch ${_b.batchNo}',
          subtitle: '${_p.name} · ${formatPackQty(_b.qty, _p.packSize, _p.category)} in this batch',
        ),
        FieldGrid(
          minColumnWidth: 180,
          children: [
            AppTextField(
              key: const ValueKey('edit-batch-no'),
              label: 'Batch no.',
              value: batchNo,
              error: errors['batch'],
              onChanged: (v) => setState(() => batchNo = v.toUpperCase()),
            ),
            AppTextField(
              key: const ValueKey('edit-batch-expiry'),
              label: 'Expiry',
              hint: 'MM/YYYY',
              value: expiry,
              enabled: !expired,
              error: errors['expiry'],
              helper: expired ? 'Expired — locked; expired stock can’t be sold' : null,
              keyboardType: TextInputType.datetime,
              onChanged: (v) => setState(() => expiry = v),
            ),
            AppTextField(
              key: const ValueKey('edit-batch-packs'),
              label: _p.sellsLoose ? 'Counted ${w.packs}' : 'Counted quantity',
              value: packs,
              error: errors['qty'],
              keyboardType: TextInputType.number,
              inputFormatters: digits,
              onChanged: (v) => setState(() => packs = v),
            ),
            if (_p.sellsLoose)
              AppTextField(
                key: const ValueKey('edit-batch-loose'),
                label: '+ loose ${w.units}',
                value: loose,
                keyboardType: TextInputType.number,
                inputFormatters: digits,
                onChanged: (v) => setState(() => loose = v),
              ),
          ],
        ),
        if (_qtyChanged && counted != null) ...[
          Text(
            'Stock ${formatPackQty(_b.qty, _p.packSize, _p.category)} → ${formatPackQty(counted, _p.packSize, _p.category)} '
            '(${counted > _b.qty ? '+' : ''}${formatPackQty(counted - _b.qty, _p.packSize, _p.category)})',
            key: const ValueKey('edit-batch-preview'),
            style: AppType.smallStrong,
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Reason', style: AppType.label),
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedPills<StockAdjustReason?>(
                  semanticLabel: 'Reason',
                  options: [for (final r in StockAdjustReason.values) PillOption(r, r.label)],
                  selected: reason,
                  onChanged: (v) => setState(() => reason = v),
                ),
              ),
              if (errors['reason'] case final m?) ...[
                const SizedBox(height: 4),
                Text(m, style: AppType.caption.copyWith(color: StockColors.out)),
              ],
            ],
          ),
          AppTextField(
            key: const ValueKey('edit-batch-note'),
            label: (reason?.needsNote ?? false) ? 'Note' : 'Note (optional)',
            hint: 'e.g. 2 strips crushed in delivery',
            value: note,
            error: errors['note'],
            onChanged: (v) => setState(() => note = v),
          ),
        ],
        if (history != null && history.isNotEmpty)
          Column(
            key: const ValueKey('edit-batch-history'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('RECENT MOVEMENTS', style: AppType.overline.copyWith(letterSpacing: 0.4)),
              const SizedBox(height: 4),
              for (final m in history)
                Text(
                  [
                    formatDate(DateTime.fromMillisecondsSinceEpoch(m.at).toLocal()),
                    movementLabel(m.reason),
                    '${m.delta > 0 ? '+' : ''}${formatPackQty(m.delta, _p.packSize, _p.category)}',
                    if (m.note.isNotEmpty) m.note,
                  ].join(' · '),
                  style: AppType.caption.copyWith(color: AppColors.body),
                ),
            ],
          ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(
              key: const ValueKey('edit-batch-save'),
              label: saving ? 'Saving…' : 'Save',
              onPressed: saving ? null : () => _save(expired),
            ),
          ],
        ),
      ],
    );
  }
}
