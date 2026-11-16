import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/app_settings.dart';
import '../application/session.dart';
import '../data/staff_repository.dart';

/// Asks for the Owner's go-ahead (e.g. past a customer's credit limit,
/// SPEC §4.10). An Owner at the counter just confirms; anyone else needs an
/// active Owner's PIN. Returns true when allowed.
Future<bool> confirmOwnerOverride(BuildContext context, WidgetRef ref, {required String title, required String message, required String allowLabel}) async {
  final owner = ref.read(sessionProvider)?.role == StaffRole.owner;
  final ok = await showAppDialog<bool>(
    context,
    builder: (_) => OwnerOverrideDialog(title: title, message: message, allowLabel: allowLabel, needPin: !owner),
  );
  return ok ?? false;
}

class OwnerOverrideDialog extends ConsumerStatefulWidget {
  const OwnerOverrideDialog({super.key, required this.title, required this.message, required this.allowLabel, required this.needPin});

  final String title;
  final String message;
  final String allowLabel;
  final bool needPin;

  @override
  ConsumerState<OwnerOverrideDialog> createState() => _OwnerOverrideDialogState();
}

class _OwnerOverrideDialogState extends ConsumerState<OwnerOverrideDialog> {
  String pin = '';
  String? error;
  bool checking = false;

  Future<void> _allow() async {
    if (!widget.needPin) {
      Navigator.of(context).pop(true);
      return;
    }
    if (pin.length != 4) {
      setState(() => error = 'Enter the Owner’s 4-digit PIN');
      return;
    }
    setState(() {
      checking = true;
      error = null;
    });
    final m = await ref.read(staffRepositoryProvider).verifyOwnerPin(pin);
    if (!mounted) return;
    if (m == null) {
      setState(() {
        checking = false;
        error = 'That isn’t an Owner PIN';
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AppDialogPanel(
      semanticLabel: widget.title,
      children: [
        Semantics(header: true, child: Text(widget.title, style: AppType.cardTitle)),
        Text(widget.message, key: const ValueKey('override-message'), style: AppType.body),
        if (widget.needPin)
          AppTextField(
            fieldKey: const ValueKey('override-pin'),
            label: 'Owner PIN',
            hint: '4 digits',
            value: pin,
            error: error,
            autofocus: true,
            obscure: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
            onChanged: (v) => setState(() => pin = v),
            onSubmitted: (_) => _allow(),
          ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.gap10,
          children: [
            AppButton.secondary(key: const ValueKey('override-cancel'), label: 'Don’t allow', onPressed: () => Navigator.of(context).pop(false)),
            AppButton(
              key: const ValueKey('override-allow'),
              label: checking ? 'Checking…' : widget.allowLabel,
              onPressed: checking ? null : _allow,
            ),
          ],
        ),
      ],
    );
  }
}
