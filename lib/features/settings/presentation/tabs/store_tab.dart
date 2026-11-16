import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../application/app_settings.dart';
import '../../application/settings_providers.dart';
import '../../data/settings_repository.dart';
import '../settings_widgets.dart';

class StoreTab extends ConsumerWidget {
  const StoreTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = watchEditing(ref);
    final errors = ref.watch(settingsDraftErrorsProvider);
    Widget field(
      String key,
      String label,
      String hint,
      String value,
      AppSettings Function(AppSettings, String) set, {
      bool full = false,
      List<TextInputFormatter>? fmt,
      TextInputType? kb,
      int? maxLength,
    }) {
      final f = AppTextField(
        key: ValueKey('store-$key'),
        label: label,
        hint: hint,
        value: value,
        error: errors[key],
        inputFormatters: fmt,
        keyboardType: kb,
        maxLength: maxLength,
        onChanged: (v) => editSettings(ref, (x) => set(x, v)),
      );
      return full ? FieldSpan(child: f) : f;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'Pharmacy details',
          subtitle: 'Printed at the top of every invoice and report.',
          children: [
            _LogoRow(settings: s),
            FieldGrid(
              children: [
                field('name', 'Pharmacy name', 'As on your drug licence', s.name, (x, v) => x.copyWith(name: v), full: true),
                field('legalName', 'Legal / business name (if different)', 'Optional', s.legalName, (x, v) => x.copyWith(legalName: v)),
                field('phone', 'Phone', 'Shop phone', s.phone, (x, v) => x.copyWith(phone: v), kb: TextInputType.phone),
                field('email', 'Email', 'Optional', s.email, (x, v) => x.copyWith(email: v.trim()), kb: TextInputType.emailAddress),
                field('addr1', 'Address line 1', 'Building, street', s.addr1, (x, v) => x.copyWith(addr1: v), full: true),
                field('addr2', 'Address line 2', 'Locality, landmark', s.addr2, (x, v) => x.copyWith(addr2: v), full: true),
                field('city', 'City / town', 'City', s.city, (x, v) => x.copyWith(city: v)),
                field('state', 'State', 'State', s.state, (x, v) => x.copyWith(state: v)),
                field(
                  'pin',
                  'PIN code',
                  '6 digits',
                  s.pin,
                  (x, v) => x.copyWith(pin: v),
                  fmt: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 6,
                  kb: TextInputType.number,
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        SettingsSection(
          title: 'Licences & tax registration',
          subtitle: 'Drug licence numbers and GSTIN must appear on a pharmacy’s sale bill.',
          children: [
            FieldGrid(
              children: [
                field(
                  'gstin',
                  'GSTIN',
                  '15-character GSTIN',
                  s.gstin,
                  (x, v) => x.copyWith(gstin: v.toUpperCase()),
                  fmt: [_UpperCase(), FilteringTextInputFormatter.allow(RegExp('[0-9A-Za-z]'))],
                  maxLength: 15,
                ),
                field('dl20b', 'Drug licence – Form 20B', 'Retail licence no.', s.dl20b, (x, v) => x.copyWith(dl20b: v)),
                field('dl21b', 'Drug licence – Form 21B', 'Retail licence no.', s.dl21b, (x, v) => x.copyWith(dl21b: v)),
                field('pharmacistName', 'Registered pharmacist in charge', 'Full name', s.pharmacistName, (x, v) => x.copyWith(pharmacistName: v)),
                field('pharmacistRegNo', 'Pharmacist registration no.', 'State council reg. no.', s.pharmacistRegNo, (x, v) => x.copyWith(pharmacistRegNo: v)),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _UpperCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}

class _LogoRow extends ConsumerWidget {
  const _LogoRow({required this.settings});

  final AppSettings settings;

  Future<void> _pick(WidgetRef ref) async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['png', 'jpg', 'jpeg']);
    final path = f?.path;
    if (path == null) return;
    try {
      final dest = await ref.read(settingsRepositoryProvider).importLogo(path);
      editSettings(ref, (x) => x.copyWith(logoPath: dest));
    } on Object catch (e) {
      ref.read(toastsProvider.notifier).show('Couldn’t use that image: $e', warn: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final hasLogo = settings.logoPath.isNotEmpty && File(settings.logoPath).existsSync();
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(border: Border.all(color: AppColors.divider), borderRadius: const BorderRadius.all(Radius.circular(12))),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpace.gap14,
        runSpacing: AppSpace.sm,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: Container(
              width: 56,
              height: 56,
              color: hasLogo ? AppColors.surface : p.accent,
              alignment: Alignment.center,
              child: hasLogo
                  ? Image.file(File(settings.logoPath), fit: BoxFit.contain, semanticLabel: 'Store logo')
                  : Text(settings.initials, style: AppType.cardTitle.copyWith(color: AppColors.onAccent, fontSize: 20)),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Logo', style: AppType.smallStrong),
                Text('Square PNG or JPG, 256 px or larger. Your initials are used until you add one.', style: AppType.caption),
              ],
            ),
          ),
          AppButton.secondary(label: hasLogo ? 'Change logo' : 'Upload logo', icon: Icons.upload_rounded, onPressed: () => _pick(ref)),
          if (hasLogo)
            AppButton.secondary(label: 'Remove', onPressed: () => editSettings(ref, (x) => x.copyWith(logoPath: ''))),
        ],
      ),
    );
  }
}
