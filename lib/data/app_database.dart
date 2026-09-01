import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/app_paths.dart';
import '../domain/entities.dart';
import 'schema.dart';

const _uuid = Uuid();

@visibleForTesting
const Set<String> softDeleteTables = <String>{
  'api_profiles',
  'conversations',
  'messages',
  'memories',
  'diary_entries',
  'user_files',
  'workspaces',
  'reminders',
  'voice_profiles',
  'voice_assets',
};

@visibleForTesting
Future<void> configureDatabasePragmas({
  required Future<void> Function(String sql) execute,
  required Future<List<Map<String, Object?>>> Function(String sql) rawQuery,
}) async {
  await execute('PRAGMA foreign_keys = ON');
  // journal_mode returns a result row. Android's SQLite wrapper rejects it
  // when invoked through execute(), so it must use the query API.
  await rawQuery('PRAGMA journal_mode = WAL');
}

@visibleForTesting
Future<void> ensureVoiceSchema({
  required Future<void> Function(String sql) execute,
}) async {
  for (final statement in voiceSchemaStatements) {
    await execute(statement);
  }
}

@visibleForTesting
Future<void> ensureVoiceGeneratedTextSchema({
  required Future<void> Function(String sql) execute,
  required Future<List<Map<String, Object?>>> Function(String sql) rawQuery,
}) async {
  final columns = await rawQuery('PRAGMA table_info(voice_assets)');
  if (!columns.any((row) => row['name'] == 'generated_text')) {
    await execute(
      "ALTER TABLE voice_assets ADD COLUMN generated_text TEXT NOT NULL DEFAULT ''",
    );
  }
}

@visibleForTesting
Future<void> ensureVoiceAssetSourceSchema({
  required Future<void> Function(String sql) execute,
  required Future<List<Map<String, Object?>>> Function(String sql) rawQuery,
}) async {
  final columns = await rawQuery('PRAGMA table_info(voice_assets)');
  final names = columns.map((row) => row['name']).whereType<String>().toSet();
  final addedSourceKind = !names.contains('source_kind');
  if (addedSourceKind) {
    await execute(
      "ALTER TABLE voice_assets ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'message'",
    );
  }
  if (!names.contains('tool_call_id')) {
    await execute(
      "ALTER TABLE voice_assets ADD COLUMN tool_call_id TEXT NOT NULL DEFAULT ''",
    );
  }
  if (addedSourceKind) {
    await execute("""UPDATE voice_assets
      SET source_kind = 'tool'
      WHERE TRIM(COALESCE(generated_text, '')) <> ''
        AND EXISTS (
          SELECT 1 FROM messages m
          WHERE m.id = voice_assets.message_id
            AND TRIM(COALESCE(voice_assets.generated_text, '')) <>
                TRIM(COALESCE(m.content, ''))
        )""");
  }
  await execute(
    'CREATE INDEX IF NOT EXISTS idx_voice_assets_source '
    'ON voice_assets(message_id, source_kind, tool_call_id)',
  );
}

@visibleForTesting
Future<void> ensureConversationArchiveSchema({
  required Future<void> Function(String sql) execute,
  required Future<List<Map<String, Object?>>> Function(String sql) rawQuery,
}) async {
  final columns = await rawQuery('PRAGMA table_info(conversations)');
  final hasArchivedAt = columns.any((row) => row['name'] == 'archived_at');
  if (!hasArchivedAt) {
    await execute('ALTER TABLE conversations ADD COLUMN archived_at TEXT');
  }
}

