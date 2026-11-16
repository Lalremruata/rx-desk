import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../../settings/application/app_settings.dart';

/// Shown instead of a screen the signed-in role can't use.
class AccessDenied extends StatelessWidget {
  const AccessDenied({super.key, required this.permission});

  final Permission permission;

  @override
  Widget build(BuildContext context) => PageScroll(
        children: [
          AppCard(
            child: EmptyState(
              icon: Icons.lock_outline_rounded,
              title: 'Not available for your role',
              message: '“${permission.label}” is turned off for your role. Ask the owner to change it in Settings › Staff & roles.',
            ),
          ),
        ],
      );
}
