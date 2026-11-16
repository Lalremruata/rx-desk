import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/widgets.dart';
import 'features/backup/presentation/auto_backup_runner.dart';
import 'features/settings/application/settings_providers.dart';
import 'features/staff/presentation/lock_gate.dart';

class RxDeskApp extends ConsumerWidget {
  const RxDeskApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(accentProvider);
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'RxDesk',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(accent),
      routerConfig: router,
      // Toasts sit above every route, dialogs included.
      builder: (context, child) => AutoBackupRunner(child: ToastHost(child: LockGate(child: child ?? const SizedBox.shrink()))),
    );
  }
}