@visibleForTesting
Future<void> ensureWorkspaceV1Schema({
  required Future<void> Function(String sql) execute,
  required Future<List<Map<String, Object?>>> Function(String sql) rawQuery,
}) async {
  final workspaceColumns = await rawQuery('PRAGMA table_info(workspaces)');
  final workspaceNames = workspaceColumns
      .map((row) => row['name'])
      .whereType<String>()
      .toSet();
  if (!workspaceNames.contains('description')) {
    await execute(
      "ALTER TABLE workspaces ADD COLUMN description TEXT NOT NULL DEFAULT ''",
    );
  }
  if (!workspaceNames.contains('project_type')) {
    await execute(
      "ALTER TABLE workspaces ADD COLUMN project_type TEXT NOT NULL DEFAULT 'web'",
    );
  }
  if (!workspaceNames.contains('settings_json')) {
    await execute(
      "ALTER TABLE workspaces ADD COLUMN settings_json TEXT NOT NULL DEFAULT '{}'",
    );
  }
  if (!workspaceNames.contains('archived_at')) {
    await execute('ALTER TABLE workspaces ADD COLUMN archived_at TEXT');
  }

  final fileColumns = await rawQuery('PRAGMA table_info(workspace_files)');
  final fileNames = fileColumns
      .map((row) => row['name'])
      .whereType<String>()
      .toSet();
  if (!fileNames.contains('deleted_at')) {
    await execute('ALTER TABLE workspace_files ADD COLUMN deleted_at TEXT');
  }
  for (final statement in workspaceV1SchemaStatements) {
    await execute(statement);
  }
}

@visibleForTesting
Future<void> ensureWorkspaceConversationSchema({
  required Future<void> Function(String sql) execute,
  required Future<List<Map<String, Object?>>> Function(String sql) rawQuery,
}) async {
  await execute(workspaceConversationSchemaStatements.first);
  final columns = await rawQuery('PRAGMA table_info(workspace_messages)');
  if (!columns.any((row) => row['name'] == 'conversation_id')) {
    await execute(
      'ALTER TABLE workspace_messages ADD COLUMN conversation_id TEXT REFERENCES workspace_conversations(id) ON DELETE CASCADE',
    );
  }
  // Every pre-v5 workspace gets one deterministic conversation. This keeps all
  // historic messages together and makes the migration safe to repeat.
  await execute('''INSERT OR IGNORE INTO workspace_conversations (
    id, workspace_id, title, created_at, updated_at, revision, origin_device_id
  ) SELECT
    'legacy-' || w.id, w.id, '主对话', w.created_at, w.updated_at, 1, w.origin_device_id
    FROM workspaces w
    WHERE NOT EXISTS (
      SELECT 1 FROM workspace_conversations c WHERE c.workspace_id = w.id
    )''');
  await execute("""UPDATE workspace_messages
    SET conversation_id = 'legacy-' || workspace_id
    WHERE COALESCE(conversation_id, '') = ''""");
  for (final statement in workspaceConversationSchemaStatements.skip(1)) {
    await execute(statement);
  }
}

class AppDatabase {
  AppDatabase._(this.paths, this.database, this.deviceId);

  /// Inert database handle used only by the deterministic visual audit.
  /// Service objects may be constructed around it, but the audit must not call
  /// persistence methods. A read of [database] therefore fails loudly instead
  /// of silently producing non-representative data.
  AppDatabase.visualAudit(this.paths, this.deviceId);

  final AppPaths paths;
  late final Database database;
  final String deviceId;

