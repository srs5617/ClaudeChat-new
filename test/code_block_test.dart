import 'package:claudechat/widgets/code_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('long fenced code blocks fold and expand', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownBody(
            data: '```dart\n1\n2\n3\n4\n5\n6\n7\n```',
            builders: <String, MarkdownElementBuilder>{
              'pre': ClaudeCodeBlockBuilder(),
            },
          ),
        ),
      ),
    );
    expect(find.text('展开'), findsOneWidget);
    expect(find.textContaining('…'), findsNothing);
    final copyButton = find.ancestor(
      of: find.text('复制'),
      matching: find.byType(TextButton),
    );
    final expandButton = find.ancestor(
      of: find.text('展开'),
      matching: find.byType(TextButton),
    );
    final copyRect = tester.getRect(copyButton);
    final expandRect = tester.getRect(expandButton);
    expect(copyRect.width, closeTo(37.135418, .001));
    expect(copyRect.height, closeTo(24, .001));
    expect(expandRect.width, closeTo(37.135418, .001));
    expect(expandRect.left - copyRect.right, closeTo(4, .001));
    final copyWidget = tester.widget<TextButton>(copyButton);
    expect(
      copyWidget.style?.backgroundColor?.resolve(const <WidgetState>{}),
      Colors.transparent,
    );
    final decorations = tester
        .widgetList<Container>(find.byType(Container))
        .map((widget) => widget.decoration)
        .whereType<BoxDecoration>();
    expect(
      decorations.any(
        (decoration) =>
            decoration.borderRadius == BorderRadius.circular(12) &&
            decoration.color == Colors.white,
      ),
      isTrue,
    );
    await tester.tap(find.text('展开'));
    await tester.pump();
    expect(find.textContaining('7'), findsOneWidget);
    expect(find.text('折叠'), findsOneWidget);
  });

  testWidgets('HTML blocks expose the native safe preview action', (
    tester,
  ) async {
    var ran = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownBody(
            data: '```html\n<h1>Hello</h1>\n```',
            builders: <String, MarkdownElementBuilder>{
              'pre': ClaudeCodeBlockBuilder(onRun: (_, _) async => ran = true),
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('运行'));
    await tester.pump();
    expect(ran, isTrue);
  });
}
