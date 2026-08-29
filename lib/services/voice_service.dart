import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import 'secure_vault.dart';

const _uuid = Uuid();

class VoiceGenerationCancelled implements Exception {
  const VoiceGenerationCancelled();

  @override
  String toString() => '语音生成已停止';
}

enum VoiceProvider { elevenLabs, minimax, volcengine, mossland, custom }

extension VoiceProviderInfo on VoiceProvider {
  String get key => switch (this) {
    VoiceProvider.elevenLabs => 'elevenlabs',
    VoiceProvider.minimax => 'minimax',
    VoiceProvider.volcengine => 'volcengine',
    VoiceProvider.mossland => 'mossland',
    VoiceProvider.custom => 'custom',
  };

  String get label => switch (this) {
    VoiceProvider.elevenLabs => 'ElevenLabs',
    VoiceProvider.minimax => 'MiniMax',
    VoiceProvider.volcengine => 'Volcengine / Volink',
    VoiceProvider.mossland => 'Mossland',
    VoiceProvider.custom => '自定义兼容接口',
  };

  String get defaultEndpoint => switch (this) {
    VoiceProvider.elevenLabs =>
      'https://api.elevenlabs.io/v1/text-to-speech/{voice_id}',
    VoiceProvider.minimax => 'https://api.minimaxi.com/v1/t2a_v2',
    VoiceProvider.volcengine => 'https://openspeech.bytedance.com/api/v1/tts',
    VoiceProvider.mossland => 'https://api.mosi.cn/v1/audio/speech',
    VoiceProvider.custom => '',
  };

  String get defaultModel => switch (this) {
    VoiceProvider.elevenLabs => 'eleven_multilingual_v2',
    VoiceProvider.minimax => 'speech-2.8-hd',
    VoiceProvider.volcengine => 'seed-tts-1.0',
    VoiceProvider.mossland => 'moss-tts',
    VoiceProvider.custom => '',
  };

  static VoiceProvider fromKey(String value) => VoiceProvider.values.firstWhere(
    (provider) => provider.key == value,
    orElse: () => VoiceProvider.custom,
  );
}

class VoiceProfile {
  const VoiceProfile({
    required this.id,
    required this.provider,
    required this.name,
    required this.endpoint,
    required this.model,
    required this.voiceId,
    required this.outputFormat,
    required this.options,
    required this.customHeaders,
    required this.active,
  });

  final String id;
  final VoiceProvider provider;
  final String name;
  final String endpoint;
  final String model;
  final String voiceId;
  final String outputFormat;
  final Map<String, Object?> options;
  final Map<String, String> customHeaders;
  final bool active;

  factory VoiceProfile.fromMap(Map<String, Object?> map) => VoiceProfile(
    id: '${map['id']}',
    provider: VoiceProviderInfo.fromKey('${map['provider']}'),
    name: '${map['name']}',
    endpoint: '${map['endpoint']}',
    model: '${map['model'] ?? ''}',
    voiceId: '${map['voice_id'] ?? ''}',
    outputFormat: '${map['output_format'] ?? 'mp3'}',
    options: _jsonMap(map['options_json']),
    customHeaders: _jsonMap(
      map['custom_headers_json'],
    ).map((key, value) => MapEntry(key, '$value')),
    active: map['is_active'] == 1 || map['is_active'] == true,
  );
}

class VoiceAsset {
  const VoiceAsset({
    required this.id,
    required this.libraryNumber,
    required this.messageId,
    required this.conversationId,
    required this.profileId,
    required this.provider,
    required this.model,
    required this.voiceId,
    required this.relativePath,
    required this.mediaType,
    required this.byteSize,
    required this.sha256,
    required this.favorite,
    required this.bound,
    required this.createdAt,
    required this.updatedAt,
    this.durationMs,
    this.sourceText = '',
    this.messageRole = '',
    this.conversationRoleName = '',
  });

  final String id;
  final int libraryNumber;
  final String messageId;
  final String conversationId;
  final String? profileId;
  final String provider;
  final String model;
  final String voiceId;
  final String relativePath;
  final String mediaType;
  final int byteSize;
  final String sha256;
  final int? durationMs;
  final bool favorite;
  final bool bound;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String sourceText;
  final String messageRole;
  final String conversationRoleName;

