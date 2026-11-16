import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/widgets/widgets.dart';

void main() {
  late ProviderContainer c;
  setUp(() => c = ProviderContainer());
  tearDown(() => c.dispose());

  test('queues in order; dismiss removes by id', () {
    final n = c.read(toastsProvider.notifier)
      ..show('one')
      ..show('two', warn: true);
    var q = c.read(toastsProvider);
    expect(q.map((m) => m.text), ['one', 'two']);
    expect(q.last.kind, ToastKind.warning);

    n.dismiss(q.first.id);
    q = c.read(toastsProvider);
    expect(q.map((m) => m.text), ['two']);
  });

  test('keeps the visible toast + the latest ${Toasts.maxWaiting} waiting', () {
    final n = c.read(toastsProvider.notifier);
    for (var i = 1; i <= 7; i++) {
      n.show('t$i');
    }
    expect(c.read(toastsProvider).map((m) => m.text), ['t1', 't5', 't6', 't7']);
  });
}
