import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CLAUDE.md UI rules: "All colours … come from core/theme/tokens.dart. No hex
/// literals in feature code." Shared widgets follow the same rule.
void main() {
  test('no colour literals outside core/theme', () {
    final offenders = <String>[];
    final pattern = RegExp(r'Color\(0x|Color\.fromARGB|Color\.fromRGBO|(?<![A-Za-z])Colors\.(?!transparent\b)\w+');
    for (final dir in ['lib/features', 'lib/core/widgets', 'lib/core/router', 'lib/app.dart']) {
      final entity = FileSystemEntity.typeSync(dir) == FileSystemEntityType.file ? [File(dir)] : Directory(dir).listSync(recursive: true);
      for (final f in entity.whereType<File>().where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))) {
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (pattern.hasMatch(lines[i])) offenders.add('${f.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'Use AppColors / StatusTone / context.palette instead:\n${offenders.join('\n')}');
  });
}
