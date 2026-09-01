import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('diary saves update the parent without cascading version deletion', () {
    final source = File(
      'lib/services/content_repository.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final start = source.indexOf('Future<String> saveDiary');
    final end = source.indexOf('Future<void> repairVersionHistories', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final saveDiary = source.substring(start, end);
    expect(saveDiary, contains("transaction.update(\n        'diary_entries'"));
    expect(saveDiary, isNot(contains('ConflictAlgorithm.replace')));
  });

  test(
    'startup repair restores orphan file versions and missing create rows',
    () {
      final source = File(
        'lib/services/content_repository.dart',
      ).readAsStringSync();
      expect(source, contains('repairVersionHistories()'));
      expect(source, contains('_repairDiaryVersionHistories'));
      expect(source, contains('_repairFileVersionHistories'));
      expect(source, contains('从本地文件恢复的历史版本'));
      expect(source, contains('创建文件（从现存最早版本恢复）'));
    },
  );

  test('workspace file version labels are sequential per file', () {
    final source = File(
      'lib/services/content_repository.dart',
    ).readAsStringSync();
    expect(
      source,
      contains(r'entry.$2.withSequence(versions.length - entry.$1)'),
    );
    expect(source, contains('final ordered = await workspaceFileVersions('));
    expect(source, contains('fileId: rawVersion.fileId'));
  });
}
