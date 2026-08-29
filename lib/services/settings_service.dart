import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import 'secure_vault.dart';

const _uuid = Uuid();

const List<Map<String, Object?>> defaultModelSlots = <Map<String, Object?>>[
  <String, Object?>{
    'id': 'sonnet',
    'label': 'Sonnet',
    'description': '日常聊天和创作',
    'mode': 'Adaptive',
    'apiProfileId': '',
    'apiName': '',
    'stream': true,
    'temperature': 0.7,
    'topP': 1.0,
    'frequencyPenalty': 0.0,
    'presencePenalty': 0.0,
    'maxTokens': null,
    'contextTokens': null,
  },
  <String, Object?>{
    'id': 'opus',
    'label': 'Opus',
    'description': '复杂任务和长对话',
    'mode': 'Deep',
    'apiProfileId': '',
    'apiName': '',
    'stream': true,
    'temperature': 0.7,
    'topP': 1.0,
    'frequencyPenalty': 0.0,
    'presencePenalty': 0.0,
    'maxTokens': null,
    'contextTokens': null,
  },
  <String, Object?>{
    'id': 'haiku',
    'label': 'Haiku',
    'description': '快速轻量回复',
    'mode': 'Fast',
    'apiProfileId': '',
    'apiName': '',
    'stream': true,
    'temperature': 0.7,
    'topP': 1.0,
    'frequencyPenalty': 0.0,
    'presencePenalty': 0.0,
    'maxTokens': null,
    'contextTokens': null,
  },
];

List<Map<String, Object?>> normalizeModelSlots(Object? value) {
  final incoming = value is List
      ? value
            .whereType<Map>()
            .map((item) => item.cast<String, Object?>())
            .where((item) => '${item['id'] ?? ''}'.trim().isNotEmpty)
            .toList()
      : <Map<String, Object?>>[];
  final normalized = <Map<String, Object?>>[];
  for (final fallback in defaultModelSlots) {
    final existing = incoming
        .where((item) => item['id'] == fallback['id'])
        .firstOrNull;
    normalized.add(<String, Object?>{...fallback, ...?existing});
  }
  for (final item in incoming) {
    if (normalized.any((slot) => slot['id'] == item['id'])) continue;
    if (normalized.length == 5) break;
    normalized.add(item);
  }
  return normalized;
}

class ApiProfile {
  const ApiProfile({
    required this.id,
    required this.name,
    required this.endpoint,
    this.models = const <String>[],
    this.customHeaders = const <String, String>{},
    this.active = false,
  });

  final String id;
  final String name;
  final String endpoint;
  final List<String> models;
  final Map<String, String> customHeaders;
  final bool active;

  factory ApiProfile.fromMap(Map<String, Object?> map) => ApiProfile(
    id: map['id']! as String,
    name: map['name']! as String,
    endpoint: map['endpoint']! as String,
    models: ((jsonDecode((map['models_json'] as String?) ?? '[]')) as List)
        .map((value) => '$value')
        .toList(),
    customHeaders:
        ((jsonDecode((map['custom_headers_json'] as String?) ?? '{}')) as Map)
            .map((key, value) => MapEntry('$key', '$value')),
    active: map['is_active'] == 1 || map['is_active'] == true,
  );
}

class SettingsService {
  SettingsService(this.store, this.vault);

  final AppDatabase store;
  final SecureVault vault;
  static const _outputLimitMigrationKey =
      'unboundedModelOutputMigrationVersion';

  static const defaults = <String, Object?>{
    'appName': 'ClaudeChat',
    'profileName': '用户',
    'profileNote': '本地账号',
    'greeting': '',
    'splashPhrases': '欢迎回来\n很高兴见到你\n我在这里\n今天想聊些什么？',
    'splashRandom': true,
    'themeMode': 'system',
    'fontFamily': 'claude',
    'customFontName': '',
    'customFontPath': '',
    'customFontFamily': '',
    'fontSize': 'compact',
    'fontScale': 1.0,
    'codeFoldLines': 5,
    'contextTokens': null,
    'tokenEstimateRatio': 1.0,
    'systemPrompt': '你是一个温柔、真诚、稳定的聊天伙伴。你会认真理解用户的表达，回应要自然、有记忆感，但不要假装拥有现实中没有的经历。',
    'temperature': 0.7,
    'topP': 1.0,
    'frequencyPenalty': 0.0,
    'presencePenalty': 0.0,
    'maxTokens': null,
    'stream': true,
    'thinking': true,
    'modelSlots': defaultModelSlots,
    'activeModelSlotId': 'sonnet',
    'activeModelId': '',
    'toolboxEnabled': true,
    'toolOverrides': <String, Object?>{},
    'webSearchEnabled': false,
    'fetchUrlEnabled': false,
    'showAssistantAvatar': false,
    'showUserAvatar': false,
    'replyNotifications': true,
    'diagnosticsEnabled': true,
    'voiceBackgroundPlayback': false,
    'language': 'zh-CN',
  };

