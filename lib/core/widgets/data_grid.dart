import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// A column of [DataGrid]: either a fixed [width] or a flexible track
/// (`minmax(minWidth, flex fr)` in CSS-grid terms).
class GridColumn {
  const GridColumn(
    this.label, {
    this.width,
    this.flex = 1,
    this.minWidth = 0,
    this.alignEnd = false,
    this.sortKey,
  });

  /// Fixed-width column.
  const GridColumn.fixed(this.label, double this.width, {this.alignEnd = false, this.sortKey})
      : flex = 0,
        minWidth = 0;

  final String label;
  final double? width;
  final double flex;
  final double minWidth;

  /// Right-align header and cells (numbers, money, actions).
  final bool alignEnd;

  /// Non-null → header is a sort button reporting this key.
  final String? sortKey;

  bool get isFixed => width != null;
}

/// Resolves column widths for an available [width] like CSS grid does for
/// `minmax(min, Nfr)` tracks: leftover space is shared by flex, and tracks
/// that would fall below their minimum are frozen at it.
///
/// Returns `(widths, totalWidth)`; `totalWidth > width` means the grid must
/// scroll horizontally.
(List<double>, double) resolveColumnWidths(
  List<GridColumn> columns,
  double width, {
  double gap = 10,
  double padding = 16,
}) {
  final fixedTotal = columns.where((c) => c.isFixed).fold<double>(0, (a, c) => a + c.width!);
  final gaps = gap * math.max(0, columns.length - 1) + padding * 2;
  final minTotal = fixedTotal +
      gaps +
      columns.where((c) => !c.isFixed).fold<double>(0, (a, c) => a + c.minWidth);
  final total = width.isFinite ? math.max(width, minTotal) : minTotal;

  final widths = List<double>.filled(columns.length, 0);
  final frozen = <int>{};
  for (var i = 0; i < columns.length; i++) {
    if (columns[i].isFixed) {
      widths[i] = columns[i].width!;
      frozen.add(i);
    }
  }
  // Iteratively share space; freeze tracks that hit their min.
  while (true) {
    final free = total - gaps - frozen.fold<double>(0, (a, i) => a + widths[i]);
    final open = [for (var i = 0; i < columns.length; i++) if (!frozen.contains(i)) i];
    if (open.isEmpty) break;
    final fr = open.fold<double>(0, (a, i) => a + columns[i].flex);
    var changed = false;
    for (final i in open) {
      final share = fr == 0 ? 0.0 : free * columns[i].flex / fr;
      if (share < columns[i].minWidth) {
        widths[i] = columns[i].minWidth;
        frozen.add(i);
        changed = true;
      }
    }
    if (!changed) {
      for (final i in open) {
        widths[i] = fr == 0 ? 0.0 : free * columns[i].flex / fr;
      }
      break;
    }
  }
  return (widths, total);
}

typedef GridCellsBuilder = List<Widget> Function(BuildContext context, int row);

/// Header + rows table with the prototype's styling. Scrolls horizontally
/// when narrower than the columns' minimum width.
///
/// * [lazy] = true builds rows with `ListView.builder` and needs a bounded
///   height (put it in an `Expanded`). Use it for long lists (CLAUDE.md rule 11).
/// * [lazy] = false lays rows out in a Column (for one page of ≤ 100 rows
///   inside a scrolling screen).
class DataGrid extends StatefulWidget {
  const DataGrid({
    super.key,
    required this.columns,
    required this.rowCount,
    required this.cells,
    this.belowRow,
    this.onRowTap,
    this.selectedRow,
    this.sortKey,
    this.sortAscending = true,
    this.onSort,
    this.lazy = false,
    this.empty,
    this.columnGap = 10,
    this.semanticLabel,
  });

  final List<GridColumn> columns;
  final int rowCount;
  final GridCellsBuilder cells;

  /// Extra content under a row (e.g. expanded batch table), full width.
  final Widget? Function(BuildContext context, int row)? belowRow;
  final ValueChanged<int>? onRowTap;
  final int? selectedRow;

  final String? sortKey;
  final bool sortAscending;
  final ValueChanged<String>? onSort;

  final bool lazy;

  /// Shown under the header when [rowCount] is 0.
  final Widget? empty;
  final double columnGap;
  final String? semanticLabel;

  static const double _pad = 16;

  @override
  State<DataGrid> createState() => _DataGridState();
}

