import 'dart:convert';
import 'dart:io';

import '../data/app_database.dart';

/// Maintains a human-inspectable, category-based mirror of the transactional
/// SQLite store. SQLite remains the authoritative index; every JSON record
/// keeps the original IDs, revisions, deletion markers and ordered message
/// parts so the mirror never flattens conversation state.
class PortableDataService {
  PortableDataService(this.store);

  final AppDatabase store;
  Future<void> _mutationTail = Future<void>.value();

  Future<void> rebuild() => _serialize(_rebuild);

  Future<void> _rebuild() async {
    await store.paths.ensureCreated();
    final livePaths = <String>[];

    await _write(
      '${store.paths.settings.path}${Platform.pathSeparator}settings.json',
      await store.database.query('settings', orderBy: 'key ASC'),
      livePaths,
    );
    await _write(
      '${store.paths.settings.path}${Platform.pathSeparator}api-profiles.json',
      await store.database.query('api_profiles', orderBy: 'created_at ASC'),
      livePaths,
    );
    await _write(
      '${store.paths.settings.path}${Platform.pathSeparator}voice-profiles.json',
      await store.database.query('voice_profiles', orderBy: 'created_at ASC'),
      livePaths,
    );
    await _write(
      '${store.paths.settings.path}${Platform.pathSeparator}devices.json',
      await store.database.query('devices', orderBy: 'created_at ASC'),
      livePaths,
    );

    final conversations = await store.database.query(
      'conversations',
      orderBy: 'created_at ASC, id ASC',
    );
    for (final conversation in conversations) {
      final id = _segment('${conversation['id']}');
      final root =
          '${store.paths.conversations.path}${Platform.pathSeparator}$id';
      await _write(
        '$root${Platform.pathSeparator}conversation.json',
        conversation,
        livePaths,
      );
      final messages = await store.database.query(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: <Object?>[conversation['id']],
        orderBy: 'sequence ASC, id ASC',
      );
      for (final message in messages) {
        final parts = await store.database.query(
          'message_parts',
          where: 'message_id = ?',
          whereArgs: <Object?>[message['id']],
          orderBy: 'sequence ASC, id ASC',
        );
        final sequence = ((message['sequence'] as num?)?.toInt() ?? 0)
            .toString()
            .padLeft(8, '0');
        final messageId = _segment('${message['id']}');
        await _write(
          '$root${Platform.pathSeparator}messages${Platform.pathSeparator}$sequence-$messageId.json',
          <String, Object?>{'message': message, 'parts': parts},
          livePaths,
        );
      }
      final attachments = await store.database.rawQuery(
        '''SELECT a.*, r.owner_id AS message_id, r.position
           FROM attachments a
           JOIN attachment_references r ON r.attachment_id = a.id
           JOIN messages m ON m.id = r.owner_id
           WHERE r.owner_type = 'message' AND m.conversation_id = ?
           ORDER BY m.sequence ASC, r.position ASC''',
        <Object?>[conversation['id']],
      );
      await _write(
        '$root${Platform.pathSeparator}attachments${Platform.pathSeparator}index.json',
        attachments,
        livePaths,
      );
      for (final attachment in attachments) {
        final relative = '${attachment['relative_path']}';
        if (relative.contains('..') || relative.startsWith('/')) continue;
        final source = File(
          '${store.paths.attachments.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
        );
        if (!source.existsSync()) continue;
        final name = _fileName('${attachment['original_name']}');
        await _copy(
          source,
          '$root${Platform.pathSeparator}attachments${Platform.pathSeparator}${_segment('${attachment['id']}')}${Platform.pathSeparator}$name',
          livePaths,
        );
      }
    }

    final allAttachments = await store.database.query(
      'attachments',
      orderBy: 'created_at ASC, id ASC',
    );
    final allAttachmentReferences = await store.database.query(
      'attachment_references',
      orderBy: 'owner_type ASC, owner_id ASC, position ASC',
    );
    await _write(
      '${store.paths.data.path}${Platform.pathSeparator}attachments${Platform.pathSeparator}index.json',
      <String, Object?>{
        'attachments': allAttachments,
        'references': allAttachmentReferences,
      },
      livePaths,
    );

    final voiceAssets = await store.database.query(
      'voice_assets',
      orderBy: 'library_number ASC, id ASC',
    );
    for (final asset in voiceAssets) {
      final conversationId = _segment('${asset['conversation_id']}');
      final messageId = _segment('${asset['message_id']}');
      final assetId = _segment('${asset['id']}');
      final root =
          '${store.paths.voices.path}${Platform.pathSeparator}$conversationId${Platform.pathSeparator}$messageId';
      await _write(
        '$root${Platform.pathSeparator}$assetId.json',
        asset,
        livePaths,
      );
      final source = _storedFile(
        store.paths.voices,
        '${asset['relative_path'] ?? ''}',
      );
      if (source != null && source.existsSync()) livePaths.add(source.path);
    }

    await _writeRowsById(
      table: 'memories',
      root: store.paths.memories,
      livePaths: livePaths,
    );

    final diaries = await store.database.query(
      'diary_entries',
      orderBy: 'created_at ASC, id ASC',
    );
    for (final entry in diaries) {
      final id = _segment('${entry['id']}');
      final root = '${store.paths.diary.path}${Platform.pathSeparator}$id';
      await _write(
        '$root${Platform.pathSeparator}entry.json',
        entry,
        livePaths,
      );
      final versions = await store.database.query(
        'diary_versions',
        where: 'diary_id = ?',
        whereArgs: <Object?>[entry['id']],
        orderBy: 'created_at ASC, id ASC',
      );
      for (final version in versions) {
        await _write(
          '$root${Platform.pathSeparator}versions${Platform.pathSeparator}${_segment('${version['id']}')}.json',
          version,
          livePaths,
        );
      }
    }

    final userFiles = await store.database.query(
      'user_files',
      orderBy: 'created_at ASC, id ASC',
    );
    for (final entry in userFiles) {
      final id = _segment('${entry['id']}');
      final root = '${store.paths.dataFiles.path}${Platform.pathSeparator}$id';
      await _write('$root${Platform.pathSeparator}file.json', entry, livePaths);
      final versions = await store.database.query(
        'file_versions',
        where: 'file_id = ?',
        whereArgs: <Object?>[entry['id']],
        orderBy: 'created_at ASC, id ASC',
      );
      await _write(
        '$root${Platform.pathSeparator}versions.json',
        versions,
        livePaths,
      );
      for (final version in versions) {
        final versionId = _segment('${version['id']}');
        final versionRoot =
            '$root${Platform.pathSeparator}versions${Platform.pathSeparator}$versionId';
        await _write(
          '$versionRoot${Platform.pathSeparator}version.json',
          version,
          livePaths,
        );
        final source = _storedFile(
          store.paths.files,
          '${version['relative_path'] ?? ''}',
        );
        if (source != null && source.existsSync()) {
          final name = _fileName('${entry['name'] ?? 'content.txt'}');
          await _copy(
            source,
            '$versionRoot${Platform.pathSeparator}${name.isEmpty ? 'content.txt' : name}',
            livePaths,
          );
        }
      }
    }

    final workspaces = await store.database.query(
      'workspaces',
      orderBy: 'created_at ASC, id ASC',
    );
    for (final workspace in workspaces) {
      final id = _segment('${workspace['id']}');
      final root = '${store.paths.workspaces.path}${Platform.pathSeparator}$id';
      await _write(
        '$root${Platform.pathSeparator}workspace.json',
        workspace,
        livePaths,
      );
      final files = await store.database.query(
        'workspace_files',
        where: 'workspace_id = ?',
        whereArgs: <Object?>[workspace['id']],
        orderBy: 'created_at ASC, id ASC',
      );
      final workspaceConversations = await store.database.query(
        'workspace_conversations',
        where: 'workspace_id = ?',
        whereArgs: <Object?>[workspace['id']],
        orderBy: 'created_at ASC, id ASC',
      );
      final messages = await store.database.query(
        'workspace_messages',
        where: 'workspace_id = ?',
        whereArgs: <Object?>[workspace['id']],
        orderBy: 'sequence ASC, id ASC',
      );
      final messageParts = await store.database.rawQuery(
        '''SELECT p.* FROM workspace_message_parts p
           INNER JOIN workspace_messages m ON m.id = p.message_id
           WHERE m.workspace_id = ?
           ORDER BY m.sequence ASC, p.sequence ASC''',
        <Object?>[workspace['id']],
      );
      final commits = await store.database.query(
        'workspace_commits',
        where: 'workspace_id = ?',
        whereArgs: <Object?>[workspace['id']],
        orderBy: 'sequence ASC, id ASC',
      );
      final commitFiles = await store.database.query(
        'workspace_commit_files',
        where: 'workspace_id = ?',
        whereArgs: <Object?>[workspace['id']],
        orderBy: 'created_at ASC, id ASC',
      );
      await _write(
        '$root${Platform.pathSeparator}files.json',
        files,
        livePaths,
      );
      await _write(
        '$root${Platform.pathSeparator}conversations.json',
        workspaceConversations,
        livePaths,
      );
      await _write(
        '$root${Platform.pathSeparator}messages.json',
        messages,
        livePaths,
      );
      await _write(
        '$root${Platform.pathSeparator}message_parts.json',
        messageParts,
        livePaths,
      );
      await _write(
        '$root${Platform.pathSeparator}commits.json',
        commits,
        livePaths,
      );
      await _write(
        '$root${Platform.pathSeparator}commit_files.json',
        commitFiles,
        livePaths,
      );
      for (final message in messages) {
        final sequence = ((message['sequence'] as num?)?.toInt() ?? 0)
            .toString()
            .padLeft(8, '0');
        final messageId = _segment('${message['id']}');
        await _write(
          '$root${Platform.pathSeparator}messages${Platform.pathSeparator}$sequence-$messageId.json',
          message,
          livePaths,
        );
      }
      for (final file in files) {
        final fileId = _segment('${file['id']}');
        final fileRoot =
            '$root${Platform.pathSeparator}files${Platform.pathSeparator}$fileId';
        await _write(
          '$fileRoot${Platform.pathSeparator}file.json',
          file,
          livePaths,
        );
        final source = _storedFile(
          store.paths.files,
          '${file['relative_path'] ?? ''}',
        );
        if (source != null && source.existsSync()) {
          final name = _fileName('${file['name'] ?? 'content.txt'}');
          await _copy(
            source,
            '$fileRoot${Platform.pathSeparator}${name.isEmpty ? 'content.txt' : name}',
            livePaths,
          );
        }
      }
      for (final commit in commits) {
        final commitId = _segment('${commit['id']}');
        final commitRoot =
            '$root${Platform.pathSeparator}commits${Platform.pathSeparator}${commit['sequence']}-$commitId';
        await _write(
          '$commitRoot${Platform.pathSeparator}commit.json',
          commit,
          livePaths,
        );
        for (final file in commitFiles.where(
          (item) => item['commit_id'] == commit['id'],
        )) {
          final fileId = _segment('${file['file_id']}');
          await _write(
            '$commitRoot${Platform.pathSeparator}$fileId.json',
            file,
            livePaths,
          );
          final source = _storedFile(
            store.paths.files,
            '${file['relative_path'] ?? ''}',
          );
          if (source != null && source.existsSync()) {
            await _copy(
              source,
              '$commitRoot${Platform.pathSeparator}$fileId.blob',
              livePaths,
            );
          }
        }
      }
    }

    await _writeRowsById(
      table: 'reminders',
      root: store.paths.reminders,
      livePaths: livePaths,
    );
    await _write(
      '${store.paths.data.path}${Platform.pathSeparator}platform${Platform.pathSeparator}bindings.json',
      await store.database.query(
        'platform_bindings',
        orderBy: 'entity_type ASC, entity_id ASC, platform ASC',
      ),
      livePaths,
    );
    await _write(
      '${store.paths.data.path}${Platform.pathSeparator}deletions${Platform.pathSeparator}tombstones.json',
      await store.database.query(
        'tombstones',
        orderBy: 'deleted_at ASC, entity_type ASC, entity_id ASC',
      ),
      livePaths,
    );
    await _write(
      '${store.paths.data.path}${Platform.pathSeparator}history${Platform.pathSeparator}entity-revisions.json',
      await store.database.query(
        'entity_revisions',
        orderBy: 'recorded_at ASC, id ASC',
      ),
      livePaths,
    );
    await _write(
      '${store.paths.data.path}${Platform.pathSeparator}index.json',
      <String, Object?>{
        'format': 'claudechat-classified-data',
        'formatVersion': 1,
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'files': livePaths.map(_relative).toList()..sort(),
      },
      <String>[],
    );
  }

