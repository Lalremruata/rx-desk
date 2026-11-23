/// GSTIN checks for B2B bills (SPEC §4.15). Pure Dart.
library;

const String _chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

/// "15 abcde1234f1z5 " → "15ABCDE1234F1Z5".
String normaliseGstin(String s) => s.toUpperCase().replaceAll(RegExp(r'\s'), '');

/// The GSTN check character for the first 14 characters (mod 36).
String gstinCheckChar(String first14) {
  var sum = 0;
  for (var i = 0; i < 14; i++) {
    final p = _chars.indexOf(first14[i]) * (i.isEven ? 1 : 2);
    sum += p ~/ 36 + p % 36;
  }
  return _chars[(36 - sum % 36) % 36];
}

/// 15 characters in the GSTIN pattern, a known state code and a matching
/// check character.
bool isValidGstin(String gstin) {
  final g = normaliseGstin(gstin);
  if (!RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$').hasMatch(g)) return false;
  if (!gstStates.containsKey(g.substring(0, 2))) return false;
  return gstinCheckChar(g.substring(0, 14)) == g[14];
}

/// The state code (first two digits) of a GSTIN.
String gstinState(String gstin) => normaliseGstin(gstin).substring(0, 2);

/// "15-Mizoram", as GSTR-1 writes a place of supply.
String placeOfSupplyLabel(String code) => '$code-${gstStates[code] ?? code}';

/// Why [buyer] can't go on a bill from a store with [storeGstin], or null
/// (SPEC §4.15). Same state only: inter-state (IGST) bills aren't supported.
String? buyerGstinProblem(String buyer, {required String storeGstin, required bool gstRegistered}) {
  final b = normaliseGstin(buyer);
  if (b.isEmpty) return null;
  if (!gstRegistered) return 'Not GST registered — a bill of supply has no buyer GSTIN';
  if (!isValidGstin(b)) return 'Buyer GSTIN looks wrong — check the 15 characters';
  if (!isValidGstin(storeGstin)) return 'Enter your own GSTIN in Settings › Store profile first';
  final bs = gstinState(b), ss = gstinState(storeGstin);
  if (bs != ss) return 'This GSTIN is from ${gstStates[bs]} — inter-state (IGST) bills aren’t supported';
  return null;
}

/// GST state / UT codes.
const Map<String, String> gstStates = {
  '01': 'Jammu and Kashmir',
  '02': 'Himachal Pradesh',
  '03': 'Punjab',
  '04': 'Chandigarh',
  '05': 'Uttarakhand',
  '06': 'Haryana',
  '07': 'Delhi',
  '08': 'Rajasthan',
  '09': 'Uttar Pradesh',
  '10': 'Bihar',
  '11': 'Sikkim',
  '12': 'Arunachal Pradesh',
  '13': 'Nagaland',
  '14': 'Manipur',
  '15': 'Mizoram',
  '16': 'Tripura',
  '17': 'Meghalaya',
  '18': 'Assam',
  '19': 'West Bengal',
  '20': 'Jharkhand',
  '21': 'Odisha',
  '22': 'Chhattisgarh',
  '23': 'Madhya Pradesh',
  '24': 'Gujarat',
  '26': 'Dadra and Nagar Haveli and Daman and Diu',
  '27': 'Maharashtra',
  '29': 'Karnataka',
  '30': 'Goa',
  '31': 'Lakshadweep',
  '32': 'Kerala',
  '33': 'Tamil Nadu',
  '34': 'Puducherry',
  '35': 'Andaman and Nicobar Islands',
  '36': 'Telangana',
  '37': 'Andhra Pradesh',
  '38': 'Ladakh',
  '97': 'Other Territory',
};
