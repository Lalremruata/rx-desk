import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/fy/fy.dart';
import '../../../core/inventory/consumption_rules.dart';
import '../../../core/sales/bill_rules.dart';
import '../../../core/sales/return_rules.dart';

part 'app_settings.freezed.dart';
part 'app_settings.g.dart';

enum InvoicePaper {
  @JsonValue('A4')
  a4('A4', 'A4', 'Laser / inkjet'),
  @JsonValue('A5')
  a5('A5', 'A5', 'Half page'),
  @JsonValue('T80')
  t80('T80', 'Thermal 80 mm', 'Receipt printer'),
  @JsonValue('T58')
  t58('T58', 'Thermal 58 mm', 'Small receipt');

  const InvoicePaper(this.code, this.label, this.help);

  final String code;
  final String label;
  final String help;

  bool get isThermal => this == t80 || this == t58;
}

enum StaffRole {
  owner('Owner'),
  pharmacist('Pharmacist'),
  cashier('Cashier');

  const StaffRole(this.label);
  final String label;

  static StaffRole fromLabel(String s) => values.firstWhere((r) => r.label == s, orElse: () => cashier);
}

/// Role permissions (SPEC §7.6). The owner always has all of them.
enum Permission {
  sellRx('Sell Schedule H / H1 medicines'),
  giveHighDiscount('Give more than 5% discount'),
  editBills('Edit or cancel a saved bill'),
  changeStock('Change stock, prices and batches'),
  viewReports('See sales register and reports'),
  backups('Export or restore backups'),
  changeSettings('Change settings'),
  supplierPayments('Record supplier payments'),
  acceptReturns('Accept returns / issue credit notes'),
  sellOnCredit('Sell on credit (udhaar)'),
  collectPayments('Collect customer payments'),
  manageCustomerCredit('Set credit limits, opening dues, void payments'),
  cashClose('Record paid-outs and close the day');

  const Permission(this.label);
  final String label;
}

const String defaultFooter =
    'Prices are MRP inclusive of GST. Goods once sold will not be taken back without the bill. Get well soon.';

/// SPEC §7.6 defaults for Pharmacist and Cashier.
const Map<String, List<String>> defaultRolePermissions = {
  'Pharmacist': [
    'sellRx',
    'giveHighDiscount',
    'editBills',
    'changeStock',
    'viewReports',
    'acceptReturns',
    'sellOnCredit',
    'collectPayments',
    'cashClose',
  ],
  'Cashier': ['collectPayments', 'cashClose'],
};

/// Every setting (SPEC §7), stored key-by-key as JSON in the `settings`
/// table and read only through `settingsProvider` (CLAUDE.md rule 12).
@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    // 7.1 Store profile
    @Default('[Your Pharmacy Name]') String name,
    @Default('') String legalName,
    @Default('') String phone,
    @Default('') String email,
    @Default('') String addr1,
    @Default('') String addr2,
    @Default('') String city,
    @Default('') String state,
    @Default('') String pin,
    @Default('') String gstin,
    @Default('') String dl20b,
    @Default('') String dl21b,
    @Default('') String pharmacistName,
    @Default('') String pharmacistRegNo,
    @Default('') String logoPath,

    // 7.2 Invoice
    @Default('INV') String prefix,

    /// '/', '-' or 'none'.
    @Default('/') String separator,
    @Default(5) int digits,
    @Default(true) bool fyInNumber,
    @Default(InvoicePaper.a4) InvoicePaper paper,
    @Default(1) int copies,
    @Default(true) bool autoPrint,
    @Default('') String defaultPrinter,
    @Default(false) bool showSalt,
    @Default(true) bool showBatch,
    @Default(true) bool showExpiry,
    @Default(false) bool showHsn,
    @Default(true) bool showDoctor,
    @Default(true) bool showSaved,
    @Default(true) bool showUpiQr,
    @Default('') String upiId,
    @Default(defaultFooter) String footer,
    @Default('Registered Pharmacist') String signatureLabel,

    // 7.3 Billing & tax
    @Default(true) bool gstRegistered,

    /// Locked on — MRP is tax-inclusive.
    @Default(true) bool mrpIncludesGst,
    @Default(true) bool roundOff,

    /// Unit quantity code in the GSTR-1 HSN table (SPEC §4.15).
    @Default('NOS') String gstUqc,
    @Default(15) int maxDiscountPct,
    @Default('Cash') String defaultPayment,
    @Default(true) bool requireDoctorForRx,

    /// Locked on — expired batches can never be sold.
    @Default(true) bool blockExpired,
    @Default(false) bool allowNegativeStock,

    /// Credit-note (sales return) number prefix — own gapless series.
    @Default('CN') String creditNotePrefix,

    /// Returns of bills older than this are blocked (Owner can override);
    /// 0 = no limit.
    @Default(30) int returnWindowDays,

    /// Credit limit (paise) for customers without their own; 0 = no limit
    /// (SPEC §4.10).
    @Default(0) int defaultCreditLimitPaise,

    // 7.4 Inventory
    @Default(3) int expiryWindowMonths,
    @Default(90) int deadStockDays,
    @Default(20) int defaultReorderLevel,
    @Default(true) bool suggestFefo,
    @Default(true) bool showLowStockBadge,

    /// Stockist lead times for the consumption register (SPEC §4.12).
    @Default(1) int avgLeadTimeDays,
    @Default(2) int maxLeadTimeDays,

    // 7.5 Appearance
    @Default('#0F766E') String accent,
    @Default(true) bool showKeyHints,
    @Default(15) int autoLockMinutes,

    // Backup (SPEC §5.6)
    @Default(true) bool autoBackup,

    /// 'Daily' | 'Weekly' | 'Monthly'
    @Default('Daily') String autoBackupFrequency,

    /// Empty = Documents/RxDesk/Backups.
    @Default('') String backupFolder,

    // 7.6 Permissions for Pharmacist / Cashier (Owner has all).
    @Default(defaultRolePermissions) Map<String, List<String>> rolePermissions,
  }) = _AppSettings;

  const AppSettings._();

  factory AppSettings.fromJson(Map<String, dynamic> json) => _$AppSettingsFromJson(json);

  InvoiceNumberFormat get numbering => InvoiceNumberFormat(
        prefix: prefix,
        separator: InvoiceSeparator.fromText(separator == 'none' ? '' : separator),
        digits: digits,
        fyInNumber: fyInNumber,
      );

  bool roleHas(StaffRole role, Permission p) =>
      role == StaffRole.owner || (rolePermissions[role.label] ?? const []).contains(p.name);

  /// Settings + the signed-in role → rules for saving a bill.
  BillRules billRules({StaffRole role = StaffRole.owner}) => BillRules(
        numbering: numbering,
        roundOff: roundOff,
        gstRegistered: gstRegistered,
        allowNegativeStock: allowNegativeStock,
        requireDoctorForRx: requireDoctorForRx,
        maxDiscountPct: maxDiscountPct,
        canSellRx: roleHas(role, Permission.sellRx),
        canGiveHighDiscount: roleHas(role, Permission.giveHighDiscount),
        canSellOnCredit: roleHas(role, Permission.sellOnCredit),
        defaultCreditLimit: defaultCreditLimitPaise,
        storeGstin: gstin,
      );

  /// Settings + the signed-in role → rules for accepting a sales return.
  ReturnRules returnRules({StaffRole role = StaffRole.owner}) => ReturnRules(
        numbering: numbering.creditNotes(creditNotePrefix),
        roundOff: roundOff,
        windowDays: returnWindowDays,
        canAcceptReturns: roleHas(role, Permission.acceptReturns),
        canOverrideWindow: role == StaffRole.owner,
      );

  /// "15 Store Name" → "SN"; "Rx" when blank.
  String get initials {
    final words = name.replaceAll(RegExp(r'[\[\]]'), '').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2);
    final s = words.map((w) => w[0].toUpperCase()).join();
    return s.isEmpty ? 'Rx' : s;
  }
}

