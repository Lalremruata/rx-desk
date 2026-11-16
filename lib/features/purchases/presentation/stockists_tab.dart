import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/daos/sources_dao.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/db/models.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/save_file.dart';
import '../../../core/widgets/widgets.dart';
import '../../sales_register/application/register_export.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/application/guarded_actions.dart';
import '../../staff/application/session.dart';
import '../application/directory_import.dart';
import '../application/purchases_providers.dart';
import '../data/purchases_repository.dart';
import 'purchase_dialogs.dart';

/// Picks the workbook to import; tests override it with bytes.
final directoryFilePickerProvider = Provider<Future<(String, Uint8List)?> Function()>((ref) => () async {
      final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['xlsx']);
      final path = f?.path;
      if (path == null) return null;
      return (f!.name, await File(path).readAsBytes());
    });

String _origin(String o) => switch (o) {
      'import' => 'Imported',
      'receipt' => 'From invoices',
      _ => 'Added',
    };

/// Purchases › Stockists — "where to get this medicine" (SPEC §5.9, §4.11).
class StockistsTab extends ConsumerStatefulWidget {
  const StockistsTab({super.key});

  @override
  ConsumerState<StockistsTab> createState() => _StockistsTabState();
}

class _StockistsTabState extends ConsumerState<StockistsTab> {
  Timer? _debounce;
  bool _busy = false;

