import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_card.dart';

/// Dashboard KPI tile: label + icon chip, big number, caption.
/// Pass [onTap] for the tap-through variant (lifts on hover, shows an arrow
/// caption like "Review and reorder →").
class KpiTile extends StatelessWidget {
  const KpiTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.caption,
    this.tone = StatusTone.accent,
    this.captionTone,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final String? caption;

  /// Colours of the icon chip.
  final StatusTone tone;

  /// When set, the caption is drawn bold in this tone's foreground colour.
  final StatusTone? captionTone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final chip = palette.tone(tone);
    final capColor = captionTone == null ? AppColors.textSecondary : palette.tone(captionTone!).fg;

    return AppCard(
      onTap: onTap,
      hoverLift: true,
      padding: const EdgeInsets.all(18),
      semanticLabel: '$label: $value${caption == null ? '' : '. $caption'}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: AppType.small.copyWith(color: AppColors.textSecondary, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: chip.bg, borderRadius: AppRadius.controlAll),
                  child: Icon(icon, size: 18, color: chip.icon),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: AppType.kpi.copyWith(fontFeatures: AppType.tabular)),
            ),
            if (caption != null) ...[
              const SizedBox(height: AppSpace.md),
              Text(
                caption!,
                style: AppType.caption.copyWith(
                  color: capColor,
                  fontWeight: captionTone == null ? FontWeight.w400 : FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
