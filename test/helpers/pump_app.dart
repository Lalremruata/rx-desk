import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/app.dart';
import 'package:rx_desk/core/db/app_database.dart';
import 'package:rx_desk/core/db/db_provider.dart';
import 'package:rx_desk/core/router/app_router.dart';
import 'package:rx_desk/core/utils/clock.dart';
import 'package:rx_desk/core/utils/format.dart';
import 'package:rx_desk/features/settings/application/app_settings.dart';
import 'package:rx_desk/features/settings/application/settings_providers.dart';
import 'package:rx_desk/features/staff/application/session.dart';
import 'package:rx_desk/features/staff/data/staff_repository.dart';

import 'fake_printer.dart';
import 'test_db.dart';

/// Fixed "now" for tests: Mon 9 Nov 2026, like the prototype.
final DateTime testNow = DateTime(2026, 11, 9, 10, 30);

/// Sizes from CLAUDE.md "Definition of done".
const Size desktop = Size(1280, 800);
const Size tabletPortrait = Size(800, 1280);
const Size phone = Size(600, 1000);

Future<void> setUpFormatting() => initFormatting();

/// Pumps the whole app at [size] (logical px) starting at [location].
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  Size size = desktop,
  String location = '/billing',
  bool disableAnimations = false,
  AppDatabase? db,
  AppSettings settings = const AppSettings(autoBackup: false),
  Future<void> Function(AppDatabase db)? setUpDb,
  SessionUser? session = const SessionUser(name: 'Owner', role: StaffRole.owner),
  List<dynamic> overrides = const [],
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  if (disableAnimations) {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }

  final database = db ?? memoryDb();
  // Close with real async: under fake time an in-flight query can make
  // close() wait forever.
  if (db == null) addTearDown(() => tester.runAsync(database.close));
  if (setUpDb != null) await tester.runAsync(() => setUpDb(database));

  final router = createRouter(initialLocation: location);
  addTearDown(router.dispose);
  final container = ProviderContainer(
    // No automatic retries: a failing provider should fail the test, not
    // leave a backoff timer running.
    retry: (count, error) => null,
    overrides: [
      appRouterProvider.overrideWithValue(router),
      clockProvider.overrideWith((ref) => Stream.value(testNow)),
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(() => testNow),
      initialSettingsProvider.overrideWithValue(settings),
      fakePrinterOverride,
      initialSessionProvider.overrideWithValue(session),
      staffRepositoryProvider.overrideWith((ref) => StaffRepository(database, () => testNow, iterations: 1000)),
      ...overrides.cast(),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const RxDeskApp()));
  await settle(tester);
  return container;
}

/// Lets enter animations finish. (`pumpAndSettle` never returns because the
/// offline dot pulses forever.)
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  // Drift closes disposed stream queries on a zero-length timer; let it fire.
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump(const Duration(milliseconds: 1));
}
