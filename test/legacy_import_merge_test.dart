import 'dart:convert';

import 'package:claudechat/core/app_paths.dart';
import 'package:claudechat/data/app_database.dart';
import 'package:claudechat/services/brand_service.dart';
import 'package:claudechat/services/legacy_import_service.dart';
import 'package:claudechat/services/secure_vault.dart';
import 'package:claudechat/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy comparison skips equal selected content', () {
    final local = <String, Object?>{
      'id': 'message-1',
      'content': 'same',
      'revision': 9,
    };
    final incoming = <String, Object?>{
      'id': 'message-1',
      'content': 'same',
      'revision': 1,
    };

    expect(legacyRowsEqual(local, incoming, const <String>['content']), isTrue);
  });

  test('legacy comparison detects updated conversation content', () {
    final local = <String, Object?>{
      'id': 'message-1',
      'content': 'before edit',
    };
    final incoming = <String, Object?>{
      'id': 'message-1',
      'content': 'after edit',
    };

    expect(
      legacyRowsEqual(local, incoming, const <String>['content']),
      isFalse,
    );
  });

  test('legacy parts keep body before the terminal status capsule', () {
    final paths = AppPaths.visualAudit();
    final database = AppDatabase.visualAudit(paths, 'test-device');
    final settings = SettingsService(database, SecureVault());
    final importer = LegacyImportService(
      database,
      settings,
      BrandService(paths, settings),
    );
    final parts = importer.buildLegacyMessageParts(
      <String, Object?>{
        'role': 'assistant',
        'content': '最终正文',
        '_statusCapsules': <Object?>[
          <String, Object?>{'type': 'sent'},
          <String, Object?>{'type': 'replying'},
          <String, Object?>{'type': 'success', 'detail': '完成'},
        ],
        'parts': <Object?>[
          <String, Object?>{'type': 'thought', 'content': '第一段思维链'},
          <String, Object?>{
            'type': 'tool',
            'item': <String, Object?>{
              'id': 'tool-call-1',
              'name': 'search_files',
              'status': 'done',
              'arg': <String, Object?>{'query': '资料'},
              'result': <String, Object?>{'matches': <Object?>[]},
            },
          },
        ],
      },
      'message-1',
      DateTime.utc(2026, 8, 19),
    );

    expect(parts.map((part) => part['type']), const <String>[
      'status',
      'status',
      'thought',
      'tool',
      'content',
      'status',
    ]);
    expect(parts.map((part) => part['sequence']), <int>[1, 2, 3, 4, 5, 6]);
    expect(parts[4]['content'], '最终正文');
    expect(jsonDecode(parts[5]['metadata_json']! as String), <String, Object?>{
      'status': 'success',
      'detail': '完成',
    });
  });

  test('legacy toolCallsResults are restored before thoughts and content', () {
    final paths = AppPaths.visualAudit();
    final database = AppDatabase.visualAudit(paths, 'test-device');
    final settings = SettingsService(database, SecureVault());
    final importer = LegacyImportService(
      database,
      settings,
      BrandService(paths, settings),
    );
    final parts = importer.buildLegacyMessageParts(
      <String, Object?>{
        'role': 'assistant',
        'content': '最终正文',
        '_statusCapsules': <Object?>[
          <String, Object?>{'type': 'sent'},
          <String, Object?>{'type': 'replying'},
          <String, Object?>{'type': 'success'},
        ],
        'parts': <Object?>[
          <String, Object?>{'type': 'thought', 'content': '历史思维链'},
        ],
        'toolCallsResults': <Object?>[
          <String, Object?>{
            'id': 'legacy-tool-1',
            'name': 'search_files',
            'status': 'done',
            'arg': <String, Object?>{'query': '资料'},
            'result': <String, Object?>{'matches': <Object?>[], 'total': 0},
          },
        ],
      },
      'message-legacy',
      DateTime.utc(2026, 8, 24),
    );

    expect(parts.map((part) => part['type']), const <String>[
      'status',
      'status',
      'tool',
      'thought',
      'content',
      'status',
    ]);
    expect(
      jsonDecode(parts[2]['metadata_json']! as String),
      containsPair('status', 'success'),
    );
    expect(jsonDecode(parts[2]['content']! as String), <String, Object?>{
      'matches': <Object?>[],
      'total': 0,
    });
  });

  test('legacy reasoning aliases survive alongside existing content parts', () {
    final paths = AppPaths.visualAudit();
    final database = AppDatabase.visualAudit(paths, 'test-device');
    final settings = SettingsService(database, SecureVault());
    final importer = LegacyImportService(
      database,
      settings,
      BrandService(paths, settings),
    );
    final parts = importer.buildLegacyMessageParts(
      <String, Object?>{
        'role': 'assistant',
        'content': '最终正文',
        'reasoning_content': '旧版单字段思维链',
        'parts': <Object?>[
          <String, Object?>{'type': 'content', 'content': '最终正文'},
        ],
      },
      'message-reasoning-alias',
      DateTime.utc(2026, 8, 28),
    );

    expect(parts.map((part) => part['type']), const <String>[
      'thought',
      'content',
    ]);
    expect(parts.first['content'], '旧版单字段思维链');
  });

  test('legacy thinking and reasoning part types remain thought parts', () {
    final paths = AppPaths.visualAudit();
    final database = AppDatabase.visualAudit(paths, 'test-device');
    final settings = SettingsService(database, SecureVault());
    final importer = LegacyImportService(
      database,
      settings,
      BrandService(paths, settings),
    );
    final parts = importer.buildLegacyMessageParts(
      <String, Object?>{
        'role': 'assistant',
        'parts': <Object?>[
          <String, Object?>{'type': 'thinking', 'text': '第一段'},
          <String, Object?>{'type': 'reasoning', 'content': '第二段'},
          <String, Object?>{'type': 'content', 'content': '正文'},
        ],
      },
      'message-part-aliases',
      DateTime.utc(2026, 8, 28),
    );

    expect(parts.map((part) => part['type']), const <String>[
      'thought',
      'thought',
      'content',
    ]);
    expect(parts.map((part) => part['content']), const <String>[
      '第一段',
      '第二段',
      '正文',
    ]);
  });
}
