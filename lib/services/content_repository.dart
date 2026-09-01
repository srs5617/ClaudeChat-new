import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../domain/entities.dart';

const _uuid = Uuid();

class FileIntegrityException implements Exception {
  const FileIntegrityException(this.message);

  final String message;

  @override
  String toString() => message;
}

class VerifiedFileWrite {
  const VerifiedFileWrite({
    required this.id,
    required this.versionId,
    required this.name,
    required this.type,
    required this.byteSize,
    required this.sha256,
    required this.action,
  });

  final String id;
  final String versionId;
  final String name;
  final String type;
  final int byteSize;
  final String sha256;
  final String action;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'fileId': id,
    'versionId': versionId,
    'name': name,
    'type': type,
    'byteSize': byteSize,
    'sha256': sha256,
    'action': action,
    'status': 'persisted',
    'verified': true,
  };
}

class VerifiedWorkspaceFileWrite {
  const VerifiedWorkspaceFileWrite({
    required this.id,
    required this.name,
    required this.type,
    required this.byteSize,
    required this.sha256,
    required this.action,
    required this.revision,
  });

  final String id;
  final String name;
  final String type;
  final int byteSize;
  final String sha256;
  final String action;
  final int revision;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'fileId': id,
    'name': name,
    'type': type,
    'byteSize': byteSize,
    'sha256': sha256,
    'action': action,
    'revision': revision,
    'status': 'persisted',
    'verified': true,
    'reference': <String, Object?>{'id': id, 'fileId': id, 'name': name},
    'nextToolArguments': <String, Object?>{
      'read_workspace_file': <String, Object?>{'name': name},
      'edit_workspace_file': <String, Object?>{'name': name},
    },
  };
}

class UserFileRecord {
  const UserFileRecord({
    required this.id,
    required this.name,
    required this.type,
    required this.updatedAt,
    this.status = 'active',
    this.deletedAt,
    this.deleteReason,
  });
  final String id;
  final String name;
  final String type;
  final String status;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final String? deleteReason;

  factory UserFileRecord.fromMap(Map<String, Object?> map) => UserFileRecord(
    id: map['id']! as String,
    name: map['name']! as String,
    type: map['type']! as String,
    status: (map['status'] as String?) ?? 'active',
    updatedAt: DateTime.parse(map['updated_at']! as String),
    deletedAt: map['deleted_at'] == null
        ? null
        : DateTime.parse(map['deleted_at']! as String),
    deleteReason: map['delete_reason'] as String?,
  );
}

class UserFileVersionRecord {
  const UserFileVersionRecord({
    required this.id,
    required this.fileId,
    required this.relativePath,
    required this.type,
    required this.reason,
    required this.createdAt,
    required this.byteSize,
    required this.contentSha256,
  });
  final String id;
  final String fileId;
  final String relativePath;
  final String type;
  final String reason;
  final DateTime createdAt;
  final int byteSize;
  final String contentSha256;

  factory UserFileVersionRecord.fromMap(Map<String, Object?> map) =>
      UserFileVersionRecord(
        id: map['id']! as String,
        fileId: map['file_id']! as String,
        relativePath: map['relative_path']! as String,
        type: map['type']! as String,
        reason: (map['reason'] as String?) ?? '',
        createdAt: DateTime.parse(map['created_at']! as String),
        byteSize: (map['byte_size']! as num).toInt(),
        contentSha256: map['content_sha256']! as String,
      );
}

class WorkspaceRecord {
  const WorkspaceRecord({
    required this.id,
    required this.name,
    required this.updatedAt,
    this.description = '',
    this.projectType = 'auto',
    this.settings = const <String, Object?>{},
    this.archivedAt,
  });
  final String id;
  final String name;
  final DateTime updatedAt;
  final String description;
  final String projectType;
  final Map<String, Object?> settings;
  final DateTime? archivedAt;

  factory WorkspaceRecord.fromMap(Map<String, Object?> map) => WorkspaceRecord(
    id: map['id']! as String,
    name: map['name']! as String,
    updatedAt: DateTime.parse(map['updated_at']! as String),
    description: (map['description'] as String?) ?? '',
    projectType: (map['project_type'] as String?) ?? 'auto',
    settings: _decodeObjectMap(map['settings_json']),
    archivedAt: map['archived_at'] == null
        ? null
        : DateTime.tryParse('${map['archived_at']}'),
  );
}

class WorkspaceFileRecord {
  const WorkspaceFileRecord({
    required this.id,
    required this.workspaceId,
    required this.name,
    required this.type,
    required this.relativePath,
    required this.updatedAt,
    this.sha256 = '',
    this.deletedAt,
  });
  final String id;
  final String workspaceId;
  final String name;
  final String type;
  final String relativePath;
  final DateTime updatedAt;
  final String sha256;
  final DateTime? deletedAt;

  factory WorkspaceFileRecord.fromMap(Map<String, Object?> map) =>
      WorkspaceFileRecord(
        id: map['id']! as String,
        workspaceId: map['workspace_id']! as String,
        name: map['name']! as String,
        type: map['type']! as String,
        relativePath: map['relative_path']! as String,
        updatedAt: DateTime.parse(map['updated_at']! as String),
        sha256: (map['sha256'] as String?) ?? '',
        deletedAt: map['deleted_at'] == null
            ? null
            : DateTime.tryParse('${map['deleted_at']}'),
      );
}

