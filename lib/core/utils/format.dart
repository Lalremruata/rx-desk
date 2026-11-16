import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

/// App locale: Indian English (₹, lakh grouping).
const String appLocale = 'en_IN';

/// Loads intl date symbols for [appLocale]. Call once at startup (and in
/// tests) before formatting dates.
Future<void> initFormatting() async {
  Intl.defaultLocale = appLocale;
  await initializeDateFormatting(appLocale);
}

final NumberFormat _count = NumberFormat.decimalPattern(appLocale);

/// Whole-number count with Indian grouping: 1649 → "1,649", 123456 → "1,23,456".
///
/// Money formatting lives in `core/money` (phase 1), not here.
String formatCount(int n) => _count.format(n);

/// Header date chip: "Mon, 9 Nov 2026".
String formatHeaderDate(DateTime d) => DateFormat('EEE, d MMM y', appLocale).format(d);
