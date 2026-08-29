import 'package:claudechat/services/secure_vault.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('exports and restores chat and voice API keys', () async {
    final vault = SecureVault();
    await vault.writeApiKey('chat-profile', 'chat-secret');
    await vault.writeVoiceApiKey('voice-profile', 'voice-secret');

    final exported = await vault.exportSecrets();
    expect(exported, <String, String>{
      'chat-profile': 'chat-secret',
      'voice:voice-profile': 'voice-secret',
    });

    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final restored = SecureVault();
    await restored.mergeSecrets(exported);

    expect(await restored.readApiKey('chat-profile'), 'chat-secret');
    expect(await restored.readVoiceApiKey('voice-profile'), 'voice-secret');
  });

  test(
    'replaceSecrets rolls back both key namespaces without touching others',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'claudechat.api-key.old-chat': 'old-chat-secret',
        'claudechat.voice-api-key.old-voice': 'old-voice-secret',
        'another.application.key': 'untouched',
      });
      final vault = SecureVault();

      await vault.replaceSecrets(<String, Object?>{
        'new-chat': 'new-chat-secret',
        'voice:new-voice': 'new-voice-secret',
      });

      expect(await vault.readApiKey('old-chat'), isNull);
      expect(await vault.readVoiceApiKey('old-voice'), isNull);
      expect(await vault.readApiKey('new-chat'), 'new-chat-secret');
      expect(await vault.readVoiceApiKey('new-voice'), 'new-voice-secret');
      expect(
        (await const FlutterSecureStorage()
            .readAll())['another.application.key'],
        'untouched',
      );
    },
  );
}
