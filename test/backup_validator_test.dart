import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:claudechat/services/backup_validator.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts a checksummed portable payload', () async {
    final bytes = utf8.encode('{"id":"one"}');
    final zip = await _backup(<String, List<int>>{
      'data/conversations.jsonl': bytes,
    });
    final validated = await validateBackupArchive(zip, encrypted: false);
    expect(validated.entries, contains('data/conversations.jsonl'));
  });

  test('rejects an unchecksummed injected entry', () async {
    final zip = await _backup(
      <String, List<int>>{'data/conversations.jsonl': utf8.encode('{}')},
      extraUnchecked: <String, List<int>>{
        'files/injected.txt': utf8.encode('x'),
      },
    );
    expect(
      () => validateBackupArchive(zip, encrypted: false),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects plaintext API secrets even with a valid checksum', () async {
    final zip = await _backup(<String, List<int>>{
      'secure/api_keys.json': utf8.encode('{"p":"sk"}'),
    }, includesSecrets: true);
    expect(
      () => validateBackupArchive(zip, encrypted: false),
      throwsA(isA<FormatException>()),
    );
  });

  test('accepts explicitly marked legacy-web plaintext API secrets', () async {
    final zip = await _backup(
      <String, List<int>>{
        'secure/api_keys.json': utf8.encode('{"p":"sk"}'),
      },
      includesSecrets: true,
      legacyPlaintextSecrets: true,
    );
    final validated = await validateBackupArchive(zip, encrypted: false);
    expect(validated.entries, contains('secure/api_keys.json'));
  });

  test('continues to accept API secrets from encrypted backups', () async {
    final zip = await _backup(<String, List<int>>{
      'secure/api_keys.json': utf8.encode('{"p":"sk"}'),
    }, includesSecrets: true);
    final validated = await validateBackupArchive(zip, encrypted: true);
    expect(validated.entries, contains('secure/api_keys.json'));
  });

  test('rejects path traversal entries', () async {
    final zip = await _backup(<String, List<int>>{
      'files/../outside.txt': utf8.encode('x'),
    });
    expect(
      () => validateBackupArchive(zip, encrypted: false),
      throwsA(isA<FormatException>()),
    );
  });
}

Future<List<int>> _backup(
  Map<String, List<int>> payload, {
  Map<String, List<int>> extraUnchecked = const <String, List<int>>{},
  bool includesSecrets = false,
  bool legacyPlaintextSecrets = false,
}) async {
  final checksums = <String, String>{};
  final archive = Archive();
  for (final entry in payload.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    checksums[entry.key] = base64Encode(
      (await Sha256().hash(entry.value)).bytes,
    );
  }
  for (final entry in extraUnchecked.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  archive.addFile(
    ArchiveFile.string(
      'manifest.json',
      jsonEncode(<String, Object?>{
        'format': 'claudechat-backup',
        'formatVersion': 1,
        if (legacyPlaintextSecrets) 'source': 'legacy-web-full-export',
        'includesSecrets': includesSecrets,
        'checksums': checksums,
        if (legacyPlaintextSecrets)
          'migration': <String, Object?>{
            'direction': 'legacy-web-to-flutter',
            'plaintextSecrets': true,
          },
      }),
    ),
  );
  return ZipEncoder().encodeBytes(archive);
}
