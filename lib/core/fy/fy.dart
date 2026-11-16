/// Indian financial year helpers (1 April – 31 March) and invoice numbering
/// (SPEC §4.2).
library;

/// First calendar year of the FY containing [d]: 9 Nov 2026 → 2026,
/// 15 Feb 2027 → 2026.
int fyStartYear(DateTime d) => d.month >= 4 ? d.year : d.year - 1;

/// FY label for [d]: 1 Apr 2026 – 31 Mar 2027 → "26-27".
String fyLabel(DateTime d) {
  final s = fyStartYear(d);
  String two(int y) => (y % 100).toString().padLeft(2, '0');
  return '${two(s)}-${two(s + 1)}';
}

/// 1 April of the FY containing [d].
DateTime fyStart(DateTime d) => DateTime(fyStartYear(d), 4);

/// Separator option for invoice numbers.
enum InvoiceSeparator {
  slash('/'),
  dash('-'),
  none('');

  const InvoiceSeparator(this.text);

  final String text;

  static InvoiceSeparator fromText(String s) => switch (s) {
        '/' => slash,
        '-' => dash,
        _ => none,
      };
}

/// Invoice number format settings.
class InvoiceNumberFormat {
  const InvoiceNumberFormat({
    this.prefix = 'INV',
    this.separator = InvoiceSeparator.slash,
    this.digits = 5,
    this.fyInNumber = true,
    this.series = '',
  });

  final String prefix;
  final InvoiceSeparator separator;
  final int digits;
  final bool fyInNumber;

  /// Separate gapless series sharing `invoice_seq` (e.g. 'CN' for credit
  /// notes). Empty for tax invoices.
  final String series;

  /// `invoice_seq` row key. Per FY when the FY is in the number (restarts at
  /// 1 each April); otherwise one running sequence. Other series are
  /// namespaced: `CN:26-27`.
  String seqKey(String fy) {
    final k = fyInNumber ? fy : 'all';
    return series.isEmpty ? k : '$series:$k';
  }

  /// Credit-note series with the same separator, digits and FY setting.
  InvoiceNumberFormat creditNotes(String cnPrefix) => InvoiceNumberFormat(
        prefix: cnPrefix,
        separator: separator,
        digits: digits,
        fyInNumber: fyInNumber,
        series: 'CN',
      );

  /// prefix + sep + (fy) + sep + zero-padded seq, skipping empty parts.
  /// `INV/26-27/00412`, `INV-26-27-0412`, `INV00412`.
  String format({required String fy, required int seq}) {
    final parts = <String>[
      prefix.trim(),
      if (fyInNumber) fy,
      seq.toString().padLeft(digits, '0'),
    ].where((p) => p.isNotEmpty);
    return parts.join(separator.text);
  }
}
