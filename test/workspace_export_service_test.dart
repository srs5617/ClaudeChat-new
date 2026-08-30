import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:claudechat/services/workspace_export_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports the complete workspace tree as a zip package', () {
    final bytes = WorkspaceExportService.buildZip(<String, String>{
      r'src\main.py': 'print("hello")',
      'assets/cards/data.json': '{"card": 1}',
      'README.md': '# Demo',
    });
    final archive = ZipDecoder().decodeBytes(bytes);
    final entries = <String, ArchiveFile>{
      for (final file in archive.files) file.name: file,
    };

    expect(
      entries.keys,
      containsAll(<String>[
        'src/',
        'src/main.py',
        'assets/',
        'assets/cards/',
        'assets/cards/data.json',
        'README.md',
      ]),
    );
    expect(
      utf8.decode(entries['assets/cards/data.json']!.readBytes()!),
      '{"card": 1}',
    );
  });

  test('rejects paths that escape the workspace root', () {
    expect(
      () => WorkspaceExportService.buildZip(<String, String>{
        '../secret.txt': 'nope',
      }),
      throwsFormatException,
    );
  });
}
