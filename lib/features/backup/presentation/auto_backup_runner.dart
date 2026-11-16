import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/widgets.dart';
import '../application/backup_service.dart';

/// Automatic backups (SPEC §5.6): at first launch of the day when overdue,
/// and when the app is closed. No background service.
class AutoBackupRunner extends ConsumerStatefulWidget {
  const AutoBackupRunner({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AutoBackupRunner> createState() => _AutoBackupRunnerState();
}

class _AutoBackupRunnerState extends ConsumerState<AutoBackupRunner> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExit);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run(announce: true)));
  }

  Future<AppExitResponse> _onExit() async {
    await _run(announce: false);
    return AppExitResponse.exit;
  }

  Future<void> _run({required bool announce}) async {
    try {
      final path = await ref.read(backupServiceProvider).runAutoIfDue();
      if (path != null && announce && mounted) ref.read(toastsProvider.notifier).show('Automatic backup saved');
    } on Object catch (e) {
      if (announce && mounted) ref.read(toastsProvider.notifier).show('Automatic backup failed: $e', warn: true);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
