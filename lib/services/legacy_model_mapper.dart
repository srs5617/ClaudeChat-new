class LegacyModelMapping {
  const LegacyModelMapping({
    required this.configs,
    required this.slots,
    this.activeApiModel,
    this.activeSlotId,
  });

  final Map<String, Object?> configs;
  final List<Map<String, Object?>> slots;
  final String? activeApiModel;
  final String? activeSlotId;
}

LegacyModelMapping mapLegacyModels(
  Object? rawModels,
  Object? rawActiveModelId,
) {
  final models = (rawModels as List? ?? const <Object?>[])
      .whereType<Map>()
      .map((item) => item.cast<String, Object?>())
      .toList();
  final configs = <String, Object?>{};
  final slots = <Map<String, Object?>>[];
  for (final model in models) {
    final apiName = _string(model['apiName']);
    if (apiName.isEmpty) continue;
    final config = <String, Object?>{
      'legacyId': _string(model['id']),
      'label': _string(model['label'], fallback: apiName),
      'apiProfileId': _string(model['apiProfileId']),
      'description': _string(model['description']),
      'mode': _string(model['mode']),
      'stream': model['stream'] != false,
      for (final key in const <String>[
        'temperature',
        'topP',
        'frequencyPenalty',
        'presencePenalty',
        'maxTokens',
        'contextTokens',
      ])
        key: model.containsKey(key) ? model[key] : null,
    };
    configs[apiName] = config;
    slots.add(<String, Object?>{
      'id': _string(model['id'], fallback: 'model-${slots.length + 1}'),
      'label': config['label'],
      'apiProfileId': config['apiProfileId'],
      'apiName': apiName,
      'description': config['description'],
      'mode': config['mode'],
      'stream': config['stream'],
      for (final key in const <String>[
        'temperature',
        'topP',
        'frequencyPenalty',
        'presencePenalty',
        'maxTokens',
        'contextTokens',
      ])
        key: config[key],
    });
  }
  final activeLegacyId = _string(rawActiveModelId);
  final active = models
      .where((model) => _string(model['id']) == activeLegacyId)
      .firstOrNull;
  final activeApiName = _string(active?['apiName']);
  return LegacyModelMapping(
    configs: configs,
    slots: slots,
    activeApiModel: activeApiName.isEmpty ? null : activeApiName,
    activeSlotId: activeApiName.isEmpty ? null : _string(active?['id']),
  );
}

String _string(Object? value, {String fallback = ''}) =>
    value == null || '$value'.trim().isEmpty ? fallback : '$value';