  /// Synchronizes one user file into the classified mirror without walking
  /// every conversation, workspace and historical attachment. The SQLite row
  /// plus the version blob remain authoritative; this mirror is derived data.
  Future<void> syncUserFile(String fileId) =>
      _serialize(() => _syncUserFile(fileId));

  Future<void> _syncUserFile(String fileId) async {
    await store.paths.ensureCreated();
    final rows = await store.database.query(
      'user_files',
      where: 'id = ?',
      whereArgs: <Object?>[fileId],
      limit: 1,
    );
    if (rows.isEmpty) return;

    final entry = rows.first;
    final id = _segment('${entry['id']}');
    final root = '${store.paths.dataFiles.path}${Platform.pathSeparator}$id';
    final livePaths = <String>[];
    await _write('$root${Platform.pathSeparator}file.json', entry, livePaths);
    final versions = await store.database.query(
      'file_versions',
      where: 'file_id = ?',
      whereArgs: <Object?>[entry['id']],
      orderBy: 'created_at ASC, id ASC',
    );
    await _write(
      '$root${Platform.pathSeparator}versions.json',
      versions,
      livePaths,
    );
    for (final version in versions) {
      final versionId = _segment('${version['id']}');
      final versionRoot =
          '$root${Platform.pathSeparator}versions${Platform.pathSeparator}$versionId';
      await _write(
        '$versionRoot${Platform.pathSeparator}version.json',
        version,
        livePaths,
      );
      final source = _storedFile(
        store.paths.files,
        '${version['relative_path'] ?? ''}',
      );
      if (source != null && source.existsSync()) {
        final name = _fileName('${entry['name'] ?? 'content.txt'}');
        await _copy(
          source,
          '$versionRoot${Platform.pathSeparator}${name.isEmpty ? 'content.txt' : name}',
          livePaths,
        );
      }
    }
    await _mergeFilePathsIntoIndex(root, livePaths);
  }

