import 'package:claudechat/services/legacy_model_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'maps legacy card id to the real API model without losing parameters',
    () {
      final result = mapLegacyModels(<Map<String, Object?>>[
        <String, Object?>{
          'id': 'sonnet',
          'label': '我的 Sonnet',
          'apiProfileId': 'provider-1',
          'apiName': 'claude-sonnet-4-5',
          'stream': false,
          'temperature': null,
          'topP': 0.9,
          'frequencyPenalty': 0.2,
          'presencePenalty': -0.1,
          'maxTokens': 8192,
          'contextTokens': 200000,
        },
      ], 'sonnet');

      expect(result.activeApiModel, 'claude-sonnet-4-5');
      expect(result.activeSlotId, 'sonnet');
      final config = result.configs['claude-sonnet-4-5'] as Map;
      expect(config['apiProfileId'], 'provider-1');
      expect(config['stream'], isFalse);
      expect(config['temperature'], isNull);
      expect(config['topP'], 0.9);
      expect(config['maxTokens'], 8192);
      expect(config['contextTokens'], 200000);
      expect(result.slots, hasLength(1));
      expect(result.slots.single['id'], 'sonnet');
      expect(result.slots.single['apiName'], 'claude-sonnet-4-5');
      expect(result.slots.single['temperature'], isNull);
    },
  );

  test('never treats an unmapped card id as an API model', () {
    final result = mapLegacyModels(<Map<String, Object?>>[
      <String, Object?>{'id': 'opus', 'apiName': ''},
    ], 'opus');
    expect(result.activeApiModel, isNull);
    expect(result.activeSlotId, isNull);
    expect(result.configs, isEmpty);
    expect(result.slots, isEmpty);
  });
}
