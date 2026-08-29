import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';

class ValidatedBackupArchive {
  const ValidatedBackupArchive({required this.manifest, required this.entries});

  final Map<String, Object?> manifest;
  final Map<String, ArchiveFile> entries;
}

Future<ValidatedBackupArchive> validateBackupArchive(
  List<int> zipBytes, {
  required bool encrypted,
}) async {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
  } on Object {
    throw const FormatException('备份 ZIP 已损坏');
  }
  final totalSize = archive.fold<int>(0, (sum, file) => sum + file.size);
  if (archive.length > 10000 || totalSize > 4 * 1024 * 1024 * 1024) {
    throw const FormatException('备份内容超过安全限制');
  }
  final entries = <String, ArchiveFile>{};
  for (final file in archive.where((item) => item.isFile)) {
    final name = file.name;
    final segments = name.split('/');
    if (name.isEmpty ||
        name.length > 512 ||
        name.startsWith('/') ||
        name.contains(r'\') ||
        name.contains(':') ||
        segments.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw FormatException('备份包含不安全路径：$name');
    }
    if (entries.containsKey(name)) {
      throw FormatException('备份包含重复条目：$name');
    }
    entries[name] = file;
  }
  final manifestFile = entries['manifest.json'];
  if (manifestFile == null) {
    throw const FormatException('不是有效的 Claude Chat 备份');
  }
  final Map<String, Object?> manifest;
  try {
    final decoded = jsonDecode(utf8.decode(manifestFile.content));
    if (decoded is! Map) throw const FormatException();
    manifest = decoded.cast<String, Object?>();
  } on Object {
    throw const FormatException('备份清单已损坏');
  }
  if (manifest['format'] != 'claudechat-backup' ||
      (manifest['formatVersion'] as num?)?.toInt() != 1) {
    throw const FormatException('不支持的备份格式');
  }
  final checksumsRaw = manifest['checksums'];
  if (checksumsRaw is! Map) throw const FormatException('备份缺少校验清单');
  final checksums = checksumsRaw.cast<String, Object?>();
  final payloadNames = entries.keys.where((name) => name != 'manifest.json');
  for (final name in payloadNames) {
    if (!checksums.containsKey(name)) {
      throw FormatException('备份包含未校验的条目：$name');
    }
  }
  for (final checksum in checksums.entries) {
    final file = entries[checksum.key];
    if (file == null ||
        checksum.value is! String ||
        await _sha256(file.content) != checksum.value) {
      throw FormatException('文件校验失败：${checksum.key}');
    }
  }
  final secretEntry = entries['secure/api_keys.json'];
  final includesSecrets = manifest['includesSecrets'] == true;
  final migration = manifest['migration'];
  final allowsLegacyPlaintextSecrets =
      !encrypted &&
      manifest['source'] == 'legacy-web-full-export' &&
      migration is Map &&
      migration['direction'] == 'legacy-web-to-flutter' &&
      migration['plaintextSecrets'] == true;
  if (secretEntry != null &&
      (!includesSecrets || (!encrypted && !allowsLegacyPlaintextSecrets))) {
    throw const FormatException('API 密钥只能存在于声明为含密钥的加密备份中');
  }
  if (includesSecrets &&
      (secretEntry == null || (!encrypted && !allowsLegacyPlaintextSecrets))) {
    throw const FormatException('含 API 密钥的备份声明与内容不一致');
  }
  return ValidatedBackupArchive(manifest: manifest, entries: entries);
}

Future<String> _sha256(List<int> bytes) async =>
    base64Encode((await Sha256().hash(bytes)).bytes);
