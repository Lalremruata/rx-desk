import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'app_database.dart';

part 'db_provider.g.dart';

/// The open database. Provided by the bootstrap (main.dart) with
/// `appDatabaseProvider.overrideWithValue(db)`; tests use an in-memory one.
/// Only repositories (features/*/data) read this — widgets never do.
@Riverpod(keepAlive: true)
AppDatabase appDatabase(Ref ref) =>
    throw StateError('appDatabaseProvider must be overridden with the opened database');

/// Wall-clock "now" used by data queries (expiry, today's sales). Tests
/// override it for a fixed date.
@Riverpod(keepAlive: true)
DateTime Function() now(Ref ref) => DateTime.now;
