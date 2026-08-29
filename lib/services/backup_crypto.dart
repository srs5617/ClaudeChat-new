import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _magic = 'CLAUDECHAT-BACKUP\n';

class BackupCrypto {
  BackupCrypto({
    this.memory = 32768,
    this.iterations = 3,
    this.parallelism = 2,
  });

  final int memory;
  final int iterations;
  final int parallelism;

  bool isEncrypted(List<int> bytes) {
    if (bytes.length < _magic.length) return false;
    return utf8.decode(bytes.sublist(0, _magic.length), allowMalformed: true) ==
        _magic;
  }

  Future<Uint8List> encrypt(List<int> plainText, String password) async {
    if (password.length < 8) throw const FormatException('备份密码至少需要 8 个字符');
    final salt = _secureRandom(16);
    final key = await _key(password, salt);
    final cipher = AesGcm.with256bits();
    final box = await cipher.encrypt(plainText, secretKey: key);
    final header = utf8.encode(
      jsonEncode(<String, Object?>{
        'version': 1,
        'cipher': 'AES-256-GCM',
        'kdf': 'Argon2id',
        'memoryKib': memory,
        'iterations': iterations,
        'parallelism': parallelism,
        'salt': base64Encode(salt),
      }),
    );
    final builder = BytesBuilder(copy: false)
      ..add(utf8.encode(_magic))
      ..add(_uint32(header.length))
      ..add(header)
      ..add(box.concatenation());
    return builder.takeBytes();
  }

  Future<Uint8List> decrypt(List<int> encrypted, String password) async {
    if (!isEncrypted(encrypted)) return Uint8List.fromList(encrypted);
    if (encrypted.length < _magic.length + 4)
      throw const FormatException('备份文件头不完整');
    final data = Uint8List.fromList(encrypted);
    final headerLength = ByteData.sublistView(
      data,
      _magic.length,
      _magic.length + 4,
    ).getUint32(0, Endian.big);
    final headerStart = _magic.length + 4;
    final headerEnd = headerStart + headerLength;
    if (headerEnd >= data.length) throw const FormatException('备份文件已损坏');
    final header =
        (jsonDecode(utf8.decode(data.sublist(headerStart, headerEnd))) as Map)
            .cast<String, Object?>();
    if (header['cipher'] != 'AES-256-GCM' || header['kdf'] != 'Argon2id') {
      throw const FormatException('不支持的备份加密版本');
    }
    final salt = base64Decode(header['salt']! as String);
    final headerMemory = (header['memoryKib'] as num).toInt();
    final headerIterations = (header['iterations'] as num).toInt();
    final headerParallelism = (header['parallelism'] as num).toInt();
    if (salt.length != 16 ||
        headerMemory < 1024 ||
        headerMemory > 262144 ||
        headerIterations < 1 ||
        headerIterations > 10 ||
        headerParallelism < 1 ||
        headerParallelism > 8) {
      throw const FormatException('备份加密参数无效');
    }
    final algorithm = Argon2id(
      memory: headerMemory,
      iterations: headerIterations,
      parallelism: headerParallelism,
      hashLength: 32,
    );
    final key = await algorithm.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    final cipher = AesGcm.with256bits();
    final box = SecretBox.fromConcatenation(
      data.sublist(headerEnd),
      nonceLength: cipher.nonceLength,
      macLength: cipher.macAlgorithm.macLength,
    );
    try {
      return Uint8List.fromList(await cipher.decrypt(box, secretKey: key));
    } on SecretBoxAuthenticationError {
      throw const FormatException('密码错误或备份文件已损坏');
    }
  }

  Future<SecretKey> _key(String password, List<int> salt) => Argon2id(
    memory: memory,
    iterations: iterations,
    parallelism: parallelism,
    hashLength: 32,
  ).deriveKeyFromPassword(password: password, nonce: salt);

  Uint8List _secureRandom(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  Uint8List _uint32(int value) {
    final bytes = Uint8List(4);
    bytes.buffer.asByteData().setUint32(0, value, Endian.big);
    return bytes;
  }
}
