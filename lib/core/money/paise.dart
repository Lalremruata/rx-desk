import 'package:intl/intl.dart';

/// Money as integer paise (CLAUDE.md rule 1). Never use `double` for stored
/// or summed money; convert to rupees only when formatting.
extension type const Paise(int value) {
  static const Paise zero = Paise(0);

  /// Whole rupees → paise.
  const Paise.rupees(int rupees) : value = rupees * 100;

  Paise operator +(Paise other) => Paise(value + other.value);
  Paise operator -(Paise other) => Paise(value - other.value);
  Paise operator -() => Paise(-value);

  /// Multiply by a whole quantity.
  Paise times(int qty) => Paise(value * qty);

  bool get isZero => value == 0;
  bool get isNegative => value < 0;
  bool operator <(Paise o) => value < o.value;
  bool operator >(Paise o) => value > o.value;
  bool operator <=(Paise o) => value <= o.value;
  bool operator >=(Paise o) => value >= o.value;

  Paise abs() => Paise(value.abs());

  /// Parses user input like "30.9", "₹1,234.50", "1,00,000" into paise
  /// without going through `double`. Returns null for invalid input or
  /// more than 2 decimals.
  static Paise? tryParse(String input) {
    var s = input.trim().replaceAll(',', '').replaceAll('₹', '').replaceAll(' ', '');
    if (s.isEmpty) return null;
    var neg = false;
    if (s.startsWith('-') || s.startsWith('−')) {
      neg = true;
      s = s.substring(1);
    }
    final m = RegExp(r'^(\d*)(?:\.(\d{0,2}))?$').firstMatch(s);
    if (m == null) return null;
    final whole = m.group(1)!;
    final frac = (m.group(2) ?? '').padRight(2, '0');
    if (whole.isEmpty && (m.group(2) ?? '').isEmpty) return null;
    final v = int.parse(whole.isEmpty ? '0' : whole) * 100 + int.parse(frac);
    return Paise(neg ? -v : v);
  }

  /// Plain rupee string for form fields: 3090 → "30.90".
  String toInputString() {
    final a = value.abs();
    final s = '${a ~/ 100}.${(a % 100).toString().padLeft(2, '0')}';
    return value < 0 ? '-$s' : s;
  }
}

/// Sum of an iterable of paise.
extension PaiseSum on Iterable<Paise> {
  Paise sum() => fold(Paise.zero, (a, b) => a + b);
}

final Map<int, NumberFormat> _inrFormats = {};

NumberFormat _inr(int decimals) => _inrFormats.putIfAbsent(
      decimals,
      () => NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: decimals),
    );

/// ₹ with Indian grouping: 123456789 paise → "₹12,34,567.89".
/// [decimals] 0 rounds half-up to whole rupees. Negative values use "−₹".
String formatInr(Paise p, {int decimals = 2}) {
  final a = p.value.abs();
  final String s;
  if (decimals == 0) {
    s = _inr(0).format((a + 50) ~/ 100);
  } else {
    // Format whole rupees as an int, then append the exact paise digits —
    // no double rounding surprises.
    final rupees = _inr(0).format(a ~/ 100);
    s = '$rupees.${(a % 100).toString().padLeft(2, '0')}';
  }
  return p.value < 0 ? '−$s' : s;
}

/// Short axis/KPI label: ₹950, ₹8k, ₹2.5L, ₹1.2Cr.
String formatInrShort(Paise p) {
  final r = p.value / 100; // display only
  final a = r.abs();
  String v;
  if (a >= 1e7) {
    v = '${_trim(a / 1e7)}Cr';
  } else if (a >= 1e5) {
    v = '${_trim(a / 1e5)}L';
  } else if (a >= 1e3) {
    v = '${_trim(a / 1e3)}k';
  } else {
    v = a.round().toString();
  }
  return '${r < 0 ? '−' : ''}₹$v';
}

String _trim(double x) {
  final s = x >= 100 ? x.toStringAsFixed(0) : x.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}
