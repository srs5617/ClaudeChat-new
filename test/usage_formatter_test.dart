import 'package:claudechat/services/usage_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats OpenAI cached token rate like the legacy client', () {
    final summary = formatCompletionUsage(<String, Object?>{
      'prompt_tokens': 1000,
      'completion_tokens': 80,
      'prompt_tokens_details': <String, Object?>{'cached_tokens': 720},
    });

    expect(summary, '输入：1.0K，输出：80，缓存：720（72%）');
  });

  test('uses explicit hit and miss counts as cache rate denominator', () {
    final summary = formatCompletionUsage(<String, Object?>{
      'input_tokens': 1100,
      'output_tokens': 40,
      'cache_read_input_tokens': 900,
      'prompt_cache_miss_tokens': 100,
      'cache_creation_input_tokens': 60,
    });

    expect(summary, contains('缓存：900（90%）'));
    expect(summary, contains('写缓存：60'));
  });

  test('supports Gemini cached content token fields', () {
    final summary = formatCompletionUsage(<String, Object?>{
      'promptTokenCount': 200,
      'cachedContentTokenCount': 50,
    });

    expect(summary, '输入：200，缓存：50（25%）');
  });

  test('uses uncached plus read and write tokens for Anthropic-style rate', () {
    final summary = formatCompletionUsage(<String, Object?>{
      'input_tokens': 100,
      'output_tokens': 20,
      'cache_read_input_tokens': 900,
      'cache_creation_input_tokens': 100,
    });

    expect(summary, contains('缓存：900（82%）'));
  });

  test('distinguishes missing cache statistics from a zero cache hit', () {
    expect(
      formatCompletionUsage(<String, Object?>{'prompt_tokens': 100}),
      '输入：100，缓存：API 未返回统计',
    );
    expect(
      formatCompletionUsage(<String, Object?>{
        'prompt_tokens': 100,
        'prompt_tokens_details': <String, Object?>{'cached_tokens': 0},
      }),
      '输入：100，缓存：0（0%）',
    );
  });

  test('labels aggregate usage that contains multiple model rounds', () {
    final summary = formatCompletionUsage(<String, Object?>{
      'prompt_tokens': 200,
      '_rounds': <Object?>[
        <String, Object?>{'prompt_tokens': 80},
        <String, Object?>{'prompt_tokens': 120},
      ],
    });

    expect(summary, contains('请求轮次：2'));
  });
}
