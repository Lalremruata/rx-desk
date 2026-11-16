import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/db_provider.dart';
import '../../../core/db/models.dart';
import '../../../core/money/paise.dart';
import '../../../core/sales/bill_rules.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/pack.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/settings_providers.dart';
import '../application/bill_controller.dart';
import '../application/bill_state.dart';
import 'billing_screen.dart';

/// 56 px search box with the results / batch picker / substitutes dropdown,
/// then the Quick add chips.
class SearchPanel extends ConsumerStatefulWidget {
  const SearchPanel({super.key, required this.focusNode});

  final FocusNode focusNode;

  @override
  ConsumerState<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends ConsumerState<SearchPanel> {
  final TextEditingController _c = TextEditingController();

  /// The dropdown is drawn in the app overlay, anchored under the search box,
  /// so it sits above the bill grid and receives clicks everywhere (a
  /// Stack overflow would be painted over and miss hit tests).
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  double _width = 0;

  @override
  void initState() {
    super.initState();
    _portal.show();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bill = ref.read(billControllerProvider.notifier);
    final query = ref.watch(billControllerProvider.select((s) => s.query));
    if (query != _c.text) {
      _c.value = TextEditingValue(text: query, selection: TextSelection.collapsed(offset: query.length));
    }
    final drop = ref.watch(billControllerProvider.select((s) => s.drop));
    final open = drop is! DropClosed;
    final p = context.palette;

    final box = Focus(
      onKeyEvent: (_, e) => handleSearchKey(e, bill),
      child: TextField(
        key: const ValueKey('billing-search'),
        controller: _c,
        focusNode: widget.focusNode,
        onChanged: bill.setQuery,
        style: AppType.body.copyWith(fontSize: 16),
        textInputAction: TextInputAction.none,
        decoration: InputDecoration(
          hintText: 'Type medicine, salt or scan barcode…  (F3)',
          prefixIcon: Icon(Icons.search_rounded, color: p.accent, size: 22),
          suffixIcon: const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [KeyHint('↑'), SizedBox(width: 4), KeyHint('↓'), SizedBox(width: 4), KeyHint('Enter')],
            ),
          ),
          constraints: const BoxConstraints(minHeight: AppSizes.searchHeight),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
          enabledBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: open ? p.accent : AppColors.inputBorder, width: open ? 1.5 : 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: p.accent, width: 2),
          ),
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, c) {
        _width = c.maxWidth;
        return OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (context) => !open
              ? const SizedBox.shrink()
              : CompositedTransformFollower(
                  link: _link,
                  showWhenUnlinked: false,
                  offset: const Offset(0, AppSizes.searchHeight + 6),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(width: _width, child: _Dropdown(key: ValueKey(drop.runtimeType), drop: drop)),
                  ),
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CompositedTransformTarget(
                link: _link,
                child: Semantics(label: 'Search medicine, salt or scan barcode', textField: true, child: box),
              ),
              const SizedBox(height: AppSpace.md),
              const _QuickAdd(),
            ],
          ),
        );
      },
    );
  }
}

class _QuickAdd extends ConsumerWidget {
  const _QuickAdd();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(quickAddProvider).value ?? const [];
    if (items.isEmpty) return const SizedBox.shrink();
    final bill = ref.read(billControllerProvider.notifier);
    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Padding(padding: const EdgeInsets.only(right: 4), child: Text('Quick add', style: AppType.label)),
        for (final q in items)
          ActionChip(
            key: ValueKey('quick-${q.productId}'),
            label: Text(q.name.replaceAll(RegExp(r' (Tablet|Capsule|Sachet)$'), '')),
            labelStyle: AppType.label.copyWith(color: AppColors.body),
            backgroundColor: AppColors.surface,
            side: const BorderSide(color: AppColors.chipBorder),
            shape: const StadiumBorder(),
            materialTapTargetSize: MaterialTapTargetSize.padded,
            onPressed: () => bill.quickAdd(q.productId),
          ),
      ],
    );
  }
}

class _Dropdown extends ConsumerWidget {
  const _Dropdown({super.key, required this.drop});

