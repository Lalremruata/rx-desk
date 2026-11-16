import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/features/billing/application/bill_controller.dart';

import '../helpers/billing_fixture.dart';
import '../helpers/pump_app.dart';

Future<void> _run(WidgetTester tester, [int ms = 400]) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(setUpFormatting);
  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);

  for (final size in [desktop, tabletPortrait]) {
    testWidgets('search dropdown sits above the bill items and takes clicks (${size.width.toInt()}×${size.height.toInt()})', (tester) async {
      final c = await pumpApp(tester, size: size, setUpDb: billingFixture);
      await _run(tester);
      // Put a line on the bill so the items grid is under the dropdown.
      await tester.enterText(find.byKey(const ValueKey('billing-search')), 'crocin');
      await _run(tester, 300);
      await tester.tap(find.text('Crocin Advance').last);
      await _run(tester);
      expect(c.read(billControllerProvider).lines, hasLength(1));

      await tester.enterText(find.byKey(const ValueKey('billing-search')), 'para');
      await _run(tester, 300);
      // Result rows lie over the bill grid: they must be on top and clickable
      // (hit-test misses are fatal in this test).
      final target = find.text('Paracetamol 500 mg Tablet');
      expect(target, findsOneWidget);
      await tester.tap(target);
      await _run(tester);
      expect(c.read(billControllerProvider).lines.map((l) => l.name), contains('Paracetamol 500 mg Tablet'));
    });
  }
}
