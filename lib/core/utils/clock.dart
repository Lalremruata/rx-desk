import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'clock.g.dart';

/// Wall clock that ticks once a minute (header date chip, "today" logic).
/// Override in tests for a fixed date.
@Riverpod(keepAlive: true)
Stream<DateTime> clock(Ref ref) async* {
  yield DateTime.now();
  yield* Stream<DateTime>.periodic(const Duration(minutes: 1), (_) => DateTime.now());
}
