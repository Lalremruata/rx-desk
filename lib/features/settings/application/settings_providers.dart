import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/theme/app_theme.dart';
import '../../staff/application/session.dart';
import '../data/settings_repository.dart';
import 'app_settings.dart';

part 'settings_providers.g.dart';

/// Settings loaded at startup (bootstrap overrides this before the app runs,
/// so every screen can read settings synchronously).
@Riverpod(keepAlive: true)
AppSettings initialSettings(Ref ref) => const AppSettings();

/// The saved settings — the one place the app reads settings from
/// (CLAUDE.md rule 12).
@Riverpod(keepAlive: true)
class Settings extends _$Settings {
  @override
  AppSettings build() => ref.watch(initialSettingsProvider);

  Future<void> save(AppSettings s) async {
    await ref.read(settingsRepositoryProvider).save(s);
    state = s;
  }
}

/// Outcome of trying to save the draft.
sealed class SaveDraftResult {
  const SaveDraftResult();
}

class DraftSaved extends SaveDraftResult {
  const DraftSaved();
}

class DraftDenied extends SaveDraftResult {
  const DraftDenied();
}

class DraftInvalid extends SaveDraftResult {
  const DraftInvalid(this.errors);
  final Map<String, String> errors;
}

/// Settings › edits go to this draft until saved (SPEC §5.7). `null` = no
/// edits in progress.
@Riverpod(keepAlive: true)
class SettingsDraft extends _$SettingsDraft {
  @override
  AppSettings? build() => null;

  AppSettings get current => state ?? ref.read(settingsProvider);


  void edit(AppSettings Function(AppSettings s) change) {
    final next = change(current);
    state = changedKeys(next, ref.read(settingsProvider)).isEmpty ? null : next;
  }

  void discard() => state = null;

  /// Loads §7 defaults into the draft. Data and staff are never touched; the
  /// user still has to press Save. Store identity fields are kept so a reset
  /// doesn't wipe the pharmacy's name and licences.
  void resetToDefaults() {
    final saved = ref.read(settingsProvider);
    edit((_) => const AppSettings().copyWith(
          name: saved.name,
          legalName: saved.legalName,
          phone: saved.phone,
          email: saved.email,
          addr1: saved.addr1,
          addr2: saved.addr2,
          city: saved.city,
          state: saved.state,
          pin: saved.pin,
          gstin: saved.gstin,
          dl20b: saved.dl20b,
          dl21b: saved.dl21b,
          pharmacistName: saved.pharmacistName,
          pharmacistRegNo: saved.pharmacistRegNo,
          logoPath: saved.logoPath,
        ));
  }

  Future<SaveDraftResult> save() async {
    final d = state;
    if (d == null) return const DraftSaved();
    if (!ref.read(canProvider(Permission.changeSettings))) return const DraftDenied();
    final errors = settingsErrors(d);
    if (errors.isNotEmpty) return DraftInvalid(errors);
    await ref.read(settingsProvider.notifier).save(d);
    state = null;
    return const DraftSaved();
  }
}

/// Names of draft fields that differ from saved settings.
@riverpod
List<String> settingsChanges(Ref ref) {
  final d = ref.watch(settingsDraftProvider);
  if (d == null) return const [];
  return changedKeys(d, ref.watch(settingsProvider));
}

/// Inline errors for the current draft.
@riverpod
Map<String, String> settingsDraftErrors(Ref ref) {
  final d = ref.watch(settingsDraftProvider);
  return d == null ? const {} : settingsErrors(d);
}

/// True while the Settings screen is open (the accent previews live there).
@Riverpod(keepAlive: true)
class SettingsOnScreen extends _$SettingsOnScreen {
  @override
  bool build() => false;

  void set(bool v) {
    if (ref.mounted) state = v;
  }
}

/// Live brand accent: the draft's colour while on Settings, else the saved
/// one (SPEC §5.7).
@Riverpod(keepAlive: true)
Color accent(Ref ref) {
  final saved = ref.watch(settingsProvider.select((s) => s.accent));
  final onScreen = ref.watch(settingsOnScreenProvider);
  final draft = onScreen ? ref.watch(settingsDraftProvider.select((d) => d?.accent)) : null;
  return colorFromHex(draft ?? saved);
}