  Future<void> _mergeFilePathsIntoIndex(
    String root,
    List<String> livePaths,
  ) async {
    final index = File(
      '${store.paths.data.path}${Platform.pathSeparator}index.json',
    );
    if (!index.existsSync()) {
      await _rebuild();
      return;
    }
    final known = <String>{};
    try {
      final decoded = jsonDecode(await index.readAsString());
      if (decoded is Map && decoded['files'] is List) {
        known.addAll(
          (decoded['files']! as List).whereType<String>().where(
            (item) => item.trim().isNotEmpty,
          ),
        );
      }
    } on Object {
      await _rebuild();
      return;
    }
    final prefix = '${_relative(root)}/';
    known.removeWhere(
      (item) => item == _relative(root) || item.startsWith(prefix),
    );
    known.addAll(livePaths.map(_relative));
    await _write(index.path, <String, Object?>{
      'format': 'claudechat-classified-data',
      'formatVersion': 1,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'files': known.toList()..sort(),
    }, <String>[]);
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _mutationTail.then((_) => operation());
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _writeRowsById({
    required String table,
    required Directory root,
    required List<String> livePaths,
  }) async {
    final rows = await store.database.query(table, orderBy: 'id ASC');
    for (final row in rows) {
      await _write(
        '${root.path}${Platform.pathSeparator}${_segment('${row['id']}')}.json',
        row,
        livePaths,
      );
    }
  }

  Future<void> _write(
    String path,
    Object? value,
    List<String> livePaths,
  ) async {
    final output = File(path);
    await output.parent.create(recursive: true);
    final temporary = File('$path.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true,
    );
    if (output.existsSync()) await output.delete();
    await temporary.rename(path);
    livePaths.add(path);
  }

  Future<void> _copy(File source, String path, List<String> livePaths) async {
    final output = File(path);
    await output.parent.create(recursive: true);
    final sourceBytes = await source.readAsBytes();
    final unchanged =
        output.existsSync() &&
        _bytesEqual(await output.readAsBytes(), sourceBytes);
    if (!unchanged) {
      final temporary = File('$path.tmp');
      await temporary.writeAsBytes(sourceBytes, flush: true);
      if (output.existsSync()) await output.delete();
      await temporary.rename(path);
    }
    livePaths.add(path);
  }

  File? _storedFile(Directory root, String relative) {
    final normalized = relative.replaceAll('\\', '/');
    final parts = normalized.split('/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
        parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      return null;
    }
    final path =
        '${root.path}${Platform.pathSeparator}${parts.join(Platform.pathSeparator)}';
    final rootPath = root.absolute.path;
    final candidate = File(path).absolute.path;
    if (!candidate.startsWith('$rootPath${Platform.pathSeparator}')) {
      return null;
    }
    return File(candidate);
  }

  bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  String _relative(String path) =>
      path.substring(store.paths.data.path.length + 1).replaceAll('\\', '/');

  String _segment(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  String _fileName(String value) {
    var cleaned = value
        .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'content.txt';
    }
    final stem = cleaned.split('.').first.toUpperCase();
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$').hasMatch(stem)) {
      cleaned = '_$cleaned';
    }
    return cleaned;
  }
}
