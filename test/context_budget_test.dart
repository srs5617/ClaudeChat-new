import 'package:claudechat/domain/entities.dart';
import 'package:claudechat/services/context_budget.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage message(int sequence, String role, String content) => ChatMessage(
  id: '$sequence',
  conversationId: 'conversation',
  sequence: sequence,
  role: role,
  content: content,
  createdAt: DateTime.utc(2026),
);

void main() {
  test('normalizes legacy K-token values and full token values', () {
    expect(ContextBudget.normalizeBudget(128), 128000);
    expect(ContextBudget.normalizeBudget(128000), 128000);
    expect(ContextBudget.normalizeBudget(null), isNull);
  });

  test('summary chunk preserves recent messages and completes a turn', () {
    final messages = <ChatMessage>[
      for (var i = 0; i < 20; i++)
        message(i, i.isEven ? 'user' : 'assistant', '内容 ${'x' * 300}'),
    ];
    final end = ContextBudget.summaryEndIndex(
      messages,
      summarizedCount: 0,
      budget: 4096,
      keepRecent: 8,
    );
    expect(end, greaterThanOrEqualTo(4));
    expect(end, lessThanOrEqualTo(12));
    expect(messages[end - 1].role, 'assistant');
  });

  test('hard trim always keeps the newest exchange', () {
    final messages = <ChatMessage>[
      for (var i = 0; i < 12; i++)
        message(i, i.isEven ? 'user' : 'assistant', 'x' * 1000),
    ];
    final result = ContextBudget.trim(
      messages,
      budget: 4096,
      reservedTokens: 2048,
    );
    expect(result.dropped, greaterThan(0));
    expect(result.messages.last.id, messages.last.id);
    expect(result.messages.first.role, 'user');
  });

  test('tool receipts contribute to context trimming', () {
    final messages = <ChatMessage>[
      for (var i = 0; i < 8; i++)
        message(i, i.isEven ? 'user' : 'assistant', 'short'),
    ];
    final withoutTools = ContextBudget.trim(
      messages,
      budget: 4096,
      reservedTokens: 1000,
    );
    final withTools = ContextBudget.trim(
      messages,
      budget: 4096,
      reservedTokens: 1000,
      extraTokens: (message) => message.role == 'assistant' ? 1200 : 0,
    );
    expect(withTools.dropped, greaterThan(withoutTools.dropped));
    expect(withTools.messages.last.id, messages.last.id);
  });
}
