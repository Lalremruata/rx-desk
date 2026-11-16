import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';

part 'session.g.dart';

/// Who is using the counter right now.
class SessionUser {
  const SessionUser({this.staffId, required this.name, required this.role});

  final int? staffId;
  final String name;
  final StaffRole role;
}

/// Session at startup. The app starts locked (null); tests override this
/// with a signed-in user.
@Riverpod(keepAlive: true)
SessionUser? initialSession(Ref ref) => null;

/// The signed-in staff member, or null when the counter is locked.
@Riverpod(keepAlive: true)
class Session extends _$Session {
  @override
  SessionUser? build() => ref.watch(initialSessionProvider);

  void signIn(SessionUser user) => state = user;
  void lock() => state = null;
}

/// Whether the current user has [p] (Owner has everything).
@riverpod
bool can(Ref ref, Permission p) {
  final user = ref.watch(sessionProvider);
  if (user == null) return false;
  return ref.watch(settingsProvider).roleHas(user.role, p);
}

class PermissionDenied implements Exception {
  const PermissionDenied(this.permission);
  final Permission permission;

  @override
  String toString() => 'Your role can’t do this: ${permission.label.toLowerCase()}. Ask the owner.';
}

/// Throws [PermissionDenied] unless the signed-in user has [p]. Application
/// services call this so rules hold even if a button is reachable.
void requirePermission(Ref ref, Permission p) {
  if (!ref.read(canProvider(p))) throw PermissionDenied(p);
}
