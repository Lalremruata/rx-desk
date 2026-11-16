// Demo catalogue, ported from the prototype's curated() and genCatalog().
// All names and makers are fictional.

/// mulberry32, as in the prototype, so the catalogue is reproducible.
class Mulberry32 {
  Mulberry32(int seed) : _s = seed & 0xFFFFFFFF;

  int _s;

  static int _imul(int a, int b) => (a * b) & 0xFFFFFFFF;

  /// Uniform in [0, 1).
  double next() {
    _s = (_s + 0x6D2B79F5) & 0xFFFFFFFF;
    var t = _imul(_s ^ (_s >>> 15), 1 | _s);
    t = ((t + _imul(t ^ (t >>> 7), 61 | t)) & 0xFFFFFFFF) ^ t;
    return ((t ^ (t >>> 14)) & 0xFFFFFFFF) / 4294967296;
  }

  int nextInt(int n) => (next() * n).floor();
}

class SeedBatch {
  SeedBatch(this.batchNo, this.expiry, this.targetQty);

  final String batchNo;
  final String expiry;

  /// Stock left after the generated history has been sold.
  final int targetQty;

  /// Filled while generating history.
  int sold = 0;
  int? id;
}

class SeedProduct {
  SeedProduct({
    required this.key,
    required this.name,
    required this.salt,
    required this.form,
    required this.maker,
    required this.pack,
    required this.category,
    required this.schedule,
    required this.reorder,
    required this.mrpPaise,
    required this.gst,
    required this.rack,
    required this.hsn,
    required this.barcode,
    required this.batches,
    this.slow = false,
  });

  final String key;
  final String name;
  final String salt;
  final String form;
  final String maker;
  final String pack;
  final String category;
  final String schedule;
  final int reorder;
  final int mrpPaise;
  final int gst;
  final String rack;
  final String hsn;
  final String barcode;
  final List<SeedBatch> batches;

  /// Not sold in the last ~4 months (dead-stock candidates).
  final bool slow;
  int? id;
}

String _ym(DateTime now, int off) {
  final m0 = now.year * 12 + (now.month - 1) + off;
  return '${m0 ~/ 12}-${(m0 % 12 + 1).toString().padLeft(2, '0')}';
}

