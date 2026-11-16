import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../staff/presentation/staff_accounts_section.dart';
import '../../application/app_settings.dart';
import '../settings_widgets.dart';

class StaffTab extends ConsumerWidget {
  const StaffTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [StaffAccountsSection(), SizedBox(height: AppSpace.lg), _PermissionsMatrix()],
    );
  }
}

class _PermissionsMatrix extends ConsumerWidget {
  const _PermissionsMatrix();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = watchEditing(ref);
    final accent = context.palette.accent;
    const roles = StaffRole.values;

    void flip(StaffRole role, Permission p) {
      editSettings(ref, (x) {
        final map = {for (final e in x.rolePermissions.entries) e.key: [...e.value]};
        final list = map.putIfAbsent(role.label, () => []);
        list.contains(p.name) ? list.remove(p.name) : list.add(p.name);
        list.sort();
        return x.copyWith(rolePermissions: map);
      });
    }

    return AppCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What each role can do', style: AppType.cardTitle),
                const SizedBox(height: 4),
                Text('The owner always has every permission.', style: AppType.small.copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ),
          DataGrid(
            semanticLabel: 'Role permissions',
            columns: const [
              GridColumn('Permission', minWidth: 220),
              GridColumn.fixed('Owner', 96),
              GridColumn.fixed('Pharmacist', 96),
              GridColumn.fixed('Cashier', 96),
            ],
            rowCount: Permission.values.length,
            cells: (context, i) {
              final p = Permission.values[i];
              return [
                Text(p.label, style: AppType.small),
                for (final r in roles)
                  _Check(
                    on: s.roleHas(r, p),
                    locked: r == StaffRole.owner,
                    accent: accent,
                    label: '${r.label}: ${p.label}',
                    onTap: () => flip(r, p),
                  ),
              ];
            },
          ),
        ],
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({required this.on, required this.locked, required this.accent, required this.label, required this.onTap});

  final bool on;
  final bool locked;
  final Color accent;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: on,
      enabled: !locked,
      label: label,
      excludeSemantics: true,
      child: Opacity(
        opacity: locked ? 0.55 : 1,
        child: InkWell(
          onTap: locked ? null : onTap,
          borderRadius: AppRadius.smallAll,
          child: SizedBox(
            width: AppSizes.controlMin,
            height: AppSizes.controlMin,
            child: Center(
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: on ? accent : AppColors.surface,
                  borderRadius: AppRadius.tinyAll,
                  border: Border.all(color: on ? accent : AppColors.kbdBorder, width: 1.5),
                ),
                child: on ? const Icon(Icons.check_rounded, size: 16, color: AppColors.onAccent) : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