// ---------------------------------------------------------------------------
// Validation (SPEC §7.1–7.2)

final RegExp _gstinPattern = RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$');

/// Null when valid (or empty), else the message to show.
String? validateGstin(String v) {
  if (v.isEmpty) return null;
  if (v.length != 15) return 'GSTIN should be 15 characters, e.g. 15ABCDE1234F1Z5.';
  if (!_gstinPattern.hasMatch(v)) return 'That doesn’t look like a GSTIN — check the format (e.g. 15ABCDE1234F1Z5).';
  return null;
}

String? validatePin(String v) => v.isEmpty || RegExp(r'^\d{6}$').hasMatch(v) ? null : 'PIN code is 6 digits.';

String? validatePrefix(String v) =>
    RegExp(r'^[A-Z0-9]{0,8}$').hasMatch(v) ? null : 'Use up to 8 letters or digits.';

/// A credit-note prefix must be set and differ from the invoice prefix so
/// the two series never share a number.
String? validateCreditNotePrefix(String v, {required String invoicePrefix}) {
  if (v.isEmpty) return 'Enter a prefix, e.g. CN.';
  final e = validatePrefix(v);
  if (e != null) return e;
  if (v == invoicePrefix) return 'Use a different prefix from invoices.';
  return null;
}

String? validateEmail(String v) =>
    v.isEmpty || RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v) ? null : 'Enter a valid email address.';

/// All field errors for [s], keyed by field name.
Map<String, String> settingsErrors(AppSettings s) => {
      if (s.name.trim().isEmpty) 'name': 'Enter the pharmacy name.',
      'gstin': ?validateGstin(s.gstin),
      'pin': ?validatePin(s.pin),
      'prefix': ?validatePrefix(s.prefix),
      'creditNotePrefix': ?validateCreditNotePrefix(s.creditNotePrefix, invoicePrefix: s.prefix),
      'email': ?validateEmail(s.email),
      if (s.footer.length > 240) 'footer': 'Footer is limited to 240 characters.',
      if (s.copies < 1 || s.copies > 3) 'copies': 'Copies must be 1–3.',
      if (s.defaultReorderLevel < 0) 'defaultReorderLevel': 'Can’t be negative.',
      if (s.defaultCreditLimitPaise < 0) 'defaultCreditLimitPaise': 'Can’t be negative.',
      'leadTime': ?validateLeadTimes(avgDays: s.avgLeadTimeDays, maxDays: s.maxLeadTimeDays),
    };

/// Keys whose values differ between [a] and [b].
List<String> changedKeys(AppSettings a, AppSettings b) {
  final ja = a.toJson(), jb = b.toJson();
  return [
    for (final k in ja.keys)
      if (!_deepEq(ja[k], jb[k])) k,
  ];
}

bool _deepEq(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    return a.keys.every((k) => b.containsKey(k) && _deepEq(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEq(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
