import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/db/app_database.dart';
import 'core/db/db_provider.dart';
import 'core/db/seed/seed.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/tokens.dart';
import 'features/backup/application/backup_service.dart';
import 'features/settings/application/app_settings.dart';
import 'features/settings/application/settings_providers.dart';
import 'features/settings/data/settings_repository.dart';

/// Debug seed flags (SPEC §10): `--dart-define=SEED=true` or
/// `--dart-define=PERF_SEED=100k`. Only applied to an empty database.
const bool _seed = bool.fromEnvironment('SEED');
const String _perfSeed = String.fromEnvironment('PERF_SEED');

/// Opens the database (optionally seeding it), then runs the app inside a
/// ProviderScope that provides it. [restart] re-opens everything — used
/// after a restore replaces the database file.
class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key, this.openDatabase});

  /// Override for tests.
  final Future<AppDatabase> Function()? openDatabase;

  static void restart(BuildContext context) => context.findAncestorStateOfType<_BootstrapState>()?._restart();

  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  AppDatabase? _db;
  String? _path;
  AppSettings _settings = const AppSettings();
  Object? _error;
  String _stage = 'Opening database';
  double? _progress;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      AppDatabase db;
      if (widget.openDatabase != null) {
        db = await widget.openDatabase!();
      } else {
        _path ??= await AppDatabase.defaultPath();
        db = AppDatabase.open(path: _path);
      }
      // Run a query so migrations happen before the UI starts.
      final empty = await isEmptyDatabase(db);
      const seedSize = _perfSeed == '100k' ? SeedSize.perf100k : (_seed ? SeedSize.demo : null);
      if (empty && seedSize != null) {
        setState(() => _stage = 'Seeding demo data');
        await seedDemoData(
          db,
          size: seedSize,
          onProgress: (p, s) {
            if (mounted) {
              setState(() {
                _progress = p;
                _stage = s;
              });
            }
          },
        );
      }
      final settings = await SettingsRepository(db.settingsDao).load();
      if (mounted) {
        setState(() {
          _settings = settings;
          _db = db;
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Restore: close, replace the database file, reopen (migrations run).
  Future<void> _replace(Uint8List bytes) async {
    final path = _path;
    if (path == null) throw StateError('Restore needs a file-backed database');
    final old = _db;
    setState(() {
      _db = null;
      _stage = 'Restoring backup';
      _progress = null;
      _generation++;
    });
    await old?.close();
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final f = File('$path$suffix');
      if (f.existsSync()) await f.delete();
    }
    await File(path).writeAsBytes(bytes, flush: true);
    await _open();
  }

  Future<void> _restart() async {
    final old = _db;
    setState(() {
      _db = null;
      _stage = 'Re-opening database';
      _progress = null;
      _generation++;
    });
    await old?.close();
    await _open();
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final db = _db;
    if (db == null) return _Splash(stage: _stage, progress: _progress, error: _error);
    return ProviderScope(
      key: ValueKey(_generation),
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        initialSettingsProvider.overrideWithValue(_settings),
        databaseSwapperProvider.overrideWithValue(_Swapper(this)),
      ],
      child: const RxDeskApp(),
    );
  }
}

class _Swapper implements DatabaseSwapper {
  _Swapper(this._state);
  final _BootstrapState _state;

  @override
  Future<void> replaceWith(Uint8List dbBytes) => _state._replace(dbBytes);
}

class _Splash extends StatelessWidget {
  const _Splash({required this.stage, this.progress, this.error});

  final String stage;
  final double? progress;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(AppColors.accentDefault),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('RxDesk', style: AppType.pageTitle, textAlign: TextAlign.center),
                const SizedBox(height: AppSpace.lg),
                if (error != null)
                  Text(
                    'Couldn’t open the database: $error',
                    textAlign: TextAlign.center,
                    style: AppType.small.copyWith(color: StatusTone.danger.colors.fg),
                  )
                else ...[
                  LinearProgressIndicator(value: progress, borderRadius: AppRadius.pillAll),
                  const SizedBox(height: AppSpace.md),
                  Text(
                    progress == null ? stage : '$stage · ${(progress! * 100).round()} %',
                    textAlign: TextAlign.center,
                    style: AppType.caption,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