class _DataGridState extends State<DataGrid> {
  /// Shared by the horizontal Scrollbar and its scroll view. Without it the
  /// Scrollbar falls back to the PrimaryScrollController, which isn't
  /// attached here, and asserts on mouse hover.
  final ScrollController _hScroll = ScrollController();

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DataGrid(
      :columns,
      :rowCount,
      :cells,
      :belowRow,
      :onRowTap,
      :selectedRow,
      :sortKey,
      :sortAscending,
      :onSort,
      :lazy,
      :empty,
      :columnGap,
      :semanticLabel,
    ) = widget;
    return LayoutBuilder(
      builder: (context, c) {
        final (widths, total) = resolveColumnWidths(columns, c.maxWidth, gap: columnGap);
        final header = _Header(
          columns: columns,
          widths: widths,
          gap: columnGap,
          sortKey: sortKey,
          ascending: sortAscending,
          onSort: onSort,
        );

        Widget row(int i) => _Row(
              key: ValueKey(i),
              widths: widths,
              columns: columns,
              gap: columnGap,
              cells: cells(context, i),
              below: belowRow?.call(context, i),
              selected: selectedRow == i,
              onTap: onRowTap == null ? null : () => onRowTap(i),
            );

        Widget body;
        if (rowCount == 0) {
          body = empty ?? const SizedBox(height: AppSpace.lg);
        } else if (lazy) {
          body = ListView.builder(itemCount: rowCount, itemBuilder: (context, i) => row(i));
        } else {
          body = Column(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < rowCount; i++) row(i)]);
        }

        Widget table = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: lazy ? MainAxisSize.max : MainAxisSize.min,
          children: [header, if (lazy) Expanded(child: body) else body],
        );
        table = Semantics(container: true, label: semanticLabel, child: table);

        if (total > c.maxWidth + 0.5) {
          final scrolled = SizedBox(width: total, height: lazy ? c.maxHeight : null, child: table);
          // Desktop adds a scrollbar to every scroll view by default; turn
          // that off for this one view (we draw our own so touch shows one
          // too) and give the rows back the normal behaviour.
          final behavior = ScrollConfiguration.of(context);
          return Scrollbar(
            controller: _hScroll,
            child: ScrollConfiguration(
              behavior: behavior.copyWith(scrollbars: false),
              child: SingleChildScrollView(
                controller: _hScroll,
                scrollDirection: Axis.horizontal,
                child: ScrollConfiguration(behavior: behavior, child: scrolled),
              ),
            ),
          );
        }
        return table;
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.columns,
    required this.widths,
    required this.gap,
    required this.sortKey,
    required this.ascending,
    required this.onSort,
  });

  final List<GridColumn> columns;
  final List<double> widths;
  final double gap;
  final String? sortKey;
  final bool ascending;
  final ValueChanged<String>? onSort;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;
    return Container(
      color: AppColors.surfaceAlt,
      constraints: const BoxConstraints(minHeight: AppSizes.controlMin),
      padding: const EdgeInsets.symmetric(horizontal: DataGrid._pad),
      child: Row(
        children: [
          for (final (i, col) in columns.indexed) ...[
            if (i > 0) SizedBox(width: gap),
            SizedBox(
              width: widths[i],
              child: Align(
                alignment: col.alignEnd ? Alignment.centerRight : Alignment.centerLeft,
                child: col.sortKey != null && onSort != null
                    ? _SortHeader(
                        label: col.label,
                        active: sortKey == col.sortKey,
                        ascending: ascending,
                        accent: accent,
                        onTap: () => onSort!(col.sortKey!),
                      )
                    : Semantics(
                        header: true,
                        child: Text(col.label, style: AppType.label, overflow: TextOverflow.ellipsis),
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SortHeader extends StatelessWidget {
  const _SortHeader({
    required this.label,
    required this.active,
    required this.ascending,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool ascending;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dir = ascending ? 'ascending' : 'descending';
    return Semantics(
      header: true,
      button: true,
      label: active ? '$label, sorted $dir' : '$label, sortable',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.tinyAll,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.controlMin),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(label, style: AppType.label, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 4),
              SizedBox(
                width: 10,
                child: Text(active ? (ascending ? '↑' : '↓') : '', style: AppType.label.copyWith(color: accent)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    super.key,
    required this.widths,
    required this.columns,
    required this.gap,
    required this.cells,
    required this.below,
    required this.selected,
    required this.onTap,
  });

  final List<double> widths;
  final List<GridColumn> columns;
  final double gap;
  final List<Widget> cells;
  final Widget? below;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    assert(widget.cells.length == widget.columns.length, 'DataGrid: cells must match columns');
    final p = context.palette;
    final bg = widget.selected
        ? p.accentSoft
        : _hover
            ? AppColors.rowHover
            : AppColors.surface;

    Widget line = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DataGrid._pad, vertical: AppSpace.sm),
        child: Row(
          children: [
            for (final (i, col) in widget.columns.indexed) ...[
              if (i > 0) SizedBox(width: widget.gap),
              SizedBox(
                width: widget.widths[i],
                child: Align(
                  alignment: col.alignEnd ? Alignment.centerRight : Alignment.centerLeft,
                  child: widget.cells[i],
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (widget.onTap != null) {
      line = InkWell(onTap: widget.onTap, hoverColor: AppColors.transparent, child: line);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: context.motion(const Duration(milliseconds: 150)),
        decoration: BoxDecoration(
          color: bg,
          border: const Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: Semantics(
          selected: widget.selected,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [line, if (widget.below != null) widget.below!],
            ),
          ),
        ),
      ),
    );
  }
}