/// 15 hand-written products with fixed barcodes (prototype `curated()`).
/// Expiries are shifted so they keep the same distance from [now] as in the
/// prototype (written for Nov 2026).
List<SeedProduct> curatedProducts(DateTime now) {
  // Prototype months are relative to 2026-11.
  String rel(String ym) {
    final y = int.parse(ym.substring(0, 4)), m = int.parse(ym.substring(5));
    return _ym(now, (y * 12 + m) - (2026 * 12 + 11));
  }

  SeedProduct c(
    String key,
    String name,
    String salt,
    String form,
    String maker,
    String pack,
    String cat,
    String sched,
    int reorder,
    String mrp,
    int gst,
    String rack,
    String hsn,
    String barcode,
    List<(String, String, int)> batches,
  ) {
    final parts = mrp.split('.');
    final paise = int.parse(parts[0]) * 100 + (parts.length > 1 ? int.parse(parts[1].padRight(2, '0')) : 0);
    return SeedProduct(
      key: key,
      name: name,
      salt: salt,
      form: form,
      maker: maker,
      pack: pack,
      category: cat,
      schedule: sched,
      reorder: reorder,
      mrpPaise: paise,
      gst: gst,
      rack: rack,
      hsn: hsn,
      barcode: barcode,
      batches: [for (final b in batches) SeedBatch(b.$1, rel(b.$2), b.$3)],
    );
  }

  return [
    c('p1', 'Paracetamol 650 mg Tablet', 'Paracetamol 650 mg', 'Tablet', 'Northline Pharma', 'Strip of 15', 'Tablet', '', 40, '30.90', 12, 'A1', '3004', '8904021650153', [('PCM2540', '2027-02', 50), ('PCM2611', '2027-08', 92)]),
    c('p2', 'Amoxicillin 500 mg Capsule', 'Amoxicillin 500 mg', 'Capsule', 'Aurelis Labs', 'Strip of 10', 'Capsule', 'H', 30, '98.50', 12, 'A3', '3004', '8904021500109', [('AMX0942', '2027-06', 18)]),
    c('p3', 'Cetirizine 10 mg Tablet', 'Cetirizine 10 mg', 'Tablet', 'Kestrel Healthcare', 'Strip of 10', 'Tablet', '', 50, '22', 12, 'A2', '3004', '8904021010103', [('CTZ1180', '2028-02', 210)]),
    c('p4', 'Pantoprazole 40 mg Tablet', 'Pantoprazole 40 mg', 'Tablet', 'Bluepeak Pharma', 'Strip of 15', 'Tablet', 'H', 30, '145', 12, 'B1', '3004', '8904021040155', [('PAN3321', '2027-05', 64)]),
    c('p5', 'Metformin 500 mg Tablet', 'Metformin 500 mg', 'Tablet', 'Meridian Generics', 'Strip of 20', 'Tablet', 'H', 40, '42', 12, 'B2', '3004', '8904021500208', [('MET7712', '2027-11', 96)]),
    c('p6', 'Dextromethorphan 100 ml Syrup', 'Dextromethorphan 100 ml', 'Syrup', 'Solace Remedies', 'Bottle', 'Syrup', '', 20, '118', 12, 'C1', '3004', '8904021100014', [('DXM3901', '2026-10', 4), ('DXM4410', '2027-02', 12)]),
    c('p7', 'Oral Rehydration Salts 21 g Sachet', 'Oral Rehydration Salts 21 g', 'Sachet', 'Verdant Lifesciences', 'Sachet', 'OTC', '', 60, '21', 5, 'D1', '3004', '8904021021009', [('ORS2209', '2027-09', 300)]),
    c('p8', 'Azithromycin 500 mg Tablet', 'Azithromycin 500 mg', 'Tablet', 'Orchid Valley Pharma', 'Strip of 3', 'Tablet', 'H', 20, '119', 12, 'A3', '3004', '8904021500031', [('AZT5590', '2026-12', 25), ('AZT6012', '2027-09', 40)]),
    c('p9', 'Insulin Glargine 100 IU/ml Cartridge', 'Insulin Glargine 100 IU/ml', 'Cartridge', 'Halcyon Labs', 'Cartridge 3 ml', 'Injection', 'H', 10, '690', 5, 'Fridge', '3004', '8904021100038', [('INS0071', '2027-03', 6)]),
    c('p10', 'Cholecalciferol 60000 IU Capsule', 'Cholecalciferol 60000 IU', 'Capsule', 'Tristar Formulations', 'Strip of 4', 'Capsule', '', 25, '128', 12, 'B4', '3004', '8904021600004', [('VTD8123', '2028-06', 75)]),
    c('p11', 'Clotrimazole 1% Cream', 'Clotrimazole 1%', 'Cream', 'Evergreen Biotech', 'Tube 20 g', 'Topical', '', 15, '85', 12, 'E2', '3004', '8904021001207', [('CLT2251', '2027-01', 40)]),
    c('p12', 'Digital Thermometer', 'Device', '', 'Coral Health', 'Unit', 'OTC', '', 5, '249', 18, 'G1', '9025', '8904021249001', [('DTH1001', '2030-12', 14)]),
    c('p13', 'Ibuprofen 400 mg Tablet', 'Ibuprofen 400 mg', 'Tablet', 'Northline Pharma', 'Strip of 15', 'Tablet', '', 30, '38', 12, 'A2', '3004', '8904021400156', [('IBU6650', '2027-04', 0)]),
    c('p14', 'Antiseptic Liquid 500 ml', 'Chloroxylenol 4.8%', 'Liquid', 'Coral Health', 'Bottle', 'OTC', '', 10, '210', 18, 'D2', '3808', '8904021500504', [('ASL3030', '2028-01', 22)]),
    c('p15', 'Ondansetron 30 ml Syrup', 'Ondansetron 30 ml', 'Syrup', 'Kestrel Healthcare', 'Bottle', 'Syrup', 'H', 15, '56', 12, 'C2', '3004', '8904021030013', [('OND5021', '2027-10', 33)]),
  ];
}

const List<String> seedMakers = [
  'Aurelis Labs', 'Bluepeak Pharma', 'Coral Health', 'Evergreen Biotech', 'Halcyon Labs', 'Kestrel Healthcare',
  'Lumina Remedies', 'Meridian Generics', 'Northline Pharma', 'Orchid Valley Pharma', 'Pinecrest Pharma',
  'Riverbend Healthcare', 'Saffron Labs', 'Solace Remedies', 'Tristar Formulations', 'Verdant Lifesciences',
];

