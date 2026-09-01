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

  test('imports the complete text tree from an exported zip package', () {
    final bytes = WorkspaceExportService.buildZip(<String, String>{
      'src/main.py': 'print("hello")',
      'assets/cards/data.json': '{"card": 1}',
    });

    expect(WorkspaceExportService.readZip(bytes), <String, String>{
      'src/main.py': 'print("hello")',
      'assets/cards/data.json': '{"card": 1}',
    });
  });

  test('rejects unsafe paths and binary files while importing', () {
    final unsafeArchive = Archive()
      ..addFile(ArchiveFile('../secret.txt', 4, utf8.encode('nope')));
    expect(
      () => WorkspaceExportService.readZip(
        ZipEncoder().encodeBytes(unsafeArchive),
      ),
      throwsFormatException,
    );

    final binaryArchive = Archive()
      ..addFile(ArchiveFile('photo.bin', 2, <int>[0xff, 0xfe]));
    expect(
      () => WorkspaceExportService.readZip(
        ZipEncoder().encodeBytes(binaryArchive),
      ),
      throwsFormatException,
    );
  });
}
