import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';

/// `.rxbak` = zip of `manifest.json` + `db.sqlite` (or `db.sqlite.enc`)
/// (SPEC §5.6). Pure functions — run them in an isolate.

const String backupExtension = 'rxbak';
const int pbkdf2Iterations = 210000;

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BackupCounts {
  const BackupCounts({this.products = 0, this.batches = 0, this.invoices = 0, this.items = 0});

  factory BackupCounts.fromJson(Map<String, dynamic> j) => BackupCounts(
        products: (j['products'] as num?)?.toInt() ?? 0,
        batches: (j['batches'] as num?)?.toInt() ?? 0,
        invoices: (j['invoices'] as num?)?.toInt() ?? 0,
        items: (j['items'] as num?)?.toInt() ?? 0,
      );

  final int products;
  final int batches;
  final int invoices;
  final int items;

  Map<String, Object> toJson() => {'products': products, 'batches': batches, 'invoices': invoices, 'items': items};
}

class BackupManifest {
  const BackupManifest({
    required this.schemaVersion,
    required this.createdAt,
    required this.counts,
    required this.encrypted,
    required this.sha256,
    this.salt,
    this.nonce,
    this.iterations,
  });

  factory BackupManifest.fromJson(Map<String, dynamic> j) {
    if (j['app'] != 'RxDesk') throw const BackupException('This file isn’t an RxDesk backup');
    final kdf = j['kdf'] as Map<String, dynamic>?;
    return BackupManifest(
      schemaVersion: (j['schemaVersion'] as num).toInt(),
      createdAt: DateTime.parse(j['createdAt'] as String),
      counts: BackupCounts.fromJson(j['counts'] as Map<String, dynamic>? ?? const {}),
      encrypted: j['encrypted'] == true,
      sha256: j['sha256'] as String,
      salt: kdf?['salt'] as String?,
      iterations: (kdf?['iterations'] as num?)?.toInt(),
      nonce: j['nonce'] as String?,
    );
  }

  final int schemaVersion;
  final DateTime createdAt;
  final BackupCounts counts;
  final bool encrypted;

  /// SHA-256 (hex) of the plain SQLite file.
  final String sha256;
  final String? salt;
  final String? nonce;
  final int? iterations;

  Map<String, Object?> toJson() => {
        'app': 'RxDesk',
        'schemaVersion': schemaVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'counts': counts.toJson(),
        'encrypted': encrypted,
        if (encrypted) 'kdf': {'alg': 'PBKDF2-SHA256', 'iterations': iterations, 'salt': salt},
        if (encrypted) 'cipher': 'AES-256-GCM',
        if (encrypted) 'nonce': nonce,
        'sha256': sha256,
      };
}

Uint8List _random(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

Future<String> sha256Hex(List<int> bytes) async {
  final h = await Sha256().hash(bytes);
  return h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Future<SecretKey> _deriveKey(String password, List<int> salt, int iterations) =>
    Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
        .deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

/// Packs a SQLite snapshot into `.rxbak` bytes. A non-empty [password]
/// encrypts the database with AES-256-GCM under a PBKDF2-SHA256 key.
Future<Uint8List> packBackup({
  required Uint8List dbBytes,
  required int schemaVersion,
  required BackupCounts counts,
  required DateTime createdAt,
  String? password,
  int iterations = pbkdf2Iterations,
}) async {
  final digest = await sha256Hex(dbBytes);
  final encrypt = password != null && password.isNotEmpty;
  Uint8List payload = dbBytes;
  String? salt, nonce;
  if (encrypt) {
    final s = _random(16), n = _random(12);
    final key = await _deriveKey(password, s, iterations);
    final box = await AesGcm.with256bits().encrypt(dbBytes, secretKey: key, nonce: n);
    payload = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    salt = base64Encode(s);
    nonce = base64Encode(n);
  }
  final manifest = BackupManifest(
    schemaVersion: schemaVersion,
    createdAt: createdAt,
    counts: counts,
    encrypted: encrypt,
    sha256: digest,
    salt: salt,
    nonce: nonce,
    iterations: encrypt ? iterations : null,
  );
  final m = utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest.toJson()));
  final archive = Archive()
    ..addFile(ArchiveFile('manifest.json', m.length, m))
    ..addFile(ArchiveFile(encrypt ? 'db.sqlite.enc' : 'db.sqlite', payload.length, payload));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Archive _open(Uint8List zip) {
  try {
    return ZipDecoder().decodeBytes(zip);
  } on Object {
    throw const BackupException('This file isn’t an RxDesk backup (not a valid archive)');
  }
}

/// Reads just the manifest (to show what's inside / ask for a password).
BackupManifest readManifest(Uint8List zip) {
  final f = _open(zip).findFile('manifest.json');
  if (f == null) throw const BackupException('Backup is missing its manifest');
  try {
    return BackupManifest.fromJson(jsonDecode(utf8.decode(f.content as List<int>)) as Map<String, dynamic>);
  } on BackupException {
    rethrow;
  } on Object {
    throw const BackupException('Backup manifest is damaged');
  }
}

/// Validates and unpacks `.rxbak` bytes → the plain SQLite file. Checks the
/// manifest, schema version, password and SHA-256 (SPEC §5.6).
Future<(BackupManifest, Uint8List)> unpackBackup(Uint8List zip, {required int currentSchema, String? password}) async {
  final manifest = readManifest(zip);
  if (manifest.schemaVersion > currentSchema) {
    throw BackupException('This backup is from a newer RxDesk (schema ${manifest.schemaVersion}). Update the app first.');
  }
  final archive = _open(zip);
  Uint8List db;
  if (manifest.encrypted) {
    if (password == null || password.isEmpty) throw const BackupException('This backup is password-protected');
    final f = archive.findFile('db.sqlite.enc');
    if (f == null || manifest.salt == null || manifest.nonce == null) throw const BackupException('Backup is incomplete');
    final data = f.content as List<int>;
    if (data.length < 16) throw const BackupException('Backup is damaged');
    final key = await _deriveKey(password, base64Decode(manifest.salt!), manifest.iterations ?? pbkdf2Iterations);
    try {
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(data.sublist(0, data.length - 16), nonce: base64Decode(manifest.nonce!), mac: Mac(data.sublist(data.length - 16))),
        secretKey: key,
      );
      db = Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const BackupException('Wrong password — the backup could not be opened');
    }
  } else {
    final f = archive.findFile('db.sqlite');
    if (f == null) throw const BackupException('Backup is missing its database');
    db = Uint8List.fromList(f.content as List<int>);
  }
  if (await sha256Hex(db) != manifest.sha256) throw const BackupException('Backup is damaged (checksum mismatch)');
  if (db.length < 16 || utf8.decode(db.sublist(0, 15), allowMalformed: true) != 'SQLite format 3') {
    throw const BackupException('Backup does not contain a SQLite database');
  }
  return (manifest, db);
}

/// `rxdesk-backup-2026-11-09-1930.rxbak`
String backupFileName(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'rxdesk-backup-${at.year}-${two(at.month)}-${two(at.day)}-${two(at.hour)}${two(at.minute)}.$backupExtension';
}

/// Whether an automatic backup is due.
bool autoBackupDue({required DateTime? last, required DateTime now, required String frequency}) {
  if (last == null) return true;
  final days = switch (frequency) {
    'Weekly' => 7,
    'Monthly' => 30,
    _ => 1,
  };
  final lastDay = DateTime(last.year, last.month, last.day);
  final today = DateTime(now.year, now.month, now.day);
  return today.difference(lastDay).inDays >= days;
}

/// "2.4 MB"
String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
}
