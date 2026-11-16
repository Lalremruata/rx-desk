import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/core/theme/app_theme.dart';
import 'package:rx_desk/core/theme/tokens.dart';
import 'package:rx_desk/core/utils/format.dart';
import 'package:rx_desk/core/widgets/widgets.dart';
import 'package:rx_desk/features/shell/application/app_section.dart';
import 'package:rx_desk/features/shell/presentation/app_shell.dart';

void main() {
  setUpAll(initFormatting);

  group('RxPalette', () {
    test('accentSoft is 12 % accent over white (CSS color-mix)', () {
      final p = RxPalette.fromAccent(AppColors.accentDefault);
      // 0.12 × (15, 118, 110) + 0.88 × 255 = (226.2, 238.56, 237.6)
      expect(p.accentSoft.r * 255, closeTo(226.2, 0.6));
      expect(p.accentSoft.g * 255, closeTo(238.56, 0.6));
      expect(p.accentSoft.b * 255, closeTo(237.6, 0.6));
    });

    test('derives from any accent, never hardcoded teal', () {
      const rose = Color(0xFFBE123C);
      final p = RxPalette.fromAccent(rose);
      expect(p.accent, rose);
      expect(p.accentSoft, AppColors.mixOverWhite(rose, 0.12));
      expect(p.accentMuted, AppColors.mixOverWhite(rose, 0.42));
      expect(p.tone(StatusTone.accent).fg, rose);
      expect(p.tone(StatusTone.accent).bg, p.accentSoft);
      expect(p.tone(StatusTone.warning).bg, StatusTone.warning.colors.bg);
    });
  });

  group('pageWindow', () {
    test('single page', () => expect(pageWindow(1, 1), [1]));
    test('no pages', () => expect(pageWindow(1, 0), isEmpty));
    test('first of many', () => expect(pageWindow(1, 10), [1, 2, null, 10]));
    test('second', () => expect(pageWindow(2, 10), [1, 2, 3, null, 10]));
    test('middle has gaps both sides', () => expect(pageWindow(5, 10), [1, null, 4, 5, 6, null, 10]));
    test('adjacent to last', () => expect(pageWindow(9, 10), [1, null, 8, 9, 10]));
    test('last', () => expect(pageWindow(10, 10), [1, null, 9, 10]));
    test('small set has no gaps', () => expect(pageWindow(2, 3), [1, 2, 3]));
  });

  group('pageRangeLabel', () {
    test('first page', () => expect(pageRangeLabel(1, 50, 1649), '1–50 of 1,649'));
    test('last partial page', () => expect(pageRangeLabel(33, 50, 1649), '1,601–1,649 of 1,649'));
    test('lakh grouping', () => expect(pageRangeLabel(1, 50, 123456), '1–50 of 1,23,456'));
    test('empty', () => expect(pageRangeLabel(1, 50, 0), '0 results'));
  });

  group('resolveColumnWidths', () {
    const cols = [
      GridColumn.fixed('#', 44),
      GridColumn('Medicine', flex: 2, minWidth: 200),
      GridColumn('Maker', minWidth: 100),
      GridColumn.fixed('MRP', 92),
    ];
    // fixed 136 + gaps 3×10 + padding 2×16 = 198 → minimum total 498.

    test('shares spare width by flex', () {
      final (w, total) = resolveColumnWidths(cols, 798);
      expect(total, 798);
      expect(w[0], 44);
      expect(w[3], 92);
      expect(w[1], closeTo(400, 0.001)); // (798 − 198) × 2/3
      expect(w[2], closeTo(200, 0.001));
    });

    test('freezes tracks at their minimum, then re-shares', () {
      final (w, total) = resolveColumnWidths(cols, 548); // 350 to share
      expect(total, 548);
      expect(w[1], closeTo(233.33, 0.01)); // 2/3 of 350 ≥ 200 ✓
      expect(w[2], closeTo(116.67, 0.01));

      final (w2, _) = resolveColumnWidths(const [
        GridColumn('A', flex: 3, minWidth: 50),
        GridColumn('B', minWidth: 150),
      ], 272); // 272 − 10 − 32 = 230 to share; B's 1/4 share (57.5) < 150 → frozen
      expect(w2[1], 150);
      expect(w2[0], closeTo(80, 0.001));
    });

    test('narrower than the minimum → minimum total (grid scrolls)', () {
      final (w, total) = resolveColumnWidths(cols, 300);
      expect(total, 498);
      expect(w[1], 200);
      expect(w[2], 100);
    });
  });

  group('ResponsiveGrid.columnsFor (minmax(220px, 1fr))', () {
    test('four tiles fit at 952 px', () => expect(ResponsiveGrid.columnsFor(952, 220, 16), 4));
    test('three at 900', () => expect(ResponsiveGrid.columnsFor(900, 220, 16), 3));
    test('never fewer than one', () => expect(ResponsiveGrid.columnsFor(100, 220, 16), 1));
  });

  group('shell breakpoints (SPEC §2)', () {
    test('≥ 1100 full sidebar', () {
      expect(ShellLayout.forWidth(1100), ShellLayout.full);
      expect(ShellLayout.forWidth(1280), ShellLayout.full);
    });
    test('760–1099 rail', () {
      expect(ShellLayout.forWidth(1099), ShellLayout.rail);
      expect(ShellLayout.forWidth(760), ShellLayout.rail);
      expect(ShellLayout.forWidth(800), ShellLayout.rail);
    });
    test('< 760 compact', () => expect(ShellLayout.forWidth(759), ShellLayout.compact));
  });

  group('AppSection', () {
    test('sidebar order matches SPEC §2', () {
      expect(AppSection.nav.map((s) => s.label), [
        'Dashboard',
        'Billing',
        'Inventory',
        'Purchases',
        'Invoices',
        'Customers',
        'Sales register',
        'Backup & restore',
        'Settings',
      ]);
      expect(AppSection.nav.map((s) => s.path), [
        '/dashboard',
        '/billing',
        '/inventory',
        '/purchases',
        '/invoices',
        '/customers',
        '/register',
        '/backup',
        '/settings',
      ]);
    });
    test('compact bar has 4 items + More holding the rest', () {
      expect({...AppSection.compactPrimary, ...AppSection.compactMore}, AppSection.nav.toSet());
    });
    test('fromPath', () {
      expect(AppSection.fromPath('/settings/invoice'), AppSection.settings);
      expect(AppSection.fromPath('/register'), AppSection.register);
      expect(AppSection.fromPath('/_gallery'), AppSection.gallery);
      expect(AppSection.fromPath('/nope'), AppSection.billing);
    });
  });

  test('header date format', () => expect(formatHeaderDate(DateTime(2026, 11, 9)), 'Mon, 9 Nov 2026'));
}
