import 'package:claudechat/data/schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = schemaStatements.join('\n');

  test('canonical schema covers every portable data category', () {
    expect(sql, contains('CREATE TABLE conversations'));
    final conversationSql = schemaStatements.firstWhere(
      (statement) => statement.contains('CREATE TABLE conversations'),
    );
    final voiceAssetSql = voiceSchemaStatements.firstWhere(
      (statement) =>
          statement.contains('CREATE TABLE IF NOT EXISTS voice_assets'),
    );
    expect(conversationSql, contains('archived_at TEXT'));
    expect(voiceAssetSql, isNot(contains('archived_at TEXT')));
    expect(sql, contains('CREATE TABLE messages'));
    expect(sql, contains('CREATE TABLE memories'));
    expect(sql, contains('CREATE TABLE diary_entries'));
    expect(sql, contains('CREATE TABLE diary_versions'));
    expect(sql, contains('CREATE TABLE user_files'));
    expect(sql, contains('CREATE TABLE file_versions'));
    expect(sql, contains('CREATE TABLE workspaces'));
    expect(sql, contains('CREATE TABLE workspace_files'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS workspace_conversations'));
    expect(sql, contains('CREATE TABLE workspace_messages'));
    expect(
      sql,
      contains(
        'conversation_id TEXT REFERENCES workspace_conversations(id) ON DELETE CASCADE',
      ),
    );
    expect(sql, contains('CREATE TABLE IF NOT EXISTS workspace_message_parts'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS workspace_commits'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS workspace_commit_files'));
    expect(sql, contains('project_type TEXT'));
    expect(sql, contains('settings_json TEXT'));
    expect(sql, contains('CREATE TABLE attachments'));
    expect(sql, contains('CREATE TABLE reminders'));
  });

  test(
    'versioned children use foreign keys and cascade only on physical parent deletion',
    () {
      expect(
        sql,
        contains(
          'diary_id TEXT NOT NULL REFERENCES diary_entries(id) ON DELETE CASCADE',
        ),
      );
      expect(
        sql,
        contains(
          'file_id TEXT NOT NULL REFERENCES user_files(id) ON DELETE CASCADE',
        ),
      );
      expect(
        sql,
        contains(
          'message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE',
        ),
      );
    },
  );

  test('merge audit tables and tombstones are part of schema', () {
    expect(sql, contains('CREATE TABLE tombstones'));
    expect(sql, contains('CREATE TABLE entity_revisions'));
    expect(sql, contains('CREATE TABLE import_batches'));
    expect(sql, contains('backup_id TEXT NOT NULL UNIQUE'));
    expect(sql, contains('CREATE TABLE import_conflicts'));
  });
}
