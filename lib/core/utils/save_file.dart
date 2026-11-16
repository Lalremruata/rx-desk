import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Asks where to save [bytes] (suggesting [fileName]) and writes it.
/// Returns the chosen location, or null if cancelled.
Future<String?> saveBytesAs(String fileName, Uint8List bytes) async {
  final uri = await FilePicker.saveFile(fileName: fileName, bytes: bytes);
  return uri?.toFilePath();
}

/// UTF-8 text with a BOM so Excel opens ₹ and Indian names correctly.
Future<String?> saveTextAs(String fileName, String text) =>
    saveBytesAs(fileName, Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]));
