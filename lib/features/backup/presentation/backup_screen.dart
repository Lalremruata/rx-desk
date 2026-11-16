import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/db_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/save_file.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../../shell/application/shell_status.dart';
import '../../staff/application/guarded_actions.dart';
import '../../staff/application/session.dart';
import '../application/backup_format.dart';
import '../application/backup_service.dart';

/// Backup history (Drift row type → declared by hand).
final _historyProvider = StreamProvider.autoDispose<List<BackupEntry>>((ref) => ref.watch(appDatabaseProvider).backupDao.watchHistory());

final _recordsProvider = FutureProvider.autoDispose<(int, int)>((ref) async {
  ref.watch(_historyProvider);
  final db = ref.watch(appDatabaseProvider);
  return (await db.catalogDao.productCount(), await db.salesDao.invoiceCount());
});

/// Backup & restore (SPEC §5.6).
class BackupScreen extends ConsumerWidget {
  const BackupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const PageScroll(
      children: [
        _StatusTiles(),
        ResponsiveGrid(minTileWidth: 340, equalHeight: false, children: [_ExportCard(), _ImportCard()]),
        _AutoCard(),
        _History(),
      ],
    );
  }
}

class _StatusTiles extends ConsumerWidget {
  const _StatusTiles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rec = ref.watch(_recordsProvider).value;
    final last = ref.watch(lastBackupLabelProvider).value ?? 'Never';
    return ResponsiveGrid(
      children: [
        const KpiTile(label: 'Storage', value: 'On this device', icon: Icons.computer_outlined, caption: 'Nothing leaves this computer'),
        KpiTile(
          label: 'Records',
          value: rec == null ? '—' : '${formatCount(rec.$1)} medicines',
          caption: rec == null ? null : '${formatCount(rec.$2)} invoices',
          icon: Icons.inventory_2_outlined,
          tone: StatusTone.info,
        ),
        KpiTile(label: 'Last backup', value: last, icon: Icons.history_rounded, tone: last == 'Never' ? StatusTone.warning : StatusTone.success),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.value, required this.label});

  final double value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: AppRadius.pillAll,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: value),
              duration: context.motion(AppMotion.progress),
              builder: (context, v, _) => LinearProgressIndicator(value: v, minHeight: 8, backgroundColor: AppColors.track),
            ),
          ),
          const SizedBox(height: 6),
          Text('$label · ${(value * 100).round()}%', style: AppType.caption),
        ],
      );
}

class _ExportCard extends ConsumerStatefulWidget {
  const _ExportCard();

  @override
  ConsumerState<_ExportCard> createState() => _ExportCardState();
}

class _ExportCardState extends ConsumerState<_ExportCard> {
  bool _encrypt = true;
  String _password = '', _confirm = '';
  double? _progress;
  String? _error;

  Future<void> _export() async {
    if (_encrypt) {
      if (_password.length < 6) return setState(() => _error = 'Use at least 6 characters');
      if (_password != _confirm) return setState(() => _error = 'Passwords don’t match');
    }
    setState(() {
      _error = null;
      _progress = 0;
    });
    final toasts = ref.read(toastsProvider.notifier);
    try {
      final svc = ref.read(backupServiceProvider);
      final b = await ref
          .read(guardedActionsProvider)
          .prepareBackup(password: _encrypt ? _password : null, onProgress: (v) => mounted ? setState(() => _progress = v) : null);
      final path = await saveBytesAs(b.fileName, b.bytes);
      if (path != null) {
        await svc.record(path, b);
        toasts.show('Backup saved · ${b.fileName}');
      }
    } on Object catch (e) {
      toasts.show('Backup failed: $e', warn: true);
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed = ref.watch(canProvider(Permission.backups));
    final busy = _progress != null;
    return AppCard(
      title: 'Export a backup',
      subtitle: const Text('A single .rxbak file with all medicines, stock, bills and settings.'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ToggleRow(
            label: 'Encrypt with password',
            help: 'Recommended for patient data',
            value: _encrypt,
            onChanged: busy ? null : (v) => setState(() => _encrypt = v),
          ),
          if (_encrypt) ...[
            const SizedBox(height: AppSpace.md),
            FieldGrid(
              minColumnWidth: 160,
              children: [
                AppTextField(key: const ValueKey('backup-password'), label: 'Password', value: _password, onChanged: (v) => setState(() => _password = v), error: _error),
                AppTextField(key: const ValueKey('backup-confirm'), label: 'Confirm password', value: _confirm, onChanged: (v) => setState(() => _confirm = v)),
              ],
            ),
            const SizedBox(height: 6),
            Text('Keep this password safe — without it the backup can’t be restored.', style: AppType.caption),
          ],
          const SizedBox(height: AppSpace.lg),
          if (busy) ...[_Progress(value: _progress!, label: 'Exporting'), const SizedBox(height: AppSpace.md)],
          AppButton(
            key: const ValueKey('backup-export'),
            label: busy ? 'Exporting…' : 'Back up now',
            icon: Icons.save_alt_rounded,
            onPressed: busy || !allowed ? null : _export,
          ),
          if (!allowed) ...[const SizedBox(height: 6), Text('Your role can’t export backups.', style: AppType.caption)],
        ],
      ),
    );
  }
}

