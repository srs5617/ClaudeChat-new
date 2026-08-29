import 'dart:convert';

import 'package:claudechat/services/backup_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AES-GCM and Argon2id encrypted backup round-trips', () async {
    final crypto = BackupCrypto(memory: 1024, iterations: 1, parallelism: 1);
    final original = utf8.encode('ClaudeChat 完整备份：对话、日记、文件');
    final encrypted = await crypto.encrypt(
      original,
      'correct horse battery staple',
    );
    expect(crypto.isEncrypted(encrypted), isTrue);
    expect(
      await crypto.decrypt(encrypted, 'correct horse battery staple'),
      original,
    );
  });

  test('wrong password is rejected before import', () async {
    final crypto = BackupCrypto(memory: 1024, iterations: 1, parallelism: 1);
    final encrypted = await crypto.encrypt(
      utf8.encode('private'),
      'correct-password',
    );
    expect(
      () => crypto.decrypt(encrypted, 'wrong-password'),
      throwsA(isA<FormatException>()),
    );
  });
}
