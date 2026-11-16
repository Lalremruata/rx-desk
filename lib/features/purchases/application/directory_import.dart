import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Import of the store's "Damdawi lak na" sheet (SPEC §4.11): Sl.No · Dawr
/// Hming (stockist) · Damdawi hming (medicine) · Phone numb · MR Hming.
/// The stockist and phone cells are filled only on some rows — each block
/// of rows belongs to the stockist above it, and its phone numbers run down
/// the phone column ("9862958415", "or", "0389-2323442"). Pure Dart.

/// One medicine line from the sheet.
class SheetSourceRow {
  const SheetSourceRow({required this.sheetRow, required this.stockist, required this.medicine, this.mrName = ''});

  /// 1-based row number in the sheet (for the review list).
  final int sheetRow;
  final String stockist;
  final String medicine;
  final String mrName;
}

class DirectorySheet {
  const DirectorySheet({required this.sheetName, required this.rows, required this.phones});
  final String sheetName;
  final List<SheetSourceRow> rows;

  /// Stockist (as written, first spelling) → numbers found in its block.
  final Map<String, List<String>> phones;

  int get stockists => {for (final r in rows) r.stockist.toLowerCase()}.length;

  List<String> phonesOf(String stockist) {
    final k = stockist.toLowerCase();
    for (final e in phones.entries) {
      if (e.key.toLowerCase() == k) return e.value;
    }
    return const [];
  }
}

