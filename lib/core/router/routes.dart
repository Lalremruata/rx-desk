/// Route paths (SPEC §2).
abstract final class Routes {
  static const String dashboard = '/dashboard';
  static const String billing = '/billing';
  static const String inventory = '/inventory';
  static const String purchases = '/purchases';
  static const String invoices = '/invoices';
  static const String customers = '/customers';
  static const String cash = '/cash';
  static const String register = '/register';
  static const String consumption = '/register/consumption';
  static const String backup = '/backup';
  static const String settings = '/settings';
  static const String gallery = '/_gallery';

  /// Default start screen (SPEC §2: Billing).
  static const String start = billing;

  static String settingsTab(String tab) => '$settings/$tab';
}
