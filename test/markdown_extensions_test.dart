import 'package:claudechat/widgets/markdown_extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

void main() {
  test('chat surfaces receive isolated Markdown parser extension sets', () {
    final ordinary = createClaudeMarkdownExtensionSet();
    final workspace = createClaudeMarkdownExtensionSet();

    expect(ordinary, isNot(same(workspace)));
    expect(ordinary.inlineSyntaxes, isNot(same(workspace.inlineSyntaxes)));
  });

  test('extended inline syntax produces safe semantic Markdown nodes', () {
    final document = md.Document(
      extensionSet: createClaudeMarkdownExtensionSet(),
    );
    final nodes = document.parseInline(
      'H<sub>2</sub>O、x<sup>2</sup>、==重点==、'
      '<mark>标记</mark>、<span><strong>内联 HTML</strong></span>、'
      '<a href="https://example.com">安全链接</a>',
    );
    final tags = <String>[];

    void visit(md.Node node) {
      if (node is! md.Element) return;
      tags.add(node.tag);
      for (final child in node.children ?? const <md.Node>[]) {
        visit(child);
      }
    }

    for (final node in nodes) {
      visit(node);
    }

    expect(
      tags,
      containsAll(<String>['sub', 'sup', 'mark', 'span', 'strong', 'a']),
    );
  });

  testWidgets('extended inline styles and mixed nested lists render together', (
    tester,
  ) async {
    const soft = Color(0xFFF4F2EF);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownBody(
            data:
                '水是 H<sub>2</sub>O，平方是 x<sup>2</sup>，'
                '这是 ==重点== 和 <u>下划线</u>。\n\n'
                '1. 有序一级\n'
                '   - 无序二级\n'
                '     1. 有序三级\n'
                '   - 第二个无序二级\n'
                '2. 第二个有序一级',
            extensionSet: createClaudeMarkdownExtensionSet(),
            builders: createClaudeInlineBuilders(
              highlightColor: const Color(0xFFF0D8CB),
              inlineCodeColor: soft,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('水是'), findsWidgets);
    expect(find.text('无序二级', findRichText: true), findsOneWidget);
    expect(find.text('有序三级', findRichText: true), findsOneWidget);
    expect(find.text('第二个无序二级', findRichText: true), findsOneWidget);
    expect(find.byType(Transform), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