class WorkspaceConversationRecord {
  const WorkspaceConversationRecord({
    required this.id,
    required this.workspaceId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String workspaceId;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory WorkspaceConversationRecord.fromMap(Map<String, Object?> map) =>
      WorkspaceConversationRecord(
        id: map['id']! as String,
        workspaceId: map['workspace_id']! as String,
        title: map['title']! as String,
        createdAt: DateTime.parse(map['created_at']! as String),
        updatedAt: DateTime.parse(map['updated_at']! as String),
      );
}

class WorkspaceCommitRecord {
  const WorkspaceCommitRecord({
    required this.id,
    required this.workspaceId,
    required this.sequence,
    required this.message,
    required this.author,
    required this.trigger,
    required this.fileCount,
    required this.createdAt,
    this.parentCommitId,
    this.manifestSha256 = '',
  });

  final String id;
  final String workspaceId;
  final String? parentCommitId;
  final int sequence;
  final String message;
  final String author;
  final String trigger;
  final String manifestSha256;
  final int fileCount;
  final DateTime createdAt;

  factory WorkspaceCommitRecord.fromMap(Map<String, Object?> map) =>
      WorkspaceCommitRecord(
        id: map['id']! as String,
        workspaceId: map['workspace_id']! as String,
        parentCommitId: map['parent_commit_id'] as String?,
        sequence: (map['sequence']! as num).toInt(),
        message: map['message']! as String,
        author: (map['author'] as String?) ?? 'user',
        trigger: (map['trigger'] as String?) ?? 'manual',
        manifestSha256: (map['manifest_sha256'] as String?) ?? '',
        fileCount: (map['file_count'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(map['created_at']! as String),
      );
}

class WorkspaceFileVersionRecord {
  const WorkspaceFileVersionRecord({
    required this.id,
    required this.commitId,
    required this.workspaceId,
    required this.fileId,
    required this.name,
    required this.type,
    required this.relativePath,
    required this.sha256,
    required this.byteSize,
    required this.sequence,
    required this.message,
    required this.trigger,
    required this.createdAt,
  });

  final String id;
  final String commitId;
  final String workspaceId;
  final String fileId;
  final String name;
  final String type;
  final String relativePath;
  final String sha256;
  final int byteSize;
  final int sequence;
  final String message;
  final String trigger;
  final DateTime createdAt;

  WorkspaceFileVersionRecord withSequence(int value) =>
      WorkspaceFileVersionRecord(
        id: id,
        commitId: commitId,
        workspaceId: workspaceId,
        fileId: fileId,
        name: name,
        type: type,
        relativePath: relativePath,
        sha256: sha256,
        byteSize: byteSize,
        sequence: value,
        message: message,
        trigger: trigger,
        createdAt: createdAt,
      );

  factory WorkspaceFileVersionRecord.fromMap(Map<String, Object?> map) =>
      WorkspaceFileVersionRecord(
        id: map['id']! as String,
        commitId: map['commit_id']! as String,
        workspaceId: map['workspace_id']! as String,
        fileId: map['file_id']! as String,
        name: map['name']! as String,
        type: map['type']! as String,
        relativePath: map['relative_path']! as String,
        sha256: map['sha256']! as String,
        byteSize: (map['byte_size']! as num).toInt(),
        sequence: (map['commit_sequence']! as num).toInt(),
        message: map['commit_message']! as String,
        trigger: map['commit_trigger']! as String,
        createdAt: DateTime.parse(map['commit_created_at']! as String),
      );

  Map<String, Object?> toMap() => <String, Object?>{
    'versionId': id,
    'commitId': commitId,
    'fileId': fileId,
    'name': name,
    'type': type,
    'sha256': sha256,
    'byteSize': byteSize,
    'sequence': sequence,
    'message': message,
    'trigger': trigger,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'immutable': true,
  };
}

class VerifiedWorkspaceFileVersion {
  const VerifiedWorkspaceFileVersion({
    required this.version,
    required this.content,
  });

  final WorkspaceFileVersionRecord version;
  final String content;
}

Map<String, Object?> _decodeObjectMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is! String || value.trim().isEmpty) {
    return <String, Object?>{};
  }
  try {
    final decoded = jsonDecode(value);
    return decoded is Map
        ? decoded.map((key, item) => MapEntry('$key', item))
        : <String, Object?>{};
  } on FormatException {
    return <String, Object?>{};
  }
}

class WorkspaceMessageRecord {
  const WorkspaceMessageRecord({
    required this.id,
    required this.workspaceId,
    required this.conversationId,
    required this.sequence,
    required this.role,
    required this.content,
    required this.createdAt,
  });
  final String id;
  final String workspaceId;
  final String conversationId;
  final int sequence;
  final String role;
  final String content;
  final DateTime createdAt;

  factory WorkspaceMessageRecord.fromMap(Map<String, Object?> map) =>
      WorkspaceMessageRecord(
        id: map['id']! as String,
        workspaceId: map['workspace_id']! as String,
        conversationId:
            (map['conversation_id'] as String?) ??
            'legacy-${map['workspace_id']}',
        sequence: (map['sequence']! as num).toInt(),
        role: map['role']! as String,
        content: map['content']! as String,
        createdAt: DateTime.parse(map['created_at']! as String),
      );
}

class ContentRepository {
  ContentRepository(this.store);
  final AppDatabase store;

  Future<List<MemoryEntry>> memories({bool includeDeleted = false}) async {
    final rows = await store.database.query(
      'memories',
      where: includeDeleted ? null : 'deleted_at IS NULL',
      orderBy:
          "CASE WHEN deleted_at IS NULL THEN 0 ELSE 1 END, "
          "CASE level WHEN 'critical' THEN 0 WHEN 'important' THEN 1 WHEN 'daily' THEN 2 WHEN 'trivial' THEN 3 ELSE 99 END, "
          'use_frequency DESC, last_accessed_at DESC, created_at DESC',
    );
    return rows.map(MemoryEntry.fromMap).toList();
  }

  Future<void> recordMemoryAccesses(Iterable<String> memoryIds) async {
    final ids = memoryIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return;
    final placeholders = List<String>.filled(ids.length, '?').join(', ');
    await store.database.rawUpdate(
      'UPDATE memories '
      'SET last_accessed_at = ?, '
      'use_frequency = COALESCE(use_frequency, 0) + 1 '
      'WHERE deleted_at IS NULL AND id IN ($placeholders)',
      <Object?>[DateTime.now().toUtc().toIso8601String(), ...ids],
    );
  }

  Future<String> saveMemory({
    String? id,
    required String content,
    required String level,
    List<String> tags = const <String>[],
    String? source,
    String? sourceConversationId,
  }) async {
    final now = DateTime.now().toUtc();
    final existing = id == null
        ? const <Map<String, Object?>>[]
        : await store.database.query(
            'memories',
            where: 'id = ?',
            whereArgs: <Object?>[id],
            limit: 1,
          );
    final created = existing.isEmpty
        ? now
        : DateTime.parse(existing.first['created_at']! as String);
    final memoryId = id ?? _uuid.v4();
    await store.database.insert(
      'memories',
      MemoryEntry(
        id: memoryId,
        content: content.trim(),
        level: level,
        tags: tags,
        source:
            source ?? (existing.firstOrNull?['source'] as String?) ?? 'user',
        sourceConversationId:
            sourceConversationId ??
            existing.firstOrNull?['source_conversation_id'] as String?,
        lastAccessedAt: existing.firstOrNull?['last_accessed_at'] == null
            ? null
            : DateTime.parse(existing.first['last_accessed_at']! as String),
        useFrequency:
            (existing.firstOrNull?['use_frequency'] as num?)?.toInt() ?? 0,
        createdAt: created,
        updatedAt: now,
        revision: existing.isEmpty
            ? 1
            : ((existing.first['revision'] as num?)?.toInt() ?? 0) + 1,
        originDeviceId: store.deviceId,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return memoryId;
  }

  Future<List<DiaryEntry>> diaries({bool includeDeleted = false}) async {
    final rows = await store.database.query(
      'diary_entries',
      where: includeDeleted ? null : 'deleted_at IS NULL AND status != ?',
      whereArgs: includeDeleted ? null : <Object?>['deleted'],
      orderBy: 'updated_at DESC, id DESC',
    );
    return rows.map(DiaryEntry.fromMap).toList();
  }

  Future<DiaryVersion?> diaryLatest(String diaryId) async {
    final entryRows = await store.database.query(
      'diary_entries',
      columns: const <String>['latest_version_id'],
      where: 'id = ?',
      whereArgs: <Object?>[diaryId],
      limit: 1,
    );
    final latestVersionId =
        entryRows.firstOrNull?['latest_version_id'] as String?;
    final rows = await store.database.query(
      'diary_versions',
      where: latestVersionId == null || latestVersionId.isEmpty
          ? 'diary_id = ?'
          : 'diary_id = ? AND id = ?',
      whereArgs: latestVersionId == null || latestVersionId.isEmpty
          ? <Object?>[diaryId]
          : <Object?>[diaryId, latestVersionId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    final fallback = rows.isNotEmpty
        ? rows
        : await store.database.query(
            'diary_versions',
            where: 'diary_id = ?',
            whereArgs: <Object?>[diaryId],
            orderBy: 'created_at DESC',
            limit: 1,
          );
    if (fallback.isEmpty) return null;
    final map = fallback.first;
    return DiaryVersion(
      id: map['id']! as String,
      diaryId: map['diary_id']! as String,
      title: map['title']! as String,
      content: map['content']! as String,
      operation: map['operation']! as String,
      tags: ((jsonDecode(map['tags_json']! as String)) as List).cast<String>(),
      createdAt: DateTime.parse(map['created_at']! as String),
      reason: map['reason'] as String?,
      mood: map['mood'] as String?,
      sourceConversationId: map['source_conversation_id'] as String?,
      originDeviceId: (map['origin_device_id'] as String?) ?? '',
    );
  }

  Future<List<DiaryVersion>> diaryVersions(String diaryId) async {
    final rows = await store.database.query(
      'diary_versions',
      where: 'diary_id = ?',
      whereArgs: <Object?>[diaryId],
      orderBy: 'created_at DESC',
    );
    return rows
        .map(
          (map) => DiaryVersion(
            id: map['id']! as String,
            diaryId: map['diary_id']! as String,
            title: map['title']! as String,
            content: map['content']! as String,
            operation: map['operation']! as String,
            tags: ((jsonDecode(map['tags_json']! as String)) as List)
                .cast<String>(),
            createdAt: DateTime.parse(map['created_at']! as String),
            reason: map['reason'] as String?,
            mood: map['mood'] as String?,
            sourceConversationId: map['source_conversation_id'] as String?,
            originDeviceId: (map['origin_device_id'] as String?) ?? '',
          ),
        )
        .toList();
  }

  Future<String> saveDiary({
    String? id,
    required String title,
    required String content,
    String? mood,
    List<String> tags = const <String>[],
    String? reason,
    String? sourceConversationId,
    String? versionSourceConversationId,
  }) async {
    final now = DateTime.now().toUtc();
    final diaryId = id ?? _uuid.v4();
    final versionId = _uuid.v4();
    final existing = id == null
        ? const <Map<String, Object?>>[]
        : await store.database.query(
            'diary_entries',
            where: 'id = ?',
            whereArgs: <Object?>[id],
            limit: 1,
          );
    final created = existing.isEmpty
        ? now
        : DateTime.parse(existing.first['created_at']! as String);
    final entryConversationId =
        sourceConversationId ??
        existing.firstOrNull?['source_conversation_id'] as String?;
    final versionConversationId =
        versionSourceConversationId ?? entryConversationId;
    await store.database.transaction((transaction) async {
      if (existing.isEmpty) {
        await transaction.insert(
          'diary_entries',
          DiaryEntry(
            id: diaryId,
            title: title.trim().isEmpty ? '未命名日记' : title.trim(),
            status: 'active',
            tags: tags,
            createdAt: created,
            updatedAt: now,
            mood: mood,
            sourceConversationId: entryConversationId,
            revision: 1,
            originDeviceId: store.deviceId,
          ).toMap(),
        );
      }
      await transaction.insert(
        'diary_versions',
        DiaryVersion(
          id: versionId,
          diaryId: diaryId,
          title: title.trim(),
          content: content,
          operation: existing.isEmpty ? 'create' : 'revise',
          reason: reason ?? (existing.isEmpty ? '创建日记' : 'AI 修订了这篇日记'),
          tags: tags,
          createdAt: now,
          mood: mood,
          sourceConversationId: versionConversationId,
          originDeviceId: store.deviceId,
        ).toMap(),
      );
      // Do not use SQLite REPLACE here. REPLACE deletes the existing parent
      // row before inserting its replacement, which activates the
      // diary_versions ON DELETE CASCADE foreign key and silently removes the
      // complete version history (including the initial `create` snapshot).
      final changed = await transaction.update(
        'diary_entries',
        <String, Object?>{
          'title': title.trim().isEmpty ? '未命名日记' : title.trim(),
          'status': 'active',
          'mood': mood,
          'tags_json': jsonEncode(tags),
          'latest_version_id': versionId,
          'source_conversation_id': entryConversationId,
          'updated_at': now.toIso8601String(),
          'deleted_at': null,
          'delete_reason': null,
          'revision': existing.isEmpty
              ? 1
              : ((existing.first['revision'] as num?)?.toInt() ?? 0) + 1,
          'origin_device_id': store.deviceId,
        },
        where: 'id = ?',
        whereArgs: <Object?>[diaryId],
      );
      if (changed != 1) {
        throw const FileIntegrityException('日记主记录更新失败');
      }
    });
    return diaryId;
  }

  /// Repairs version chains damaged by earlier builds that updated parent
  /// rows with SQLite REPLACE.
  ///
  /// File payloads live outside SQLite, so orphaned version files can be
  /// restored losslessly. Diary payloads lived in the cascaded child table;
  /// when the original snapshot is no longer available, the earliest
  /// surviving snapshot is copied and explicitly labelled as recovered rather
  /// than pretending that it is the original text.
  Future<void> repairVersionHistories() async {
    await _repairDiaryVersionHistories();
    await _repairFileVersionHistories();
  }

  Future<void> _repairDiaryVersionHistories() async {
    final entries = await store.database.query('diary_entries');
    for (final entry in entries) {
      final diaryId = entry['id']! as String;
      final versions = await store.database.query(
        'diary_versions',
        where: 'diary_id = ?',
        whereArgs: <Object?>[diaryId],
        orderBy: 'created_at ASC, id ASC',
      );
      if (versions.isEmpty ||
          versions.any((row) => row['operation'] == 'create')) {
        continue;
      }
      final earliest = versions.first;
      await store.database.insert('diary_versions', <String, Object?>{
        'id': _uuid.v4(),
        'diary_id': diaryId,
        'title': earliest['title'] ?? entry['title'] ?? '',
        'content': earliest['content'] ?? '',
        'operation': 'create',
        'reason': '补建创建记录（原始快照缺失，内容取自现存最早版本）',
        'mood': earliest['mood'] ?? entry['mood'],
        'tags_json': earliest['tags_json'] ?? entry['tags_json'] ?? '[]',
        'source_conversation_id':
            earliest['source_conversation_id'] ??
            entry['source_conversation_id'],
        'created_at': entry['created_at'] ?? earliest['created_at'],
        'origin_device_id': store.deviceId,
      });
    }
  }

  Future<void> _repairFileVersionHistories() async {
    final files = await store.database.query('user_files');
    for (final fileRow in files) {
      final fileId = fileRow['id']! as String;
      final directory = Directory(
        '${store.paths.files.path}${Platform.pathSeparator}$fileId',
      );
      final knownRows = await store.database.query(
        'file_versions',
        where: 'file_id = ?',
        whereArgs: <Object?>[fileId],
      );
      final knownIds = knownRows.map((row) => row['id']! as String).toSet();
      if (await directory.exists()) {
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is! File ||
              !entity.path.toLowerCase().endsWith('.txt') ||
              entity.path.toLowerCase().endsWith('.pending')) {
            continue;
          }
          final fileName = entity.uri.pathSegments.last;
          final versionId = fileName.substring(0, fileName.length - 4);
          if (versionId.isEmpty || knownIds.contains(versionId)) continue;
          final bytes = await entity.readAsBytes();
          final stat = await entity.stat();
          await store.database.insert('file_versions', <String, Object?>{
            'id': versionId,
            'file_id': fileId,
            'relative_path': '$fileId/$fileName',
            'content_sha256': await _sha256Hex(bytes),
            'byte_size': bytes.length,
            'type': fileRow['type'] ?? 'text',
            'reason': '从本地文件恢复的历史版本',
            'created_at': stat.modified.toUtc().toIso8601String(),
            'origin_device_id': store.deviceId,
          });
          knownIds.add(versionId);
        }
      }
      final repaired = await store.database.query(
        'file_versions',
        where: 'file_id = ?',
        whereArgs: <Object?>[fileId],
        orderBy: 'created_at ASC, id ASC',
      );
      final hasCreate = repaired.any(
        (row) => '${row['reason'] ?? ''}'.contains('创建'),
      );
      if (!hasCreate && repaired.isNotEmpty) {
        await store.database.update(
          'file_versions',
          const <String, Object?>{'reason': '创建文件（从现存最早版本恢复）'},
          where: 'id = ?',
          whereArgs: <Object?>[repaired.first['id']],
        );
      }
    }
  }

  Future<List<UserFileRecord>> files({bool includeDeleted = false}) async {
    final rows = await store.database.query(
      'user_files',
      where: includeDeleted ? null : 'deleted_at IS NULL AND status = ?',
      whereArgs: includeDeleted ? null : <Object?>['active'],
      orderBy: 'updated_at DESC, id DESC',
    );
    return rows.map(UserFileRecord.fromMap).toList();
  }

  Future<VerifiedFileWrite> saveTextFile({
    String? id,
    required String name,
    required String content,
    String type = 'text',
    String? reason,
  }) async {
    final now = DateTime.now().toUtc();
    final fileId = id ?? _uuid.v4();
    final versionId = _uuid.v4();
    final existing = id == null
        ? const <Map<String, Object?>>[]
        : await store.database.query(
            'user_files',
            where: 'id = ?',
            whereArgs: <Object?>[id],
            limit: 1,
          );
    final cleanName = name.trim().isEmpty ? 'untitled.txt' : name.trim();
    final relative = '$fileId/$versionId.txt';
    final output = File(
      '${store.paths.files.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
    );
    final staged = File('${output.path}.pending');
    final bytes = utf8.encode(content);
    final digest = await _sha256Hex(bytes);
    var databaseCommitted = false;
    await output.parent.create(recursive: true);
    try {
      await staged.writeAsBytes(bytes, flush: true);
      await _readVerifiedFile(
        staged,
        expectedByteSize: bytes.length,
        expectedSha256: digest,
      );
      await staged.rename(output.path);
      await store.database.transaction((transaction) async {
        final fileValues = <String, Object?>{
          'name': cleanName,
          'type': type,
          'status': 'active',
          'current_version_id': versionId,
          'updated_at': now.toIso8601String(),
          'deleted_at': null,
          'delete_reason': null,
          'revision': existing.isEmpty
              ? 1
              : ((existing.first['revision'] as num?)?.toInt() ?? 0) + 1,
          'origin_device_id': store.deviceId,
        };
        if (existing.isEmpty) {
          await transaction.insert('user_files', <String, Object?>{
            'id': fileId,
            ...fileValues,
            'created_at': now.toIso8601String(),
          });
        } else {
          final changed = await transaction.update(
            'user_files',
            fileValues,
            where: 'id = ?',
            whereArgs: <Object?>[fileId],
          );
          if (changed != 1) {
            throw const FileIntegrityException('文件主记录更新失败');
          }
        }
        await transaction.insert('file_versions', <String, Object?>{
          'id': versionId,
          'file_id': fileId,
          'relative_path': relative,
          'content_sha256': digest,
          'byte_size': bytes.length,
          'type': type,
          'reason': reason ?? (existing.isEmpty ? '创建文件' : '保存新版本'),
          'created_at': now.toIso8601String(),
          'origin_device_id': store.deviceId,
        });
      });
      databaseCommitted = true;
      await _verifyCurrentFileWrite(
        fileId: fileId,
        versionId: versionId,
        expectedByteSize: bytes.length,
        expectedSha256: digest,
      );
      return VerifiedFileWrite(
        id: fileId,
        versionId: versionId,
        name: cleanName,
        type: type,
        byteSize: bytes.length,
        sha256: digest,
        action: existing.isEmpty ? 'created' : 'updated',
      );
    } on Object catch (error) {
      if (databaseCommitted) {
        await store.database.transaction((transaction) async {
          if (existing.isEmpty) {
            await transaction.delete(
              'user_files',
              where: 'id = ?',
              whereArgs: <Object?>[fileId],
            );
          } else {
            await transaction.delete(
              'file_versions',
              where: 'id = ?',
              whereArgs: <Object?>[versionId],
            );
            await transaction.update(
              'user_files',
              existing.first,
              where: 'id = ?',
              whereArgs: <Object?>[fileId],
            );
          }
        });
      }
      if (await staged.exists()) await staged.delete();
      if (await output.exists()) await output.delete();
      if (error is FileIntegrityException) rethrow;
      throw FileIntegrityException('文件写入未完成：$error');
    }
  }

  Future<String> readFile(String id) async {
    final rows = await store.database.rawQuery(
      '''SELECT f.current_version_id, v.id AS version_id, v.relative_path,
      v.content_sha256, v.byte_size FROM user_files f
      JOIN file_versions v ON v.id = f.current_version_id WHERE f.id = ?''',
      <Object?>[id],
    );
    if (rows.isEmpty) {
      final fileRows = await store.database.query(
        'user_files',
        columns: const <String>['id'],
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      throw FileIntegrityException(fileRows.isEmpty ? '文件记录不存在' : '文件当前版本记录缺失');
    }
    final relative = rows.first['relative_path']! as String;
    return _readVerifiedFile(
      File(
        '${store.paths.files.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
      ),
      expectedByteSize: (rows.first['byte_size']! as num).toInt(),
      expectedSha256: rows.first['content_sha256']! as String,
    );
  }

  Future<List<UserFileVersionRecord>> fileVersions(String fileId) async {
    final rows = await store.database.query(
      'file_versions',
      where: 'file_id = ?',
      whereArgs: <Object?>[fileId],
      orderBy: 'created_at DESC',
    );
    return rows.map(UserFileVersionRecord.fromMap).toList();
  }

  Future<String> readFileVersion(
    UserFileVersionRecord value,
  ) => _readVerifiedFile(
    File(
      '${store.paths.files.path}${Platform.pathSeparator}${value.relativePath.replaceAll('/', Platform.pathSeparator)}',
    ),
    expectedByteSize: value.byteSize,
    expectedSha256: value.contentSha256,
  );

  Future<void> restoreFileVersion(
    UserFileRecord file,
    UserFileVersionRecord version,
  ) async {
    await saveTextFile(
      id: file.id,
      name: file.name,
      content: await readFileVersion(version),
      type: version.type,
    );
  }

  Future<void> _verifyCurrentFileWrite({
    required String fileId,
    required String versionId,
    required int expectedByteSize,
    required String expectedSha256,
  }) async {
    final rows = await store.database.rawQuery(
      '''SELECT f.current_version_id, v.relative_path, v.byte_size,
      v.content_sha256 FROM user_files f
      JOIN file_versions v ON v.id = f.current_version_id
      WHERE f.id = ? AND f.current_version_id = ?''',
      <Object?>[fileId, versionId],
    );
    if (rows.length != 1) {
      throw const FileIntegrityException('数据库未指向刚写入的文件版本');
    }
    final row = rows.single;
    if ((row['byte_size'] as num?)?.toInt() != expectedByteSize ||
        row['content_sha256'] != expectedSha256) {
      throw const FileIntegrityException('数据库中的文件校验信息不一致');
    }
    final relative = row['relative_path']! as String;
    await _readVerifiedFile(
      File(
        '${store.paths.files.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
      ),
      expectedByteSize: expectedByteSize,
      expectedSha256: expectedSha256,
    );
  }

  Future<String> _readVerifiedFile(
    File file, {
    required int expectedByteSize,
    required String expectedSha256,
  }) async {
    if (!await file.exists()) {
      throw FileIntegrityException('文件内容缺失：${file.path}');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != expectedByteSize) {
      throw FileIntegrityException(
        '文件大小校验失败（应为 $expectedByteSize 字节，实际为 ${bytes.length} 字节）',
      );
    }
    final digest = await _sha256Hex(bytes);
    if (digest.toLowerCase() != expectedSha256.toLowerCase()) {
      throw const FileIntegrityException('文件内容哈希校验失败');
    }
    return utf8.decode(bytes);
  }

  Future<String> _sha256Hex(List<int> bytes) async => (await Sha256().hash(
    bytes,
  )).bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  Future<List<WorkspaceRecord>> workspaces({bool archived = false}) async {
    final rows = await store.database.query(
      'workspaces',
      where: archived
          ? 'deleted_at IS NULL AND archived_at IS NOT NULL'
          : 'deleted_at IS NULL AND archived_at IS NULL',
      orderBy: 'updated_at DESC',
    );
    return rows.map(WorkspaceRecord.fromMap).toList();
  }

  Future<WorkspaceRecord> createWorkspace(
    String name, {
    String projectType = 'auto',
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final id = _uuid.v4();
    await store.database.insert('workspaces', <String, Object?>{
      'id': id,
      'name': name.trim().isEmpty ? '我的工作区' : name.trim(),
      'description': '',
      'project_type': projectType,
      'settings_json': '{}',
      'created_at': now,
      'updated_at': now,
      'revision': 1,
      'origin_device_id': store.deviceId,
    });
    await createWorkspaceConversation(id, title: '主对话');
    await createWorkspaceCheckpoint(id, message: '初始化工作区', trigger: 'initial');
    final rows = await store.database.query(
      'workspaces',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return WorkspaceRecord.fromMap(rows.single);
  }

  Future<void> renameWorkspace(String id, String name) async {
    final rows = await store.database.query(
      'workspaces',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await store.database.update(
      'workspaces',
      <String, Object?>{
        'name': name.trim().isEmpty ? '我的工作区' : name.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'revision': ((rows.first['revision'] as num?)?.toInt() ?? 0) + 1,
        'origin_device_id': store.deviceId,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> updateWorkspace({
    required String id,
    String? name,
    String? description,
    String? projectType,
    Map<String, Object?>? settings,
  }) async {
    final rows = await store.database.query(
      'workspaces',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.single;
    await store.database.update(
      'workspaces',
      <String, Object?>{
        if (name != null) 'name': name.trim().isEmpty ? '我的工作区' : name.trim(),
        if (description != null) 'description': description.trim(),
        'project_type': ?projectType,
        if (settings != null) 'settings_json': jsonEncode(settings),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'revision': ((row['revision'] as num?)?.toInt() ?? 0) + 1,
        'origin_device_id': store.deviceId,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> archiveWorkspace(String id) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await store.database.rawUpdate(
      'UPDATE workspaces SET archived_at = ?, updated_at = ?, revision = revision + 1, origin_device_id = ? WHERE id = ? AND deleted_at IS NULL',
      <Object?>[now, now, store.deviceId, id],
    );
  }

  Future<void> unarchiveWorkspace(String id) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await store.database.rawUpdate(
      'UPDATE workspaces SET archived_at = NULL, updated_at = ?, revision = revision + 1, origin_device_id = ? WHERE id = ? AND deleted_at IS NULL',
      <Object?>[now, store.deviceId, id],
    );
  }

  Future<List<WorkspaceFileRecord>> workspaceFiles(String workspaceId) async {
    final rows = await store.database.query(
      'workspace_files',
      where: 'workspace_id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[workspaceId],
      orderBy: 'updated_at DESC',
    );
    return rows.map(WorkspaceFileRecord.fromMap).toList();
  }

  Future<VerifiedWorkspaceFileWrite> saveWorkspaceFile({
    required String workspaceId,
    String? id,
    required String name,
    required String content,
    String type = 'text',
  }) async {
    final now = DateTime.now().toUtc();
    final fileId = id ?? _uuid.v4();
    final normalizedName = name.trim().isEmpty ? 'untitled.txt' : name.trim();
    final normalizedType = type.trim().isEmpty ? 'text' : type.trim();
    final relative = 'workspaces/$workspaceId/$fileId.txt';
    final output = File(
      '${store.paths.files.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
    );
    final existing = id == null
        ? const <Map<String, Object?>>[]
        : await store.database.query(
            'workspace_files',
            where: 'id = ? AND workspace_id = ?',
            whereArgs: <Object?>[id, workspaceId],
            limit: 1,
          );
    if (id != null && existing.isEmpty) {
      throw StateError('要编辑的工作区文件不存在：$id');
    }
    final workspaceRows = await store.database.query(
      'workspaces',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[workspaceId],
      limit: 1,
    );
    if (workspaceRows.isEmpty) throw StateError('工作区不存在：$workspaceId');

    final bytes = utf8.encode(content);
    final digest = await _sha256Hex(bytes);
    final revision = existing.isEmpty
        ? 1
        : ((existing.single['revision'] as num?)?.toInt() ?? 0) + 1;
    final pending = File('${output.path}.pending-${_uuid.v4()}');
    final previousBytes = await output.exists()
        ? await output.readAsBytes()
        : null;
    final previousRow = existing.firstOrNull;
    final previousWorkspace = workspaceRows.single;

    try {
      await output.parent.create(recursive: true);
      await pending.writeAsBytes(bytes, flush: true);
      await _readVerifiedFile(
        pending,
        expectedByteSize: bytes.length,
        expectedSha256: digest,
      );
      if (await output.exists()) await output.delete();
      await pending.rename(output.path);
      await _readVerifiedFile(
        output,
        expectedByteSize: bytes.length,
        expectedSha256: digest,
      );

      await store.database.transaction((transaction) async {
        await transaction.insert('workspace_files', <String, Object?>{
          'id': fileId,
          'workspace_id': workspaceId,
          'name': normalizedName,
          'type': normalizedType,
          'relative_path': relative,
          'sha256': digest,
          'created_at': existing.isEmpty
              ? now.toIso8601String()
              : existing.single['created_at'],
          'updated_at': now.toIso8601String(),
          'revision': revision,
          'origin_device_id': store.deviceId,
          'deleted_at': null,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await transaction.rawUpdate(
          'UPDATE workspaces SET updated_at = ?, revision = revision + 1, origin_device_id = ? WHERE id = ?',
          <Object?>[now.toIso8601String(), store.deviceId, workspaceId],
        );
      });

      final verifiedRows = await store.database.query(
        'workspace_files',
        where: 'id = ? AND workspace_id = ? AND deleted_at IS NULL',
        whereArgs: <Object?>[fileId, workspaceId],
        limit: 1,
      );
      if (verifiedRows.length != 1 ||
          verifiedRows.single['sha256'] != digest ||
          verifiedRows.single['relative_path'] != relative ||
          verifiedRows.single['name'] != normalizedName) {
        throw const FileIntegrityException('工作区文件数据库回读校验失败');
      }
      await _readVerifiedFile(
        output,
        expectedByteSize: bytes.length,
        expectedSha256: digest,
      );
      return VerifiedWorkspaceFileWrite(
        id: fileId,
        name: normalizedName,
        type: normalizedType,
        byteSize: bytes.length,
        sha256: digest,
        action: existing.isEmpty ? 'created' : 'updated',
        revision: revision,
      );
    } on Object {
      if (await pending.exists()) await pending.delete();
      if (previousBytes == null) {
        if (await output.exists()) await output.delete();
      } else {
        await output.parent.create(recursive: true);
        await output.writeAsBytes(previousBytes, flush: true);
      }
      await store.database.transaction((transaction) async {
        if (previousRow == null) {
          await transaction.delete(
            'workspace_files',
            where: 'id = ?',
            whereArgs: <Object?>[fileId],
          );
        } else {
          await transaction.insert(
            'workspace_files',
            previousRow,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await transaction.update(
          'workspaces',
          previousWorkspace,
          where: 'id = ?',
          whereArgs: <Object?>[workspaceId],
        );
      });
      rethrow;
    }
  }

  Future<String> readWorkspaceFile(WorkspaceFileRecord value) async {
    final file = File(
      '${store.paths.files.path}${Platform.pathSeparator}${value.relativePath.replaceAll('/', Platform.pathSeparator)}',
    );
    if (!await file.exists()) {
      throw FileIntegrityException('工作区文件内容缺失：${value.name}');
    }
    final bytes = await file.readAsBytes();
    if (value.sha256.isNotEmpty) {
      final digest = await _sha256Hex(bytes);
      if (digest.toLowerCase() != value.sha256.toLowerCase()) {
        throw FileIntegrityException('工作区文件内容校验失败：${value.name}');
      }
    }
    return utf8.decode(bytes);
  }

  Future<void> deleteWorkspaceFile(WorkspaceFileRecord value) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await store.database.rawUpdate(
      'UPDATE workspace_files SET deleted_at = ?, updated_at = ?, revision = revision + 1, origin_device_id = ? WHERE id = ?',
      <Object?>[now, now, store.deviceId, value.id],
    );
  }

  Future<List<WorkspaceConversationRecord>> workspaceConversations(
    String workspaceId,
  ) async {
    var rows = await store.database.query(
      'workspace_conversations',
      where: 'workspace_id = ? AND deleted_at IS NULL AND archived_at IS NULL',
      whereArgs: <Object?>[workspaceId],
      orderBy: 'updated_at DESC, created_at DESC',
    );
    if (rows.isEmpty) {
      await createWorkspaceConversation(workspaceId, title: '主对话');
      rows = await store.database.query(
        'workspace_conversations',
        where:
            'workspace_id = ? AND deleted_at IS NULL AND archived_at IS NULL',
        whereArgs: <Object?>[workspaceId],
        orderBy: 'updated_at DESC, created_at DESC',
      );
    }
    return rows.map(WorkspaceConversationRecord.fromMap).toList();
  }

  Future<WorkspaceConversationRecord> createWorkspaceConversation(
    String workspaceId, {
    String title = '新对话',
  }) async {
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await store.database.insert('workspace_conversations', <String, Object?>{
      'id': id,
      'workspace_id': workspaceId,
      'title': title.trim().isEmpty ? '新对话' : title.trim(),
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'revision': 1,
      'origin_device_id': store.deviceId,
    });
    return WorkspaceConversationRecord(
      id: id,
      workspaceId: workspaceId,
      title: title.trim().isEmpty ? '新对话' : title.trim(),
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Returns the most recently active conversation that contains at least one
  /// persisted message. The workspace predicate is intentionally repeated in
  /// the EXISTS clause so an empty draft in one workspace can never select a
  /// conversation or message owned by another workspace.
  Future<WorkspaceConversationRecord?> latestNonEmptyWorkspaceConversation(
    String workspaceId, {
    String? excludingConversationId,
  }) async {
    final exclude = excludingConversationId?.trim();
    final rows = await store.database.rawQuery(
      '''SELECT conversation.*
         FROM workspace_conversations AS conversation
         WHERE conversation.workspace_id = ?
           AND conversation.deleted_at IS NULL
           AND conversation.archived_at IS NULL
           ${exclude == null || exclude.isEmpty ? '' : 'AND conversation.id != ?'}
           AND EXISTS (
             SELECT 1 FROM workspace_messages AS message
             WHERE message.workspace_id = conversation.workspace_id
               AND message.conversation_id = conversation.id
           )
         ORDER BY conversation.updated_at DESC, conversation.created_at DESC
         LIMIT 1''',
      <Object?>[
        workspaceId,
        if (exclude != null && exclude.isNotEmpty) exclude,
      ],
    );
    return rows.isEmpty
        ? null
        : WorkspaceConversationRecord.fromMap(rows.first);
  }

  Future<List<WorkspaceMessageRecord>> workspaceMessages(
    String workspaceId, {
    String? conversationId,
  }) async {
    final rows = await store.database.query(
      'workspace_messages',
      where: conversationId == null
          ? 'workspace_id = ?'
          : 'workspace_id = ? AND conversation_id = ?',
      whereArgs: <Object?>[workspaceId, ?conversationId],
      orderBy: 'sequence ASC, created_at ASC',
    );
    return rows.map(WorkspaceMessageRecord.fromMap).toList();
  }

  Future<Map<String, List<MessagePart>>> workspaceMessageParts(
    String workspaceId, {
    String? conversationId,
  }) async {
    final rows = await store.database.rawQuery(
      '''SELECT p.* FROM workspace_message_parts p
         INNER JOIN workspace_messages m ON m.id = p.message_id
         WHERE m.workspace_id = ?${conversationId == null ? '' : ' AND m.conversation_id = ?'}
         ORDER BY m.sequence ASC, p.sequence ASC''',
      <Object?>[workspaceId, ?conversationId],
    );
    final output = <String, List<MessagePart>>{};
    for (final row in rows) {
      final part = MessagePart.fromMap(row);
      (output[part.messageId] ??= <MessagePart>[]).add(part);
    }
    return output;
  }

  Future<WorkspaceMessageRecord> appendWorkspaceMessage({
    required String workspaceId,
    required String conversationId,
    required String role,
    required String content,
    List<MessagePartInput> parts = const <MessagePartInput>[],
  }) async {
    final maxRows = await store.database.rawQuery(
      'SELECT COALESCE(MAX(sequence), 0) AS value FROM workspace_messages WHERE workspace_id = ? AND conversation_id = ?',
      <Object?>[workspaceId, conversationId],
    );
    final now = DateTime.now().toUtc();
    final value = WorkspaceMessageRecord(
      id: _uuid.v4(),
      workspaceId: workspaceId,
      conversationId: conversationId,
      sequence: ((maxRows.first['value'] as num?)?.toInt() ?? 0) + 1,
      role: role,
      content: content,
      createdAt: now,
    );
    await store.database.transaction((transaction) async {
      await transaction.insert('workspace_messages', <String, Object?>{
        'id': value.id,
        'workspace_id': workspaceId,
        'conversation_id': conversationId,
        'sequence': value.sequence,
        'role': role,
        'content': content,
        'created_at': now.toIso8601String(),
        'revision': 1,
        'origin_device_id': store.deviceId,
      });
      for (var index = 0; index < parts.length; index++) {
        final part = parts[index];
        await transaction.insert('workspace_message_parts', <String, Object?>{
          'id': _uuid.v4(),
          'message_id': value.id,
          'sequence': index + 1,
          'type': part.type,
          'content': part.content,
          'metadata_json': jsonEncode(part.metadata),
          'created_at': now.toIso8601String(),
        });
      }
      await transaction.rawUpdate(
        'UPDATE workspace_conversations SET updated_at = ?, revision = revision + 1, origin_device_id = ? WHERE id = ? AND workspace_id = ?',
        <Object?>[
          now.toIso8601String(),
          store.deviceId,
          conversationId,
          workspaceId,
        ],
      );
      await transaction.update(
        'workspaces',
        <String, Object?>{'updated_at': now.toIso8601String()},
        where: 'id = ?',
        whereArgs: <Object?>[workspaceId],
      );
    });
    return value;
  }

  Future<List<WorkspaceCommitRecord>> workspaceCommits(
    String workspaceId,
  ) async {
    final rows = await store.database.query(
      'workspace_commits',
      where: 'workspace_id = ?',
      whereArgs: <Object?>[workspaceId],
      orderBy: 'sequence DESC, created_at DESC',
    );
    return rows.map(WorkspaceCommitRecord.fromMap).toList();
  }

  Future<List<WorkspaceFileVersionRecord>> workspaceFileVersions({
    required String workspaceId,
    String? fileId,
    String? name,
  }) async {
    final clauses = <String>['f.workspace_id = ?'];
    final args = <Object?>[workspaceId];
    if (fileId != null && fileId.trim().isNotEmpty) {
      clauses.add('f.file_id = ?');
      args.add(fileId.trim());
    } else if (name != null && name.trim().isNotEmpty) {
      clauses.add('f.name = ?');
      args.add(name.trim());
    }
    final rows = await store.database.rawQuery(
      '''SELECT f.*, c.sequence AS commit_sequence,
                c.message AS commit_message, c.trigger AS commit_trigger,
                c.created_at AS commit_created_at
         FROM workspace_commit_files f
         INNER JOIN workspace_commits c ON c.id = f.commit_id
         WHERE ${clauses.join(' AND ')}
         ORDER BY c.sequence DESC, c.created_at DESC''',
      args,
    );
    final seenHashes = <String>{};
    final versions = rows
        .map(WorkspaceFileVersionRecord.fromMap)
        .where((version) => seenHashes.add(version.sha256.toLowerCase()))
        .toList(growable: false);
    return versions.indexed
        .map((entry) => entry.$2.withSequence(versions.length - entry.$1))
        .toList(growable: false);
  }

  Future<VerifiedWorkspaceFileVersion> readWorkspaceFileVersion(
    String versionId, {
    required String workspaceId,
  }) async {
    final rows = await store.database.rawQuery(
      '''SELECT f.*, c.sequence AS commit_sequence,
                c.message AS commit_message, c.trigger AS commit_trigger,
                c.created_at AS commit_created_at
         FROM workspace_commit_files f
         INNER JOIN workspace_commits c ON c.id = f.commit_id
         WHERE f.id = ? AND f.workspace_id = ? LIMIT 1''',
      <Object?>[versionId, workspaceId],
    );
    if (rows.isEmpty) throw StateError('工作区文件版本不存在：$versionId');
    final rawVersion = WorkspaceFileVersionRecord.fromMap(rows.single);
    final ordered = await workspaceFileVersions(
      workspaceId: workspaceId,
      fileId: rawVersion.fileId,
    );
    final version =
        ordered.where((item) => item.id == versionId).firstOrNull ??
        rawVersion.withSequence(1);
    final snapshot = File(
      '${store.paths.files.path}${Platform.pathSeparator}${version.relativePath.replaceAll('/', Platform.pathSeparator)}',
    );
    final content = await _readVerifiedFile(
      snapshot,
      expectedByteSize: version.byteSize,
      expectedSha256: version.sha256,
    );
    return VerifiedWorkspaceFileVersion(version: version, content: content);
  }

  Future<VerifiedWorkspaceFileWrite> restoreWorkspaceFileVersion(
    String versionId, {
    required String workspaceId,
  }) async {
    final snapshot = await readWorkspaceFileVersion(
      versionId,
      workspaceId: workspaceId,
    );
    await createWorkspaceCheckpoint(
      workspaceId,
      message: '恢复文件前自动检查点：${snapshot.version.name}',
      trigger: 'before_file_restore',
      force: true,
    );
    final receipt = await saveWorkspaceFile(
      workspaceId: workspaceId,
      id: snapshot.version.fileId,
      name: snapshot.version.name,
      type: snapshot.version.type,
      content: snapshot.content,
    );
    await createWorkspaceCheckpoint(
      workspaceId,
      message: '恢复 ${snapshot.version.name} 到版本 #${snapshot.version.sequence}',
      trigger: 'file_version_restore',
    );
    return receipt;
  }

  Future<WorkspaceCommitRecord> createWorkspaceCheckpoint(
    String workspaceId, {
    required String message,
    String author = 'user',
    String trigger = 'manual',
    bool force = false,
  }) async {
    final files = await workspaceFiles(workspaceId);
    files.sort((left, right) {
      final byName = left.name.compareTo(right.name);
      return byName == 0 ? left.id.compareTo(right.id) : byName;
    });
    final manifest = <Map<String, Object?>>[];
    final snapshots = <Map<String, Object?>>[];
    for (final file in files) {
      final source = File(
        '${store.paths.files.path}${Platform.pathSeparator}${file.relativePath.replaceAll('/', Platform.pathSeparator)}',
      );
      if (!await source.exists()) {
        throw FileIntegrityException('无法创建检查点，文件内容缺失：${file.name}');
      }
      final bytes = await source.readAsBytes();
      final digest = await _sha256Hex(bytes);
      if (file.sha256.isNotEmpty && digest != file.sha256.toLowerCase()) {
        throw FileIntegrityException('无法创建检查点，文件校验失败：${file.name}');
      }
      final snapshotRelative = 'workspaces/$workspaceId/.history/$digest.blob';
      final snapshot = File(
        '${store.paths.files.path}${Platform.pathSeparator}${snapshotRelative.replaceAll('/', Platform.pathSeparator)}',
      );
      if (!await snapshot.exists()) {
        await snapshot.parent.create(recursive: true);
        await snapshot.writeAsBytes(bytes, flush: true);
      }
      manifest.add(<String, Object?>{
        'id': file.id,
        'name': file.name,
        'type': file.type,
        'sha256': digest,
      });
      snapshots.add(<String, Object?>{
        'file': file,
        'relative_path': snapshotRelative,
        'sha256': digest,
        'byte_size': bytes.length,
      });
    }
    final manifestSha256 = await _sha256Hex(utf8.encode(jsonEncode(manifest)));
    final latestRows = await store.database.query(
      'workspace_commits',
      where: 'workspace_id = ?',
      whereArgs: <Object?>[workspaceId],
      orderBy: 'sequence DESC',
      limit: 1,
    );
    if (!force &&
        latestRows.isNotEmpty &&
        latestRows.single['manifest_sha256'] == manifestSha256) {
      return WorkspaceCommitRecord.fromMap(latestRows.single);
    }
    final workspaceRows = await store.database.query(
      'workspaces',
      where: 'id = ?',
      whereArgs: <Object?>[workspaceId],
      limit: 1,
    );
    if (workspaceRows.isEmpty) {
      throw StateError('工作区不存在');
    }
    final now = DateTime.now().toUtc();
    final commitId = _uuid.v4();
    final sequence = latestRows.isEmpty
        ? 1
        : ((latestRows.single['sequence'] as num?)?.toInt() ?? 0) + 1;
    await store.database.transaction((transaction) async {
      await transaction.insert('workspace_commits', <String, Object?>{
        'id': commitId,
        'workspace_id': workspaceId,
        'parent_commit_id': latestRows.isEmpty ? null : latestRows.single['id'],
        'sequence': sequence,
        'message': message.trim().isEmpty ? '保存检查点' : message.trim(),
        'author': author,
        'trigger': trigger,
        'manifest_sha256': manifestSha256,
        'file_count': files.length,
        'settings_json': workspaceRows.single['settings_json'] ?? '{}',
        'created_at': now.toIso8601String(),
        'revision': 1,
        'origin_device_id': store.deviceId,
      });
      for (final item in snapshots) {
        final file = item['file']! as WorkspaceFileRecord;
        await transaction.insert('workspace_commit_files', <String, Object?>{
          'id': _uuid.v4(),
          'commit_id': commitId,
          'workspace_id': workspaceId,
          'file_id': file.id,
          'name': file.name,
          'type': file.type,
          'relative_path': item['relative_path'],
          'sha256': item['sha256'],
          'byte_size': item['byte_size'],
          'created_at': now.toIso8601String(),
        });
      }
    });
    return WorkspaceCommitRecord(
      id: commitId,
      workspaceId: workspaceId,
      parentCommitId: latestRows.isEmpty
          ? null
          : latestRows.single['id'] as String?,
      sequence: sequence,
      message: message.trim().isEmpty ? '保存检查点' : message.trim(),
      author: author,
      trigger: trigger,
      manifestSha256: manifestSha256,
      fileCount: files.length,
      createdAt: now,
    );
  }

  Future<void> restoreWorkspaceCheckpoint(WorkspaceCommitRecord commit) async {
    final rows = await store.database.query(
      'workspace_commit_files',
      where: 'commit_id = ?',
      whereArgs: <Object?>[commit.id],
      orderBy: 'name ASC',
    );
    final verifiedSnapshots = <({Map<String, Object?> row, List<int> bytes})>[];
    for (final row in rows) {
      final snapshot = File(
        '${store.paths.files.path}${Platform.pathSeparator}${(row['relative_path']! as String).replaceAll('/', Platform.pathSeparator)}',
      );
      if (!await snapshot.exists()) {
        throw FileIntegrityException('检查点文件缺失：${row['name']}');
      }
      final bytes = await snapshot.readAsBytes();
      if (bytes.length != (row['byte_size'] as num).toInt()) {
        throw FileIntegrityException('检查点文件大小校验失败：${row['name']}');
      }
      final digest = await _sha256Hex(bytes);
      if (digest != '${row['sha256']}'.toLowerCase()) {
        throw FileIntegrityException('检查点文件校验失败：${row['name']}');
      }
      verifiedSnapshots.add((row: row, bytes: bytes));
    }
    await createWorkspaceCheckpoint(
      commit.workspaceId,
      message: '回退前自动检查点（目标 #${commit.sequence}）',
      trigger: 'before_restore',
      force: true,
    );
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    await store.database.rawUpdate(
      'UPDATE workspace_files SET deleted_at = ?, updated_at = ?, revision = revision + 1 WHERE workspace_id = ? AND deleted_at IS NULL',
      <Object?>[deletedAt, deletedAt, commit.workspaceId],
    );
    for (final snapshot in verifiedSnapshots) {
      final row = snapshot.row;
      await saveWorkspaceFile(
        workspaceId: commit.workspaceId,
        id: row['file_id']! as String,
        name: row['name']! as String,
        type: row['type']! as String,
        content: utf8.decode(snapshot.bytes),
      );
    }
  }
}
