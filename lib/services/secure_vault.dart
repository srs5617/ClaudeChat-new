import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureVault {
  SecureVault({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _prefix = 'claudechat.api-key.';
  static const _voicePrefix = 'claudechat.voice-api-key.';
  final FlutterSecureStorage _storage;

  Future<void> writeApiKey(String profileId, String value) =>
      _storage.write(key: '$_prefix$profileId', value: value);

  Future<String?> readApiKey(String profileId) =>
      _storage.read(key: '$_prefix$profileId');

  Future<void> deleteApiKey(String profileId) =>
      _storage.delete(key: '$_prefix$profileId');

  Future<void> writeVoiceApiKey(String profileId, String value) =>
      _storage.write(key: '$_voicePrefix$profileId', value: value);

  Future<String?> readVoiceApiKey(String profileId) =>
      _storage.read(key: '$_voicePrefix$profileId');

  Future<void> deleteVoiceApiKey(String profileId) =>
      _storage.delete(key: '$_voicePrefix$profileId');

  Future<Map<String, String>> exportSecrets() async {
    final all = await _storage.readAll();
    return <String, String>{
      for (final entry in all.entries)
        if (entry.key.startsWith(_prefix))
          entry.key.substring(_prefix.length): entry.value
        else if (entry.key.startsWith(_voicePrefix))
          'voice:${entry.key.substring(_voicePrefix.length)}': entry.value,
    };
  }

  Future<void> mergeSecrets(Map<String, Object?> values) async {
    for (final entry in values.entries) {
      final value = entry.value;
      if (value is String && value.isNotEmpty) {
        if (entry.key.startsWith('voice:')) {
          await writeVoiceApiKey(entry.key.substring('voice:'.length), value);
        } else {
          await writeApiKey(entry.key, value);
        }
      }
    }
  }

  Future<void> replaceSecrets(Map<String, Object?> values) async {
    final all = await _storage.readAll();
    for (final key in all.keys.toList(growable: false)) {
      if (key.startsWith(_prefix) || key.startsWith(_voicePrefix)) {
        await _storage.delete(key: key);
      }
    }
    await mergeSecrets(values);
  }
}
