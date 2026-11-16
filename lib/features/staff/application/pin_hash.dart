import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Staff PINs are stored only as salted PBKDF2-SHA256 hashes
/// (CLAUDE.md rule 13). Stored format: `pbkdf2-sha256$<iterations>$<b64>`.
const int pinIterations = 60000;

bool isValidPin(String pin) => RegExp(r'^\d{4}$').hasMatch(pin);

Future<List<int>> _derive(String pin, List<int> salt, int iterations) async {
  final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
      .deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt);
  return key.extractBytes();
}

/// Returns (hash, salt), both strings for the `staff` table.
Future<(String, String)> hashPin(String pin, {int iterations = pinIterations}) async {
  final r = Random.secure();
  final salt = List<int>.generate(16, (_) => r.nextInt(256));
  final h = await _derive(pin, salt, iterations);
  return ('pbkdf2-sha256\$$iterations\$${base64Encode(h)}', base64Encode(salt));
}

/// Constant-time comparison of [pin] against a stored hash.
Future<bool> verifyPin(String pin, {required String hash, required String salt}) async {
  final parts = hash.split(r'$');
  if (parts.length != 3 || parts[0] != 'pbkdf2-sha256') return false;
  final iterations = int.tryParse(parts[1]);
  if (iterations == null) return false;
  final expected = base64Decode(parts[2]);
  final got = await _derive(pin, base64Decode(salt), iterations);
  if (got.length != expected.length) return false;
  var diff = 0;
  for (var i = 0; i < got.length; i++) {
    diff |= got[i] ^ expected[i];
  }
  return diff == 0;
}