  factory VoiceAsset.fromMap(Map<String, Object?> map) => VoiceAsset(
    id: '${map['id']}',
    libraryNumber: (map['library_number'] as num).toInt(),
    messageId: '${map['message_id']}',
    conversationId: '${map['conversation_id']}',
    profileId: map['voice_profile_id'] as String?,
    provider: '${map['provider']}',
    model: '${map['model'] ?? ''}',
    voiceId: '${map['voice_id'] ?? ''}',
    relativePath: '${map['relative_path']}',
    mediaType: '${map['media_type'] ?? 'audio/mpeg'}',
    byteSize: (map['byte_size'] as num).toInt(),
    sha256: '${map['sha256']}',
    durationMs: (map['duration_ms'] as num?)?.toInt(),
    favorite: map['is_favorite'] == 1 || map['is_favorite'] == true,
    bound: map['is_bound'] == 1 || map['is_bound'] == true,
    createdAt: DateTime.parse('${map['created_at']}'),
    updatedAt: DateTime.parse('${map['updated_at']}'),
    sourceText: '${map['source_text'] ?? ''}',
    messageRole: '${map['message_role'] ?? ''}',
    conversationRoleName: '${map['conversation_role_name'] ?? ''}',
  );

  String get numberLabel => '#${libraryNumber.toString().padLeft(4, '0')}';

  String get roleName {
    final configured = conversationRoleName.trim();
    if (configured.isNotEmpty) return configured;
    return messageRole == 'user' ? '用户' : '助手';
  }
}

class GeneratedVoice {
  const GeneratedVoice(this.bytes, this.extension, this.mediaType);
  final Uint8List bytes;
  final String extension;
  final String mediaType;
}

typedef VoiceGenerationProgress = void Function(String status);

