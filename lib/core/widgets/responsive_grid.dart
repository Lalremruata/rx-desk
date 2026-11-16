import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';

/// CSS `grid-template-columns: repeat(auto-fit, minmax(minTileWidth, 1fr))`.
///
/// Fits as many columns as possible with tiles at least [minTileWidth] wide,
/// shares the leftover width equally, and makes tiles in a row equal height.
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({
    super.key,
    required this.children,
    this.minTileWidth = AppSizes.minTile,
    this.gap = AppSpace.lg,
    this.equalHeight = true,
  });

  final List<Widget> children;
  final double minTileWidth;
  final double gap;

  /// Stretch tiles in a row to the same height (uses IntrinsicHeight, so
  /// children must not contain LayoutBuilders). Turn off for card grids.
  final bool equalHeight;

  /// Number of columns that fit in [width].
  static int columnsFor(double width, double minTileWidth, double gap) {
    if (!width.isFinite) return 1;
    final n = ((width + gap) / (minTileWidth + gap)).floor();
    return n < 1 ? 1 : n;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = columnsFor(c.maxWidth, minTileWidth, gap).clamp(1, children.isEmpty ? 1 : children.length);
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += cols) {
          final cells = <Widget>[];
          for (var j = 0; j < cols; j++) {
            if (j > 0) cells.add(SizedBox(width: gap));
            final k = i + j;
            cells.add(Expanded(child: k < children.length ? children[k] : const SizedBox.shrink()));
          }
          if (rows.isNotEmpty) rows.add(SizedBox(height: gap));
          rows.add(
            equalHeight
                ? IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells))
                : Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells),
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: rows);
      },
    );
  }
}
