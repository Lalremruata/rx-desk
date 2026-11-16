import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rx_desk/features/backup/application/backup_format.dart';

Uint8List fakeDb() => Uint8List.fromList([...utf8.encode('SQLite format 3'), 0, ...List<int>.generate(4000, (i) => i % 251)]);

Future<Uint8List> pack({String? pw, int schema = 2}) => packBackup(
      dbBytes: fakeDb(),
      schemaVersion: schema,
      counts: const BackupCounts(products: 3, invoices: 7),
      createdAt: DateTime.utc(2026, 11, 9, 19, 30),
      password: pw,
      iterations: 1000,
    );

void main() {
  test('plain round trip + manifest', () async {
    final zip = await pack();
    final m = readManifest(zip);
    expect(m.encrypted, isFalse);
    expect(m.counts.invoices, 7);
    expect(m.schemaVersion, 2);
    final (_, db) = await unpackBackup(zip, currentSchema: 2);
    expect(db, fakeDb());
    final names = ZipDecoder().decodeBytes(zip).files.map((f) => f.name);
    expect(names, containsAll(['manifest.json', 'db.sqlite']));
  });

  test('encrypted round trip; wrong or missing password fails cleanly', () async {
    final zip = await pack(pw: 'secret-123');
    final m = readManifest(zip);
    expect(m.encrypted, isTrue);
    expect(m.salt, isNotNull);
    expect(ZipDecoder().decodeBytes(zip).files.map((f) => f.name), contains('db.sqlite.enc'));
    expect(utf8.decode(ZipDecoder().decodeBytes(zip).findFile('db.sqlite.enc')!.content as List<int>, allowMalformed: true), isNot(contains('SQLite format 3')));
    final (_, db) = await unpackBackup(zip, currentSchema: 2, password: 'secret-123');
    expect(db, fakeDb());
    await expectLater(unpackBackup(zip, currentSchema: 2, password: 'nope'), throwsA(isA<BackupException>().having((e) => e.message, 'msg', contains('Wrong password'))));
    await expectLater(unpackBackup(zip, currentSchema: 2), throwsA(isA<BackupException>()));
  });

  test('newer schema is refused; older is accepted', () async {
    await expectLater(unpackBackup(await pack(schema: 3), currentSchema: 2), throwsA(isA<BackupException>()));
    final (m, _) = await unpackBackup(await pack(schema: 1), currentSchema: 2);
    expect(m.schemaVersion, 1);
  });

  test('checksum mismatch and junk files are rejected', () async {
    final zip = await pack();
    final a = ZipDecoder().decodeBytes(zip);
    final tampered = Archive();
    for (final f in a.files) {
      if (f.name == 'db.sqlite') {
        final c = Uint8List.fromList(f.content as List<int>)..[100] ^= 0xFF;
        tampered.addFile(ArchiveFile('db.sqlite', c.length, c));
      } else {
        tampered.addFile(f);
      }
    }
    await expectLater(
      unpackBackup(Uint8List.fromList(ZipEncoder().encode(tampered)!), currentSchema: 2),
      throwsA(isA<BackupException>().having((e) => e.message, 'msg', contains('checksum'))),
    );
    expect(() => readManifest(Uint8List.fromList(utf8.encode('hello'))), throwsA(isA<BackupException>()));
  });

  test('file name, due rule, sizes', () {
    expect(backupFileName(DateTime(2026, 11, 9, 19, 5)), 'rxdesk-backup-2026-11-09-1905.rxbak');
    final now = DateTime(2026, 11, 9, 9);
    expect(autoBackupDue(last: null, now: now, frequency: 'Daily'), isTrue);
    expect(autoBackupDue(last: DateTime(2026, 11, 9, 7), now: now, frequency: 'Daily'), isFalse);
    expect(autoBackupDue(last: DateTime(2026, 11, 8, 23), now: now, frequency: 'Daily'), isTrue);
    expect(autoBackupDue(last: DateTime(2026, 11, 5), now: now, frequency: 'Weekly'), isFalse);
    expect(autoBackupDue(last: DateTime(2026, 11, 2), now: now, frequency: 'Weekly'), isTrue);
    expect(formatBytes(2516582), '2.4 MB');
  });
}
