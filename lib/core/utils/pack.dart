/// Loose selling (SPEC §4.9): stock is held in the smallest unit (a tablet);
/// a product's pack holds `units_per_pack` of them. These helpers turn unit
/// counts into "12 strips + 4 tabs" and back. Pure Dart.
library;

/// Words for a product's pack and its loose unit, from its category.
class PackNouns {
  const PackNouns(this.pack, this.packs, this.unit, this.units);

  final String pack;
  final String packs;
  final String unit;
  final String units;

  static const tablet = PackNouns('strip', 'strips', 'tab', 'tabs');
  static const capsule = PackNouns('strip', 'strips', 'cap', 'caps');
  static const other = PackNouns('pack', 'packs', 'unit', 'units');

  static PackNouns of(String category) => switch (category) {
        'Tablet' => tablet,
        'Capsule' => capsule,
        _ => other,
      };

  String packWord(int n) => n == 1 ? pack : packs;

  /// "Strips per box" — how many packs one stockist box holds.
  String get perBoxLabel => '${packs[0].toUpperCase()}${packs.substring(1)} per box';
  String unitWord(int n) => n == 1 ? unit : units;

  /// Label for the units-per-pack field: "Tablets per strip".
  String get sizeLabel => switch (this) {
        tablet => 'Tablets per strip',
        capsule => 'Capsules per strip',
        _ => 'Units per pack',
      };
}

/// "1 box = 20 strips = 200 tabs" — the Add medicine form's pack fields
/// read as one picture. Null when there is nothing to explain (sold whole,
/// box size not known).
String? packSummary(PackNouns n, {required int packSize, int? packsPerBox}) {
  final loose = packSize > 1;
  final box = packsPerBox != null && packsPerBox >= 1;
  if (box && loose) return '1 box = $packsPerBox ${n.packWord(packsPerBox)} = ${packsPerBox * packSize} ${n.units}';
  if (box) return '1 box = $packsPerBox ${n.packWord(packsPerBox)}';
  if (loose) return '1 ${n.pack} = $packSize ${n.units}, sold by the ${n.pack} or the ${n.unit}';
  return null;
}

/// Largest pack size accepted.
const int maxPackSize = 1000;

/// Most packs (strips) one stockist box can hold (products.packs_per_box).
const int maxPacksPerBox = 500;

/// Whole packs and loose units in [units]. Negative values split by
/// magnitude with the sign on both parts.
(int packs, int loose) splitPack(int units, int packSize) {
  if (packSize <= 1) return (units, 0);
  final neg = units < 0;
  final u = units.abs();
  final p = u ~/ packSize, l = u % packSize;
  return neg ? (-p, -l) : (p, l);
}

String _n(int n) => n.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d\d)+\d$)'), (m) => '${m[1]},');

/// "12 strips + 4 tabs", "1 strip", "4 tabs"; plain "12" when the product
/// isn't sold loose ([packSize] 1). Uses Indian digit grouping.
String formatPackQty(int units, int packSize, String category) {
  if (packSize <= 1) return _n(units);
  final words = PackNouns.of(category);
  final (p, l) = splitPack(units, packSize);
  final sign = units < 0 ? '−' : '';
  final pa = p.abs(), la = l.abs();
  if (la == 0) return '$sign${_n(pa)} ${words.packWord(pa)}';
  if (pa == 0) return '$sign${_n(la)} ${words.unitWord(la)}';
  return '$sign${_n(pa)} ${words.packWord(pa)} + ${_n(la)} ${words.unitWord(la)}';
}

/// Compact quantity for invoice / receipt tables: "2" for whole packs (the
/// MRP column is per pack), "5 tab" or "1 + 5 tab" with loose units.
String compactPackQty(int units, int packSize, String category) {
  if (packSize <= 1) return units < 0 ? '−${_n(-units)}' : _n(units);
  final sign = units < 0 ? '−' : '';
  final (p, l) = splitPack(units.abs(), packSize);
  if (l == 0) return '$sign${_n(p)}';
  final unit = PackNouns.of(category).unit;
  return p == 0 ? '$sign${_n(l)} $unit' : '$sign${_n(p)} + ${_n(l)} $unit';
}

/// Units from a packs + loose entry. Null when either part is negative or
/// loose ≥ pack size.
int? unitsFrom({required int packs, int loose = 0, required int packSize}) {
  if (packs < 0 || loose < 0) return null;
  if (packSize <= 1) return packs + loose;
  if (loose >= packSize) return null;
  return packs * packSize + loose;
}

/// Suggests a pack size from pack text: "Strip of 10" → 10, "10 tablets" →
/// 10, "Strip of 15 caps" → 15. Only for tablets and capsules; 1 otherwise.
int suggestPackSize(String pack, String category) {
  if (category != 'Tablet' && category != 'Capsule') return 1;
  final m = RegExp(r'(?:strip|blister)\s*of\s*(\d{1,3})\b', caseSensitive: false).firstMatch(pack) ??
      RegExp(r'^\s*(\d{1,3})\s*(?:tab|cap)', caseSensitive: false).firstMatch(pack);
  final n = m == null ? 1 : int.parse(m.group(1)!);
  return n < 1 || n > maxPackSize ? 1 : n;
}