class DirectoryImportException implements Exception {
  const DirectoryImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

final RegExp _phone = RegExp(r'\+?\d[\d\s\-]{5,}\d');

/// Phone numbers in a cell: "9862958415", "0389-2323442", "or" → none.
List<String> phonesIn(String cell) => [
      for (final m in _phone.allMatches(cell))
        if (m.group(0)!.replaceAll(RegExp(r'\D'), '').length >= 7) m.group(0)!.trim().replaceAll(RegExp(r'\s+'), ' '),
    ];

/// Cleans a stockist / medicine cell: trims, collapses spaces.
String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

int _col(List<String> header, RegExp re) => header.indexWhere((h) => re.hasMatch(h.toLowerCase()));

/// Parses sheet rows (cells as text). Finds the header row by "Dawr Hming"
/// / "Damdawi hming" (or "stockist" / "medicine"); without one, assumes
/// columns B–E like the original sheet.
DirectorySheet parseDirectoryRows(List<List<String>> rows, {String sheetName = ''}) {
  var start = 0;
  var stockistCol = 1, medicineCol = 2, phoneCol = 3, mrCol = 4;
  for (var i = 0; i < rows.length && i < 10; i++) {
    final h = rows[i];
    final s = _col(h, RegExp(r'dawr\s*hming|stockist|supplier|shop'));
    final m = _col(h, RegExp(r'damdawi|medicine|item'));
    if (s >= 0 && m >= 0) {
      stockistCol = s;
      medicineCol = m;
      phoneCol = _col(h, RegExp(r'phone|mobile|contact'));
      mrCol = _col(h, RegExp(r'\bmr\b|representative'));
      start = i + 1;
      break;
    }
  }
  String at(List<String> r, int c) => c >= 0 && c < r.length ? _clean(r[c]) : '';

  final out = <SheetSourceRow>[];
  final phones = <String, List<String>>{};
  final spelling = <String, String>{};
  String? current;
  for (var i = start; i < rows.length; i++) {
    final r = rows[i];
    final s = at(r, stockistCol);
    if (s.isNotEmpty) current = spelling.putIfAbsent(s.toLowerCase(), () => s);
    if (current == null) continue;
    for (final p in phonesIn(at(r, phoneCol))) {
      final list = phones.putIfAbsent(current, () => []);
      final digits = p.replaceAll(RegExp(r'\D'), '');
      if (!list.any((x) => x.replaceAll(RegExp(r'\D'), '') == digits)) list.add(p);
    }
    final med = at(r, medicineCol);
    if (med.isEmpty) continue;
    out.add(SheetSourceRow(sheetRow: i + 1, stockist: current, medicine: med, mrName: at(r, mrCol)));
  }
  return DirectorySheet(sheetName: sheetName, rows: out, phones: phones);
}

/// Decodes an .xlsx and parses the directory sheet: the first sheet whose
/// header looks like the directory, else the first sheet.
///
/// Reads the workbook XML directly (shared strings + sheet cells): the
/// `excel` package rejects workbooks that redefine built-in number formats,
/// which Excel itself writes.
DirectorySheet parseDirectoryWorkbook(Uint8List bytes) {
  bool looksLikeDirectory(List<List<String>> rows) {
    final head = rows.take(10).expand((r) => r).map((c) => c.toLowerCase()).join(' ');
    return head.contains('damdawi') || head.contains('dawr');
  }

  final sheets = readXlsxSheets(bytes, stopAt: looksLikeDirectory);
  if (sheets.isEmpty) throw const DirectoryImportException('The workbook has no sheets');
  for (final e in sheets.entries) {
    if (looksLikeDirectory(e.value)) return parseDirectoryRows(e.value, sheetName: e.key);
  }
  return parseDirectoryRows(sheets.values.first, sheetName: sheets.keys.first);
}

/// Visible sheets in workbook order → rows of cell text (columns by
/// position; missing cells are ''). Stops after the first sheet [stopAt]
/// accepts.
Map<String, List<List<String>>> readXlsxSheets(Uint8List bytes, {bool Function(List<List<String>> rows)? stopAt}) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } on Object {
    throw const DirectoryImportException('That file isn’t an Excel workbook (.xlsx)');
  }
  XmlDocument? doc(String path) {
    final f = zip.findFile(path);
    if (f == null) return null;
    return XmlDocument.parse(utf8.decode(f.content as List<int>, allowMalformed: true));
  }

  final book = doc('xl/workbook.xml');
  final rels = doc('xl/_rels/workbook.xml.rels');
  if (book == null || rels == null) throw const DirectoryImportException('That file isn’t an Excel workbook (.xlsx)');
  final targets = {
    for (final r in rels.findAllElements('Relationship')) r.getAttribute('Id'): r.getAttribute('Target') ?? '',
  };
  final shared = [
    for (final si in doc('xl/sharedStrings.xml')?.findAllElements('si') ?? const <XmlElement>[])
      si.findAllElements('t').map((t) => t.innerText).join(),
  ];
  final out = <String, List<List<String>>>{};
  for (final s in book.findAllElements('sheet')) {
    if (s.getAttribute('state') == 'hidden') continue;
    final rid = s.attributes.firstWhere((a) => a.name.local == 'id', orElse: () => XmlAttribute(XmlName('id'), '')).value;
    var target = targets[rid] ?? '';
    if (target.isEmpty) continue;
    target = target.startsWith('/') ? target.substring(1) : 'xl/$target';
    final sheet = doc(target);
    if (sheet == null) continue;
    final rows = <List<String>>[];
    for (final row in sheet.findAllElements('row')) {
      final rn = int.tryParse(row.getAttribute('r') ?? '') ?? rows.length + 1;
      while (rows.length < rn - 1) {
        rows.add(const []);
      }
      final cells = <String>[];
      for (final c in row.findElements('c')) {
        final col = _colIndex(c.getAttribute('r') ?? '');
        while (cells.length < col) {
          cells.add('');
        }
        final type = c.getAttribute('t');
        final v = c.getElement('v')?.innerText ?? '';
        final text = switch (type) {
          's' => (int.tryParse(v) ?? -1) >= 0 && int.parse(v) < shared.length ? shared[int.parse(v)] : '',
          'inlineStr' => c.findAllElements('t').map((t) => t.innerText).join(),
          _ => _number(v),
        };
        if (col >= cells.length) {
          cells.add(text);
        } else {
          cells[col] = text;
        }
      }
      rows.add(cells);
    }
    out[s.getAttribute('name') ?? 'Sheet${out.length + 1}'] = rows;
    if (stopAt != null && stopAt(rows)) break;
  }
  return out;
}