/// Shared restore flow: password (if needed) → confirm → restore.
Future<void> restoreFlow(BuildContext context, WidgetRef ref, Uint8List bytes, String fileName) async {
  final svc = ref.read(backupServiceProvider);
  final toasts = ref.read(toastsProvider.notifier);
  final BackupManifest manifest;
  try {
    manifest = svc.inspect(bytes);
  } on BackupException catch (e) {
    toasts.show(e.message, warn: true);
    return;
  }
  String? password;
  if (manifest.encrypted) {
    if (!context.mounted) return;
    password = await showAppDialog<String>(context, builder: (_) => const _PasswordDialog());
    if (password == null) return;
  }
  if (!context.mounted) return;
  final c = manifest.counts;
  final ok = await showConfirmDialog(
    context,
    title: 'Restore this backup?',
    message: '$fileName (${formatCount(c.products)} medicines, ${formatCount(c.invoices)} invoices, made ${manifest.createdAt.toLocal().toString().substring(0, 16)}) '
        'will replace the current medicines, stock and invoices on this device. A safety copy of today’s data is saved first.',
    confirmLabel: 'Restore',
  );
  if (!ok) return;
  try {
    await ref.read(guardedActionsProvider).restoreBackup(bytes, password: password);
    toasts.show('Restored from $fileName');
  } on BackupException catch (e) {
    toasts.show(e.message, warn: true);
  } on Object catch (e) {
    toasts.show('Restore failed: $e', warn: true);
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  String _pw = '';

  @override
  Widget build(BuildContext context) => AppDialogPanel(
        semanticLabel: 'Backup password',
        children: [
          Text('Backup password', style: AppType.dialogTitle),
          Text('This backup is encrypted. Enter the password used when it was made.', style: AppType.small.copyWith(color: AppColors.textSecondary)),
          AppTextField(
            key: const ValueKey('restore-password'),
            label: 'Password',
            value: _pw,
            autofocus: true,
            onChanged: (v) => setState(() => _pw = v),
            onSubmitted: (_) => Navigator.of(context).pop(_pw),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpace.gap10,
            children: [
              AppButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
              AppButton(label: 'Continue', onPressed: _pw.isEmpty ? null : () => Navigator.of(context).pop(_pw)),
            ],
          ),
        ],
      );
}

class _ImportCard extends ConsumerWidget {
  const _ImportCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = ref.watch(canProvider(Permission.backups));
    return AppCard(
      title: 'Restore from a backup',
      subtitle: const Text('Replaces the data on this device. A safety copy is made first.'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(color: StatusTone.warning.colors.bg, borderRadius: const BorderRadius.all(Radius.circular(12))),
            child: Text(
              'Restoring closes and reopens the database. Make sure no bill is being saved.',
              style: AppType.small.copyWith(color: StatusTone.warning.colors.fg),
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          AppButton.secondary(
            key: const ValueKey('backup-import'),
            label: 'Choose backup file…',
            icon: Icons.folder_open_outlined,
            onPressed: !allowed
                ? null
                : () async {
                    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const [backupExtension]);
                    final path = f?.path;
                    if (path == null) return;
                    final bytes = await File(path).readAsBytes();
                    if (!context.mounted) return;
                    await restoreFlow(context, ref, bytes, f!.name);
                  },
          ),
          if (!allowed) ...[const SizedBox(height: 6), Text('Your role can’t restore backups.', style: AppType.caption)],
        ],
      ),
    );
  }
}