/// ~1,600 generated variants: salts × strengths × packs × 16 makers
/// (prototype `genCatalog()`), with [variantsPerMaker] ≈ 1.
List<SeedProduct> generatedProducts(DateTime now, {Set<String>? usedBarcodes}) {
  final rnd = Mulberry32(20261109);
  const packs = {
    'Tablet': [('Strip of 10', 1.0), ('Strip of 15', 1.5), ('Box of 10×10', 9.5)],
    'Capsule': [('Strip of 10', 1.0), ('Strip of 15', 1.5)],
    'Syrup': [('Bottle', 1.0)],
    'Injection': [('Vial', 1.0)],
    'Topical': [('Tube', 1.0)],
    'OTC': [('Unit', 1.0)],
  };
  const rack = {'Tablet': 'A', 'Capsule': 'B', 'Syrup': 'C', 'OTC': 'D', 'Topical': 'E', 'Injection': 'F'};
  // (salt, strengths, form, category, gst, schedule, base MRP ₹)
  const salts = <(String, List<String>, String, String, int, String, int)>[
    ('Paracetamol', ['500 mg', '650 mg'], 'Tablet', 'Tablet', 12, '', 18),
    ('Amoxicillin', ['250 mg', '500 mg'], 'Capsule', 'Capsule', 12, 'H', 70),
    ('Amoxicillin + Clavulanic Acid', ['625 mg'], 'Tablet', 'Tablet', 12, 'H', 190),
    ('Azithromycin', ['250 mg', '500 mg'], 'Tablet', 'Tablet', 12, 'H', 75),
    ('Cetirizine', ['10 mg'], 'Tablet', 'Tablet', 12, '', 18),
    ('Levocetirizine', ['5 mg'], 'Tablet', 'Tablet', 12, '', 35),
    ('Pantoprazole', ['20 mg', '40 mg'], 'Tablet', 'Tablet', 12, 'H', 95),
    ('Omeprazole', ['20 mg'], 'Capsule', 'Capsule', 12, 'H', 55),
    ('Metformin', ['500 mg', '1000 mg'], 'Tablet', 'Tablet', 12, 'H', 25),
    ('Glimepiride', ['1 mg', '2 mg'], 'Tablet', 'Tablet', 12, 'H', 60),
    ('Amlodipine', ['5 mg', '10 mg'], 'Tablet', 'Tablet', 12, 'H', 30),
    ('Telmisartan', ['40 mg', '80 mg'], 'Tablet', 'Tablet', 12, 'H', 85),
    ('Atorvastatin', ['10 mg', '20 mg'], 'Tablet', 'Tablet', 12, 'H', 90),
    ('Losartan', ['50 mg'], 'Tablet', 'Tablet', 12, 'H', 55),
    ('Ibuprofen', ['200 mg', '400 mg'], 'Tablet', 'Tablet', 12, '', 25),
    ('Diclofenac', ['50 mg'], 'Tablet', 'Tablet', 12, 'H', 20),
    ('Montelukast', ['10 mg'], 'Tablet', 'Tablet', 12, 'H', 140),
    ('Ondansetron', ['4 mg'], 'Tablet', 'Tablet', 12, 'H', 45),
    ('Domperidone', ['10 mg'], 'Tablet', 'Tablet', 12, 'H', 30),
    ('Ciprofloxacin', ['500 mg'], 'Tablet', 'Tablet', 12, 'H', 55),
    ('Doxycycline', ['100 mg'], 'Capsule', 'Capsule', 12, 'H', 60),
    ('Cholecalciferol', ['60000 IU'], 'Capsule', 'Capsule', 12, '', 110),
    ('Calcium + Vitamin D3', ['500 mg'], 'Tablet', 'Tablet', 12, '', 95),
    ('Ferrous Ascorbate + Folic Acid', ['100 mg'], 'Tablet', 'Tablet', 12, '', 110),
    ('Dextromethorphan', ['100 ml'], 'Syrup', 'Syrup', 12, '', 105),
    ('Ambroxol', ['100 ml'], 'Syrup', 'Syrup', 12, '', 85),
    ('Paracetamol', ['60 ml'], 'Suspension', 'Syrup', 12, '', 35),
    ('Lactulose', ['200 ml'], 'Solution', 'Syrup', 12, '', 240),
    ('Insulin Glargine', ['100 IU/ml'], 'Cartridge', 'Injection', 5, 'H', 650),
    ('Ceftriaxone', ['1 g'], 'Injection', 'Injection', 12, 'H1', 60),
    ('Clotrimazole', ['1%'], 'Cream', 'Topical', 12, '', 75),
    ('Mupirocin', ['2%'], 'Ointment', 'Topical', 12, 'H', 120),
    ('Diclofenac', ['1%'], 'Gel', 'Topical', 12, '', 95),
    ('Oral Rehydration Salts', ['21 g'], 'Sachet', 'OTC', 5, '', 19),
    ('Povidone Iodine', ['5%'], 'Solution', 'OTC', 12, '', 90),
    ('Hand Sanitizer', ['500 ml'], '', 'OTC', 18, '', 180),
    ('Cotton Roll', ['100 g'], '', 'OTC', 12, '', 60),
    ('Crepe Bandage', ['10 cm'], '', 'OTC', 12, '', 110),
  ];

  final barcodes = usedBarcodes ?? <String>{};
  final out = <SeedProduct>[];
  var n = 0;
  for (final s in salts) {
    final code = s.$1.replaceAll(RegExp('[^A-Za-z]'), '').substring(0, 3).toUpperCase();
    for (final strength in s.$2) {
      for (final pk in packs[s.$4]!) {
        for (final maker in seedMakers) {
          if (rnd.next() < 0.08) continue;
          n++;
          final reorder = const [10, 15, 20, 25, 30][rnd.nextInt(5)];
          final mode = rnd.next();
          var total = mode < 0.035
              ? 0
              : mode < 0.11
                  ? rnd.nextInt(reorder)
                  : reorder + 10 + rnd.nextInt(200);
          final k = 1 + (rnd.next() < 0.35 ? 1 : 0) + (rnd.next() < 0.1 ? 1 : 0);
          final offs = <int>[];
          for (var i = 0; i < k; i++) {
            final r = rnd.next();
            offs.add(r < 0.012 ? -1 : r < 0.06 ? 1 + rnd.nextInt(3) : 4 + rnd.nextInt(24));
          }
          offs.sort();
          final batches = <SeedBatch>[];
          final used = <String>{};
          for (var i = 0; i < k; i++) {
            final q = i == k - 1 ? total : (total * (0.3 + rnd.next() * 0.4)).floor();
            total -= q;
            var bno = '$code${1000 + rnd.nextInt(9000)}';
            while (!used.add(bno)) {
              bno = '$code${1000 + rnd.nextInt(9000)}';
            }
            batches.add(SeedBatch(bno, _ym(now, offs[i]), q));
          }
          final hsn = s.$1 == 'Hand Sanitizer'
              ? '3808'
              : (s.$1 == 'Cotton Roll' || s.$1 == 'Crepe Bandage')
                  ? '3005'
                  : '3004';
          // Round to ₹0.50 like the prototype.
          final halfRupees = (s.$7 * pk.$2 * (0.8 + rnd.next() * 0.5) * 2).round();
          var barcode = '890${(1000000000 + (rnd.next() * 8999999999).floor()).toString().substring(0, 10)}';
          while (!barcodes.add(barcode)) {
            barcode = '890${(1000000000 + (rnd.next() * 8999999999).floor()).toString().substring(0, 10)}';
          }
          final slow = rnd.next() < 0.05;
          out.add(
            SeedProduct(
              key: 'g$n',
              name: '${s.$1} $strength ${s.$3}'.trim(),
              salt: '${s.$1} $strength',
              form: s.$3,
              maker: maker,
              pack: pk.$1,
              category: s.$4,
              schedule: s.$6,
              reorder: reorder,
              mrpPaise: halfRupees * 50,
              gst: s.$5,
              rack: '${rack[s.$4]}${1 + rnd.nextInt(12)}',
              hsn: hsn,
              barcode: barcode,
              batches: batches,
              slow: slow,
            ),
          );
        }
      }
    }
  }
  return out;
}

const List<String> seedCustomers = [
  'C. Lalrinmawia', 'Esther Zothanpari', 'H. Vanlalruata', 'R. Lalhmangaihi', 'F. Lalremsiami',
  'J. Laldinpuia', 'V. Lalmuanawma', 'B. Zonunmawii', 'M. Lalthansangi', 'P. Lalchhanhima',
];

const List<String> seedDoctors = [
  'Dr. C. Vanlalhruaia', 'Dr. J. Lalrinsanga', 'Dr. K. Lalnunmawii', 'Dr. L. Hmingthanzuali',
  'Dr. S. Lalbiakzuala', 'Dr. T. Malsawmtluanga',
];