  static const _columns = [
    GridColumn('Medicine', flex: 2, minWidth: 200),
    GridColumn('Stockist', flex: 1.6, minWidth: 180),
    GridColumn.fixed('MR', 140),
    GridColumn.fixed('Last received', 120),
    GridColumn.fixed('Source', 110),
    GridColumn.fixed('', 156, alignEnd: true),
  ];

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _import() async {
    final picked = await ref.read(directoryFilePickerProvider)();
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final sheet = await parseDirectoryWorkbookInIsolate(picked.$2);
      if (sheet.rows.isEmpty) {
        ref.read(toastsProvider.notifier).show('No stockist / medicine rows found in ${picked.$1}', warn: true);
        return;
      }
      final candidates = await matchToCatalogue(sheet, ref.read(purchasesRepositoryProvider).searchCatalogue);
      if (!mounted) return;
      await showAppDialog<void>(
        context,
        maxWidth: 980,
        topPadding: 32,
        builder: (_) => DirectoryImportDialog(fileName: picked.$1, sheet: sheet, candidates: candidates),
      );
    } on DirectoryImportException catch (e) {
      ref.read(toastsProvider.notifier).show(e.message, warn: true);
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('Import failed: $e', warn: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(purchasesRepositoryProvider);
      final rows = <SourceRow>[];
      SourceCursor? after;
      while (true) {
        final p = await repo.sourcesPage(after: after, limit: 500);
        rows.addAll(p.rows);
        if (!p.hasMore) break;
        after = SourceCursor(p.rows.last.supplierName, p.rows.last.itemName, p.rows.last.id);
      }
      final now = ref.read(nowProvider)();
      // The store's sheet layout: phones once, on the first row of each
      // stockist's block.
      final lines = <List<Object>>[];
      String? last;
      for (final (i, r) in rows.indexed) {
        lines.add([i + 1, r.supplierName, r.itemName, last == r.supplierName ? '' : r.phones, r.mr]);
        last = r.supplierName;
      }
      final table = ExportTable(
        title: 'Stockist directory',
        headerBlock: [ref.read(settingsProvider).name, 'Damdawi lak na — stockist directory', 'Generated ${formatDate(now)}'],
        columns: const ['Sl.No', 'Dawr Hming', 'Damdawi hming', 'Phone numb', 'MR Hming'],
        rows: lines,
        totals: ['', '${rows.map((r) => r.supplierId).toSet().length} stockists', '${rows.length} medicines', '', ''],
      );
      final name = 'stockist-directory-${dateKey(now)}';
      String? path;
      try {
        path = await saveBytesAs('$name.xlsx', await buildXlsxInIsolate(table, sheetName: 'Damdawi lak na'));
      } on Object {
        path = await saveTextAs('$name.csv', buildCsv(table));
      }
      if (path != null) ref.read(toastsProvider.notifier).show('${path.split(RegExp(r'[/\\]')).last} saved · ${rows.length} lines');
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('Export failed: $e', warn: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(SourceRow r) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Remove ${r.itemName}?',
      message: 'It no longer shows ${r.supplierName} as a place to get it. Stock and invoices are not touched.',
      confirmLabel: 'Remove',
      tone: ConfirmTone.danger,
    );
    if (!ok) return;
    try {
      await ref.read(guardedActionsProvider).removeSource(r.id);
      ref.read(toastsProvider.notifier).show('${r.itemName} removed from ${r.supplierName}');
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('$e', warn: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(sourcesListControllerProvider);
    final ctl = ref.read(sourcesListControllerProvider.notifier);
    final async = ref.watch(sourcesPageProvider);
    final page = async.value;
    final rows = page?.rows ?? const <SourceRow>[];
    final stockists = ref.watch(suppliersProvider).value ?? const <Supplier>[];
    final canEdit = ref.watch(canProvider(Permission.changeStock));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpace.gap10,
          runSpacing: AppSpace.gap10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 240, maxWidth: 360),
              child: AppTextField(
                fieldKey: const ValueKey('sources-search'),
                label: '',
                hint: 'Medicine, stockist, MR or phone…',
                prefixIcon: Icons.search_rounded,
                value: st.search,
                onChanged: (v) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 150), () => ctl.setSearch(v));
                },
              ),
            ),
            AppDropdown<int?>(
              label: 'Stockist',
              value: st.supplierId,
              width: 220,
              options: [const DropdownOption(null, 'All stockists'), for (final s in stockists) DropdownOption(s.id, s.name)],
              onChanged: ctl.setSupplier,
            ),
            AppButton(
              key: const ValueKey('source-add'),
              label: 'Add',
              icon: Icons.add_rounded,
              onPressed: canEdit ? () => showAppDialog<void>(context, maxWidth: 560, builder: (_) => const SourceEditDialog()) : null,
            ),
            AppButton.secondary(
              key: const ValueKey('sources-import'),
              label: _busy ? 'Working…' : 'Import from Excel',
              icon: Icons.upload_file_rounded,
              onPressed: canEdit && !_busy ? _import : null,
            ),
            AppButton.secondary(label: 'Export', icon: Icons.download_rounded, onPressed: _busy ? null : _export),
          ],
        ),
        const SizedBox(height: AppSpace.gap14),
        AppCard(
          padding: EdgeInsets.zero,
          clip: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (async.isLoading && page == null) const LinearProgressIndicator(minHeight: 2),
              DataGrid(
                semanticLabel: 'Stockist directory',
                columns: _columns,
                rowCount: rows.length,
                empty: page == null
                    ? const SizedBox(height: 120)
                    : EmptyState(
                        icon: Icons.contact_phone_outlined,
                        title: st.search.isEmpty && st.supplierId == null ? 'No stockists listed yet' : 'Nothing matches',
                        message: st.search.isEmpty && st.supplierId == null
                            ? 'Receiving a stockist invoice adds its medicines here. You can also import your "Damdawi lak na" sheet.'
                            : 'Try another name, or clear the search.',
                      ),
                cells: (context, i) {
                  final r = rows[i];
                  return [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(r.itemName, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis),
                        if (r.productId == null) const StatusBadge.tag('Not in catalogue'),
                        if (r.note.isNotEmpty) Text(r.note, style: AppType.caption, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(r.supplierName, style: AppType.smallStrong, overflow: TextOverflow.ellipsis),
                        if (r.phones.isNotEmpty) Text(r.phones, style: AppType.caption, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                    Text(r.mr.isEmpty ? '—' : r.mr, style: AppType.small.copyWith(color: r.mr.isEmpty ? AppColors.textMuted : AppColors.body), overflow: TextOverflow.ellipsis),
                    Text(r.lastReceived == null ? '—' : dayLabel(r.lastReceived!), style: AppType.small.copyWith(color: AppColors.body)),
                    StatusBadge.tag(_origin(r.origin), tone: r.origin == 'receipt' ? StatusTone.success : StatusTone.neutral),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          key: ValueKey('source-edit-${r.id}'),
                          tooltip: 'Edit — link the medicine, MR, note',
                          onPressed: canEdit ? () => showAppDialog<void>(context, maxWidth: 560, builder: (_) => SourceEditDialog(row: r)) : null,
                          icon: const Icon(Icons.edit_outlined, size: 18),
                        ),
                        IconButton(
                          key: ValueKey('stockist-phones-${r.id}'),
                          tooltip: 'Stockist phone numbers',
                          onPressed: canEdit ? () => showAppDialog<void>(context, builder: (_) => StockistContactDialog(row: r)) : null,
                          icon: const Icon(Icons.contact_phone_outlined, size: 18),
                        ),
                        IconButton(
                          key: ValueKey('source-remove-${r.id}'),
                          tooltip: 'Remove from the directory',
                          onPressed: canEdit ? () => _remove(r) : null,
                          icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        ),
                      ],
                    ),
                  ];
                },
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        page == null ? '' : 'Page ${st.page} · ${formatCount(page.total)} lines · ${page.ms.toStringAsFixed(1)} ms',
                        style: AppType.small.copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                    PagerButton(label: '‹ Previous', semanticLabel: 'Previous page', onTap: st.cursors.isEmpty ? null : ctl.previous),
                    const SizedBox(width: 4),
                    PagerButton(
                      label: 'Next ›',
                      semanticLabel: 'Next page',
                      onTap: page?.hasMore ?? false ? () => ctl.next(SourceCursor(rows.last.supplierName, rows.last.itemName, rows.last.id)) : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Add / edit a line

class SourceEditDialog extends ConsumerStatefulWidget {
  const SourceEditDialog({super.key, this.row});

  /// Null = add.
  final SourceRow? row;

  @override
  ConsumerState<SourceEditDialog> createState() => _SourceEditDialogState();
}

class _SourceEditDialogState extends ConsumerState<SourceEditDialog> {
  late String stockist = widget.row?.supplierName ?? '';
  late int? productId = widget.row?.productId;
  late String itemName = widget.row?.itemName ?? '';
  late String mrName = widget.row?.mrName ?? '';
  late String mrPhone = widget.row?.mrPhone ?? '';
  late String note = widget.row?.note ?? '';
  bool saving = false;

  Future<void> _save() async {
    if (widget.row == null && stockist.trim().isEmpty) {
      ref.read(toastsProvider.notifier).show('Enter the stockist', warn: true);
      return;
    }
    if (productId == null && itemName.trim().isEmpty) {
      ref.read(toastsProvider.notifier).show('Pick or type the medicine', warn: true);
      return;
    }
    setState(() => saving = true);
    try {
      final g = ref.read(guardedActionsProvider);
      final r = widget.row;
      if (r == null) {
        await g.addSource(supplierName: stockist, productId: productId, itemName: itemName, mrName: mrName, mrPhone: mrPhone, note: note);
      } else {
        await g.updateSource(r.id, productId: productId, itemName: itemName, mrName: mrName, mrPhone: mrPhone, note: note);
      }
      ref.read(toastsProvider.notifier).show('${itemName.trim()} saved');
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      toastPurchaseError(ref, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    return AppDialogPanel(
      semanticLabel: r == null ? 'Add to directory' : 'Edit directory line',
      children: [
        PurchaseDialogHeader(
          title: r == null ? 'Where to get a medicine' : r.supplierName,
          subtitle: r == null ? 'The stockist is matched by name, or added.' : (r.phones.isEmpty ? null : r.phones),
        ),
        if (r == null)
          AppTextField(
            fieldKey: const ValueKey('source-stockist'),
            label: 'Stockist',
            hint: 'e.g. Life Drugs Centre',
            value: stockist,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            onChanged: (v) => setState(() => stockist = v),
          ),
        if (productId != null || itemName.isNotEmpty)
          Row(
            children: [
              Expanded(
                child: Text(
                  productId == null ? '$itemName  (not in catalogue)' : itemName,
                  key: const ValueKey('source-medicine'),
                  style: AppType.bodyStrong,
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  productId = null;
                  itemName = '';
                }),
                child: const Text('Change'),
              ),
            ],
          )
        else
          ProductPicker(
            fieldKey: const ValueKey('source-pick'),
            label: 'Medicine',
            onPicked: (p) => setState(() {
              productId = p.id;
              itemName = p.name;
            }),
            onFreeText: (t) => setState(() {
              productId = null;
              itemName = t.trim();
            }),
          ),
        FieldGrid(
          minColumnWidth: 180,
          children: [
            AppTextField(fieldKey: const ValueKey('source-mr'), label: 'MR name', hint: 'Optional', value: mrName, onChanged: (v) => setState(() => mrName = v)),
            AppTextField(
              label: 'MR phone',
              hint: 'Optional',
              value: mrPhone,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ \-]')), LengthLimitingTextInputFormatter(20)],
              onChanged: (v) => setState(() => mrPhone = v),
            ),
            FieldSpan(child: AppTextField(label: 'Note', hint: 'Optional', value: note, onChanged: (v) => setState(() => note = v))),
          ],
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(key: const ValueKey('source-save'), label: saving ? 'Saving…' : 'Save', onPressed: saving ? null : _save),
          ],
        ),
      ],
    );
  }
}

class StockistContactDialog extends ConsumerStatefulWidget {
  const StockistContactDialog({super.key, required this.row});

  final SourceRow row;

  @override
  ConsumerState<StockistContactDialog> createState() => _StockistContactDialogState();
}

class _StockistContactDialogState extends ConsumerState<StockistContactDialog> {
  late String phone = widget.row.phone;
  late String others = widget.row.otherPhones;

  @override
  Widget build(BuildContext context) {
    return AppDialogPanel(
      semanticLabel: 'Stockist phone numbers',
      children: [
        PurchaseDialogHeader(title: widget.row.supplierName, subtitle: 'Phone numbers'),
        AppTextField(fieldKey: const ValueKey('stockist-phone'), label: 'Main phone', value: phone, keyboardType: TextInputType.phone, onChanged: (v) => setState(() => phone = v)),
        AppTextField(label: 'Other numbers', hint: 'Separate with /', value: others, onChanged: (v) => setState(() => others = v)),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(
              key: const ValueKey('stockist-phone-save'),
              label: 'Save',
              onPressed: () async {
                try {
                  await ref.read(guardedActionsProvider).setStockistContact(widget.row.supplierId, phone: phone, otherPhones: others);
                  ref.read(toastsProvider.notifier).show('${widget.row.supplierName} updated');
                  if (context.mounted) Navigator.of(context).pop();
                } on Object catch (e) {
                  toastPurchaseError(ref, e);
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Import review

class DirectoryImportDialog extends ConsumerStatefulWidget {
  const DirectoryImportDialog({super.key, required this.fileName, required this.sheet, required this.candidates});

  final String fileName;
  final DirectorySheet sheet;
  final List<ImportCandidate> candidates;

  @override
  ConsumerState<DirectoryImportDialog> createState() => _DirectoryImportDialogState();
}

enum _Show { unmatched, matched, all }

class _DirectoryImportDialogState extends ConsumerState<DirectoryImportDialog> {
  _Show show = _Show.unmatched;
  bool saving = false;

  List<ImportCandidate> get _visible => [
        for (final c in widget.candidates)
          if (show == _Show.all || (show == _Show.matched) == c.matched) c,
      ];

  Future<void> _link(ImportCandidate c) async {
    final picked = await showAppDialog<StockRow>(
      context,
      maxWidth: 560,
      builder: (context) => AppDialogPanel(
        semanticLabel: 'Link to a medicine',
        children: [
          PurchaseDialogHeader(title: 'Link “${c.row.medicine}”', subtitle: c.row.stockist),
          ProductPicker(fieldKey: const ValueKey('import-link-pick'), autofocus: true, onPicked: (p) => Navigator.of(context).pop(p)),
          Align(alignment: Alignment.centerRight, child: AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop())),
        ],
      ),
    );
    if (picked == null) return;
    setState(() {
      c
        ..productId = picked.id
        ..productName = picked.name
        ..choice = ImportChoice.link;
    });
  }

  Future<void> _save() async {
    final rows = [
      for (final c in widget.candidates)
        if (c.choice != ImportChoice.skip)
          DirectoryImportRow(
            supplierName: c.row.stockist,
            itemName: c.row.medicine,
            productId: c.choice == ImportChoice.link ? c.productId : null,
            phones: widget.sheet.phonesOf(c.row.stockist),
            mrName: c.row.mrName,
          ),
    ];
    setState(() => saving = true);
    try {
      final r = await ref.read(guardedActionsProvider).importDirectory(rows);
      ref.read(toastsProvider.notifier).show(
            'Imported ${formatCount(r.added)} lines · ${formatCount(r.linked)} linked to the catalogue'
            '${r.stockistsAdded > 0 ? ' · ${r.stockistsAdded} new stockists' : ''}'
            '${r.skipped > 0 ? ' · ${formatCount(r.skipped)} already listed' : ''}',
          );
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      toastPurchaseError(ref, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.candidates;
    final matched = all.where((c) => c.matched).length;
    final skip = all.where((c) => c.choice == ImportChoice.skip).length;
    final visible = _visible;
    return AppDialogPanel(
      semanticLabel: 'Import stockist directory',
      children: [
        PurchaseDialogHeader(
          title: 'Import “${widget.sheet.sheetName}”',
          subtitle: '${widget.fileName} · ${widget.sheet.stockists} stockists · ${all.length} medicines · '
              '$matched found in the catalogue · ${all.length - matched} not',
        ),
        Text(
          'Medicines not in the catalogue are kept as text (you can link them later), or link / skip them here.',
          style: AppType.caption,
        ),
        Wrap(
          spacing: AppSpace.gap10,
          runSpacing: AppSpace.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedPills<_Show>(
              semanticLabel: 'Show',
              options: [
                PillOption(_Show.unmatched, 'Not in catalogue (${all.length - matched})'),
                PillOption(_Show.matched, 'Found ($matched)'),
                const PillOption(_Show.all, 'All'),
              ],
              selected: show,
              onChanged: (v) => setState(() => show = v),
            ),
            TextButton(
              key: const ValueKey('import-skip-unmatched'),
              onPressed: () => setState(() {
                for (final c in all.where((c) => c.choice == ImportChoice.keep)) {
                  c.choice = ImportChoice.skip;
                }
              }),
              child: const Text('Skip all not found'),
            ),
            TextButton(
              onPressed: () => setState(() {
                for (final c in all.where((c) => c.choice == ImportChoice.skip)) {
                  c.choice = c.matched ? ImportChoice.link : ImportChoice.keep;
                }
              }),
              child: const Text('Keep all'),
            ),
          ],
        ),
        Container(
          height: 380,
          decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: const BorderRadius.all(Radius.circular(12))),
          clipBehavior: Clip.antiAlias,
          child: visible.isEmpty
              ? const Center(child: EmptyState(title: 'Nothing here'))
              : ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final c = visible[i];
                    return Container(
                      key: ValueKey('import-row-${c.row.sheetRow}'),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(border: i == 0 ? null : const Border(top: BorderSide(color: AppColors.divider))),
                      child: Row(
                        children: [
                          SizedBox(width: 44, child: Text('${c.row.sheetRow}', style: AppType.caption)),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c.row.medicine, style: AppType.smallStrong, overflow: TextOverflow.ellipsis),
                                Text(
                                  [
                                    c.row.stockist,
                                    if (c.row.mrName.isNotEmpty) 'MR ${c.row.mrName}',
                                    if (c.productName != null) '→ ${c.productName}',
                                  ].join(' · '),
                                  style: AppType.caption.copyWith(color: c.productName != null ? StatusTone.success.colors.fg : null),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            key: ValueKey('import-link-${c.row.sheetRow}'),
                            tooltip: 'Link to a catalogue medicine',
                            onPressed: () => _link(c),
                            icon: const Icon(Icons.link_rounded, size: 18),
                          ),
                          SegmentedPills<ImportChoice>(
                            key: ValueKey('import-choice-${c.row.sheetRow}'),
                            semanticLabel: 'Import ${c.row.medicine} as',
                            options: [
                              if (c.productId != null) const PillOption(ImportChoice.link, 'Linked'),
                              const PillOption(ImportChoice.keep, 'Text'),
                              const PillOption(ImportChoice.skip, 'Skip'),
                            ],
                            selected: c.choice,
                            onChanged: (v) => setState(() => c.choice = v),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpace.gap10,
          children: [
            Text('${formatCount(all.length - skip)} to import${skip > 0 ? ' · $skip skipped' : ''}', style: AppType.smallStrong),
            AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            AppButton(key: const ValueKey('import-save'), label: saving ? 'Importing…' : 'Import', onPressed: saving ? null : _save),
          ],
        ),
      ],
    );
  }
}
