import '../domain/entities.dart';

class ContextBudget {
  const ContextBudget._();

  static int estimateText(String value) {
    var cjk = 0;
    var otherWide = 0;
    for (final rune in value.runes) {
      if ((rune >= 0x3400 && rune <= 0x9fff) ||
          (rune >= 0x3040 && rune <= 0x30ff) ||
          (rune >= 0xac00 && rune <= 0xd7af)) {
        cjk++;
      } else if (rune > 0x7f) {
        otherWide++;
      }
    }
    final ascii = value.runes.length - cjk - otherWide;
    return (cjk * .6 + otherWide * .4 + ascii * .25).ceil();
  }

  static int estimateMessages(
    Iterable<ChatMessage> messages, {
    int Function(ChatMessage message)? extraTokens,
  }) => messages.fold(
    0,
    (total, message) =>
        total +
        estimateText(message.content) +
        8 +
        (extraTokens?.call(message) ?? 0),
  );

  static int? normalizeBudget(Object? raw) {
    if (raw is! num || raw <= 0) return null;
    final value = raw < 1024 ? raw * 1000 : raw;
    return value.round().clamp(4096, 2000000);
  }

  static int summaryEndIndex(
    List<ChatMessage> messages, {
    required int summarizedCount,
    required int budget,
    int keepRecent = 8,
    int Function(ChatMessage message)? extraTokens,
  }) {
    final start = summarizedCount.clamp(0, messages.length);
    final latestEnd = messages.length - keepRecent;
    if (latestEnd <= start) return start;
    final target = (budget * .28).round();
    var tokens = 0;
    var end = start;
    while (end < latestEnd) {
      tokens +=
          estimateText(messages[end].content) +
          8 +
          (extraTokens?.call(messages[end]) ?? 0);
      end++;
      if (tokens >= target && end - start >= 4) break;
    }
    if (end < latestEnd &&
        end > start &&
        messages[end - 1].role == 'user' &&
        messages[end].role == 'assistant') {
      end++;
    }
    return end;
  }

  static ContextTrim trim(
    List<ChatMessage> messages, {
    required int budget,
    required int reservedTokens,
    double targetRatio = .9,
    int Function(ChatMessage message)? extraTokens,
  }) {
    final limit = (budget * targetRatio).round() - reservedTokens;
    if (limit <= 0) {
      return ContextTrim(
        messages: messages.isEmpty
            ? const <ChatMessage>[]
            : <ChatMessage>[messages.last],
        dropped: messages.isEmpty ? 0 : messages.length - 1,
      );
    }
    var start = 0;
    var tokens = estimateMessages(messages, extraTokens: extraTokens);
    while (start < messages.length - 2 && tokens > limit) {
      tokens -=
          estimateText(messages[start].content) +
          8 +
          (extraTokens?.call(messages[start]) ?? 0);
      start++;
    }
    if (start > 0 &&
        start < messages.length &&
        messages[start].role == 'assistant') {
      start++;
    }
    return ContextTrim(messages: messages.skip(start).toList(), dropped: start);
  }
}

class ContextTrim {
  const ContextTrim({required this.messages, required this.dropped});

  final List<ChatMessage> messages;
  final int dropped;
}