  final DropMode drop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hi = ref.watch(billControllerProvider.select((s) => s.highlight));
    final bill = ref.read(billControllerProvider.notifier);
    final body = switch (drop) {
      DropResults(:final results) => _Results(results: results, hi: hi, bill: bill),
      DropBatchPicker(:final product, :final options, :final expired) =>
        _BatchPicker(product: product, options: options, expired: expired, hi: hi, bill: bill),
      DropSubstitutes(:final product, :final substitutes) => _Substitutes(product: product, subs: substitutes, hi: hi, bill: bill),
      DropClosed() => const SizedBox.shrink(),
    };
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: context.motion(AppMotion.dropdown),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, AppMotion.dropdownDy * (1 - t)), child: child),
      ),
      child: Material(
        color: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          side: BorderSide(color: AppColors.border),
        ),
        child: DecoratedBox(
          decoration: const BoxDecoration(borderRadius: BorderRadius.all(Radius.circular(14)), boxShadow: [AppShadows.dropdown]),
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(14)),
            child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 460), child: body),
          ),
        ),
      ),
    );
  }
}

Widget _headerBar(List<Widget> children) => Container(
      color: AppColors.surfaceAlt,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(children: children),
    );

class _StockText extends StatelessWidget {
  const _StockText(this.row);
  final StockRow row;

  @override
  Widget build(BuildContext context) {
    final qty = compactPackQty(row.saleable, row.packSize, row.category);
    final (t, c) = row.isOut
        ? ('Out', StockColors.out)
        : row.isLow
            ? ('$qty left', StockColors.low)
            : (qty, StockColors.ok);
    final text = Text(t, textAlign: TextAlign.right, style: AppType.smallStrong.copyWith(color: c));
    if (!row.sellsLoose || row.isOut) return text;
    return Tooltip(message: '${formatPackQty(row.saleable, row.packSize, row.category)} in stock', child: text);
  }
}

/// Row in results / substitutes.
class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.row, required this.sub, required this.selected, required this.onTap, required this.onHover, required this.rowKey});

  final StockRow row;
  final String sub;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHover;
  final Key rowKey;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      onEnter: (_) => onHover(),
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          key: rowKey,
          onTap: onTap,
          child: Container(
            color: selected ? p.accentSoft : AppColors.transparent,
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(child: Text(row.name, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis)),
                          if (row.schedule.isNotEmpty) ...[const SizedBox(width: 6), RxBadge(row.schedule)],
                        ],
                      ),
                      Text(sub, style: AppType.caption, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                SizedBox(width: 60, child: Text(row.rack, style: AppType.small.copyWith(color: AppColors.body))),
                SizedBox(width: 70, child: _StockText(row)),
                SizedBox(width: 84, child: Text(formatInr(row.mrp), textAlign: TextAlign.right, style: AppType.bodyStrong)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.results, required this.hi, required this.bill});

  final SearchResults results;
  final int hi;
  final BillController bill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = ref.watch(catalogueSizeProvider).value;
    final info = results.total > results.rows.length
        ? 'Top ${results.rows.length} of ${formatCount(results.total)} matches — keep typing to narrow'
        : '${formatCount(results.total)} ${results.total == 1 ? 'match' : 'matches'}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Row(
            children: [
              Expanded(child: Text(info, style: AppType.caption.copyWith(fontWeight: FontWeight.w600))),
              Text(
                'Searched ${size == null ? '' : '${formatCount(size)} '}items in ${results.ms.toStringAsFixed(1)} ms',
                style: AppType.caption.copyWith(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        _headerBar([
          Expanded(child: Text('MEDICINE · SALT · MAKER', style: AppType.overline)),
          SizedBox(width: 60, child: Text('RACK', style: AppType.overline)),
          SizedBox(width: 70, child: Text('STOCK', textAlign: TextAlign.right, style: AppType.overline)),
          SizedBox(width: 84, child: Text('MRP', textAlign: TextAlign.right, style: AppType.overline)),
        ]),
        if (results.rows.isEmpty)
          Padding(
            padding: const EdgeInsets.all(18),
            child: Text('No medicine matches. Try the salt name, or press Esc to clear.', style: AppType.small.copyWith(color: AppColors.textSecondary)),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: results.rows.length,
              itemBuilder: (context, i) {
                final r = results.rows[i];
                return _ProductRow(
                  rowKey: ValueKey('result-$i'),
                  row: r,
                  sub: '${r.salt} · ${r.maker} · ${r.pack}',
                  selected: i == hi,
                  onTap: () => bill.selectProduct(r),
                  onHover: () => bill.setHighlight(i),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _DropTitle extends StatelessWidget {
  const _DropTitle({required this.title, required this.subtitle, required this.onClose});

  final String title;
  final String subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppType.bodyStrong),
                  Text(subtitle, style: AppType.caption),
                ],
              ),
            ),
            Tooltip(
              message: 'Close (Esc)',
              child: InkWell(onTap: onClose, borderRadius: AppRadius.tinyAll, child: const Padding(padding: EdgeInsets.all(10), child: KeyHint('Esc'))),
            ),
          ],
        ),
      );
}