  static Future<AppDatabase> open(AppPaths paths) async {
    final db = await openDatabase(
      '${paths.database.path}${Platform.pathSeparator}claudechat.sqlite3',
      version: databaseVersion,
      onConfigure: (database) async {
        await configureDatabasePragmas(
          execute: database.execute,
          rawQuery: database.rawQuery,
        );
      },
      onCreate: (database, version) async {
        final batch = database.batch();
        for (final statement in schemaStatements) {
          batch.execute(statement);
        }
        batch.insert('schema_migrations', <String, Object?>{
          'version': version,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
        await batch.commit(noResult: true);
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await ensureVoiceSchema(execute: database.execute);
          await database.insert('schema_migrations', <String, Object?>{
            'version': 2,
            'applied_at': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        if (oldVersion < 3) {
          await ensureConversationArchiveSchema(
            execute: database.execute,
            rawQuery: database.rawQuery,
          );
          await database.insert('schema_migrations', <String, Object?>{
            'version': 3,
            'applied_at': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        if (oldVersion < 4) {
          await ensureWorkspaceV1Schema(
            execute: database.execute,
            rawQuery: database.rawQuery,
          );
          await database.insert('schema_migrations', <String, Object?>{
            'version': 4,
            'applied_at': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        if (oldVersion < 5) {
          await ensureWorkspaceConversationSchema(
            execute: database.execute,
            rawQuery: database.rawQuery,
          );
          await database.insert('schema_migrations', <String, Object?>{
            'version': 5,
            'applied_at': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        if (oldVersion < 6) {
          await ensureVoiceGeneratedTextSchema(
            execute: database.execute,
            rawQuery: database.rawQuery,
          );
          await database.insert('schema_migrations', <String, Object?>{
            'version': 6,
            'applied_at': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        if (oldVersion < 7) {
          await ensureVoiceAssetSourceSchema(
            execute: database.execute,
            rawQuery: database.rawQuery,
          );
          await database.insert('schema_migrations', <String, Object?>{
            'version': 7,
            'applied_at': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      },
      // Repair a previously interrupted v2 migration without deleting data.
      // All statements are idempotent, so complete databases remain unchanged.
      onOpen: (database) async {
        await ensureVoiceSchema(execute: database.execute);
        await ensureVoiceGeneratedTextSchema(
          execute: database.execute,
          rawQuery: database.rawQuery,
        );
        await ensureVoiceAssetSourceSchema(
          execute: database.execute,
          rawQuery: database.rawQuery,
        );
        await ensureConversationArchiveSchema(
          execute: database.execute,
          rawQuery: database.rawQuery,
        );
        await ensureWorkspaceV1Schema(
          execute: database.execute,
          rawQuery: database.rawQuery,
        );
        await ensureWorkspaceConversationSchema(
          execute: database.execute,
          rawQuery: database.rawQuery,
        );
      },
    );
    final preferences = await SharedPreferences.getInstance();
    var deviceId = preferences.getString('claudechat.device_id');
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = _uuid.v4();
      await preferences.setString('claudechat.device_id', deviceId);
    }
    final current = await db.query(
      'devices',
      where: 'id = ?',
      whereArgs: <Object?>[deviceId],
      limit: 1,
    );
    final now = DateTime.now().toUtc().toIso8601String();
    if (current.isEmpty) {
      await db.insert('devices', <String, Object?>{
        'id': deviceId,
        'label': Platform.localHostname.isEmpty
            ? 'ClaudeChat device'
            : Platform.localHostname,
        'platform': Platform.operatingSystem,
        'created_at': now,
        'last_seen_at': now,
      });
    } else {
      await db.update(
        'devices',
        <String, Object?>{'last_seen_at': now},
        where: 'id = ?',
        whereArgs: <Object?>[deviceId],
      );
    }
    return AppDatabase._(paths, db, deviceId);
  }

  Future<List<Conversation>> conversations({
    bool includeDeleted = false,
    bool includeArchived = false,
  }) async {
    final conditions = <String>[
      if (!includeDeleted) 'deleted_at IS NULL',
      if (!includeArchived) 'archived_at IS NULL',
    ];
    final rows = await database.query(
      'conversations',
      where: conditions.isEmpty ? null : conditions.join(' AND '),
      orderBy: 'is_starred DESC, updated_at DESC',
    );
    return rows.map(Conversation.fromMap).toList();
  }

  Future<List<Conversation>> archivedConversations() async {
    final rows = await database.query(
      'conversations',
      where: 'deleted_at IS NULL AND archived_at IS NOT NULL',
      orderBy: 'archived_at DESC, updated_at DESC',
    );
    return rows.map(Conversation.fromMap).toList();
  }

  Future<Conversation> createConversation({
    String title = '新的对话',
    String? modelId,
  }) async {
    final now = DateTime.now().toUtc();
    final value = Conversation(
      id: _uuid.v4(),
      title: title,
      modelId: modelId,
      createdAt: now,
      updatedAt: now,
      originDeviceId: deviceId,
    );
    await database.insert('conversations', value.toMap());
    return value;
  }

  Future<Conversation> branchConversation({
    required Conversation source,
    required List<ChatMessage> messages,
  }) async {
    final branch = await createConversation(
      title: '${source.title} · 分支',
      modelId: source.modelId,
    );
    await database.transaction((transaction) async {
      for (var index = 0; index < messages.length; index++) {
        final original = messages[index];
        final now = DateTime.now().toUtc();
        final copyId = _uuid.v4();
        await transaction.insert(
          'messages',
          ChatMessage(
            id: copyId,
            conversationId: branch.id,
            sequence: index + 1,
            role: original.role,
            content: original.content,
            status: original.status,
            error: original.error,
            metadataJson: original.metadataJson,
            createdAt: now,
            updatedAt: now,
            originDeviceId: deviceId,
          ).toMap(),
        );
        final references = await transaction.query(
          'attachment_references',
          where: "owner_type = 'message' AND owner_id = ?",
          whereArgs: <Object?>[original.id],
        );
        for (final reference in references) {
          await transaction.insert('attachment_references', <String, Object?>{
            'attachment_id': reference['attachment_id'],
            'owner_type': 'message',
            'owner_id': copyId,
            'position': reference['position'],
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        final parts = await transaction.query(
          'message_parts',
          where: 'message_id = ?',
          whereArgs: <Object?>[original.id],
          orderBy: 'sequence ASC',
        );
        for (final part in parts) {
          await transaction.insert('message_parts', <String, Object?>{
            'id': _uuid.v4(),
            'message_id': copyId,
            'sequence': part['sequence'],
            'type': part['type'],
            'content': part['content'],
            'metadata_json': part['metadata_json'],
            'created_at': now.toIso8601String(),
          });
        }
      }
    });
    return branch;
  }

  Future<void> saveConversation(Conversation value) => database.insert(
    'conversations',
    value.toMap(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<List<ChatMessage>> messages(
    String conversationId, {
    bool includeDeleted = false,
  }) async {
    final rows = await database.query(
      'messages',
      where: includeDeleted
          ? 'conversation_id = ?'
          : 'conversation_id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[conversationId],
      orderBy: 'sequence ASC, created_at ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<ChatMessage> appendMessage({
    required String conversationId,
    required String role,
    required String content,
    String status = 'complete',
    String? error,
    String metadataJson = '{}',
    List<MessagePartInput> parts = const <MessagePartInput>[],
  }) async {
    final maxRows = await database.rawQuery(
      'SELECT COALESCE(MAX(sequence), 0) AS value FROM messages WHERE conversation_id = ?',
      <Object?>[conversationId],
    );
    final now = DateTime.now().toUtc();
    final message = ChatMessage(
      id: _uuid.v4(),
      conversationId: conversationId,
      sequence: ((maxRows.first['value'] as num?)?.toInt() ?? 0) + 1,
      role: role,
      content: content,
      status: status,
      error: error,
      createdAt: now,
      updatedAt: now,
      originDeviceId: deviceId,
      metadataJson: metadataJson,
    );
    await database.transaction((transaction) async {
      await transaction.insert('messages', message.toMap());
      for (var index = 0; index < parts.length; index++) {
        final part = parts[index];
        await transaction.insert(
          'message_parts',
          MessagePart(
            id: _uuid.v4(),
            messageId: message.id,
            sequence: index + 1,
            type: part.type,
            content: part.content,
            metadataJson: canonicalJson(part.metadata),
            createdAt: now,
          ).toMap(),
        );
      }
      await transaction.update(
        'conversations',
        <String, Object?>{'updated_at': now.toIso8601String()},
        where: 'id = ?',
        whereArgs: <Object?>[conversationId],
      );
    });
    return message;
  }

  Future<List<MessagePart>> messageParts(String conversationId) async {
    final rows = await database.rawQuery(
      '''SELECT part.*
         FROM message_parts AS part
         INNER JOIN messages AS message ON message.id = part.message_id
         WHERE message.conversation_id = ? AND message.deleted_at IS NULL
         ORDER BY message.sequence ASC, part.sequence ASC''',
      <Object?>[conversationId],
    );
    return rows.map(MessagePart.fromMap).toList();
  }

  Future<void> updateMessage(ChatMessage value) => database.update(
    'messages',
    value.toMap(),
    where: 'id = ?',
    whereArgs: <Object?>[value.id],
  );

  Future<void> renameConversation(String id, String title) async {
    final rows = await database.query(
      'conversations',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await database.update(
      'conversations',
      <String, Object?>{
        'title': title.trim().isEmpty ? '新的对话' : title.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'revision': ((rows.first['revision'] as num?)?.toInt() ?? 0) + 1,
        'origin_device_id': deviceId,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> setConversationStarred(
    String id, {
    required bool starred,
  }) async {
    final rows = await database.query(
      'conversations',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await database.update(
      'conversations',
      <String, Object?>{
        'is_starred': starred ? 1 : 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'revision': ((rows.first['revision'] as num?)?.toInt() ?? 0) + 1,
        'origin_device_id': deviceId,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> setConversationArchived(
    String id, {
    required bool archived,
  }) async {
    final rows = await database.query(
      'conversations',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final now = DateTime.now().toUtc().toIso8601String();
    await database.update(
      'conversations',
      <String, Object?>{
        'archived_at': archived ? now : null,
        'updated_at': now,
        'revision': ((rows.first['revision'] as num?)?.toInt() ?? 0) + 1,
        'origin_device_id': deviceId,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> updateConversationSummary(
    String id, {
    required String? summary,
    required int summarizedMessageCount,
    required int summaryFoldCount,
  }) async {
    final rows = await database.query(
      'conversations',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await database.update(
      'conversations',
      <String, Object?>{
        'accumulated_summary': summary,
        'summarized_message_count': summarizedMessageCount,
        'summary_fold_count': summaryFoldCount,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'revision': ((rows.first['revision'] as num?)?.toInt() ?? 0) + 1,
        'origin_device_id': deviceId,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> replaceMessageContent(String id, String content) async {
    final rows = await database.query(
      'messages',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await database.update(
      'messages',
      <String, Object?>{
        'content': content,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'revision': ((rows.first['revision'] as num?)?.toInt() ?? 0) + 1,
        'origin_device_id': deviceId,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> deleteMessagesAfter(String conversationId, int sequence) async {
    final rows = await database.query(
      'messages',
      where: 'conversation_id = ? AND sequence > ?',
      whereArgs: <Object?>[conversationId, sequence],
    );
    for (final row in rows) {
      await softDelete('messages', row['id']! as String);
    }
  }

  Future<void> softDelete(String table, String id) async {
    if (!softDeleteTables.contains(table)) {
      throw ArgumentError.value(table, 'table');
    }
    final rows = await database.query(
      table,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final revision = ((rows.first['revision'] as num?)?.toInt() ?? 0) + 1;
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    await database.transaction((transaction) async {
      await transaction.update(
        table,
        <String, Object?>{
          'deleted_at': deletedAt,
          'revision': revision,
          'origin_device_id': deviceId,
        },
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      await transaction.insert('tombstones', <String, Object?>{
        'entity_type': table,
        'entity_id': id,
        'deleted_at': deletedAt,
        'revision': revision,
        'origin_device_id': deviceId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<List<Map<String, Object?>>> rows(String table) async {
    if (!exportedTables.contains(table))
      throw ArgumentError.value(table, 'table');
    return database.query(table);
  }

  Future<void> close() => database.close();
}

const List<String> exportedTables = <String>[
  'devices',
  'settings',
  'api_profiles',
  'conversations',
  'messages',
  'message_parts',
  'memories',
  'diary_entries',
  'diary_versions',
  'user_files',
  'file_versions',
  'workspaces',
  'workspace_files',
  'workspace_conversations',
  'workspace_messages',
  'workspace_message_parts',
  'workspace_commits',
  'workspace_commit_files',
  'attachments',
  'attachment_references',
  'reminders',
  'platform_bindings',
  'tombstones',
  'entity_revisions',
  'voice_profiles',
  'voice_assets',
];
