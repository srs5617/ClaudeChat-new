import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart' as image_picker;
import 'package:mime/mime.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';

const _uuid = Uuid();

class PendingAttachment {
  const PendingAttachment({
    required this.id,
    required this.name,
    required this.mediaType,
    required this.relativePath,
    required this.byteSize,
    required this.sha256,
  });

  final String id;
  final String name;
  final String mediaType;
  final String relativePath;
  final int byteSize;
  final String sha256;

  bool get isImage => mediaType.startsWith('image/');

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'mediaType': mediaType,
    'relativePath': relativePath,
    'byteSize': byteSize,
    'sha256': sha256,
  };
}

class LargeAttachmentSelection {
  const LargeAttachmentSelection({
    required this.fileNames,
    required this.largeFileNames,
    required this.totalBytes,
    required this.largestFileBytes,
  });

  final List<String> fileNames;
  final List<String> largeFileNames;
  final int totalBytes;
  final int largestFileBytes;
}

typedef ConfirmLargeAttachmentSelection =
    Future<bool> Function(LargeAttachmentSelection selection);

bool requiresLargeAttachmentConfirmation(Iterable<int> byteSizes) {
  var total = 0;
  for (final size in byteSizes) {
    total += size;
    if (size > AttachmentService.warningThresholdBytes) return true;
  }
  return total > AttachmentService.warningThresholdBytes;
}

class AttachmentService {
  AttachmentService(this.store);

  static const warningThresholdBytes = 50 * 1024 * 1024;
  final AppDatabase store;
  final image_picker.ImagePicker _imagePicker = image_picker.ImagePicker();

  Future<List<PendingAttachment>> pickAndStore({
    ConfirmLargeAttachmentSelection? confirmLargeSelection,
  }) async {
    final pickedFiles = await openFiles();
    return _storePickedFiles(
      pickedFiles,
      confirmLargeSelection: confirmLargeSelection,
    );
  }

  Future<List<PendingAttachment>> captureImageAndStore({
    ConfirmLargeAttachmentSelection? confirmLargeSelection,
  }) async {
    final picked = await _imagePicker.pickImage(
      source: image_picker.ImageSource.camera,
      requestFullMetadata: false,
    );
    return _storePickedFiles(
      picked == null ? const <XFile>[] : <XFile>[picked],
      confirmLargeSelection: confirmLargeSelection,
    );
  }

  Future<List<PendingAttachment>> pickImagesAndStore({
    ConfirmLargeAttachmentSelection? confirmLargeSelection,
  }) async {
    final picked = await _imagePicker.pickMultiImage(
      requestFullMetadata: false,
    );
    return _storePickedFiles(
      picked,
      confirmLargeSelection: confirmLargeSelection,
    );
  }

  Future<List<PendingAttachment>> _storePickedFiles(
    List<XFile> pickedFiles, {
    ConfirmLargeAttachmentSelection? confirmLargeSelection,
  }) async {
    if (pickedFiles.isEmpty) return const <PendingAttachment>[];
    final selections = <({XFile file, int size})>[];
    for (final file in pickedFiles) {
      selections.add((file: file, size: await file.length()));
    }
    final totalBytes = selections.fold<int>(
      0,
      (sum, selection) => sum + selection.size,
    );
    final largeFiles = selections
        .where((selection) => selection.size > warningThresholdBytes)
        .toList(growable: false);
    if (requiresLargeAttachmentConfirmation(
      selections.map((selection) => selection.size),
    )) {
      final approved =
          confirmLargeSelection != null &&
          await confirmLargeSelection(
            LargeAttachmentSelection(
              fileNames: selections
                  .map((selection) => selection.file.name)
                  .toList(growable: false),
              largeFileNames: largeFiles
                  .map((selection) => selection.file.name)
                  .toList(growable: false),
              totalBytes: totalBytes,
              largestFileBytes: selections.fold<int>(
                0,
                (largest, selection) =>
                    selection.size > largest ? selection.size : largest,
              ),
            ),
          );
      if (!approved) return const <PendingAttachment>[];
    }
    final output = <PendingAttachment>[];
    for (final selection in selections) {
      final picked = selection.file;
      final staged = File(
        '${store.paths.temp.path}${Platform.pathSeparator}attachment-${_uuid.v4()}.part',
      );
      await staged.parent.create(recursive: true);
      final outputSink = staged.openWrite();
      final hashSink = Sha256().toSync().newHashSink();
      final header = <int>[];
      var copiedBytes = 0;
      try {
        await for (final chunk in picked.openRead()) {
          if (header.length < 16) {
            header.addAll(chunk.take(16 - header.length));
          }
          copiedBytes += chunk.length;
          hashSink.add(chunk);
          outputSink.add(chunk);
        }
        await outputSink.flush();
        await outputSink.close();
        hashSink.close();
      } on Object {
        await outputSink.close();
        hashSink.close();
        if (await staged.exists()) await staged.delete();
        rethrow;
      }
      final hash = _hex((await hashSink.hash()).bytes);
      final existing = await store.database.query(
        'attachments',
        where: 'sha256 = ?',
        whereArgs: <Object?>[hash],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        await staged.delete();
        final row = existing.first;
        output.add(
          PendingAttachment(
            id: row['id']! as String,
            name: row['original_name']! as String,
            mediaType: row['media_type']! as String,
            relativePath: row['relative_path']! as String,
            byteSize: (row['byte_size']! as num).toInt(),
            sha256: hash,
          ),
        );
        continue;
      }
      final id = _uuid.v4();
      final safeName = _safeName(picked.name);
      final relative = '$hash/$safeName';
      final file = File(
        '${store.paths.attachments.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
      );
      await file.parent.create(recursive: true);
      await staged.rename(file.path);
      final mediaType =
          lookupMimeType(picked.name, headerBytes: header) ??
          'application/octet-stream';
      await store.database.insert('attachments', <String, Object?>{
        'id': id,
        'original_name': picked.name,
        'media_type': mediaType,
        'relative_path': relative,
        'byte_size': copiedBytes,
        'sha256': hash,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'origin_device_id': store.deviceId,
      });
      output.add(
        PendingAttachment(
          id: id,
          name: picked.name,
          mediaType: mediaType,
          relativePath: relative,
          byteSize: copiedBytes,
          sha256: hash,
        ),
      );
    }
    return output;
  }

