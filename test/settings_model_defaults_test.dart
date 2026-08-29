import 'package:claudechat/data/app_database.dart';
import 'package:claudechat/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fresh installs expose the three required model slots', () {
    final slots = normalizeModelSlots(null);

    expect(slots.map((slot) => slot['id']), <String>[
      'sonnet',
      'opus',
      'haiku',
    ]);
    expect(slots.map((slot) => slot['label']), <String>[
      'Sonnet',
      'Opus',
      'Haiku',
    ]);
    for (final slot in slots) {
      expect(slot['temperature'], 0.7);
      expect(slot['topP'], 1.0);
      expect(slot['frequencyPenalty'], 0.0);
      expect(slot['presencePenalty'], 0.0);
      expect(slot['maxTokens'], isNull);
    }
  });

  test('normalization repairs missing defaults and enforces five-slot cap', () {
    final slots = normalizeModelSlots(<Object?>[
      <String, Object?>{'id': 'haiku', 'label': 'Quick'},
      <String, Object?>{'id': 'custom-1', 'label': 'One'},
      <String, Object?>{'id': 'custom-2', 'label': 'Two'},
      <String, Object?>{'id': 'custom-3', 'label': 'Three'},
    ]);

    expect(slots, hasLength(5));
    expect(slots.map((slot) => slot['id']), <String>[
      'sonnet',
      'opus',
      'haiku',
      'custom-1',
      'custom-2',
    ]);
    expect(slots[2]['label'], 'Quick');
  });

  test('profile tables participate in generic soft deletion', () {
    expect(softDeleteTables, contains('api_profiles'));
    expect(softDeleteTables, contains('voice_profiles'));
  });
}
