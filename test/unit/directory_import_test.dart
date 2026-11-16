import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/features/purchases/application/directory_import.dart';

void main() {
  test('phones in a cell', () {
    expect(phonesIn('9862958415'), ['9862958415']);
    expect(phonesIn('or'), isEmpty);
    expect(phonesIn('0389-2323442'), ['0389-2323442']);
    expect(phonesIn('03842-469597'), ['03842-469597']);
    expect(phonesIn('Tab 500'), isEmpty);
  });

  test('medicine names normalise and match', () {
    expect(normalizeMedicineName('Syp.Ostcred  60ml'), 'ostcred 60ml');
    expect(normalizeMedicineName('Tab. Pantop 40'), 'pantop 40');
    expect(normalizeMedicineName('Caps. Rewind Plus '), 'rewind plus');
    expect(normalizeMedicineName('Inj.Rezobact 1.125mg'), 'rezobact 1 125mg');
    expect(normalizeMedicineName('Pantop 40 Tablet'), 'pantop 40');
    expect(namesMatch('Tab. Pantop 40', 'Pantop 40 Tablet'), isTrue);
    expect(namesMatch('Pantop', 'Pantop 40 Tablet'), isFalse);
    expect(namesMatch('Pantop', 'Pantop 40 Tablet', allowPrefix: true), isTrue);
    expect(namesMatch('Pan', 'Pantop 40 Tablet', allowPrefix: true), isFalse);
  });

  test('rows: stockist carried down, phones collected per block, MR per row, header found', () {
    final sheet = parseDirectoryRows([
      ['Sl.No', '   Dawr Hming', 'Damdawi hming', 'Phone numb', 'MR Hming'],
      ['1', 'EMY PHARMACY', 'Judiliv Syrub 200ml', '9862958415'],
      ['2', 'EMY PHARMACY', 'Suspencio.Victocof L Oral ', 'or'],
      ['3', 'EMY PHARMACY', 'Syp.Ostcred  60ml', '0389-2323442'],
      ['', 'RF PHARMACY', 'Esomate', '', 'Pu Robert'],
      ['4', '', 'Syr. Immuvus', '9862125221'],
      ['5', 'Emy Pharmacy', 'Anxynil M'],
      ['6', 'THUAMPUI PHARMACY', '', '9612221737'],
    ]);
    expect(sheet.rows.map((r) => (r.stockist, r.medicine)), [
      ('EMY PHARMACY', 'Judiliv Syrub 200ml'),
      ('EMY PHARMACY', 'Suspencio.Victocof L Oral'),
      ('EMY PHARMACY', 'Syp.Ostcred 60ml'),
      ('RF PHARMACY', 'Esomate'),
      ('RF PHARMACY', 'Syr. Immuvus'),
      ('EMY PHARMACY', 'Anxynil M'), // same stockist, other spelling
    ]);
    expect(sheet.rows[3].mrName, 'Pu Robert');
    expect(sheet.phonesOf('emy pharmacy'), ['9862958415', '0389-2323442']);
    expect(sheet.phonesOf('RF PHARMACY'), ['9862125221']);
    expect(sheet.phonesOf('THUAMPUI PHARMACY'), ['9612221737']);
    expect(sheet.stockists, 2);
    expect(sheet.rows.first.sheetRow, 2);
  });

  test('the store’s own workbook (docs/Daily Sales.xlsx)', () {
    final f = File('docs/Daily Sales.xlsx');
    if (!f.existsSync()) return; // not shipped everywhere
    final sheet = parseDirectoryWorkbook(f.readAsBytesSync());
    expect(sheet.sheetName, 'Damdawi lak na');
    expect(sheet.rows.length, 318); // rows 322–1141 hold only serial numbers
    expect(sheet.phonesOf('EMY PHARMACY'), ['9862958415', '0389-2323442']);
    final nitro = sheet.rows.firstWhere((r) => r.medicine == 'Nitrocube Sr 100');
    expect((nitro.stockist, nitro.mrName), ('RB PAHRMACY', 'Tluangtea'));
    expect(sheet.rows.where((r) => r.stockist == 'LIFE DRUGS CENTRE').length, greaterThan(30));
  });

  test('not a workbook', () {
    expect(() => parseDirectoryWorkbook(Uint8List.fromList([1, 2, 3])), throwsA(isA<DirectoryImportException>()));
  });

  test('matching: exact, spacing, single strength variant; ambiguous / unknown stay unmatched', () async {
    const catalogue = [(1, 'Ostcred Syrup 60 ml'), (2, 'Pantop 40 Tablet'), (3, 'Pantop DSR Capsule'), (4, 'Esomate 40'), (5, 'Calpol 500 Tablet'), (6, 'Calpol 650 Tablet')];
    Future<List<(int, String)>> search(String q) async {
      final words = q.split(' ');
      return [for (final c in catalogue) if (words.every((w) => normalizeMedicineName(c.$2).replaceAll(' ', '').contains(w))) c];
    }

    final sheet = parseDirectoryRows([
      ['Sl.No', 'Dawr Hming', 'Damdawi hming'],
      ['1', 'A', 'Syp.Ostcred  60ml'],
      ['2', 'A', 'Tab. Pantop 40'],
      ['3', 'A', 'Esomate'],
      ['4', 'A', 'Calpol'],
      ['5', 'A', 'Judiliv Syrub 200ml'],
    ]);
    final m = await matchToCatalogue(sheet, search);
    expect(m.map((c) => c.productId), [1, 2, 4, null, null]);
    expect(m.map((c) => c.choice), [ImportChoice.link, ImportChoice.link, ImportChoice.link, ImportChoice.keep, ImportChoice.keep]);
  });
}