class _BatchPicker extends ConsumerWidget {
  const _BatchPicker({required this.product, required this.options, required this.expired, required this.hi, required this.bill});

  final StockRow product;
  final List<BatchOption> options;
  final List<BatchOption> expired;
  final int hi;
  final BillController bill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final s = ref.watch(settingsProvider);
    final now = ref.watch(nowProvider)();

    Widget row(BatchOption b, int i, {required bool blocked}) {
      final ml = monthsLeft(b.expiry, now);
      final (tag, tone) = blocked
          ? ('Expired · blocked', StatusTone.danger)
          : i == 0 && s.suggestFefo
              ? ('FEFO · sell first', StatusTone.accent)
              : ml <= s.expiryWindowMonths
                  ? ('Near expiry', StatusTone.warning)
                  : ('OK', StatusTone.neutral);
      final selected = !blocked && i == hi;
      final content = Container(
        color: selected ? p.accentSoft : AppColors.transparent,
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            SizedBox(width: 110, child: Text(b.batchNo, style: AppType.mono.copyWith(fontSize: 13))),
            SizedBox(
              width: 96,
              child: Text(
                formatExpiry(b.expiry),
                style: AppType.smallStrong.copyWith(color: blocked ? StockColors.out : ml <= s.expiryWindowMonths ? StockColors.low : AppColors.text),
              ),
            ),
            SizedBox(
              width: 80,
              child: Text(compactPackQty(b.qty, product.packSize, product.category), textAlign: TextAlign.right, style: AppType.smallStrong),
            ),
            SizedBox(width: 90, child: Text(formatInr(product.mrp), textAlign: TextAlign.right, style: AppType.small)),
            const SizedBox(width: 14),
            Expanded(child: Align(alignment: Alignment.centerLeft, child: StatusBadge.tag(tag, tone: tone))),
          ],
        ),
      );
      return Opacity(
        opacity: blocked ? 0.6 : 1,
        child: MouseRegion(
          onEnter: blocked ? null : (_) => bill.setHighlight(i),
          child: Semantics(
            button: !blocked,
            enabled: !blocked,
            selected: selected,
            child: InkWell(key: ValueKey('batch-${b.batchNo}'), onTap: blocked ? null : () => bill.pickBatch(b), child: content),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DropTitle(
          title: 'Choose batch · ${product.name}',
          subtitle: 'Earliest expiry first (FEFO). Expired batches are blocked.',
          onClose: bill.escape,
        ),
        _headerBar([
          SizedBox(width: 110, child: Text('BATCH', style: AppType.overline)),
          SizedBox(width: 96, child: Text('EXPIRY', style: AppType.overline)),
          SizedBox(width: 80, child: Text('AVAILABLE', textAlign: TextAlign.right, style: AppType.overline)),
          SizedBox(width: 90, child: Text('MRP', textAlign: TextAlign.right, style: AppType.overline)),
          const Spacer(),
        ]),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final (i, b) in options.indexed) row(b, i, blocked: false),
                for (final (i, b) in expired.indexed) row(b, options.length + i, blocked: true),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Substitutes extends StatelessWidget {
  const _Substitutes({required this.product, required this.subs, required this.hi, required this.bill});

  final StockRow product;
  final List<StockRow> subs;
  final int hi;
  final BillController bill;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DropTitle(
          title: '${product.name} is out of stock',
          subtitle: 'Same salt (${product.salt}) available from other makers:',
          onClose: bill.escape,
        ),
        if (subs.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
            child: Text('No substitute in stock. Add it to the purchase order.', style: AppType.small.copyWith(color: AppColors.textSecondary)),
          )
        else
          for (final (i, r) in subs.indexed)
            _ProductRow(
              rowKey: ValueKey('sub-$i'),
              row: r,
              sub: '${r.maker} · ${r.pack}',
              selected: i == hi,
              onTap: () => bill.selectProduct(r),
              onHover: () => bill.setHighlight(i),
            ),
      ],
    );
  }
}

/// Exposed for the grid: same MRP text.
String mrpLabel(Paise p) => formatInr(p);
