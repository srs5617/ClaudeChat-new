import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../domain/entities.dart';
import 'settings_service.dart';
import 'brand_service.dart';
import 'legacy_model_mapper.dart';

const _uuid = Uuid();

bool legacyRowsEqual(
  Map<String, Object?> left,
  Map<String, Object?> right,
  Iterable<String> fields,
) =>
    canonicalJson(<String, Object?>{
      for (final field in fields) field: left[field],
    }) ==
    canonicalJson(<String, Object?>{
      for (final field in fields) field: right[field],
    });

class LegacyImportService {
  LegacyImportService(this.store, this.settings, this.brand);

  final AppDatabase store;
  final SettingsService settings;
  final BrandService brand;

  bool recognizes(List<int> bytes) {
    try {
      final root = jsonDecode(utf8.decode(bytes));
      return root is Map &&
          (root.containsKey('conversations') ||
              root.containsKey('conversation') ||
              root.containsKey('memories'));
    } on FormatException {
      return false;
    }
  }

  Future<ImportReport> import(List<int> bytes) async {
    final root = (jsonDecode(utf8.decode(bytes)) as Map)
        .cast<String, Object?>();
    final report = ImportReport();
    await store.database.transaction((transaction) async {
      final rawConversations = <Object?>[
        ...?root['conversations'] as List?,
        if (root['conversation'] != null) root['conversation'],
      ];
      for (final value in rawConversations.whereType<Map>()) {
        final source = value.cast<String, Object?>();
        if (source['isDraft'] == true) continue;
        final id = _string(source['id'], fallback: _uuid.v4());
        final created = _date(source['createdAt']);
        final updated = _date(source['updatedAt'], fallback: created);
        final conversation = Conversation(
          id: id,
          title: _string(source['title'], fallback: '新的对话'),
          modelId: _nullable(source['modelId']),
          starred: source['starred'] == true,
          accumulatedSummary: _nullable(source['accumulatedSummary']),
          summarizedMessageCount: _integer(source['summarizedMessageCount']),
          summaryFoldCount: _integer(source['summaryFoldCount']),
          createdAt: created,
          updatedAt: updated,
          originDeviceId: store.deviceId,
        );
        final incomingConversation = conversation.toMap();
        final exists = await transaction.query(
          'conversations',
          where: 'id = ?',
          whereArgs: <Object?>[id],
          limit: 1,
        );
        if (exists.isEmpty) {
          await transaction.insert('conversations', incomingConversation);
          report.added++;
        } else {
          final local = exists.first;
          const fields = <String>[
            'title',
            'model_id',
            'is_starred',
            'accumulated_summary',
            'summarized_message_count',
            'summary_fold_count',
            'created_at',
            'updated_at',
          ];
          if (local['deleted_at'] == null &&
              legacyRowsEqual(local, incomingConversation, fields)) {
            report.skipped++;
          } else {
            incomingConversation['deleted_at'] = null;
            incomingConversation['revision'] =
                ((local['revision'] as num?)?.toInt() ?? 0) + 1;
            incomingConversation['origin_device_id'] = store.deviceId;
            await transaction.update(
              'conversations',
              incomingConversation,
              where: 'id = ?',
              whereArgs: <Object?>[id],
            );
            await _clearTombstone(transaction, 'conversations', id);
            report.updated++;
          }
        }
        var sequence = 0;
        for (final item
            in (source['messages'] as List? ?? const <Object?>[])
                .whereType<Map>()) {
          final message = item.cast<String, Object?>();
          final messageId = _string(message['id'], fallback: _uuid.v4());
          sequence++;
          final legacyReasoning = _legacyReasoningSource(message);
          final importedMetadata = <String, Object?>{
            'thoughts': ?legacyReasoning,
            if (message['toolCallsResults'] != null)
              'toolCallsResults': message['toolCallsResults'],
            if (message['_images'] != null) 'legacyImages': message['_images'],
            if (message['editedAt'] != null) 'editedAt': message['editedAt'],
          };
          final incomingMessage = ChatMessage(
            id: messageId,
            conversationId: id,
            sequence: sequence,
            role: _string(message['role'], fallback: 'user'),
            content: _legacyContent(message['content']),
            status: message['error'] == null ? 'complete' : 'error',
            error: _nullable(message['error']),
            metadataJson: canonicalJson(importedMetadata),
            createdAt: _date(
              message['createdAt'],
              fallback: created.add(Duration(milliseconds: sequence)),
            ),
            updatedAt: _nullableDate(message['editedAt']),
            originDeviceId: store.deviceId,
          ).toMap();
          final partRows = buildLegacyMessageParts(
            message,
            messageId,
            DateTime.parse(incomingMessage['created_at']! as String),
          );
          final found = await transaction.query(
            'messages',
            where: 'id = ?',
            whereArgs: <Object?>[messageId],
            limit: 1,
          );
          if (found.isEmpty) {
            await transaction.insert('messages', incomingMessage);
            await _replaceMessageParts(transaction, messageId, partRows);
            await _mergeLegacyImages(
              transaction,
              conversationId: id,
              messageId: messageId,
              raw: message['_images'] ?? message['images'],
            );
            report.added++;
            continue;
          }
          final local = found.first;
          const messageFields = <String>[
            'conversation_id',
            'sequence',
            'role',
            'content',
            'status',
            'error',
          ];
          final localMetadata = _jsonMap(local['metadata_json']);
          final sameLegacyMetadata =
              canonicalJson(<String, Object?>{
                for (final key in const <String>[
                  'thoughts',
                  'toolCallsResults',
                  'legacyImages',
                  'editedAt',
                ])
                  if (localMetadata.containsKey(key)) key: localMetadata[key],
              }) ==
              canonicalJson(importedMetadata);
          final localParts = await transaction.query(
            'message_parts',
            where: 'message_id = ?',
            whereArgs: <Object?>[messageId],
            orderBy: 'sequence ASC',
          );
          final sameParts = _sameMessageParts(localParts, partRows);
          final imagesChanged = await _mergeLegacyImages(
            transaction,
            conversationId: id,
            messageId: messageId,
            raw: message['_images'] ?? message['images'],
          );
          if (local['deleted_at'] == null &&
              legacyRowsEqual(local, incomingMessage, messageFields) &&
              sameLegacyMetadata &&
              sameParts &&
              !imagesChanged) {
            report.skipped++;
            continue;
          }
          for (final key in const <String>[
            'thoughts',
            'legacyImages',
            'editedAt',
          ]) {
            localMetadata.remove(key);
          }
          localMetadata.addAll(importedMetadata);
          incomingMessage['metadata_json'] = canonicalJson(localMetadata);
          incomingMessage['updated_at'] =
              _nullableDate(message['editedAt'])?.toIso8601String() ??
              DateTime.now().toUtc().toIso8601String();
          incomingMessage['deleted_at'] = null;
          incomingMessage['revision'] =
              ((local['revision'] as num?)?.toInt() ?? 0) + 1;
          incomingMessage['origin_device_id'] = store.deviceId;
          await transaction.update(
            'messages',
            incomingMessage,
            where: 'id = ?',
            whereArgs: <Object?>[messageId],
          );
          await _replaceMessageParts(transaction, messageId, partRows);
          await _clearTombstone(transaction, 'messages', messageId);
          report.updated++;
        }
      }
      for (final value
          in (root['memories'] as List? ?? const <Object?>[])
              .whereType<Map>()) {
        final source = value.cast<String, Object?>();
        final id = _string(source['id'], fallback: _uuid.v4());
        final found = await transaction.query(
          'memories',
          where: 'id = ?',
          whereArgs: <Object?>[id],
          limit: 1,
        );
        final created = _date(source['createdAt']);
        final incomingMemory = MemoryEntry(
          id: id,
          content: _string(source['content']),
          level: _string(source['level'], fallback: 'daily'),
          tags: _strings(source['tags']),
          source: _string(
            source['source'] ?? source['origin'],
            fallback: 'user',
          ),
          sourceConversationId: _nullable(source['sourceConversationId']),
          lastAccessedAt: _nullableDate(
            source['last_accessed'] ?? source['lastUsedAt'],
          ),
          useFrequency: _integer(source['use_frequency'] ?? source['useCount']),
          createdAt: created,
          updatedAt: _date(source['updatedAt'], fallback: created),
          deletedAt: _nullableDate(source['deletedAt']),
          deleteReason: _nullable(source['deleteReason']),
          originDeviceId: store.deviceId,
        ).toMap();
        if (found.isEmpty) {
          await transaction.insert('memories', incomingMemory);
          report.added++;
        } else {
          final local = found.first;
          const fields = <String>[
            'content',
            'level',
            'tags_json',
            'source',
            'source_conversation_id',
            'last_accessed_at',
            'use_frequency',
            'created_at',
            'updated_at',
            'deleted_at',
            'delete_reason',
          ];
          if (legacyRowsEqual(local, incomingMemory, fields)) {
            report.skipped++;
          } else {
            incomingMemory['revision'] =
                ((local['revision'] as num?)?.toInt() ?? 0) + 1;
            incomingMemory['origin_device_id'] = store.deviceId;
            await transaction.update(
              'memories',
              incomingMemory,
              where: 'id = ?',
              whereArgs: <Object?>[id],
            );
            if (incomingMemory['deleted_at'] == null) {
              await _clearTombstone(transaction, 'memories', id);
            }
            report.updated++;
          }
        }
        await _syncLegacyTombstone(transaction, 'memories', id);
      }
      for (final value
          in (root['diaryEntries'] as List? ?? const <Object?>[])
              .whereType<Map>()) {
        final source = value.cast<String, Object?>();
        final id = _string(source['id'], fallback: _uuid.v4());
        final found = await transaction.query(
          'diary_entries',
          where: 'id = ?',
          whereArgs: <Object?>[id],
          limit: 1,
        );
        final created = _date(source['createdAt']);
        final status = _string(source['status'], fallback: 'active');
        final updated = _date(source['updatedAt'], fallback: created);
        final incomingDiary = DiaryEntry(
          id: id,
          title: _string(source['title'], fallback: '未命名日记'),
          status: status,
          tags: _strings(source['tags']),
          mood: _nullable(source['mood']),
          latestVersionId: _nullable(source['latestVersionId']),
          sourceConversationId: _nullable(source['sourceConversationId']),
          createdAt: created,
          updatedAt: updated,
          deletedAt:
              _nullableDate(source['deletedAt']) ??
              (status == 'deleted' ? updated : null),
          deleteReason: _nullable(source['deleteReason']),
          originDeviceId: store.deviceId,
        ).toMap();
        if (found.isEmpty) {
          await transaction.insert('diary_entries', incomingDiary);
          report.added++;
        } else {
          final local = found.first;
          const fields = <String>[
            'title',
            'status',
            'mood',
            'tags_json',
            'latest_version_id',
            'source_conversation_id',
            'created_at',
            'updated_at',
            'deleted_at',
            'delete_reason',
          ];
          if (legacyRowsEqual(local, incomingDiary, fields)) {
            report.skipped++;
          } else {
            incomingDiary['revision'] =
                ((local['revision'] as num?)?.toInt() ?? 0) + 1;
            incomingDiary['origin_device_id'] = store.deviceId;
            await transaction.update(
              'diary_entries',
              incomingDiary,
              where: 'id = ?',
              whereArgs: <Object?>[id],
            );
            if (incomingDiary['deleted_at'] == null) {
              await _clearTombstone(transaction, 'diary_entries', id);
            }
            report.updated++;
          }
        }
        await _syncLegacyTombstone(transaction, 'diary_entries', id);
      }
      for (final value
          in (root['diaryVersions'] as List? ?? const <Object?>[])
              .whereType<Map>()) {
        final source = value.cast<String, Object?>();
        final id = _string(source['id'], fallback: _uuid.v4());
        final found = await transaction.query(
          'diary_versions',
          where: 'id = ?',
          whereArgs: <Object?>[id],
          limit: 1,
        );
        final incomingVersion = DiaryVersion(
          id: id,
          diaryId: _string(source['diaryId']),
          title: _string(source['title']),
          content: _string(source['content']),
          operation: _string(source['operation'], fallback: 'revise'),
          tags: _strings(source['tags']),
          reason: _nullable(source['reason']),
          mood: _nullable(source['mood']),
          sourceConversationId: _nullable(source['sourceConversationId']),
          createdAt: _date(source['createdAt']),
          originDeviceId: store.deviceId,
        ).toMap();
        if (found.isEmpty) {
          await transaction.insert('diary_versions', incomingVersion);
          report.added++;
          continue;
        }
        const versionFields = <String>[
          'diary_id',
          'title',
          'content',
          'operation',
          'reason',
          'mood',
          'tags_json',
          'source_conversation_id',
          'created_at',
        ];
        if (legacyRowsEqual(found.first, incomingVersion, versionFields)) {
          report.skipped++;
          continue;
        }
        await transaction.update(
          'diary_versions',
          incomingVersion,
          where: 'id = ?',
          whereArgs: <Object?>[id],
        );
        report.updated++;
      }
      await _legacyFiles(transaction, root['userFiles'], report);
      await _legacyWorkspaces(transaction, root['workspaces'], report);
    });
    final rawSettings = root['settings'];
    if (rawSettings is Map) {
      final mapped = rawSettings.cast<String, Object?>();
      await _importSettings(mapped);
      await brand.importLegacyAssets(mapped);
    }
    return report;
  }