/// "C12" → 2.
int _colIndex(String ref) {
  var n = 0;
  for (final ch in ref.codeUnits) {
    if (ch < 65 || ch > 90) break;
    n = n * 26 + (ch - 64);
  }
  return n == 0 ? 0 : n - 1;
}

/// "9862958415", "2.4"; "9.862958415E9" → "9862958415".
String _number(String v) {
  final d = double.tryParse(v);
  if (d == null) return v;
  return d == d.roundToDouble() && d.abs() < 1e15 ? d.toInt().toString() : v;
}

/// Off the UI isolate (SPEC §10).
Future<DirectorySheet> parseDirectoryWorkbookInIsolate(Uint8List bytes) => Isolate.run(() => parseDirectoryWorkbook(bytes));

// ---------------------------------------------------------------------------
// Matching sheet names to the catalogue.

final RegExp _formPrefix = RegExp(
  r'^(tabs?|tablets?|caps?|capsules?|syps?|syrs?|syrups?|syrubs?|susp|suspension|inj|injection|oint|ointment|drops?)\b\.?\s*',
);

/// "Syp.Ostcred  60ml" → "ostcred 60ml"; "Tab. Pantop 40" → "pantop 40".
String normalizeMedicineName(String s) {
  var t = s.toLowerCase().trim();
  for (var i = 0; i < 2; i++) {
    t = t.replaceFirst(_formPrefix, '');
  }
  t = t.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  // Form words anywhere ("Ostcred Syrup 60 ml", "Pantop 40 Tablet").
  t = t
      .split(' ')
      .where((w) => !const {'tab', 'tabs', 'tablet', 'tablets', 'cap', 'caps', 'capsule', 'capsules', 'syp', 'syr', 'syrup', 'syrups', 'syrub', 'susp', 'suspension', 'inj', 'injection'}.contains(w))
      .join(' ');
  return t.trim();
}

/// Whether a catalogue name is the sheet's medicine: equal once normalised,
/// or one is the other plus a strength / pack ("pantop" vs "pantop 40").
bool namesMatch(String sheetName, String catalogueName, {bool allowPrefix = false}) {
  final a = normalizeMedicineName(sheetName), b = normalizeMedicineName(catalogueName);
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b || a.replaceAll(' ', '') == b.replaceAll(' ', '')) return true;
  if (!allowPrefix) return false;
  return b.startsWith('$a ') || a.startsWith('$b ');
}

// ---------------------------------------------------------------------------
// Review list.

enum ImportChoice { link, keep, skip }

/// A sheet row with its catalogue match and what to do with it.
class ImportCandidate {
  ImportCandidate(this.row, {this.productId, this.productName}) : choice = productId == null ? ImportChoice.keep : ImportChoice.link;

  final SheetSourceRow row;
  int? productId;
  String? productName;
  ImportChoice choice;

  bool get matched => productId != null;
}

/// Matches each row to the catalogue with [search] (catalogue FTS →
/// (id, name) best first): an exact normalised name, else a single
/// name that only adds a strength / pack. Others stay unmatched ("keep as
/// text" by default).
Future<List<ImportCandidate>> matchToCatalogue(
  DirectorySheet sheet,
  Future<List<(int, String)>> Function(String query) search,
) async {
  final cache = <String, (int, String)?>{};
  Future<(int, String)?> best(String medicine) async {
    final q = normalizeMedicineName(medicine);
    if (q.isEmpty) return null;
    if (cache.containsKey(q)) return cache[q];
    var hits = await search(q);
    if (hits.isEmpty && q.contains(' ')) hits = await search(q.split(' ').first);
    final exact = hits.where((h) => namesMatch(medicine, h.$2)).toList();
    final pick = exact.length == 1
        ? exact.single
        : exact.isEmpty
            ? (() {
                final loose = hits.where((h) => namesMatch(medicine, h.$2, allowPrefix: true)).toList();
                return loose.length == 1 ? loose.single : null;
              })()
            : null;
    return cache[q] = pick;
  }

  return [
    for (final r in sheet.rows)
      await best(r.medicine).then((m) => ImportCandidate(r, productId: m?.$1, productName: m?.$2)),
  ];
}
