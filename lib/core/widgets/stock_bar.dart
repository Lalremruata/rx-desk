import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

enum StockLevel { ok, low, out }

/// Thin progress bar for stock (inventory grid, reorder list) with an
/// optional number on the right. Bar colour: accent when OK, amber when low,
/// red when out. Width tweens linearly in 180 ms.
class StockBar extends StatelessWidget {
  const StockBar({
    super.key,
    required this.fraction,
    this.level = StockLevel.ok,
    this.trailing,
    this.color,
    this.semanticLabel,
  });

  /// 0–1, clamped.
  final double fraction;
  final StockLevel level;

  /// Text after the bar (e.g. the unit count).
  final String? trailing;

  /// Overrides the level colour.
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final f = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0);
    final barColor = color ??
        switch (level) {
          StockLevel.ok => context.palette.accent,
          StockLevel.low => StockColors.barLow,
          StockLevel.out => StockColors.barOut,
        };
    final bar = ClipRRect(
      borderRadius: AppRadius.pillAll,
      child: SizedBox(
        height: 6,
        child: DecoratedBox(
          decoration: const BoxDecoration(color: AppColors.track),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: f),
              duration: context.motion(AppMotion.progress),
              builder: (context, v, _) => FractionallySizedBox(
                widthFactor: v,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: barColor, borderRadius: AppRadius.pillAll),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Semantics(
      label: semanticLabel ?? trailing,
      value: '${(f * 100).round()}%',
      excludeSemantics: true,
      child: Row(
        children: [
          Expanded(child: bar),
          if (trailing != null) ...[
            const SizedBox(width: AppSpace.gap10),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 34),
              child: Text(
                trailing!,
                textAlign: TextAlign.right,
                style: AppType.bodyStrong.copyWith(fontFeatures: AppType.tabular),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
