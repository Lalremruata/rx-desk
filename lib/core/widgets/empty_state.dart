import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Centered "nothing here" message, e.g. "No medicines match" /
/// "Try a salt name or barcode, or clear the filters."
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.message, this.icon, this.action});

  final String title;
  final String? message;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: p.accentSoft, borderRadius: const BorderRadius.all(Radius.circular(12))),
              child: Icon(icon, size: 20, color: p.accent),
            ),
            const SizedBox(height: AppSpace.md),
          ],
          Text(title, style: AppType.emptyTitle, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              style: AppType.small.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
          if (action != null) ...[const SizedBox(height: AppSpace.lg), action!],
        ],
      ),
    );
  }
}