class VoiceService {
  VoiceService(
    this.store,
    this.vault, {
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 90),
  }) : client = client ?? http.Client();

  final AppDatabase store;
  final SecureVault vault;
  final http.Client client;
  final Duration requestTimeout;

  Future<List<VoiceProfile>> profiles() async {
    final rows = await store.database.query(
      'voice_profiles',
      where: 'deleted_at IS NULL',
      orderBy: 'is_active DESC, created_at ASC',
    );
    return rows.map(VoiceProfile.fromMap).toList();
  }

  Future<VoiceProfile> saveProfile({
    String? id,
    required VoiceProvider provider,
    required String name,
    required String endpoint,
    required String apiKey,
    required String model,
    required String voiceId,
    String outputFormat = 'mp3',
    Map<String, Object?> options = const <String, Object?>{},
    Map<String, String> customHeaders = const <String, String>{},
    bool active = true,
  }) async {
    final profileId = id ?? _uuid.v4();
    final cleanEndpoint = endpoint.trim();
    _validateEndpoint(cleanEndpoint);
    final old = await store.database.query(
      'voice_profiles',
      where: 'id = ?',
      whereArgs: <Object?>[profileId],
      limit: 1,
    );
    final now = DateTime.now().toUtc().toIso8601String();
    await store.database.transaction((transaction) async {
      if (active) {
        await transaction.update('voice_profiles', <String, Object?>{
          'is_active': 0,
        });
      }
      await transaction.insert('voice_profiles', <String, Object?>{
        'id': profileId,
        'provider': provider.key,
        'name': name.trim().isEmpty ? provider.label : name.trim(),
        'endpoint': cleanEndpoint,
        'model': model.trim(),
        'voice_id': voiceId.trim(),
        'output_format': outputFormat.trim().isEmpty
            ? 'mp3'
            : outputFormat.trim(),
        'options_json': jsonEncode(options),
        'custom_headers_json': jsonEncode(customHeaders),
        'is_active': active ? 1 : 0,
        'created_at': old.isEmpty ? now : old.first['created_at'],
        'updated_at': now,
        'revision': old.isEmpty
            ? 1
            : ((old.first['revision'] as num?)?.toInt() ?? 0) + 1,
        'origin_device_id': store.deviceId,
        'deleted_at': null,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    if (apiKey.trim().isNotEmpty) {
      await vault.writeVoiceApiKey(profileId, apiKey.trim());
    }
    return (await profiles()).firstWhere((item) => item.id == profileId);
  }

  Future<void> deleteProfile(String id) async {
    await store.softDelete('voice_profiles', id);
    await vault.deleteVoiceApiKey(id);
    final remaining = await profiles();
    if (remaining.isNotEmpty && remaining.every((item) => !item.active)) {
      await store.database.update(
        'voice_profiles',
        <String, Object?>{
          'is_active': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: <Object?>[remaining.first.id],
      );
    }
  }

  Future<List<VoiceAsset>> assets({String? messageId}) async {
    final rows = await store.database.rawQuery(
      'SELECT va.*, m.content AS source_text, m.role AS message_role, '
      "COALESCE(c.model_id, '') AS conversation_role_name "
      'FROM voice_assets va '
      'LEFT JOIN messages m ON m.id = va.message_id '
      'LEFT JOIN conversations c ON c.id = va.conversation_id '
      'WHERE va.deleted_at IS NULL '
      '${messageId == null ? '' : 'AND va.message_id = ? '} '
      'ORDER BY ${messageId == null ? 'va.library_number DESC' : 'va.created_at DESC'}',
      messageId == null ? null : <Object?>[messageId],
    );
    return rows.map(VoiceAsset.fromMap).toList();
  }

  Future<VoiceAsset?> boundForMessage(String messageId) async {
    final rows = await store.database.query(
      'voice_assets',
      where: 'deleted_at IS NULL AND message_id = ? AND is_bound = 1',
      whereArgs: <Object?>[messageId],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : VoiceAsset.fromMap(rows.first);
  }

  Future<VoiceAsset> generate({
    required String messageId,
    required String conversationId,
    required String text,
    VoiceProfile? profile,
    bool bind = true,
    Future<void>? abortTrigger,
    VoiceGenerationProgress? onProgress,
  }) async {
    final selected = profile ?? (await profiles()).firstOrNull;
    if (selected == null) throw const FormatException('请先在设置中添加一个语音接口');
    final apiKey = await vault.readVoiceApiKey(selected.id) ?? '';
    onProgress?.call('正在向 ${selected.provider.label} 请求语音…');
    final generated = await synthesize(
      profile: selected,
      apiKey: apiKey,
      text: text,
      abortTrigger: abortTrigger,
    );
    if (abortTrigger != null) {
      var cancelled = false;
      abortTrigger.then((_) => cancelled = true);
      await Future<void>.delayed(Duration.zero);
      if (cancelled) throw const VoiceGenerationCancelled();
    }
    if (generated.bytes.isEmpty) throw const FormatException('语音接口返回了空音频');
    onProgress?.call('语音已生成，正在保存…');
    final id = _uuid.v4();
    final numberRows = await store.database.rawQuery(
      'SELECT COALESCE(MAX(library_number), 0) AS value FROM voice_assets',
    );
    final number = ((numberRows.first['value'] as num?)?.toInt() ?? 0) + 1;
    final relativePath =
        '$conversationId/$messageId/$id.${generated.extension}';
    final output = File(
      '${store.paths.voices.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
    );
    await output.parent.create(recursive: true);
    await output.writeAsBytes(generated.bytes, flush: true);
    final digest = (await Sha256().hash(
      generated.bytes,
    )).bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final now = DateTime.now().toUtc().toIso8601String();
    onProgress?.call('正在写入声音库…');
    await store.database.transaction((transaction) async {
      if (bind) {
        await transaction.rawUpdate(
          'UPDATE voice_assets '
          'SET is_bound = 0, updated_at = ?, revision = revision + 1, '
          'origin_device_id = ? '
          'WHERE message_id = ? AND deleted_at IS NULL AND is_bound = 1',
          <Object?>[now, store.deviceId, messageId],
        );
      }
      await transaction.insert('voice_assets', <String, Object?>{
        'id': id,
        'library_number': number,
        'message_id': messageId,
        'conversation_id': conversationId,
        'voice_profile_id': selected.id,
        'provider': selected.provider.key,
        'model': selected.model,
        'voice_id': selected.voiceId,
        'relative_path': relativePath,
        'media_type': generated.mediaType,
        'byte_size': generated.bytes.length,
        'sha256': digest,
        'duration_ms': null,
        'is_favorite': 0,
        'is_bound': bind ? 1 : 0,
        'created_at': now,
        'updated_at': now,
        'deleted_at': null,
        'revision': 1,
        'origin_device_id': store.deviceId,
      });
    });
    return (await assets(
      messageId: messageId,
    )).firstWhere((item) => item.id == id);
  }

  Future<void> bind(VoiceAsset asset) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await store.database.transaction((transaction) async {
      await transaction.rawUpdate(
        'UPDATE voice_assets '
        'SET is_bound = 0, updated_at = ?, revision = revision + 1, '
        'origin_device_id = ? '
        'WHERE message_id = ? AND deleted_at IS NULL AND is_bound = 1',
        <Object?>[now, store.deviceId, asset.messageId],
      );
      await transaction.rawUpdate(
        'UPDATE voice_assets '
        'SET is_bound = 1, updated_at = ?, revision = revision + 1, '
        'origin_device_id = ? WHERE id = ?',
        <Object?>[now, store.deviceId, asset.id],
      );
    });
  }

  Future<void> setFavorite(VoiceAsset asset, bool favorite) =>
      store.database.rawUpdate(
        'UPDATE voice_assets '
        'SET is_favorite = ?, updated_at = ?, revision = revision + 1, '
        'origin_device_id = ? WHERE id = ?',
        <Object?>[
          favorite ? 1 : 0,
          DateTime.now().toUtc().toIso8601String(),
          store.deviceId,
          asset.id,
        ],
      );

  String absolutePath(VoiceAsset asset) =>
      '${store.paths.voices.path}${Platform.pathSeparator}${asset.relativePath.replaceAll('/', Platform.pathSeparator)}';

  Future<GeneratedVoice> synthesize({
    required VoiceProfile profile,
    required String apiKey,
    required String text,
    Future<void>? abortTrigger,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) throw const FormatException('空消息不能生成语音');
    if (clean.length > 10000) throw const FormatException('单次语音文本不能超过 10000 字');
    _validateEndpoint(profile.endpoint);
    return switch (profile.provider) {
      VoiceProvider.elevenLabs => _elevenLabs(
        profile,
        apiKey,
        clean,
        abortTrigger,
      ),
      VoiceProvider.minimax => _minimax(profile, apiKey, clean, abortTrigger),
      VoiceProvider.volcengine => _volcengine(
        profile,
        apiKey,
        clean,
        abortTrigger,
      ),
      VoiceProvider.mossland => _mossland(profile, apiKey, clean, abortTrigger),
      VoiceProvider.custom => _openAiCompatible(
        profile,
        apiKey,
        clean,
        abortTrigger,
      ),
    };
  }

  Future<GeneratedVoice> _elevenLabs(
    VoiceProfile profile,
    String apiKey,
    String text,
    Future<void>? abortTrigger,
  ) async {
    if (profile.voiceId.isEmpty)
      throw const FormatException('ElevenLabs 需要 voice ID');
    var endpoint = profile.endpoint.replaceAll('{voice_id}', profile.voiceId);
    final uri = Uri.parse(endpoint);
    final outputFormat = profile.outputFormat.contains('_')
        ? profile.outputFormat
        : 'mp3_44100_128';
    final response = await _post(
      uri.replace(
        queryParameters: <String, String>{
          ...uri.queryParameters,
          'output_format': outputFormat,
        },
      ),
      headers: _headers(profile, <String, String>{'xi-api-key': apiKey}),
      body: jsonEncode(<String, Object?>{
        'text': text,
        if (profile.model.isNotEmpty) 'model_id': profile.model,
      }),
      abortTrigger: abortTrigger,
    );
    return _audioResponse(response, profile.outputFormat);
  }

  Future<GeneratedVoice> _minimax(
    VoiceProfile profile,
    String apiKey,
    String text,
    Future<void>? abortTrigger,
  ) async {
    if (profile.voiceId.isEmpty)
      throw const FormatException('MiniMax 需要 voice ID');
    final response = await _post(
      Uri.parse(profile.endpoint),
      headers: _headers(profile, <String, String>{
        'Authorization': 'Bearer $apiKey',
      }),
      body: jsonEncode(<String, Object?>{
        'model': profile.model.isEmpty ? 'speech-2.8-hd' : profile.model,
        'text': text,
        'stream': false,
        'voice_setting': <String, Object?>{
          'voice_id': profile.voiceId,
          'speed': profile.options['speed'] ?? 1,
          'vol': profile.options['volume'] ?? 1,
          'pitch': profile.options['pitch'] ?? 0,
        },
        'audio_setting': <String, Object?>{
          'sample_rate': profile.options['sampleRate'] ?? 32000,
          'bitrate': profile.options['bitrate'] ?? 128000,
          'format': _simpleFormat(profile.outputFormat),
          'channel': profile.options['channel'] ?? 1,
        },
      }),
      abortTrigger: abortTrigger,
    );
    return _audioResponse(response, profile.outputFormat);
  }

  Future<GeneratedVoice> _volcengine(
    VoiceProfile profile,
    String apiKey,
    String text,
    Future<void>? abortTrigger,
  ) async {
    final appId = '${profile.options['appId'] ?? ''}'.trim();
    if (appId.isEmpty || profile.voiceId.isEmpty) {
      throw const FormatException('火山引擎需要 App ID 和音色 ID');
    }
    final response = await _post(
      Uri.parse(profile.endpoint),
      headers: _headers(profile, <String, String>{
        'Authorization': 'Bearer;$apiKey',
      }),
      body: jsonEncode(<String, Object?>{
        'app': <String, Object?>{
          'appid': appId,
          'token': apiKey,
          'cluster': profile.options['cluster'] ?? 'volcano_tts',
        },
        'user': <String, Object?>{'uid': store.deviceId},
        'audio': <String, Object?>{
          'voice_type': profile.voiceId,
          'encoding': _simpleFormat(profile.outputFormat),
          'speed_ratio': profile.options['speed'] ?? 1.0,
          'volume_ratio': profile.options['volume'] ?? 1.0,
          'pitch_ratio': profile.options['pitch'] ?? 1.0,
        },
        'request': <String, Object?>{
          'reqid': _uuid.v4(),
          'text': text,
          'text_type': 'plain',
          'operation': 'query',
        },
      }),
      abortTrigger: abortTrigger,
    );
    return _audioResponse(response, profile.outputFormat);
  }

  Future<GeneratedVoice> _mossland(
    VoiceProfile profile,
    String apiKey,
    String text,
    Future<void>? abortTrigger,
  ) async {
    if (apiKey.trim().isEmpty) {
      throw const FormatException('Mossland 需要 API Key');
    }
    if (profile.voiceId.trim().isEmpty) {
      throw const FormatException('Mossland 需要 voice ID');
    }
    final version = '${profile.options['version'] ?? ''}'.trim();
    final aigcMetadata = profile.options['aigcMetadata'];
    final response = await _post(
      Uri.parse(profile.endpoint),
      headers: _headers(profile, <String, String>{
        'Authorization': 'Bearer $apiKey',
      }),
      body: jsonEncode(<String, Object?>{
        'model': profile.model.isEmpty ? 'moss-tts' : profile.model,
        if (version.isNotEmpty) 'version': version,
        'input': text,
        'voice_id': profile.voiceId,
        'response_format': _simpleFormat(profile.outputFormat),
        'delivery_method': 'audio',
        'async': false,
        if (aigcMetadata is Map) 'aigc_metadata': aigcMetadata,
      }),
      abortTrigger: abortTrigger,
    );
    return _audioResponse(response, profile.outputFormat);
  }

  Future<GeneratedVoice> _openAiCompatible(
    VoiceProfile profile,
    String apiKey,
    String text,
    Future<void>? abortTrigger,
  ) async {
    final response = await _post(
      Uri.parse(profile.endpoint),
      headers: _headers(
        profile,
        apiKey.isEmpty
            ? const <String, String>{}
            : <String, String>{'Authorization': 'Bearer $apiKey'},
      ),
      body: jsonEncode(<String, Object?>{
        'model': profile.model,
        'voice': profile.voiceId,
        'input': text,
        'response_format': _simpleFormat(profile.outputFormat),
        ...profile.options,
      }),
      abortTrigger: abortTrigger,
    );
    return _audioResponse(response, profile.outputFormat);
  }

  Map<String, String> _headers(
    VoiceProfile profile,
    Map<String, String> authentication,
  ) => <String, String>{
    'Content-Type': 'application/json',
    'Accept': 'audio/*, application/json',
    ...authentication,
    ...profile.customHeaders,
  };

  Future<http.Response> _post(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Future<void>? abortTrigger,
  }) {
    final request = http.AbortableRequest(
      'POST',
      uri,
      abortTrigger: abortTrigger,
    )..headers.addAll(headers);
    request.bodyBytes = switch (body) {
      String value => utf8.encode(value),
      List<int> value => value,
      _ => utf8.encode('$body'),
    };
    return client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(
          requestTimeout,
          onTimeout: () => throw TimeoutException(
            '语音接口等待超过 ${requestTimeout.inSeconds} 秒，请稍后重试或缩短文本',
          ),
        );
  }

  GeneratedVoice _audioResponse(http.Response response, String requested) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      throw HttpException(
        '语音接口返回 ${response.statusCode}：${body.length > 500 ? body.substring(0, 500) : body}',
      );
    }
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.startsWith('audio/') || !contentType.contains('json')) {
      final format = _formatInfo(requested, contentType: contentType);
      return GeneratedVoice(response.bodyBytes, format.$1, format.$2);
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final encoded = _findAudioValue(decoded);
    if (encoded == null || encoded.isEmpty) {
      throw const FormatException('语音接口 JSON 中没有找到 audio/data 字段');
    }
    final bytes = _decodeAudio(encoded);
    final format = _formatInfo(requested);
    return GeneratedVoice(bytes, format.$1, format.$2);
  }

  String? _findAudioValue(Object? value) {
    if (value is Map) {
      for (final key in const <String>['audio', 'audio_data', 'audioContent']) {
        final direct = value[key];
        if (direct is String && direct.isNotEmpty) return direct;
      }
      final data = value['data'];
      if (data is String && data.isNotEmpty) return data;
      final nested = _findAudioValue(data);
      if (nested != null) return nested;
      final result = _findAudioValue(value['result']);
      if (result != null) return result;
    }
    return null;
  }

  Uint8List _decodeAudio(String encoded) {
    final clean = encoded.contains(',') && encoded.startsWith('data:')
        ? encoded.substring(encoded.indexOf(',') + 1)
        : encoded.trim();
    if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean) && clean.length.isEven) {
      return Uint8List.fromList(<int>[
        for (var index = 0; index < clean.length; index += 2)
          int.parse(clean.substring(index, index + 2), radix: 16),
      ]);
    }
    return base64Decode(clean);
  }

  (String, String) _formatInfo(String value, {String contentType = ''}) {
    final simple = _simpleFormat(value);
    if (contentType.contains('wav') || simple == 'wav')
      return ('wav', 'audio/wav');
    if (contentType.contains('ogg') || simple.contains('ogg'))
      return ('ogg', 'audio/ogg');
    if (contentType.contains('aac') || simple == 'aac')
      return ('aac', 'audio/aac');
    if (contentType.contains('pcm') || simple == 'pcm')
      return ('pcm', 'audio/pcm');
    return ('mp3', 'audio/mpeg');
  }

  String _simpleFormat(String value) => value.toLowerCase().split('_').first;

  void _validateEndpoint(String endpoint) {
    final normalized = endpoint.replaceAll('{voice_id}', 'voice');
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('语音 API 地址无效');
    }
    final loopback =
        uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1';
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) {
      throw const FormatException('语音 API 必须使用 HTTPS；本机调试地址除外');
    }
  }
}

Map<String, Object?> _jsonMap(Object? value) {
  try {
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is Map) {
      return decoded.map((key, item) => MapEntry('$key', item));
    }
  } on FormatException {
    // Invalid optional provider options fall back to an empty map.
  }
  return const <String, Object?>{};
}
