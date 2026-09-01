import 'dart:async';
import 'dart:convert';

import 'package:claudechat/core/app_paths.dart';
import 'package:claudechat/data/app_database.dart';
import 'package:claudechat/data/schema.dart';
import 'package:claudechat/services/secure_vault.dart';
import 'package:claudechat/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

VoiceProfile profile({
  required VoiceProvider provider,
  required String endpoint,
  String model = 'model',
  String voiceId = 'voice',
  String outputFormat = 'mp3',
}) => VoiceProfile(
  id: 'profile',
  provider: provider,
  name: 'Voice',
  endpoint: endpoint,
  model: model,
  voiceId: voiceId,
  outputFormat: outputFormat,
  options: const <String, Object?>{},
  customHeaders: const <String, String>{},
  active: true,
);

VoiceService service(
  http.Client client, {
  Duration timeout = const Duration(seconds: 90),
}) => VoiceService(
  AppDatabase.visualAudit(AppPaths.visualAudit(), 'test-device'),
  SecureVault(),
  client: client,
  requestTimeout: timeout,
);

class _CapturingClient extends http.BaseClient {
  bool sawAbortableRequest = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sawAbortableRequest = request is http.AbortableRequest;
    return http.StreamedResponse(
      Stream<List<int>>.value(<int>[1, 2, 3]),
      200,
      headers: <String, String>{'content-type': 'audio/mpeg'},
    );
  }
}

void main() {
  test('voice schema is versioned and exported for merge backups', () {
    expect(databaseVersion, 7);
    expect(
      exportedTables,
      containsAll(<String>['voice_profiles', 'voice_assets']),
    );
    expect(
      voiceSchemaStatements.join('\n'),
      allOf(
        contains('message_id'),
        contains('library_number'),
        contains('is_bound'),
        contains('generated_text'),
        contains('source_kind'),
        contains('tool_call_id'),
      ),
    );
  });

  test(
    'ElevenLabs adapter uses voice path, api key, and binary response',
    () async {
      final voice = service(
        MockClient((request) async {
          expect(request.url.path, '/v1/text-to-speech/voice-123');
          expect(request.url.queryParameters['output_format'], 'mp3_44100_128');
          expect(request.headers['xi-api-key'], 'secret');
          final body = jsonDecode(request.body) as Map<String, Object?>;
          expect(body['text'], '你好');
          expect(body['model_id'], 'eleven_multilingual_v2');
          return http.Response.bytes(
            <int>[1, 2, 3],
            200,
            headers: <String, String>{'content-type': 'audio/mpeg'},
          );
        }),
      );

      final result = await voice.synthesize(
        profile: profile(
          provider: VoiceProvider.elevenLabs,
          endpoint: 'https://api.elevenlabs.io/v1/text-to-speech/{voice_id}',
          model: 'eleven_multilingual_v2',
          voiceId: 'voice-123',
          outputFormat: 'mp3_44100_128',
        ),
        apiKey: 'secret',
        text: '你好',
      );
      expect(result.bytes, <int>[1, 2, 3]);
      expect(result.extension, 'mp3');
    },
  );

  test('MiniMax adapter decodes official hexadecimal audio payload', () async {
    final voice = service(
      MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer secret');
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body['model'], 'speech-2.8-hd');
        expect((body['voice_setting'] as Map)['voice_id'], 'male-qn-qingse');
        return http.Response(
          jsonEncode(<String, Object?>{
            'data': <String, Object?>{'audio': '0102ff', 'status': 2},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    final result = await voice.synthesize(
      profile: profile(
        provider: VoiceProvider.minimax,
        endpoint: 'https://api.minimaxi.com/v1/t2a_v2',
        model: 'speech-2.8-hd',
        voiceId: 'male-qn-qingse',
      ),
      apiKey: 'secret',
      text: '测试',
    );
    expect(result.bytes, <int>[1, 2, 255]);
  });

  test('Mossland adapter follows the official synchronous audio API', () async {
    final voice = service(
      MockClient((request) async {
        expect(request.url, Uri.parse('https://api.mosi.cn/v1/audio/speech'));
        expect(request.headers['authorization'], 'Bearer secret');
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body, <String, Object?>{
          'model': 'moss-tts',
          'input': '你好 Moss',
          'voice_id': 'voice-id',
          'response_format': 'mp3',
          'delivery_method': 'audio',
          'async': false,
        });
        return http.Response.bytes(
          <int>[6, 5, 4],
          200,
          headers: <String, String>{'content-type': 'audio/mpeg'},
        );
      }),
    );

    final result = await voice.synthesize(
      profile: profile(
        provider: VoiceProvider.mossland,
        endpoint: 'https://api.mosi.cn/v1/audio/speech',
        model: 'moss-tts',
        voiceId: 'voice-id',
      ),
      apiKey: 'secret',
      text: '你好 Moss',
    );
    expect(result.bytes, <int>[6, 5, 4]);
  });

  test('custom adapter accepts nested base64 audio', () async {
    final voice = service(
      MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body['input'], 'custom');
        return http.Response(
          jsonEncode(<String, Object?>{
            'data': <String, Object?>{
              'audio': base64Encode(<int>[9, 8, 7]),
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    final result = await voice.synthesize(
      profile: profile(
        provider: VoiceProvider.custom,
        endpoint: 'https://voice.example.com/v1/audio/speech',
      ),
      apiKey: 'secret',
      text: 'custom',
    );
    expect(result.bytes, <int>[9, 8, 7]);
  });

  test('remote plaintext voice endpoints are rejected', () async {
    final voice = service(
      MockClient((request) async => http.Response('', 200)),
    );
    expect(
      () => voice.synthesize(
        profile: profile(
          provider: VoiceProvider.custom,
          endpoint: 'http://voice.example.com/tts',
        ),
        apiKey: '',
        text: 'unsafe',
      ),
      throwsFormatException,
    );
  });

  test('voice requests stop waiting after the configured timeout', () async {
    final voice = service(
      MockClient((request) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        return http.Response.bytes(<int>[1], 200);
      }),
      timeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      voice.synthesize(
        profile: profile(
          provider: VoiceProvider.mossland,
          endpoint: 'https://api.mosi.cn/v1/audio/speech',
          model: 'moss-tts',
          voiceId: 'voice-id',
        ),
        apiKey: 'secret',
        text: 'timeout',
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('voice requests are issued as abortable HTTP requests', () async {
    final abort = Completer<void>();
    final client = _CapturingClient();
    final voice = service(client);

    final result = await voice.synthesize(
      profile: profile(
        provider: VoiceProvider.mossland,
        endpoint: 'https://api.mosi.cn/v1/audio/speech',
        model: 'moss-tts',
        voiceId: 'voice-id',
      ),
      apiKey: 'secret',
      text: '可以终止的语音请求',
      abortTrigger: abort.future,
    );
    expect(client.sawAbortableRequest, isTrue);
    expect(result.bytes, <int>[1, 2, 3]);
  });
}