  Future<void> _legacyFiles(
    Transaction transaction,
    Object? raw,
    ImportReport report,
  ) async {
    for (final value in (raw as List? ?? const <Object?>[]).whereType<Map>()) {
      final source = value.cast<String, Object?>();
      final id = _string(source['id'], fallback: _uuid.v4());
      final created = _date(source['createdAt']);
      final updated = _date(source['updatedAt'], fallback: created);
      final content = _string(source['content']);
      final type = _string(source['type'], fallback: 'text');
      final contentBytes = utf8.encode(content);
      final contentDigest = (await Sha256().hash(
        contentBytes,
      )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      final currentVersionId =
          'legacy-current-$id-${contentDigest.substring(0, 16)}';
      final found = await transaction.query(
        'user_files',
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      final status = _string(source['status'], fallback: 'active');
      final deletedAt = status == 'deleted'
          ? (_nullableDate(source['deletedAt']) ?? updated)
          : null;
      final incoming = <String, Object?>{
        'id': id,
        'name': _string(source['name'], fallback: 'untitled.txt'),
        'type': type,
        'status': status,
        'current_version_id': currentVersionId,
        'created_at': created.toIso8601String(),
        'updated_at': updated.toIso8601String(),
        'deleted_at': deletedAt?.toIso8601String(),
        'delete_reason': _nullable(source['deleteReason']),
        'revision': found.isEmpty
            ? 1
            : ((found.first['revision'] as num?)?.toInt() ?? 0) + 1,
        'origin_device_id': store.deviceId,
      };
      if (found.isEmpty) {
        // Establish the parent row before inserting its version rows so
        // foreign-key checking remains enabled during import.
        await transaction.insert('user_files', incoming);
      }
      var versionChanged = await _writeLegacyFileVersion(
        transaction: transaction,
        fileId: id,
        versionId: currentVersionId,
        content: content,
        type: type,
        reason: '从旧版当前内容导入',
        createdAt: updated,
      );
      for (final item
          in (source['versions'] as List? ?? const <Object?>[])
              .whereType<Map>()) {
        final version = item.cast<String, Object?>();
        versionChanged =
            await _writeLegacyFileVersion(
              transaction: transaction,
              fileId: id,
              versionId: _string(version['id'], fallback: _uuid.v4()),
              content: _string(version['content']),
              type: _string(version['type'], fallback: type),
              reason: _string(version['reason'], fallback: '从旧版历史版本导入'),
              createdAt: _date(version['createdAt'], fallback: created),
            ) ||
            versionChanged;
      }
      if (found.isEmpty) {
        report.added++;
      } else {
        final local = found.first;
        const fields = <String>[
          'name',
          'type',
          'status',
          'current_version_id',
          'created_at',
          'updated_at',
          'deleted_at',
          'delete_reason',
        ];
        if (!versionChanged && legacyRowsEqual(local, incoming, fields)) {
          report.skipped++;
        } else {
          await transaction.update(
            'user_files',
            incoming,
            where: 'id = ?',
            whereArgs: <Object?>[id],
          );
          report.updated++;
        }
      }
      if (deletedAt == null) {
        await _clearTombstone(transaction, 'user_files', id);
      } else {
        await transaction.insert('tombstones', <String, Object?>{
          'entity_type': 'user_files',
          'entity_id': id,
          'deleted_at': deletedAt.toIso8601String(),
          'revision': incoming['revision'],
          'origin_device_id': store.deviceId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }

  Future<bool> _writeLegacyFileVersion({
    required Transaction transaction,
    required String fileId,
    required String versionId,
    required String content,
    required String type,
    required String reason,
    required DateTime createdAt,
  }) async {
    final bytes = utf8.encode(content);
    final digest = (await Sha256().hash(
      bytes,
    )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final relativePath = '$fileId/$versionId.txt';
    final found = await transaction.query(
      'file_versions',
      where: 'id = ?',
      whereArgs: <Object?>[versionId],
      limit: 1,
    );
    final incoming = <String, Object?>{
      'id': versionId,
      'file_id': fileId,
      'relative_path': relativePath,
      'content_sha256': digest,
      'byte_size': bytes.length,
      'type': type,
      'reason': reason,
      'created_at': createdAt.toUtc().toIso8601String(),
      'origin_device_id': store.deviceId,
    };
    const fields = <String>[
      'file_id',
      'relative_path',
      'content_sha256',
      'byte_size',
      'type',
      'reason',
      'created_at',
    ];
    final changed =
        found.isEmpty || !legacyRowsEqual(found.first, incoming, fields);
    if (!changed) return false;
    final output = File(
      '${store.paths.files.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
    );
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes, flush: true);
    await transaction.insert(
      'file_versions',
      incoming,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return true;
  }

  Future<void> _legacyWorkspaces(
    Transaction transaction,
    Object? raw,
    ImportReport report,
  ) async {
    for (final value in (raw as List? ?? const <Object?>[]).whereType<Map>()) {
      final source = value.cast<String, Object?>();
      final id = _string(source['id'], fallback: _uuid.v4());
      final found = await transaction.query(
        'workspaces',
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      final created = _date(source['createdAt']);
      final incomingWorkspace = <String, Object?>{
        'id': id,
        'name': _string(source['name'], fallback: '我的工作区'),
        'created_at': created.toIso8601String(),
        'updated_at': _date(
          source['updatedAt'],
          fallback: created,
        ).toIso8601String(),
        'deleted_at': null,
        'revision': 1,
        'origin_device_id': store.deviceId,
      };
      var workspaceChanged = found.isEmpty;
      if (found.isEmpty) {
        await transaction.insert('workspaces', incomingWorkspace);
      } else {
        const fields = <String>[
          'name',
          'created_at',
          'updated_at',
          'deleted_at',
        ];
        if (!legacyRowsEqual(found.first, incomingWorkspace, fields)) {
          incomingWorkspace['revision'] =
              ((found.first['revision'] as num?)?.toInt() ?? 0) + 1;
          await transaction.update(
            'workspaces',
            incomingWorkspace,
            where: 'id = ?',
            whereArgs: <Object?>[id],
          );
          workspaceChanged = true;
        }
      }
      await _clearTombstone(transaction, 'workspaces', id);
      var sequence = 0;
      for (final item
          in (source['messages'] as List? ?? const <Object?>[])
              .whereType<Map>()) {
        final message = item.cast<String, Object?>();
        sequence++;
        final messageId = _string(message['id'], fallback: _uuid.v4());
        final incomingMessage = <String, Object?>{
          'id': messageId,
          'workspace_id': id,
          'sequence': sequence,
          'role': _string(message['role'], fallback: 'user'),
          'content': _legacyContent(message['content']),
          'created_at': _date(
            message['createdAt'],
            fallback: created.add(Duration(milliseconds: sequence)),
          ).toIso8601String(),
          'revision': 1,
          'origin_device_id': store.deviceId,
        };
        final existingMessage = await transaction.query(
          'workspace_messages',
          where: 'id = ?',
          whereArgs: <Object?>[messageId],
          limit: 1,
        );
        if (existingMessage.isEmpty) {
          await transaction.insert('workspace_messages', incomingMessage);
          workspaceChanged = true;
        } else {
          const fields = <String>[
            'workspace_id',
            'sequence',
            'role',
            'content',
            'created_at',
          ];
          if (!legacyRowsEqual(
            existingMessage.first,
            incomingMessage,
            fields,
          )) {
            incomingMessage['revision'] =
                ((existingMessage.first['revision'] as num?)?.toInt() ?? 0) + 1;
            await transaction.update(
              'workspace_messages',
              incomingMessage,
              where: 'id = ?',
              whereArgs: <Object?>[messageId],
            );
            workspaceChanged = true;
          }
        }
      }
      for (final item
          in (source['files'] as List? ?? const <Object?>[]).whereType<Map>()) {
        final file = item.cast<String, Object?>();
        final fileId = _string(file['id'], fallback: _uuid.v4());
        final content = _string(file['content']);
        final relativePath = '$id/$fileId.txt';
        final bytes = utf8.encode(content);
        final digest = (await Sha256().hash(
          bytes,
        )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
        final createdAt = _date(
          file['createdAt'],
          fallback: created,
        ).toIso8601String();
        final incomingFile = <String, Object?>{
          'id': fileId,
          'workspace_id': id,
          'name': _string(file['name'], fallback: 'untitled.txt'),
          'type': _string(file['type'], fallback: 'text'),
          'relative_path': 'workspaces/$relativePath',
          'sha256': digest,
          'created_at': createdAt,
          'updated_at': _date(
            file['updatedAt'],
            fallback: DateTime.parse(createdAt),
          ).toIso8601String(),
          'revision': 1,
          'origin_device_id': store.deviceId,
        };
        final existingFile = await transaction.query(
          'workspace_files',
          where: 'id = ?',
          whereArgs: <Object?>[fileId],
          limit: 1,
        );
        const fields = <String>[
          'workspace_id',
          'name',
          'type',
          'relative_path',
          'sha256',
          'created_at',
          'updated_at',
        ];
        final changed =
            existingFile.isEmpty ||
            !legacyRowsEqual(existingFile.first, incomingFile, fields);
        if (!changed) continue;
        final output = File(
          '${store.paths.files.path}${Platform.pathSeparator}workspaces${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes, flush: true);
        if (existingFile.isEmpty) {
          await transaction.insert('workspace_files', incomingFile);
        } else {
          incomingFile['revision'] =
              ((existingFile.first['revision'] as num?)?.toInt() ?? 0) + 1;
          await transaction.update(
            'workspace_files',
            incomingFile,
            where: 'id = ?',
            whereArgs: <Object?>[fileId],
          );
        }
        workspaceChanged = true;
      }
      if (found.isEmpty) {
        report.added++;
      } else if (workspaceChanged) {
        report.updated++;
      } else {
        report.skipped++;
      }
    }
  }

  Future<void> _importSettings(Map<String, Object?> source) async {
    const allowed = <String>{
      'appName',
      'profileName',
      'profileNote',
      'greeting',
      'theme',
      'fontFamily',
      'fontSize',
      'codeFoldLines',
      'language',
      'systemPrompt',
      'thinking',
      'toolboxEnabled',
      'toolOverrides',
      'webSearchEnabled',
      'fetchUrlEnabled',
      'showAssistantAvatar',
      'showUserAvatar',
      'tokenEstimateRatio',
      'diaryViewMode',
      'splashPhrases',
      'splashRandom',
    };
    for (final entry in source.entries) {
      if (allowed.contains(entry.key))
        await settings.set(
          entry.key == 'theme' ? 'themeMode' : entry.key,
          entry.value,
        );
    }
    final legacyModels = (source['models'] as List? ?? const <Object?>[])
        .whereType<Map>()
        .map((item) => item.cast<String, Object?>())
        .toList();
    final profiles = source['apiProfiles'];
    if (profiles is List) {
      for (final value in profiles.whereType<Map>()) {
        final profile = value.cast<String, Object?>();
        final headers = _headers(profile['customHeaders']);
        final profileId = _nullable(profile['id']);
        final fetchedModels = (profile['models'] as List? ?? const <Object?>[])
            .map(
              (model) => model is Map
                  ? '${model['id'] ?? model['apiName'] ?? ''}'
                  : '$model',
            )
            .where((value) => value.isNotEmpty)
            .toList();
        final configuredModels = legacyModels
            .where(
              (model) =>
                  _string(model['apiProfileId']) == (profileId ?? '') &&
                  _string(model['apiName']).isNotEmpty,
            )
            .map((model) => _string(model['apiName']));
        await settings.saveProfile(
          id: profileId,
          name: _string(profile['name'], fallback: '导入的接口'),
          endpoint: _string(profile['endpoint']),
          apiKey: _string(profile['apiKey']),
          models: <String>{...fetchedModels, ...configuredModels}.toList(),
          customHeaders: headers,
          active: source['activeApiId'] == profile['id'],
        );
      }
    }
    if (legacyModels.isNotEmpty) {
      final mapping = mapLegacyModels(legacyModels, source['activeModelId']);
      await settings.set('modelConfigs', mapping.configs);
      await settings.set('modelSlots', mapping.slots);
      if (mapping.activeSlotId != null) {
        await settings.set('activeModelSlotId', mapping.activeSlotId);
      }
      if (mapping.activeApiModel != null) {
        await settings.set('activeModelId', mapping.activeApiModel);
      }
    } else {
      final active = _string(source['activeModelId']);
      if (active.isNotEmpty) await settings.set('activeModelId', active);
    }
  }

  Map<String, String> _headers(Object? raw) {
    if (raw is Map) return raw.map((key, value) => MapEntry('$key', '$value'));
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        return (jsonDecode(raw) as Map).map(
          (key, value) => MapEntry('$key', '$value'),
        );
      } on Object {
        return const <String, String>{};
      }
    }
    return const <String, String>{};
  }

  List<Map<String, Object?>> buildLegacyMessageParts(
    Map<String, Object?> message,
    String messageId,
    DateTime createdAt,
  ) {
    final inputs = <Map<String, Object?>>[];
    final statuses = (message['_statusCapsules'] as List? ?? const <Object?>[])
        .whereType<Map>()
        .map((item) => item.cast<String, Object?>())
        .toList();
    void addStatus(Map<String, Object?> status) {
      inputs.add(<String, Object?>{
        'type': 'status',
        'content': null,
        'metadata': <String, Object?>{
          'status': _string(status['type']),
          if (_string(status['detail']).isNotEmpty)
            'detail': _string(status['detail']),
        },
      });
    }

    for (final status in statuses.where(
      (item) => item['type'] == 'sent' || item['type'] == 'replying',
    )) {
      addStatus(status);
    }
    final rawParts = (message['parts'] as List? ?? const <Object?>[])
        .whereType<Map>()
        .map((item) => item.cast<String, Object?>())
        .toList();
    final hasToolPart = rawParts.any((part) => _string(part['type']) == 'tool');
    if (!hasToolPart && message['role'] == 'assistant') {
      for (final item
          in (message['toolCallsResults'] as List? ?? const <Object?>[])
              .whereType<Map>()) {
        inputs.add(_legacyToolInput(item.cast<String, Object?>()));
      }
    }
    if (rawParts.isNotEmpty) {
      for (final part in rawParts) {
        final type = _string(part['type'], fallback: 'content').toLowerCase();
        if (type == 'tool') {
          final item = part['item'] is Map
              ? (part['item']! as Map).cast<String, Object?>()
              : part;
          inputs.add(_legacyToolInput(item));
        } else if (type == 'status') {
          final item = part['item'] is Map
              ? (part['item']! as Map).cast<String, Object?>()
              : part;
          addStatus(item);
        } else {
          final normalizedType =
              const <String>{
                'thought',
                'thinking',
                'reasoning',
                'analysis',
              }.contains(type)
              ? 'thought'
              : 'content';
          inputs.add(<String, Object?>{
            'type': normalizedType,
            'content': _string(
              part['content'] ??
                  part['text'] ??
                  part['reasoning'] ??
                  part['analysis'] ??
                  part['thinking'],
            ),
            'metadata': const <String, Object?>{},
          });
        }
      }
    }
    if (message['role'] == 'assistant') {
      final importedThoughts = inputs
          .where((item) => item['type'] == 'thought')
          .map((item) => _string(item['content']).trim())
          .where((value) => value.isNotEmpty)
          .toSet();
      final missingThoughts = <Map<String, Object?>>[];
      for (final thought in _legacyReasoningValues(message)) {
        if (!importedThoughts.add(thought.trim())) continue;
        missingThoughts.add(<String, Object?>{
          'type': 'thought',
          'content': thought,
          'metadata': const <String, Object?>{},
        });
      }
      if (missingThoughts.isNotEmpty) {
        final firstContent = inputs.indexWhere(
          (item) => item['type'] == 'content',
        );
        inputs.insertAll(
          firstContent < 0 ? inputs.length : firstContent,
          missingThoughts,
        );
      }
    }
    final fallbackContent = _legacyContent(message['content']);
    if (message['role'] == 'assistant' &&
        fallbackContent.isNotEmpty &&
        !inputs.any((item) => item['type'] == 'content')) {
      inputs.add(<String, Object?>{
        'type': 'content',
        'content': fallbackContent,
        'metadata': const <String, Object?>{},
      });
    }
    for (final status in statuses.where(
      (item) => item['type'] != 'sent' && item['type'] != 'replying',
    )) {
      addStatus(status);
    }
    return inputs.indexed
        .map(
          (entry) => <String, Object?>{
            'id': '$messageId-import-part-${entry.$1 + 1}',
            'message_id': messageId,
            'sequence': entry.$1 + 1,
            'type': entry.$2['type'],
            'content': entry.$2['content'],
            'metadata_json': canonicalJson(
              (entry.$2['metadata']! as Map).cast<String, Object?>(),
            ),
            'created_at': createdAt.toUtc().toIso8601String(),
          },
        )
        .toList();
  }

  Map<String, Object?> _legacyToolInput(Map<String, Object?> item) {
    final result =
        item['result'] ??
        (item['error'] == null
            ? <String, Object?>{}
            : <String, Object?>{'error': item['error']});
    return <String, Object?>{
      'type': 'tool',
      'content': jsonEncode(
        result is Map ? canonicalize(result.cast<String, Object?>()) : result,
      ),
      'metadata': <String, Object?>{
        'callId': _string(item['id'], fallback: _uuid.v4()),
        'name': _string(item['name'], fallback: 'tool'),
        'arguments': item['arg'] is Map
            ? item['arg']
            : item['arguments'] is Map
            ? item['arguments']
            : <String, Object?>{},
        'status': switch ('${item['status'] ?? ''}') {
          'done' || 'success' => 'success',
          'denied' => 'denied',
          'pending_approval' => 'pending_approval',
          _ => 'error',
        },
      },
    };
  }

  Object? _legacyReasoningSource(Map<String, Object?> message) {
    for (final key in const <String>[
      'thoughts',
      'reasoning',
      'reasoning_content',
      'reasoningContent',
      'reasoning_text',
      'reasoningText',
      'analysis_content',
      'analysisContent',
      'analysis',
      'thinking',
      'thought',
    ]) {
      final value = message[key];
      if (_reasoningStrings(value).isNotEmpty) return value;
    }
    final legacy = message['legacy'];
    if (legacy is Map) {
      return _legacyReasoningSource(legacy.cast<String, Object?>());
    }
    return null;
  }

  List<String> _legacyReasoningValues(Map<String, Object?> message) {
    final values = <String>[];
    final source = _legacyReasoningSource(message);
    values.addAll(_reasoningStrings(source));
    final rawParts = message['parts'];
    if (rawParts is List) {
      for (final raw in rawParts.whereType<Map>()) {
        final part = raw.cast<String, Object?>();
        final type = _string(part['type']).toLowerCase();
        if (!const <String>{
          'thought',
          'thinking',
          'reasoning',
          'analysis',
        }.contains(type)) {
          continue;
        }
        values.addAll(
          _reasoningStrings(
            part['content'] ??
                part['text'] ??
                part['reasoning'] ??
                part['analysis'] ??
                part['thinking'],
          ),
        );
      }
    }
    return values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
  }

  List<String> _reasoningStrings(Object? raw) {
    if (raw is String) return raw.trim().isEmpty ? const [] : <String>[raw];
    if (raw is! List) {
      if (raw is Map) {
        final item = raw.cast<String, Object?>();
        return _reasoningStrings(
          item['content'] ??
              item['text'] ??
              item['reasoning'] ??
              item['analysis'] ??
              item['thinking'],
        );
      }
      return const <String>[];
    }
    return raw.expand<String>(_reasoningStrings).toList();
  }

  /// Repairs packages produced by older exporters that preserved legacy
  /// `toolCallsResults` in message metadata but did not create message_parts.
  /// The operation is idempotent and never replaces an already migrated tool
  /// capsule.
  Future<int> repairLegacyToolParts() async {
    final rows = await store.database.query(
      'messages',
      where: 'role = ?',
      whereArgs: const <Object?>['assistant'],
      orderBy: 'created_at ASC, id ASC',
    );
    var repaired = 0;
    for (final row in rows) {
      final messageId = _string(row['id']);
      final metadata = _jsonMap(row['metadata_json']);
      final legacy = metadata['legacy'] is Map
          ? (metadata['legacy']! as Map).cast<String, Object?>()
          : metadata;
      final legacyResults =
          legacy['toolCallsResults'] ?? metadata['toolCallsResults'];
      if (legacyResults is! List || legacyResults.whereType<Map>().isEmpty) {
        continue;
      }
      final existing = await store.database.query(
        'message_parts',
        where: 'message_id = ?',
        whereArgs: <Object?>[messageId],
        orderBy: 'sequence ASC, id ASC',
      );
      if (existing.any((part) => part['type'] == 'tool')) continue;
      final createdAt = _date(row['created_at']);
      if (existing.isEmpty) {
        final rebuilt = buildLegacyMessageParts(
          <String, Object?>{
            ...legacy,
            'role': row['role'],
            'content': row['content'],
            'toolCallsResults': legacyResults,
          },
          messageId,
          createdAt,
        );
        await store.database.transaction(
          (transaction) =>
              _replaceMessageParts(transaction, messageId, rebuilt),
        );
        repaired++;
        continue;
      }
      final toolRows = legacyResults
          .whereType<Map>()
          .map((item) => _legacyToolInput(item.cast<String, Object?>()))
          .toList();
      var insertAt = 0;
      while (insertAt < existing.length &&
          existing[insertAt]['type'] == 'status') {
        final status = _jsonMap(existing[insertAt]['metadata_json'])['status'];
        if (status != 'sent' && status != 'replying') break;
        insertAt++;
      }
      final combined = <Map<String, Object?>>[
        ...existing.take(insertAt),
        ...toolRows.indexed.map(
          (entry) => <String, Object?>{
            'id': '$messageId-legacy-tool-${entry.$1 + 1}',
            'message_id': messageId,
            'type': entry.$2['type'],
            'content': entry.$2['content'],
            'metadata_json': canonicalJson(
              (entry.$2['metadata']! as Map).cast<String, Object?>(),
            ),
            'created_at': createdAt.toUtc().toIso8601String(),
          },
        ),
        ...existing.skip(insertAt),
      ];
      final resequenced = combined.indexed
          .map(
            (entry) => <String, Object?>{...entry.$2, 'sequence': entry.$1 + 1},
          )
          .toList();
      await store.database.transaction(
        (transaction) =>
            _replaceMessageParts(transaction, messageId, resequenced),
      );
      repaired++;
    }
    return repaired;
  }

  bool _sameMessageParts(
    List<Map<String, Object?>> local,
    List<Map<String, Object?>> incoming,
  ) {
    Map<String, Object?> selected(Map<String, Object?> row) =>
        <String, Object?>{
          'sequence': row['sequence'],
          'type': row['type'],
          'content': row['content'],
          'metadata_json': row['metadata_json'],
        };
    return canonicalJson(<String, Object?>{
          'parts': local.map(selected).toList(),
        }) ==
        canonicalJson(<String, Object?>{
          'parts': incoming.map(selected).toList(),
        });
  }

  Future<void> _replaceMessageParts(
    Transaction transaction,
    String messageId,
    List<Map<String, Object?>> parts,
  ) async {
    await transaction.delete(
      'message_parts',
      where: 'message_id = ?',
      whereArgs: <Object?>[messageId],
    );
    for (final part in parts) {
      await transaction.insert('message_parts', part);
    }
  }

  Future<bool> _mergeLegacyImages(
    Transaction transaction, {
    required String conversationId,
    required String messageId,
    required Object? raw,
  }) async {
    var changed = false;
    var position = 0;
    for (final value in (raw as List? ?? const <Object?>[]).whereType<Map>()) {
      final image = value.cast<String, Object?>();
      final encoded = _string(image['content'] ?? image['src']);
      final match = RegExp(
        r'^data:([^;,]+);base64,(.+)$',
        dotAll: true,
      ).firstMatch(encoded);
      if (match == null) continue;
      late final List<int> bytes;
      try {
        bytes = base64Decode(match.group(2)!);
      } on FormatException {
        continue;
      }
      final digest = (await Sha256().hash(
        bytes,
      )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      final name = _safeFileName(
        _string(image['name'], fallback: 'legacy-image.png'),
      );
      final found = await transaction.query(
        'attachments',
        where: 'sha256 = ?',
        whereArgs: <Object?>[digest],
        limit: 1,
      );
      late final String attachmentId;
      if (found.isEmpty) {
        attachmentId = _uuid.v4();
        final relativePath =
            'conversations/${_safeFileName(conversationId)}/${_safeFileName(messageId)}/$digest/$name';
        final output = File(
          '${store.paths.attachments.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes, flush: true);
        await transaction.insert('attachments', <String, Object?>{
          'id': attachmentId,
          'original_name': name,
          'media_type': match.group(1),
          'relative_path': relativePath,
          'byte_size': bytes.length,
          'sha256': digest,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'origin_device_id': store.deviceId,
        });
        changed = true;
      } else {
        attachmentId = found.first['id']! as String;
      }
      final existingReference = await transaction.query(
        'attachment_references',
        where: "attachment_id = ? AND owner_type = 'message' AND owner_id = ?",
        whereArgs: <Object?>[attachmentId, messageId],
        limit: 1,
      );
      if (existingReference.isEmpty) {
        await transaction.insert('attachment_references', <String, Object?>{
          'attachment_id': attachmentId,
          'owner_type': 'message',
          'owner_id': messageId,
          'position': position,
        });
        changed = true;
      } else if (existingReference.first['position'] != position) {
        await transaction.update(
          'attachment_references',
          <String, Object?>{'position': position},
          where:
              "attachment_id = ? AND owner_type = 'message' AND owner_id = ?",
          whereArgs: <Object?>[attachmentId, messageId],
        );
        changed = true;
      }
      position++;
    }
    return changed;
  }

  String _safeFileName(String value) {
    final clean = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim();
    if (clean.isEmpty) return 'legacy-file';
    return clean.substring(0, clean.length.clamp(0, 120));
  }

  Map<String, Object?> _jsonMap(Object? raw) {
    if (raw is Map) return raw.cast<String, Object?>();
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return decoded.cast<String, Object?>();
      } on Object {
        // Invalid legacy metadata is treated as empty and replaced on update.
      }
    }
    return <String, Object?>{};
  }

  Future<void> _clearTombstone(
    Transaction transaction,
    String table,
    String id,
  ) => transaction.delete(
    'tombstones',
    where: 'entity_type = ? AND entity_id = ?',
    whereArgs: <Object?>[table, id],
  );

  Future<void> _syncLegacyTombstone(
    Transaction transaction,
    String table,
    String id,
  ) async {
    final rows = await transaction.query(
      table,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    final row = rows.firstOrNull;
    if (row == null || row['deleted_at'] == null) {
      await _clearTombstone(transaction, table, id);
      return;
    }
    await transaction.insert('tombstones', <String, Object?>{
      'entity_type': table,
      'entity_id': id,
      'deleted_at': row['deleted_at'],
      'revision': row['revision'],
      'origin_device_id': row['origin_device_id'] ?? store.deviceId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  String _legacyContent(Object? value) {
    if (value is String) return value;
    if (value is List)
      return value
          .map(
            (part) => part is Map
                ? '${part['text'] ?? part['content'] ?? ''}'
                : '$part',
          )
          .join('\n');
    return '${value ?? ''}';
  }

  String _string(Object? value, {String fallback = ''}) =>
      value == null || '$value'.trim().isEmpty ? fallback : '$value';
  String? _nullable(Object? value) =>
      value == null || '$value'.trim().isEmpty ? null : '$value';
  int _integer(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  List<String> _strings(Object? value) =>
      value is List ? value.map((item) => '$item').toList() : const <String>[];
  DateTime _date(Object? value, {DateTime? fallback}) =>
      DateTime.tryParse('${value ?? ''}')?.toUtc() ??
      fallback ??
      DateTime.now().toUtc();
  DateTime? _nullableDate(Object? value) => value == null || '$value'.isEmpty
      ? null
      : DateTime.tryParse('$value')?.toUtc();
}