  Future<Map<String, Object?>> load() async {
    final rows = await store.database.query('settings');
    final output = <String, Object?>{...defaults};
    for (final row in rows) {
      try {
        output[row['key']! as String] = jsonDecode(
          row['value_json']! as String,
        );
      } on FormatException {
        // Ignore a malformed individual setting; all user data remains intact.
      }
    }
    final outputLimitMigration =
        (output[_outputLimitMigrationKey] as num?)?.toInt() ?? 0;
    if (outputLimitMigration < 1) {
      final slots = output['modelSlots'];
      if (slots is List) {
        final migratedSlots = slots.whereType<Map>().map((slot) {
          final migrated = slot.cast<String, Object?>();
          return <String, Object?>{
            ...migrated,
            if (migrated['maxTokens'] == 4096) 'maxTokens': null,
          };
        }).toList();
        output['modelSlots'] = migratedSlots;
        await set('modelSlots', migratedSlots);
      }
      if (output['maxTokens'] == 4096) {
        output['maxTokens'] = null;
        await set('maxTokens', null);
      }
      output[_outputLimitMigrationKey] = 1;
      await set(_outputLimitMigrationKey, 1);
    }
    output.remove('useProxy');
    if (rows.any((row) => row['key'] == 'useProxy')) {
      await store.database.delete(
        'settings',
        where: 'key = ?',
        whereArgs: const <Object?>['useProxy'],
      );
    }
    final normalizedSlots = normalizeModelSlots(output['modelSlots']);
    if (jsonEncode(output['modelSlots']) != jsonEncode(normalizedSlots)) {
      await set('modelSlots', normalizedSlots);
    }
    output['modelSlots'] = normalizedSlots;
    final selectedSlot = '${output['activeModelSlotId'] ?? ''}';
    if (!normalizedSlots.any((slot) => slot['id'] == selectedSlot)) {
      output['activeModelSlotId'] = 'sonnet';
      await set('activeModelSlotId', 'sonnet');
    }
    return output;
  }

  Future<void> set(String key, Object? value) async {
    final existing = await store.database.query(
      'settings',
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    final revision = existing.isEmpty
        ? 1
        : ((existing.first['revision'] as num?)?.toInt() ?? 0) + 1;
    await store.database.insert('settings', <String, Object?>{
      'key': key,
      'value_json': jsonEncode(value),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'revision': revision,
      'origin_device_id': store.deviceId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<ApiProfile>> profiles() async {
    final rows = await store.database.query(
      'api_profiles',
      where: 'deleted_at IS NULL',
      orderBy: 'is_active DESC, created_at ASC',
    );
    return rows.map(ApiProfile.fromMap).toList();
  }

  Future<ApiProfile> saveProfile({
    String? id,
    required String name,
    required String endpoint,
    required String apiKey,
    required List<String> models,
    Map<String, String> customHeaders = const <String, String>{},
    bool active = true,
  }) async {
    final profileId = id ?? _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    final old = await store.database.query(
      'api_profiles',
      where: 'id = ?',
      whereArgs: <Object?>[profileId],
      limit: 1,
    );
    final createdAt = old.isEmpty ? now : old.first['created_at']! as String;
    final revision = old.isEmpty
        ? 1
        : ((old.first['revision'] as num?)?.toInt() ?? 0) + 1;
    await store.database.transaction((transaction) async {
      if (active)
        await transaction.update('api_profiles', <String, Object?>{
          'is_active': 0,
        });
      await transaction.insert('api_profiles', <String, Object?>{
        'id': profileId,
        'name': name.trim().isEmpty ? '默认接口' : name.trim(),
        'endpoint': endpoint.trim(),
        'custom_headers_json': jsonEncode(customHeaders),
        'models_json': jsonEncode(
          models.where((value) => value.trim().isNotEmpty).toList(),
        ),
        'is_active': active ? 1 : 0,
        'created_at': createdAt,
        'updated_at': now,
        'revision': revision,
        'origin_device_id': store.deviceId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    if (apiKey.isNotEmpty) await vault.writeApiKey(profileId, apiKey);
    return ApiProfile(
      id: profileId,
      name: name,
      endpoint: endpoint,
      models: models,
      customHeaders: customHeaders,
      active: active,
    );
  }

  Future<void> deleteProfile(String id) async {
    await store.softDelete('api_profiles', id);
    await vault.deleteApiKey(id);
    final remaining = await profiles();
    if (remaining.isNotEmpty && remaining.every((item) => !item.active)) {
      await store.database.update(
        'api_profiles',
        <String, Object?>{'is_active': 1},
        where: 'id = ?',
        whereArgs: <Object?>[remaining.first.id],
      );
    }
  }
}
