import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../utils/format.dart';

/// Page numbers to show for [page] of [pages] (both 1-based): first, last,
/// and the current page ± 1, with `null` marking an ellipsis gap.
///
/// `pageWindow(5, 10)` → `[1, null, 4, 5, 6, null, 10]` (prototype logic).
List<int?> pageWindow(int page, int pages) {
  if (pages <= 0) return const [];
  final want = <int>{1, pages, page - 1, page, page + 1}.where((n) => n >= 1 && n <= pages).toList()..sort();
  final out = <int?>[];
  for (final (i, n) in want.indexed) {
    if (i > 0 && n - want[i - 1] > 1) out.add(null);
    out.add(n);
  }
  return out;
}

/// "1–50 of 1,649" for 1-based [page].
String pageRangeLabel(int page, int pageSize, int totalRows) {
  if (totalRows <= 0) return '0 results';
  final from = (page - 1) * pageSize + 1;
  final to = (page * pageSize).clamp(0, totalRows);
  return '${formatCount(from)}–${formatCount(to)} of ${formatCount(totalRows)}';
}

/// Numbered pager footer (Inventory): range text, rows-per-page select,
/// ‹ Prev · 1 … 4 5 6 … 33 · Next ›.
class Pager extends StatelessWidget {
  const Pager({
    super.key,
    required this.page,
    required this.pageSize,
    required this.totalRows,
    required this.onPage,
    this.onPageSize,
    this.pageSizes = const [25, 50, 100],
    this.trailingNote,
  });

  /// 1-based.
  final int page;
  final int pageSize;
  final int totalRows;
  final ValueChanged<int> onPage;
  final ValueChanged<int>? onPageSize;
  final List<int> pageSizes;

  /// Extra footer text, e.g. "computed in 18.4 ms".
  final String? trailingNote;

  int get pages => totalRows <= 0 ? 1 : (totalRows / pageSize).ceil();

  @override
  Widget build(BuildContext context) {
    final p = page.clamp(1, pages);
    return DefaultTextStyle.merge(
      style: AppType.small.copyWith(color: AppColors.textSecondary),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              children: [
                Text(pageRangeLabel(p, pageSize, totalRows)),
                if (onPageSize != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Rows'),
                      const SizedBox(width: 6),
                      _RowsSelect(value: pageSize, options: pageSizes, onChanged: onPageSize!),
                    ],
                  ),
                if (trailingNote != null) Text(trailingNote!),
              ],
            ),
            Semantics(
              container: true,
              label: 'Pages',
              child: Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  PagerButton(label: '‹ Prev', semanticLabel: 'Previous page', onTap: p > 1 ? () => onPage(p - 1) : null),
                  for (final n in pageWindow(p, pages))
                    n == null
                        ? const PagerButton(label: '…', gap: true)
                        : PagerButton(
                            label: '$n',
                            semanticLabel: 'Page $n',
                            current: n == p,
                            onTap: n == p ? null : () => onPage(n),
                          ),
                  PagerButton(label: 'Next ›', semanticLabel: 'Next page', onTap: p < pages ? () => onPage(p + 1) : null),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keyset pager (Invoices, Sales register lines): "‹ Newer" / "Older ›".
class KeysetPager extends StatelessWidget {
  const KeysetPager({super.key, required this.label, this.onNewer, this.onOlder});

  final String label;
  final VoidCallback? onNewer;
  final VoidCallback? onOlder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppType.small.copyWith(color: AppColors.textSecondary))),
          PagerButton(label: '‹ Newer', semanticLabel: 'Newer', onTap: onNewer),
          const SizedBox(width: 4),
          PagerButton(label: 'Older ›', semanticLabel: 'Older', onTap: onOlder),
        ],
      ),
    );
  }
}

/// 36 px pager button inside a 44 px hit area.
class PagerButton extends StatelessWidget {
  const PagerButton({
    super.key,
    required this.label,
    this.onTap,
    this.current = false,
    this.gap = false,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onTap;
  final bool current;
  final bool gap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;
    final enabled = onTap != null;
    final bg = gap ? AppColors.transparent : (current ? accent : AppColors.surface);
    final bd = gap ? AppColors.transparent : (current ? accent : AppColors.chipBorder);
    final fg = gap ? AppColors.textMuted : (current ? AppColors.onAccent : AppColors.body);
    final dim = !enabled && !current && !gap;

    final visual = Container(
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: bg, borderRadius: AppRadius.smallAll, border: Border.all(color: bd)),
      child: Center(widthFactor: 1, heightFactor: 1, child: Text(label, style: AppType.smallStrong.copyWith(color: fg))),
    );

    if (gap) return ExcludeSemantics(child: SizedBox(height: AppSizes.controlMin, child: Center(widthFactor: 1, child: visual)));
    return Semantics(
      button: true,
      enabled: enabled,
      selected: current,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      child: Opacity(
        opacity: dim ? 0.45 : 1,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: AppRadius.smallAll,
            child: SizedBox(height: AppSizes.controlMin, child: Center(widthFactor: 1, child: visual)),
          ),
        ),
      ),
    );
  }
}

class _RowsSelect extends StatelessWidget {
  const _RowsSelect({required this.value, required this.options, required this.onChanged});

  final int value;
  final List<int> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.smallAll,
        border: Border.all(color: AppColors.inputBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: value,
          isDense: true,
          borderRadius: AppRadius.smallAll,
          style: AppType.smallStrong,
          icon: const Icon(Icons.expand_more_rounded, size: 18),
          items: [for (final n in options) DropdownMenuItem(value: n, child: Text('$n'))],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}
