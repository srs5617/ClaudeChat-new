import 'dart:convert';
import 'dart:io';

import 'package:claudechat/services/diagnostics_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('persists events while removing secrets and full content', () async {
    final root = await Directory.systemTemp.createTemp(
      'claudechat-diagnostics-test-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final service = DiagnosticsService(root, maxBytes: 4096);

    await service.record(<String, Object?>{
      'event': 'tool_execution_started',
      'authorization': 'Bearer secret-token',
      'apiKey': 'secret-key',
      'content': 'private conversation text',
      'arguments': <String, Object?>{'query': 'private query'},
      'argumentKeys': <String>['query'],
      'argumentBytes': 20,
    });

    final entries = await service.entries();
    expect(entries, hasLength(1));
    expect(entries.single['authorization'], '[REDACTED]');
    expect(entries.single['apiKey'], '[REDACTED]');
    expect(entries.single['content'], '[REDACTED]');
    expect(entries.single['arguments'], '[REDACTED]');
    expect(entries.single['argumentKeys'], <Object?>['query']);

    final exportPath = await service.export(destination: root);
    final exported = jsonDecode(await File(exportPath).readAsString()) as Map;
    expect(exported['format'], 'claudechat-redacted-diagnostics');
    expect(jsonEncode(exported), isNot(contains('secret-token')));
    expect(jsonEncode(exported), isNot(contains('private conversation text')));
  });
}
