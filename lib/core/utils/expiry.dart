/// Pharma expiry is month-level, stored as 'YYYY-MM' and treated as the last
/// day of that month (SPEC §3): a batch expiring '2026-11' can still be sold
/// on 30 Nov 2026 and is expired from 1 Dec 2026.
library;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String monthKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

/// 'YYYY-MM' [months] after the month of [d] (negative goes back).
String addMonthsKey(DateTime d, int months) {
  final m0 = d.year * 12 + (d.month - 1) + months;
  return '${(m0 ~/ 12).toString().padLeft(4, '0')}-${(m0 % 12 + 1).toString().padLeft(2, '0')}';
}

bool isValidExpiry(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(s);
  if (m == null) return false;
  final mo = int.parse(m.group(2)!);
  return mo >= 1 && mo <= 12;
}

/// Expired when the expiry month is before the current month.
bool isExpired(String expiry, DateTime now) => expiry.compareTo(monthKey(now)) < 0;

/// Whole months from the current month to the expiry month: same month → 0,
/// next month → 1, last month → −1.
int monthsLeft(String expiry, DateTime now) {
  final y = int.parse(expiry.substring(0, 4));
  final m = int.parse(expiry.substring(5, 7));
  return (y * 12 + m) - (now.year * 12 + now.month);
}

/// '2027-02' → 'Feb 2027'.
String formatExpiry(String expiry) {
  if (!isValidExpiry(expiry)) return '—';
  return '${_months[int.parse(expiry.substring(5, 7)) - 1]} ${expiry.substring(0, 4)}';
}

/// Local calendar date key 'YYYY-MM-DD'.
String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime parseDateKey(String s) => DateTime(int.parse(s.substring(0, 4)), int.parse(s.substring(5, 7)), int.parse(s.substring(8, 10)));

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// '2026-11-03' → 'Tue 3 Nov 26' (prototype `dayLabel`).
String dayLabel(String key) {
  final d = parseDateKey(key);
  return '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]} ${(d.year % 100).toString().padLeft(2, '0')}';
}

/// '9 Nov 2026'.
String formatDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

String monthName(int month) => _months[month - 1];

/// '09:05'.
String formatTime(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
