import 'expiry.dart';

/// Date presets used by Invoices and the Sales register.
enum DatePreset {
  today('Today'),
  yesterday('Yesterday'),
  last7('Last 7 days'),
  thisMonth('This month'),
  lastMonth('Last month'),
  thisFy('This FY'),
  custom('Custom');

  const DatePreset(this.label);
  final String label;
}

/// Inclusive local date range as 'YYYY-MM-DD' keys.
class DateRangeKeys {
  const DateRangeKeys(this.from, this.to);
  final String from;
  final String to;

  bool get singleDay => from == to;

  /// "Mon 9 Nov 26" or "Mon 2 Nov 26 – Mon 9 Nov 26".
  String get label => singleDay ? dayLabel(from) : '${dayLabel(from)} – ${dayLabel(to)}';

  @override
  bool operator ==(Object other) => other is DateRangeKeys && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

DateRangeKeys rangeFor(DatePreset p, DateTime now, {DateTime? from, DateTime? to}) {
  final today = DateTime(now.year, now.month, now.day);
  DateRangeKeys r(DateTime a, DateTime b) => DateRangeKeys(dateKey(a), dateKey(b));
  switch (p) {
    case DatePreset.today:
      return r(today, today);
    case DatePreset.yesterday:
      final y = today.subtract(const Duration(days: 1));
      return r(y, y);
    case DatePreset.last7:
      return r(today.subtract(const Duration(days: 6)), today);
    case DatePreset.thisMonth:
      return r(DateTime(now.year, now.month), today);
    case DatePreset.lastMonth:
      final first = DateTime(now.year, now.month - 1);
      return r(first, DateTime(now.year, now.month, 0));
    case DatePreset.thisFy:
      final start = now.month >= 4 ? DateTime(now.year, 4) : DateTime(now.year - 1, 4);
      return r(start, today);
    case DatePreset.custom:
      final a = from ?? today, b = to ?? today;
      return a.isAfter(b) ? r(b, a) : r(a, b);
  }
}
