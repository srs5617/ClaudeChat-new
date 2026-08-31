import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only model search, update, and reads count as memory usage', () {
    final repository = File(
      'lib/services/content_repository.dart',
    ).readAsStringSync();
    final tools = File('lib/services/tool_service.dart').readAsStringSync();
    final controller = File('lib/app_controller.dart').readAsStringSync();
    final app = File('lib/app.dart').readAsStringSync();

    expect(
      repository,
      contains('use_frequency = COALESCE(use_frequency, 0) + 1'),
    );
    expect(
      _between(
        tools,
        'Future<Map<String, Object?>> _searchMemory',
        'Future<Map<String, Object?>> _createMemory',
      ),
      contains('content.recordMemoryAccesses'),
    );
    expect(
      _between(
        tools,
        'Future<Map<String, Object?>> _createMemory',
        'Future<Map<String, Object?>> _updateMemory',
      ),
      isNot(contains('content.recordMemoryAccesses')),
    );
    expect(
      _between(
        tools,
        'Future<Map<String, Object?>> _updateMemory',
        'Future<Map<String, Object?>> _deleteMemory',
      ),
      contains('content.recordMemoryAccesses'),
    );
    expect(
      _between(
        tools,
        'Future<Map<String, Object?>> _deleteMemory',
        'Future<MemoryEntry> _memory',
      ),
      isNot(contains('content.recordMemoryAccesses')),
    );
    expect(controller, contains('_recordInjectedCriticalMemoryAccess'));
    expect(controller, contains('await content.recordMemoryAccesses(ids)'));
    expect(
      _between(
        app,
        'Future<void> _saveEditor()',
        'Future<void> _deleteMemory(MemoryEntry item)',
      ),
      isNot(contains('recordMemoryAccesses')),
    );
  });
}

String _between(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(startIndex, greaterThanOrEqualTo(0), reason: 'missing $start');
  expect(endIndex, greaterThan(startIndex), reason: 'missing $end');
  return source.substring(startIndex, endIndex);
}
