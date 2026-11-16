import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/theme/app_theme.dart';
import 'package:rx_desk/core/theme/tokens.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/shell/presentation/app_shell.dart';

import '../helpers/pump_app.dart';

/// Advances [ms] in 50 ms frames (a ticker's first frame only records its
/// start time, so a single long pump doesn't finish an animation).
Future<void> _run(WidgetTester tester, int ms) async {
  for (var t = 0; t <= ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
      theme: buildAppTheme(AppColors.accentDefault),
      home: MediaQuery(
        data: MediaQueryData(size: const Size(1000, 800), disableAnimations: disableAnimations),
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  setUpAll(setUpFormatting);

  testWidgets('gallery shows every shared widget from SPEC §8', (tester) async {
    await pumpApp(tester, location: '/_gallery');
    expect(find.descendant(of: find.byType(PageHeader), matching: find.text('Widget gallery')), findsOneWidget);
    for (final type in [
      AppButton,
      AppCard,
      KpiTile,
      ResponsiveGrid,
      SegmentedPills<String>,
      FilterChipRow<String>,
      ToggleRow,
      AppSwitch,
      StatusBadge,
      RxBadge,
      StockBar,
      DataGrid,
      Pager,
      KeysetPager,
      AppToast,
      PageEnter,
      KeyHint,
      EmptyState,
      PulseDot,
    ]) {
      expect(find.byType(type, skipOffstage: false), findsWidgets, reason: '$type');
    }
    expect(find.text('Open confirm dialog', skipOffstage: false), findsOneWidget);
  });

  testWidgets('gallery accent swatch re-themes the app live', (tester) async {
    await pumpApp(tester, location: '/_gallery');
    await tester.tap(find.bySemanticsLabel('Accent Rose'));
    await settle(tester);
    final ctx = tester.element(find.byType(PageHeader));
    expect(ctx.palette.accent, AppColors.accentOptions['Rose']);
  });

  group('motion (SPEC §9)', () {
    testWidgets('PageEnter fades + rises over 500 ms', (tester) async {
      await tester.pumpWidget(_host(const PageEnter(child: Text('hi'))));
      Opacity op() => tester.widget<Opacity>(find.ancestor(of: find.text('hi'), matching: find.byType(Opacity)).first);
      expect(op().opacity, 0);
      await tester.pump(const Duration(milliseconds: 250));
      expect(op().opacity, inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 260));
      expect(op().opacity, 1);
    });

    testWidgets('PageEnter stagger delays later children by 50 ms each', (tester) async {
      await tester.pumpWidget(_host(const Column(children: [PageEnter(child: Text('a')), PageEnter(index: 3, child: Text('b'))])));
      await tester.pump(const Duration(milliseconds: 140));
      double op(String t) => tester.widget<Opacity>(find.ancestor(of: find.text(t), matching: find.byType(Opacity)).first).opacity;
      expect(op('a'), greaterThan(0));
      expect(op('b'), 0); // still inside its 150 ms delay
    });

    testWidgets('PageEnter is skipped when animations are disabled', (tester) async {
      await tester.pumpWidget(_host(const PageEnter(child: Text('hi')), disableAnimations: true));
      final op = tester.widget<Opacity>(find.ancestor(of: find.text('hi'), matching: find.byType(Opacity)).first);
      expect(op.opacity, 1);
    });

    testWidgets('tappable card lifts −2 px with shadow on mouse hover', (tester) async {
      await tester.pumpWidget(_host(SizedBox(width: 260, child: KpiTile(label: 'Low', value: '3', icon: Icons.warning, onTap: () {}))));
      AnimatedContainer box() => tester.widget<AnimatedContainer>(
            find.descendant(of: find.byType(AppCard), matching: find.byType(AnimatedContainer)).first,
          );
      expect(box().transform!.getTranslation().y, 0);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(KpiTile)));
      await tester.pump(const Duration(milliseconds: 300));

      expect(box().transform!.getTranslation().y, AppMotion.hoverLiftDy);
      expect((box().decoration! as BoxDecoration).boxShadow, [AppShadows.cardHover]);
    });

    testWidgets('buttons scale to 0.97 while pressed', (tester) async {
      await tester.pumpWidget(_host(AppButton(label: 'Go', onPressed: () {})));
      AnimatedScale scale() => tester.widget<AnimatedScale>(find.byType(AnimatedScale));
      expect(scale().scale, 1);
      final g = await tester.startGesture(tester.getCenter(find.text('Go')));
      await tester.pump(const Duration(milliseconds: 160));
      expect(scale().scale, AppMotion.pressScale);
      await g.up();
      await tester.pump(const Duration(milliseconds: 160));
      expect(scale().scale, 1);
    });
  });

  group('controls', () {
    testWidgets('ToggleRow toggles from the row and exposes a toggled semantics node', (tester) async {
      var v = false;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, set) => SizedBox(
              width: 400,
              child: ToggleRow(label: 'Encrypt', help: 'Help', value: v, onChanged: (x) => set(() => v = x)),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Help'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(v, isTrue);
      expect(
        tester.getSemantics(find.byType(ToggleRow)),
        matchesSemantics(
          label: 'Encrypt',
          hint: 'Help',
          isToggled: true,
          hasToggledState: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
    });

    testWidgets('locked ToggleRow cannot change', (tester) async {
      var changed = false;
      await tester.pumpWidget(
        _host(SizedBox(width: 400, child: ToggleRow(label: 'Block expired', value: true, locked: true, onChanged: (_) => changed = true))),
      );
      await tester.tap(find.text('Block expired'));
      await tester.pump();
      expect(changed, isFalse);
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    });

    testWidgets('Pager reports page taps and disables Prev on page 1', (tester) async {
      int? picked;
      await tester.pumpWidget(_host(SizedBox(width: 900, child: Pager(page: 1, pageSize: 50, totalRows: 1649, onPage: (p) => picked = p))));
      expect(find.text('1–50 of 1,649'), findsOneWidget);
      expect(find.text('33'), findsOneWidget);
      await tester.tap(find.text('‹ Prev'));
      expect(picked, isNull);
      await tester.tap(find.text('Next ›'));
      expect(picked, 2);
      await tester.tap(find.text('33'));
      expect(picked, 33);
    });

    testWidgets('DataGrid sort header reports its key; scrolls under min width', (tester) async {
      String? sorted;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 300,
            child: DataGrid(
              columns: const [GridColumn('Medicine', minWidth: 300, sortKey: 'name'), GridColumn.fixed('MRP', 100)],
              rowCount: 2,
              cells: (c, i) => [Text('Row $i'), const Text('₹1')],
              sortKey: 'name',
              onSort: (k) => sorted = k,
            ),
          ),
        ),
      );
      expect(find.byType(SingleChildScrollView), findsOneWidget); // horizontal scroll
      expect(find.text('↑'), findsOneWidget);
      await tester.tap(find.text('Medicine'));
      expect(sorted, 'name');
    });

    // Regression: the horizontal Scrollbar had no controller, fell back to the
    // (unattached) PrimaryScrollController and asserted on mouse hover — the
    // debugger paused there and the desktop app looked frozen.
    testWidgets(
      'DataGrid horizontal scrollbar survives mouse hover on desktop',
      (tester) async {
        await tester.pumpWidget(
          _host(
            SizedBox(
              width: 300,
              height: 400,
              child: DataGrid(
                lazy: true,
                columns: const [GridColumn('Medicine', minWidth: 300), GridColumn.fixed('MRP', 100)],
                rowCount: 3,
                cells: (c, i) => [Text('Row $i'), const Text('₹1')],
              ),
            ),
          ),
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(find.text('Row 1')));
        await tester.pump();
        await mouse.moveTo(tester.getBottomLeft(find.byType(DataGrid)) + const Offset(20, -3));
        await _run(tester, 300);
        expect(tester.takeException(), isNull);
        // One horizontal scrollbar, not the explicit one plus the desktop default.
        final horizontal = tester
            .widgetList<RawScrollbar>(find.byWidgetPredicate((w) => w is RawScrollbar))
            .where((s) => s.controller != null && s.controller!.hasClients && s.controller!.position.axis == Axis.horizontal);
        expect(horizontal, hasLength(1));
      },
      variant: TargetPlatformVariant.desktop(),
    );
  });

  group('ConfirmDialog', () {
    Future<bool?> open(WidgetTester tester) async {
      bool? result;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showConfirmDialog(
                context,
                title: 'Restore this backup?',
                message: 'Replaces current data.',
                confirmLabel: 'Restore',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Restore this backup?'), findsOneWidget);
      return result;
    }

    testWidgets('Restore → true', (tester) async {
      bool? result;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showConfirmDialog(
                context,
                title: 'T',
                message: 'M',
                confirmLabel: 'Restore',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Restore'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(result, isTrue);
    });

    testWidgets('Esc closes and resolves false; Cancel has initial focus', (tester) async {
      await open(tester);
      final cancel = tester.widget<TextButton>(find.ancestor(of: find.text('Cancel'), matching: find.byType(TextButton)));
      expect(cancel.autofocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _run(tester, 400);
      expect(find.text('Restore this backup?'), findsNothing);
    });
  });

  group('ToastHost', () {
    testWidgets('shows queued toasts one at a time, each for 2.8 s', (tester) async {
      final c = await pumpApp(tester, location: '/dashboard');
      c.read(toastsProvider.notifier)
        ..show('First')
        ..show('Second', warn: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsNothing);

      await _run(tester, 2400 + 250 + 400); // 2.8 s on screen, exit, next one enters
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsOneWidget);
      expect(find.byIcon(Icons.priority_high_rounded), findsOneWidget);

      await _run(tester, 2800 + 300); // auto-dismiss
      expect(find.text('Second'), findsNothing);
      expect(c.read(toastsProvider), isEmpty);
    });
  });
}
