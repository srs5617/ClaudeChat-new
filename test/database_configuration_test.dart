import 'package:claudechat/data/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('journal mode is configured through the SQLite query API', () async {
    final executed = <String>[];
    final queried = <String>[];

    await configureDatabasePragmas(
      execute: (sql) async => executed.add(sql),
      rawQuery: (sql) async {
        queried.add(sql);
        return <Map<String, Object?>>[
          <String, Object?>{'journal_mode': 'wal'},
        ];
      },
    );

    expect(executed, <String>['PRAGMA foreign_keys = ON']);
    expect(queried, <String>['PRAGMA journal_mode = WAL']);
  });

  test(
    'voice schema repair is idempotent and preserves existing data',
    () async {
      final executed = <String>[];

      await ensureVoiceSchema(execute: (sql) async => executed.add(sql));

      expect(executed, isNotEmpty);
      expect(
        executed.where((sql) => sql.startsWith('CREATE TABLE')),
        everyElement(contains('IF NOT EXISTS')),
      );
      expect(
        executed.where((sql) => sql.startsWith('CREATE INDEX')),
        everyElement(contains('IF NOT EXISTS')),
      );
    },
  );

  test('conversation archive repair only adds a missing column', () async {
    final executed = <String>[];

    await ensureConversationArchiveSchema(
      execute: (sql) async => executed.add(sql),
      rawQuery: (_) async => <Map<String, Object?>>[
        <String, Object?>{'name': 'id'},
        <String, Object?>{'name': 'title'},
      ],
    );

    expect(executed, <String>[
      'ALTER TABLE conversations ADD COLUMN archived_at TEXT',
    ]);

    executed.clear();
    await ensureConversationArchiveSchema(
      execute: (sql) async => executed.add(sql),
      rawQuery: (_) async => <Map<String, Object?>>[
        <String, Object?>{'name': 'id'},
        <String, Object?>{'name': 'archived_at'},
      ],
    );
    expect(executed, isEmpty);
  });

  test(
    'workspace v1 repair adds columns and creates idempotent tables',
    () async {
      final executed = <String>[];

      await ensureWorkspaceV1Schema(
        execute: (sql) async => executed.add(sql),
        rawQuery: (sql) async {
          if (sql.contains('workspace_files')) {
            return <Map<String, Object?>>[
              <String, Object?>{'name': 'id'},
            ];
          }
          return <Map<String, Object?>>[
            <String, Object?>{'name': 'id'},
            <String, Object?>{'name': 'name'},
          ];
        },
      );

      expect(executed, contains(contains('ADD COLUMN description')));
      expect(executed, contains(contains('ADD COLUMN project_type')));
      expect(executed, contains(contains('ADD COLUMN settings_json')));
      expect(executed, contains(contains('ADD COLUMN archived_at')));
      expect(
        executed,
        contains(contains('workspace_files ADD COLUMN deleted_at')),
      );
      expect(
        executed.where((sql) => sql.startsWith('CREATE TABLE')),
        everyElement(contains('IF NOT EXISTS')),
      );
      expect(
        executed.where((sql) => sql.startsWith('CREATE INDEX')),
        everyElement(contains('IF NOT EXISTS')),
      );
    },
  );

  test(
    'workspace conversation repair keeps historic messages in one thread',
    () async {
      final executed = <String>[];

      await ensureWorkspaceConversationSchema(
        execute: (sql) async => executed.add(sql),
        rawQuery: (_) async => <Map<String, Object?>>[
          <String, Object?>{'name': 'id'},
          <String, Object?>{'name': 'workspace_id'},
        ],
      );

      expect(executed.first, contains('workspace_conversations'));
      expect(executed, contains(contains('ADD COLUMN conversation_id')));
      expect(executed, contains(contains("'legacy-' || w.id")));
      expect(executed, contains(contains('WHERE NOT EXISTS')));
      expect(executed, contains(contains('SET conversation_id')));
      expect(
        executed.where((sql) => sql.startsWith('CREATE INDEX')),
        everyElement(contains('IF NOT EXISTS')),
      );
    },
  );
}