  Future<void> linkToMessage(
    String messageId,
    List<PendingAttachment> attachments,
  ) async {
    final batch = store.database.batch();
    for (var index = 0; index < attachments.length; index++) {
      batch.insert('attachment_references', <String, Object?>{
        'attachment_id': attachments[index].id,
        'owner_type': 'message',
        'owner_id': messageId,
        'position': index,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  Future<List<PendingAttachment>> forMessage(String messageId) async {
    final rows = await store.database.rawQuery(
      '''SELECT a.* FROM attachments a
         JOIN attachment_references r ON r.attachment_id = a.id
         WHERE r.owner_type = 'message' AND r.owner_id = ?
         ORDER BY r.position ASC''',
      <Object?>[messageId],
    );
    return rows
        .map(
          (row) => PendingAttachment(
            id: row['id']! as String,
            name: row['original_name']! as String,
            mediaType: row['media_type']! as String,
            relativePath: row['relative_path']! as String,
            byteSize: (row['byte_size']! as num).toInt(),
            sha256: row['sha256']! as String,
          ),
        )
        .toList();
  }

  String absolutePath(PendingAttachment item) =>
      '${store.paths.attachments.path}${Platform.pathSeparator}${item.relativePath.replaceAll('/', Platform.pathSeparator)}';

  Future<List<Map<String, Object?>>> apiContent(
    String text,
    List<PendingAttachment> attachments,
  ) async {
    final content = <Map<String, Object?>>[];
    if (text.trim().isNotEmpty)
      content.add(<String, Object?>{'type': 'text', 'text': text});
    for (final item in attachments) {
      final file = File(
        '${store.paths.attachments.path}${Platform.pathSeparator}${item.relativePath.replaceAll('/', Platform.pathSeparator)}',
      );
      if (item.isImage) {
        content.add(<String, Object?>{
          'type': 'image_url',
          'image_url': <String, String>{
            'url':
                'data:${item.mediaType};base64,${base64Encode(await file.readAsBytes())}',
          },
        });
      } else {
        final readable =
            item.mediaType.startsWith('text/') ||
            const <String>{
              'application/json',
              'application/xml',
              'application/javascript',
              'application/x-yaml',
            }.contains(item.mediaType);
        if (!readable) {
          content.add(<String, Object?>{
            'type': 'text',
            'text': '[附件：${item.name}，${item.mediaType}，${item.byteSize} 字节]',
          });
        } else {
          content.add(<String, Object?>{
            'type': 'text',
            'text': '[附件：${item.name}]\n${await file.readAsString()}',
          });
        }
      }
    }
    return content;
  }

  String metadata(List<PendingAttachment> items) =>
      jsonEncode(<String, Object?>{
        'attachments': items.map((item) => item.toJson()).toList(),
      });

  String _safeName(String value) {
    final clean = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim();
    return clean.isEmpty
        ? 'attachment.bin'
        : clean.substring(0, clean.length.clamp(0, 120));
  }

  String _hex(List<int> bytes) =>
      bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}
