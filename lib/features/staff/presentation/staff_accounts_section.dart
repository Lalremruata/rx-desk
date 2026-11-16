import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/presentation/settings_widgets.dart';
import '../application/session.dart';
import '../data/staff_repository.dart';
import 'lock_gate.dart';

/// Settings › Staff & roles › Staff accounts. Changes apply immediately
/// (they're accounts, not draft settings) and need "change settings".
class StaffAccountsSection extends ConsumerWidget {
  const StaffAccountsSection({super.key});

  Future<void> _run(WidgetRef ref, Future<void> Function() f, String done) async {
    try {
      if (!ref.read(canProvider(Permission.changeSettings))) throw const PermissionDenied(Permission.changeSettings);
      await f();
      ref.read(toastsProvider.notifier).show(done);
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('$e', warn: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final staff = ref.watch(staffAccountsProvider).value ?? const <StaffMember>[];
    final me = ref.watch(sessionProvider);
    final repo = ref.read(staffRepositoryProvider);
    final allowed = ref.watch(canProvider(Permission.changeSettings));
    return SettingsSection(
      title: 'Staff accounts',
      subtitle: 'Each person signs in at the counter with a 4-digit PIN. Bills record who made them.',
      trailing: AppButton(
        key: const ValueKey('add-staff'),
        label: 'Add staff',
        icon: Icons.person_add_alt_1_outlined,
        height: 40,
        onPressed: !allowed
            ? null
            : () async {
                final r = await showAppDialog<(String, StaffRole, String)>(context, builder: (_) => const _StaffDialog());
                if (r == null) return;
                await _run(ref, () => repo.add(name: r.$1, role: r.$2, pin: r.$3), '${r.$1.trim()} added as ${r.$2.label}');
              },
      ),
      children: [
        if (staff.isEmpty) Text('No accounts yet.', style: AppType.small.copyWith(color: AppColors.textSecondary)),
        for (final s in staff)
          Container(
            key: ValueKey('staff-row-${s.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(border: Border.all(color: AppColors.divider), borderRadius: const BorderRadius.all(Radius.circular(12))),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              spacing: AppSpace.md,
              runSpacing: AppSpace.sm,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: (AppColors.role[s.role] ?? StatusTone.neutral.colors).bg,
                      child: Text(s.name.isEmpty ? '?' : s.name[0].toUpperCase(), style: AppType.bodyStrong.copyWith(color: (AppColors.role[s.role] ?? StatusTone.neutral.colors).fg)),
                    ),
                    const SizedBox(width: AppSpace.md),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${s.name}${me?.staffId == s.id ? ' (you)' : ''}', style: AppType.bodyStrong),
                        Text('${s.role} · ${s.active ? 'Active' : 'Disabled'} · PIN set', style: AppType.caption),
                      ],
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppDropdown<StaffRole>(
                      semanticLabel: 'Role for ${s.name}',
                      value: StaffRole.fromLabel(s.role),
                      options: [for (final r in StaffRole.values) DropdownOption(r, r.label)],
                      onChanged: allowed ? (r) => _run(ref, () => repo.setRole(s.id, r), '${s.name} is now ${r.label}') : null,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    AppButton.secondary(
                      label: 'Reset PIN',
                      height: 40,
                      onPressed: !allowed
                          ? null
                          : () async {
                              final pin = await showAppDialog<String>(context, builder: (_) => _PinDialog(name: s.name));
                              if (pin != null) await _run(ref, () => repo.resetPin(s.id, pin), 'PIN changed for ${s.name}');
                            },
                    ),
                    const SizedBox(width: AppSpace.sm),
                    AppSwitch(
                      semanticLabel: 'Active: ${s.name}',
                      value: s.active,
                      onChanged: allowed ? (v) => _run(ref, () => repo.setActive(s.id, v), v ? '${s.name} enabled' : '${s.name} disabled') : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StaffDialog extends StatefulWidget {
  const _StaffDialog();

  @override
  State<_StaffDialog> createState() => _StaffDialogState();
}

class _StaffDialogState extends State<_StaffDialog> {
  String _name = '', _pin = '';
  StaffRole _role = StaffRole.cashier;
  String? _error;

  void _ok() {
    if (_name.trim().isEmpty) return setState(() => _error = 'Enter the name');
    if (!RegExp(r'^\d{4}$').hasMatch(_pin)) return setState(() => _error = 'PIN must be 4 digits');
    Navigator.of(context).pop((_name, _role, _pin));
  }

  @override
  Widget build(BuildContext context) => AppDialogPanel(
        semanticLabel: 'Add staff',
        children: [
          Text('Add staff member', style: AppType.dialogTitle),
          AppTextField(key: const ValueKey('staff-name'), label: 'Name', value: _name, autofocus: true, onChanged: (v) => setState(() => _name = v)),
          SegmentedPills<StaffRole>(
            semanticLabel: 'Role',
            options: [for (final r in StaffRole.values) PillOption(r, r.label)],
            selected: _role,
            onChanged: (r) => setState(() => _role = r),
          ),
          AppTextField(
            key: const ValueKey('staff-pin'),
            label: '4-digit PIN',
            value: _pin,
            maxLength: 4,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            error: _error,
            onChanged: (v) => setState(() => _pin = v),
            onSubmitted: (_) => _ok(),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpace.gap10,
            children: [
              AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
              AppButton(key: const ValueKey('staff-save'), label: 'Add', onPressed: _ok),
            ],
          ),
        ],
      );
}

class _PinDialog extends StatefulWidget {
  const _PinDialog({required this.name});
  final String name;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  String _pin = '';

  @override
  Widget build(BuildContext context) => AppDialogPanel(
        semanticLabel: 'Reset PIN',
        children: [
          Text('New PIN for ${widget.name}', style: AppType.dialogTitle),
          AppTextField(
            label: '4-digit PIN',
            value: _pin,
            autofocus: true,
            maxLength: 4,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) => setState(() => _pin = v),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpace.gap10,
            children: [
              AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
              AppButton(label: 'Save PIN', onPressed: _pin.length == 4 ? () => Navigator.of(context).pop(_pin) : null),
            ],
          ),
        ],
      );
}
