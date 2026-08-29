String formatCompletionUsage(Map<String, Object?> usage) {
  num? numberAt(List<String> paths) {
    for (final path in paths) {
      Object? value = usage;
      for (final segment in path.split('.')) {
        if (value is! Map || !value.containsKey(segment)) {
          value = null;
          break;
        }
        value = value[segment];
      }
      if (value is num) return value;
      if (value is String && num.tryParse(value) != null) {
        return num.parse(value);
      }
    }
    return null;
  }

  String shortNumber(num value) {
    final absolute = value.abs();
    if (absolute >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (absolute >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
    return '$value';
  }

  final input = numberAt(const <String>[
    'prompt_tokens',
    'input_tokens',
    'prompt_token_count',
    'promptTokenCount',
    'inputTokenCount',
  ]);
  final output = numberAt(const <String>[
    'completion_tokens',
    'output_tokens',
    'candidates_token_count',
    'outputTokenCount',
    'candidatesTokenCount',
  ]);
  final total = numberAt(const <String>[
    'total_tokens',
    'total_token_count',
    'totalTokenCount',
  ]);
  final reasoning = numberAt(const <String>[
    'completion_tokens_details.reasoning_tokens',
    'output_tokens_details.reasoning_tokens',
    'reasoning_tokens',
    'thoughts_token_count',
    'thoughtsTokenCount',
  ]);
  final cacheHit = numberAt(const <String>[
    'prompt_tokens_details.cached_tokens',
    'input_tokens_details.cached_tokens',
    'prompt_cache_hit_tokens',
    'cache_read_input_tokens',
    'cached_tokens',
    'cached_content_token_count',
    'cachedContentTokenCount',
  ]);
  final cacheMiss = numberAt(const <String>[
    'prompt_cache_miss_tokens',
    'cache_miss_input_tokens',
    'cache_miss_tokens',
  ]);
  final cacheWrite = numberAt(const <String>[
    'cache_creation_input_tokens',
    'cache_write_input_tokens',
    'cache_creation_tokens',
  ]);
  final cacheRead = numberAt(const <String>['cache_read_input_tokens']);
  final rawRounds = usage['_rounds'];
  final roundCount = rawRounds is List ? rawRounds.length : 0;

  final values = <String>[];
  if (input != null) values.add('输入：${shortNumber(input)}');
  if (output != null) values.add('输出：${shortNumber(output)}');
  if (total != null) values.add('总计：${shortNumber(total)}');
  if (reasoning != null) values.add('思考：${shortNumber(reasoning)}');
  if (cacheHit != null) {
    final denominator = cacheMiss != null
        ? cacheHit + cacheMiss
        : cacheRead != null && input != null
        ? input + cacheHit + (cacheWrite ?? 0)
        : input != null && cacheHit <= input
        ? input
        : input != null
        ? input + cacheHit + (cacheWrite ?? 0)
        : null;
    final rate = denominator == null || denominator <= 0
        ? null
        : ((cacheHit / denominator) * 100).round();
    values.add('缓存：${shortNumber(cacheHit)}${rate == null ? '' : '（$rate%）'}');
  }
  if (cacheMiss != null && cacheHit == null) {
    values.add('未命中：${shortNumber(cacheMiss)}');
  }
  if (input != null &&
      cacheHit == null &&
      cacheMiss == null &&
      cacheWrite == null) {
    values.add('缓存：API 未返回统计');
  }
  if (cacheWrite != null) values.add('写缓存：${shortNumber(cacheWrite)}');
  if (roundCount > 1) values.add('请求轮次：$roundCount');
  return values.join('，');
}
