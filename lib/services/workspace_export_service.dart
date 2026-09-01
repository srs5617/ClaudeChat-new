import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class WorkspaceExportService {
  const WorkspaceExportService._();

  static Uint8List buildZip(Map<String, String> files) {
    if (files.isEmpty) {
      throw const FormatException('工作区中没有可以导出的文件');
    }

    final normalizedFiles = <String, String>{};
    final directories = <String>{};
    for (final entry in files.entries) {
      final path = normalizeEntryPath(entry.key);
      if (normalizedFiles.containsKey(path)) {
        throw FormatException('工作区中存在重复的文件路径：$path');
      }
      normalizedFiles[path] = entry.value;

      final segments = path.split('/');
      for (var index = 1; index < segments.length; index++) {
        directories.add('${segments.take(index).join('/')}/');
      }
    }

    final archive = Archive();
    final sortedDirectories = directories.toList()
      ..sort((left, right) {
        final depth = left.split('/').length.compareTo(right.split('/').length);
        return depth == 0 ? left.compareTo(right) : depth;
      });
    for (final directory in sortedDirectories) {
      archive.addFile(ArchiveFile.directory(directory));
    }

    final sortedFiles = normalizedFiles.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    for (final file in sortedFiles) {
      archive.addFile(
        ArchiveFile.bytes(
          file.key,
          Uint8List.fromList(utf8.encode(file.value)),
        ),
      );
    }
    return ZipEncoder().encodeBytes(archive);
  }

  static Map<String, String> readZip(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final output = <String, String>{};
    for (final entry in archive.files.where((file) => file.isFile)) {
      final path = normalizeEntryPath(entry.name);
      final data = entry.readBytes();
      if (data == null) continue;
      try {
        output[path] = utf8.decode(data, allowMalformed: false);
      } on FormatException {
        throw FormatException('暂不支持导入二进制文件：$path');
      }
    }
    if (output.isEmpty) throw const FormatException('ZIP 文件包中没有可导入的文本文件');
    return output;
  }

  static String normalizeEntryPath(String value) {
    final source = value.trim().replaceAll('\\', '/');
    if (source.isEmpty ||
        source.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(source)) {
      throw FormatException('无效的工作区文件路径：$value');
    }
    final segments = <String>[];
    for (final segment in source.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        throw FormatException('工作区文件路径不能跳出项目目录：$value');
      }
      segments.add(segment);
    }
    if (segments.isEmpty) {
      throw FormatException('无效的工作区文件路径：$value');
    }
    return segments.join('/');
  }
}
