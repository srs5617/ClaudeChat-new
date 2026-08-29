import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../data/schema.dart';
import '../domain/entities.dart';
import 'backup_crypto.dart';
import 'backup_validator.dart';
import 'merge_policy.dart';
import 'portable_data_service.dart';
import 'secure_vault.dart';

const _uuid = Uuid();

class BackupService {
  BackupService(
    this.store,
    this.vault, {
    BackupCrypto? crypto,
    MergePolicy? mergePolicy,
  }) : crypto = crypto ?? BackupCrypto(),
       mergePolicy = mergePolicy ?? const MergePolicy();

  final AppDatabase store;
  final SecureVault vault;
  final BackupCrypto crypto;
  final MergePolicy mergePolicy;
  final Map<String, String> _relocatedFiles = <String, String>{};

  Future<Uint8List> export({
    String? password,
    bool includeSecrets = false,
  }) async {
    await PortableDataService(store).rebuild();
    final backupId = _uuid.v4();
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final archive = Archive();
    final checksums = <String, String>{};
    final counts = <String, int>{};
    for (final table in exportedTables) {
      final rows = await store.rows(table);
      final body = rows.map(jsonLine).join('\n');
      final bytes = utf8.encode(body);
      final name = 'data/$table.jsonl';
      archive.addFile(ArchiveFile.bytes(name, bytes));
      checksums[name] = await _sha256(bytes);
      counts[table] = rows.length;
    }
    if (includeSecrets) {
      if (password == null || password.isEmpty) {
        throw const FormatException('包含 API 密钥的备份必须设置密码');
      }
      final bytes = utf8.encode(jsonEncode(await vault.exportSecrets()));
      archive.addFile(ArchiveFile.bytes('secure/api_keys.json', bytes));
      checksums['secure/api_keys.json'] = await _sha256(bytes);
    }
    final portableDirectories = <String, Directory>{
      'attachments': store.paths.attachments,
      'files': store.paths.files,
      'fonts': store.paths.fonts,
      'icons': store.paths.icons,
      'voices': store.paths.voices,
    };
    for (final named in portableDirectories.entries) {
      final directory = named.value;
      if (!directory.existsSync()) continue;
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final relative = entity.path
            .substring(directory.path.length + 1)
            .replaceAll('\\', '/');
        if (relative.contains('../')) continue;
        final bytes = await entity.readAsBytes();
        final name = '${named.key}/$relative';
        archive.addFile(ArchiveFile.bytes(name, bytes));
        checksums[name] = await _sha256(bytes);
      }
    }
    final manifest = <String, Object?>{
      'format': 'claudechat-backup',
      'formatVersion': 1,
      'schemaVersion': databaseVersion,
      'backupId': backupId,
      'sourceDeviceId': store.deviceId,
      'createdAt': createdAt,
      'mergeMode': 'merge',
      'counts': counts,
      'checksums': checksums,
      'includesSecrets': includeSecrets,
    };
    archive.addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
    final zipped = ZipEncoder().encodeBytes(archive);
    return password == null || password.isEmpty
        ? zipped
        : crypto.encrypt(zipped, password);
  }

  Future<ImportReport> import(List<int> source, {String? password}) async {
    final encrypted = crypto.isEncrypted(source);
    final zipBytes = encrypted
        ? await crypto.decrypt(source, password ?? '')
        : Uint8List.fromList(source);
    final validated = await validateBackupArchive(
      zipBytes,
      encrypted: encrypted,
    );
    final entries = validated.entries;
    final manifest = validated.manifest;
    final secretValues = _decodeSecrets(entries['secure/api_keys.json']);
    final previousSecrets = secretValues == null
        ? null
        : await vault.exportSecrets();
    final backupId = manifest['backupId']! as String;
    final duplicate = await store.database.query(
      'import_batches',
      where: 'backup_id = ?',
      whereArgs: <Object?>[backupId],
      limit: 1,
    );
    await _preflightFiles(entries, backupId);
    final report = ImportReport();
    final batchId = duplicate.isEmpty
        ? _uuid.v4()
        : duplicate.first['id']! as String;
    final stagedFiles = await _stageFiles(entries, batchId);
    final installedFiles = <File>[];
    try {
      await store.database.transaction((transaction) async {
        final startedAt = DateTime.now().toUtc().toIso8601String();
        if (duplicate.isEmpty) {
          await transaction.insert('import_batches', <String, Object?>{
            'id': batchId,
            'backup_id': backupId,
            'source_device_id': manifest['sourceDeviceId'],
            'started_at': startedAt,
            'status': 'running',
            'report_json': '{}',
          });
        } else {
          await transaction.update(
            'import_batches',
            <String, Object?>{
              'source_device_id': manifest['sourceDeviceId'],
              'started_at': startedAt,
              'completed_at': null,
              'status': 'running',
              'report_json': '{}',
            },
            where: 'id = ?',
            whereArgs: <Object?>[batchId],
          );
        }
        for (final table in exportedTables) {
          final file = entries['data/$table.jsonl'];
          if (file == null || file.content.isEmpty) continue;
          final lines = const LineSplitter().convert(utf8.decode(file.content));
          for (final line in lines.where((value) => value.trim().isNotEmpty)) {
            final incoming = (jsonDecode(line) as Map).cast<String, Object?>();
            await _mergeRow(transaction, batchId, table, incoming, report);
          }
        }
        await _installStagedFiles(stagedFiles, installedFiles);
        if (secretValues != null) await vault.mergeSecrets(secretValues);
        await transaction.update(
          'import_batches',
          <String, Object?>{
            'status': 'database_complete',
            'report_json': jsonEncode(report.toJson()),
          },
          where: 'id = ?',
          whereArgs: <Object?>[batchId],
        );
      });
    } on Object {
      await _rollbackInstalledFiles(installedFiles);
      if (previousSecrets != null) {
        await vault.replaceSecrets(previousSecrets);
      }
      await _discardStagedFiles(stagedFiles);
      rethrow;
    }
    await _discardStagedFiles(stagedFiles);
    await store.database.update(
      'import_batches',
      <String, Object?>{
        'completed_at': DateTime.now().toUtc().toIso8601String(),
        'status': 'complete',
        'report_json': jsonEncode(report.toJson()),
      },
      where: 'id = ?',
      whereArgs: <Object?>[batchId],
    );
    await PortableDataService(store).rebuild();
    return report;
  }

  Map<String, Object?>? _decodeSecrets(ArchiveFile? file) {
    if (file == null) return null;
    try {
      final decoded = jsonDecode(utf8.decode(file.content));
      if (decoded is! Map) throw const FormatException();
      final values = decoded.cast<String, Object?>();
      if (values.entries.any(
        (entry) =>
            entry.key.trim().isEmpty ||
            entry.value is! String ||
            (entry.value! as String).isEmpty,
      )) {
        throw const FormatException();
      }
      return values;
    } on Object {
      throw const FormatException('API 密钥载荷已损坏');
    }
  }

  Future<void> _mergeRow(
    Transaction transaction,
    String batchId,
    String table,
    Map<String, Object?> incoming,
    ImportReport report,
  ) async {
    if ((table == 'workspace_files' || table == 'workspace_commit_files') &&
        incoming['relative_path'] is String) {
      final original = incoming['relative_path']! as String;
      final relocated = _relocatedFiles[original];
      if (relocated != null) {
        incoming = <String, Object?>{...incoming, 'relative_path': relocated};
      }
    }
    if (table == 'entity_revisions') {
      final match = await transaction.query(
        table,
        where: 'content_hash = ?',
        whereArgs: <Object?>[incoming['content_hash']],
        limit: 1,
      );
      if (match.isNotEmpty) {
        report.skipped++;
        return;
      }
      final copy = <String, Object?>{...incoming}..remove('id');
      await transaction.insert(table, copy);
      report.added++;
      return;
    }
    final identity = _identityFor(table, incoming);
    final where = identity.keys.map((key) => '$key = ?').join(' AND ');
    final args = identity.values.toList();
    final rows = await transaction.query(
      table,
      where: where,
      whereArgs: args,
      limit: 1,
    );
    final local = rows.isEmpty ? null : rows.first;
    final decision = mergePolicy.decide(
      table: table,
      local: local,
      incoming: incoming,
    );
    switch (decision.action) {
      case MergeAction.add:
        await transaction.insert(
          table,
          incoming,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        report.added++;
        break;
      case MergeAction.skip:
        report.skipped++;
        break;
      case MergeAction.replaceLocal:
      case MergeAction.applyTombstone:
        await _recordRevision(
          transaction,
          table,
          identity.values.join(':'),
          local!,
          batchId,
        );
        await transaction.update(
          table,
          incoming,
          where: where,
          whereArgs: args,
        );
        if (decision.action == MergeAction.replaceLocal &&
            incoming['deleted_at'] == null &&
            incoming['id'] != null) {
          await transaction.delete(
            'tombstones',
            where: 'entity_type = ? AND entity_id = ?',
            whereArgs: <Object?>[table, incoming['id']],
          );
        }
        report.updated++;
        break;
      case MergeAction.preserveBoth:
        await transaction.insert('import_conflicts', <String, Object?>{
          'id': _uuid.v4(),
          'import_batch_id': batchId,
          'entity_type': table,
          'entity_id': identity.values.join(':'),
          'local_snapshot_json': jsonEncode(local),
          'imported_snapshot_json': jsonEncode(incoming),
          'resolution': 'kept-local-recorded-import',
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
        await _recordRevision(
          transaction,
          table,
          identity.values.join(':'),
          incoming,
          batchId,
        );
        report.conflicts++;
        break;
    }
  }

  Map<String, Object?> _identityFor(String table, Map<String, Object?> row) {
    const compound = <String, List<String>>{
      'settings': <String>['key'],
      'attachment_references': <String>[
        'attachment_id',
        'owner_type',
        'owner_id',
      ],
      'platform_bindings': <String>[
        'entity_type',
        'entity_id',
        'platform',
        'binding_type',
        'device_id',
      ],
      'tombstones': <String>['entity_type', 'entity_id'],
    };
    final keys = compound[table] ?? <String>['id'];
    return <String, Object?>{for (final key in keys) key: row[key]};
  }

  Future<void> _recordRevision(
    Transaction transaction,
    String table,
    String id,
    Map<String, Object?> snapshot,
    String batchId,
  ) async {
    await transaction.insert('entity_revisions', <String, Object?>{
      'entity_type': table,
      'entity_id': id,
      'revision': (snapshot['revision'] as num?)?.toInt() ?? 1,
      'snapshot_json': jsonEncode(snapshot),
      'content_hash': await _sha256(utf8.encode(jsonLine(snapshot))),
      'recorded_at': DateTime.now().toUtc().toIso8601String(),
      'import_batch_id': batchId,
    });
  }

  Future<List<_StagedFile>> _stageFiles(
    Map<String, ArchiveFile> entries,
    String batchId,
  ) async {
    final stagingRoot = Directory(
      '${store.paths.importStaging.path}${Platform.pathSeparator}$batchId',
    );
    final output = <_StagedFile>[];
    var index = 0;
    try {
      for (final entry in entries.entries) {
        final destination = _fileDestination(entry.key);
        if (destination == null || destination.existsSync()) continue;
        final staged = File(
          '${stagingRoot.path}${Platform.pathSeparator}${index++}.part',
        );
        await staged.parent.create(recursive: true);
        await staged.writeAsBytes(entry.value.content, flush: true);
        output.add(_StagedFile(staged: staged, destination: destination));
      }
      return output;
    } on Object {
      await _discardStagedFiles(output, stagingRoot: stagingRoot);
      rethrow;
    }
  }

  Future<void> _installStagedFiles(
    List<_StagedFile> stagedFiles,
    List<File> installedFiles,
  ) async {
    for (final item in stagedFiles) {
      await item.destination.parent.create(recursive: true);
      if (item.destination.existsSync()) {
        if (await _sha256File(item.destination) !=
            await _sha256File(item.staged)) {
          throw FormatException('导入期间目标文件已被其他操作修改：${item.destination.path}');
        }
        await item.staged.delete();
        continue;
      }
      await item.staged.rename(item.destination.path);
      installedFiles.add(item.destination);
    }
  }

  Future<void> _rollbackInstalledFiles(List<File> installedFiles) async {
    for (final file in installedFiles.reversed) {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _discardStagedFiles(
    List<_StagedFile> stagedFiles, {
    Directory? stagingRoot,
  }) async {
    for (final item in stagedFiles) {
      if (await item.staged.exists()) await item.staged.delete();
    }
    final root = stagingRoot ?? stagedFiles.firstOrNull?.staged.parent;
    if (root != null &&
        root.parent.path == store.paths.importStaging.path &&
        await root.exists()) {
      await root.delete(recursive: true);
    }
  }

  File? _fileDestination(String entryName) {
    Directory? root;
    String? relative;
    if (entryName.startsWith('attachments/')) {
      root = store.paths.attachments;
      relative = entryName.substring('attachments/'.length);
    } else if (entryName.startsWith('files/')) {
      root = store.paths.files;
      relative = entryName.substring('files/'.length);
      relative = _relocatedFiles[relative] ?? relative;
    } else if (entryName.startsWith('fonts/')) {
      root = store.paths.fonts;
      relative = entryName.substring('fonts/'.length);
    } else if (entryName.startsWith('icons/')) {
      root = store.paths.icons;
      relative = entryName.substring('icons/'.length);
    } else if (entryName.startsWith('voices/')) {
      root = store.paths.voices;
      relative = entryName.substring('voices/'.length);
    }
    if (root == null ||
        relative == null ||
        relative.contains('..') ||
        relative.startsWith('/')) {
      return null;
    }
    return File(
      '${root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
    );
  }

  Future<void> _preflightFiles(
    Map<String, ArchiveFile> entries,
    String backupId,
  ) async {
    _relocatedFiles.clear();
    final workspaceHashes = <String, String>{};
    final workspaceData = entries['data/workspace_files.jsonl'];
    if (workspaceData != null && workspaceData.content.isNotEmpty) {
      for (final line in const LineSplitter().convert(
        utf8.decode(workspaceData.content),
      )) {
        if (line.trim().isEmpty) continue;
        final row = (jsonDecode(line) as Map).cast<String, Object?>();
        final path = row['relative_path'];
        final hash = row['sha256'];
        if (path is String && hash is String) workspaceHashes[path] = hash;
      }
    }
    for (final entry in entries.entries) {
      Directory? root;
      String? relative;
      if (entry.key.startsWith('attachments/')) {
        root = store.paths.attachments;
        relative = entry.key.substring('attachments/'.length);
      } else if (entry.key.startsWith('files/')) {
        root = store.paths.files;
        relative = entry.key.substring('files/'.length);
      } else if (entry.key.startsWith('fonts/')) {
        root = store.paths.fonts;
        relative = entry.key.substring('fonts/'.length);
      } else if (entry.key.startsWith('icons/')) {
        root = store.paths.icons;
        relative = entry.key.substring('icons/'.length);
      } else if (entry.key.startsWith('voices/')) {
        root = store.paths.voices;
        relative = entry.key.substring('voices/'.length);
      }
      if (root == null ||
          relative == null ||
          relative.contains('..') ||
          relative.startsWith('/'))
        continue;
      final output = File(
        '${root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
      );
      if (!output.existsSync()) continue;
      if (await _sha256File(output) == await _sha256(entry.value.content))
        continue;
      final incomingDigest = (await Sha256().hash(
        entry.value.content,
      )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      if (root.path == store.paths.files.path &&
          workspaceHashes[relative] == incomingDigest) {
        final name = relative.split('/').last;
        _relocatedFiles[relative] =
            'workspaces/imported-$backupId/$incomingDigest/$name';
        continue;
      }
      throw FormatException('本机文件与备份中的同一路径内容不同，已在写入数据库前停止：$relative');
    }
  }

  Future<String> _sha256(List<int> bytes) async =>
      base64Encode((await Sha256().hash(bytes)).bytes);

  Future<String> _sha256File(File file) async {
    final sink = Sha256().toSync().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    return base64Encode((await sink.hash()).bytes);
  }
}

class _StagedFile {
  const _StagedFile({required this.staged, required this.destination});

  final File staged;
  final File destination;
}
