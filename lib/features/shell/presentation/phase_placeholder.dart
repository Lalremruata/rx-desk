import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';

/// Temporary body for screens that later phases build. Lists what the
/// screen will do so testers know what's coming.
class PhasePlaceholder extends StatelessWidget {
  const PhasePlaceholder({
    super.key,
    required this.phase,
    required this.icon,
    required this.summary,
    required this.bullets,
    this.leading = const [],
  });

  final int phase;
  final IconData icon;
  final String summary;
  final List<String> bullets;

  /// Extra widgets above the placeholder card (e.g. Settings tab chips).
  final List<Widget> leading;

  @override
  Widget build(BuildContext context) {
    return PageScroll(
      children: [
        ...leading,
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EmptyState(icon: icon, title: 'Coming in phase $phase', message: summary),
              const Divider(),
              const SizedBox(height: AppSpace.lg),
              for (final b in bullets)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 3, right: AppSpace.gap10),
                        child: Icon(Icons.check_circle_outline_rounded, size: 16, color: AppColors.textMuted),
                      ),
                      Expanded(child: Text(b, style: AppType.small.copyWith(color: AppColors.body))),
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