class _AutoCard extends ConsumerWidget {
  const _AutoCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    Future<void> save(AppSettings next) => ref.read(settingsProvider.notifier).save(next);
    return AppCard(
      title: 'Automatic backup',
      subtitle: const Text('Runs when RxDesk closes, and at the first launch of the day if one is due. Keeps the latest 30.'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ToggleRow(
            label: 'Back up automatically',
            help: 'Automatic backups are not password-protected — keep the folder private.',
            value: s.autoBackup,
            onChanged: (v) {
              save(s.copyWith(autoBackup: v));
              ref.read(toastsProvider.notifier).show(v ? 'Automatic backup turned on' : 'Automatic backup turned off');
            },
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.lg,
            runSpacing: AppSpace.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedPills<String>(
                semanticLabel: 'Frequency',
                options: const [PillOption('Daily', 'Daily'), PillOption('Weekly', 'Weekly'), PillOption('Monthly', 'Monthly')],
                selected: s.autoBackupFrequency,
                onChanged: (v) => save(s.copyWith(autoBackupFrequency: v)),
              ),
              Text(s.backupFolder.isEmpty ? 'Folder: Documents/RxDesk/Backups' : 'Folder: ${s.backupFolder}', style: AppType.small),
              AppButton.secondary(
                label: 'Change folder',
                height: 36,
                onPressed: () async {
                  final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Backup folder');
                  if (dir != null) await save(s.copyWith(backupFolder: dir));
                },
              ),
              AppButton.secondary(
                label: 'Run now',
                height: 36,
                onPressed: () async {
                  try {
                    final p = await ref.read(backupServiceProvider).runAutoIfDue(force: true);
                    if (p != null) ref.read(toastsProvider.notifier).show('Automatic backup saved');
                  } on Object catch (e) {
                    ref.read(toastsProvider.notifier).show('Backup failed: $e', warn: true);
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _History extends ConsumerWidget {
  const _History();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_historyProvider).value ?? const <BackupEntry>[];
    final now = ref.watch(nowProvider)();
    final allowed = ref.watch(canProvider(Permission.backups));
    return AppCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.all(AppSpace.cardPad), child: Text('History', style: AppType.cardTitle)),
          DataGrid(
            semanticLabel: 'Backup history',
            columns: const [
              GridColumn('File', flex: 2.4, minWidth: 260),
              GridColumn('Created', minWidth: 140),
              GridColumn.fixed('Size', 90, alignEnd: true),
              GridColumn.fixed('Type', 110),
              GridColumn.fixed('', 110, alignEnd: true),
            ],
            rowCount: rows.length,
            empty: const EmptyState(title: 'No backups yet', message: 'Back up now, or turn on automatic backups.'),
            cells: (context, i) {
              final b = rows[i];
              final exists = File(b.path).existsSync();
              return [
                Row(
                  children: [
                    if (b.encrypted) ...[const Tooltip(message: 'Encrypted', child: Icon(Icons.lock_outline_rounded, size: 14, color: AppColors.textMuted)), const SizedBox(width: 6)],
                    Flexible(child: Text(b.fileName, style: AppType.mono, overflow: TextOverflow.ellipsis)),
                  ],
                ),
                Text(backupWhen(b.createdAt, now), style: AppType.small),
                Text(formatBytes(b.sizeBytes), style: AppType.small),
                StatusBadge(b.kind, tone: b.kind == 'Manual' ? StatusTone.info : StatusTone.neutral),
                AppButton.secondary(
                  label: 'Restore',
                  height: 36,
                  onPressed: !exists || !allowed
                      ? null
                      : () async {
                          final bytes = await File(b.path).readAsBytes();
                          if (context.mounted) await restoreFlow(context, ref, bytes, b.fileName);
                        },
                ),
              ];
            },
          ),
        ],
      ),
    );
  }
}

/// Accent text helper (keeps the palette import used).
Color backupAccent(BuildContext context) => context.palette.accent;
