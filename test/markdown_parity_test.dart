import 'package:claudechat/app.dart';
import 'package:claudechat/app_controller.dart';
import 'package:claudechat/domain/entities.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('legacy fenced code keeps the following reply text visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController.visualAudit(
      initialSection: AppSection.chat,
      scenario: 'chat-markdown',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsWidgets);
    expect(find.text('展开'), findsOneWidget);
    expect(find.textContaining('”。'), findsOneWidget);
    expect(
      find.textContaining('等你在设置里填好 OpenAI-compatible endpoint'),
      findsOneWidget,
    );

    final markdownBodies = tester.widgetList<MarkdownBody>(
      find.byType(MarkdownBody),
    );
    expect(
      markdownBodies.any(
        (body) =>
            (body.styleSheet?.codeblockDecoration as BoxDecoration?)?.color ==
            Colors.transparent,
      ),
      isTrue,
    );
    expect(
      markdownBodies.any((body) {
        final decoration =
            body.styleSheet?.horizontalRuleDecoration as BoxDecoration?;
        final border = decoration?.border as Border?;
        return border?.top.width == .666667 && (border?.top.color.a ?? 1) < 1;
      }),
      isTrue,
    );
    final readingSurface = tester.widget<GestureDetector>(
      find.byKey(const Key('chat-reading-surface')),
    );
    expect(readingSurface.onVerticalDragDown, isNull);
  });

  testWidgets('assistant markdown renders inline and display formulas', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController.visualAudit(
      initialSection: AppSection.chat,
      scenario: 'chat-markdown',
    );
    addTearDown(controller.dispose);
    final message = controller.messages.last;
    controller.messagePartsByMessage[message.id] = <MessagePart>[
      MessagePart(
        id: 'formula-content',
        messageId: message.id,
        sequence: 1,
        type: 'content',
        content:
            r'内联公式 $E=mc^2$。'
            '\n\n'
            r'$$'
            '\n'
            r'x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}'
            '\n'
            r'$$',
        createdAt: message.createdAt,
      ),
    ];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == 'Math',
      ),
      findsNWidgets(2),
    );
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('ordinary chat renders extended inline HTML and mixed lists', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController.visualAudit(
      initialSection: AppSection.chat,
      scenario: 'chat-markdown',
    );
    addTearDown(controller.dispose);
    final message = controller.messages.last;
    controller.messagePartsByMessage[message.id] = <MessagePart>[
      MessagePart(
        id: 'extended-markdown-content',
        messageId: message.id,
        sequence: 1,
        type: 'content',
        content:
            'H<sub>2</sub>O、x<sup>2</sup>、==重点==、<u>下划线</u>。\n\n'
            '1. 普通对话一级\n'
            '   - 普通对话二级\n'
            '     1. 普通对话三级',
        createdAt: message.createdAt,
      ),
    ];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('普通对话二级', findRichText: true), findsOneWidget);
    expect(find.text('普通对话三级', findRichText: true), findsOneWidget);
    expect(find.textContaining('<sup>'), findsNothing);
    expect(find.textContaining('<sub>'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('assistant links offer safe preview before external browsing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController.visualAudit(
      initialSection: AppSection.chat,
      scenario: 'chat-markdown',
    );
    addTearDown(controller.dispose);
    final message = controller.messages.last;
    controller.messagePartsByMessage[message.id] = <MessagePart>[
      MessagePart(
        id: 'link-content',
        messageId: message.id,
        sequence: 1,
        type: 'content',
        content: '[示例链接](https://example.com/path)',
        createdAt: message.createdAt,
      ),
    ];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('示例链接', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('打开链接'), findsOneWidget);
    expect(find.text('安全预览'), findsOneWidget);
    expect(find.text('使用浏览器打开'), findsOneWidget);

    await tester.tap(find.text('使用浏览器打开'));
    await tester.pumpAndSettle();
    expect(find.text('使用系统浏览器打开？'), findsOneWidget);
    expect(find.text('确认前往'), findsOneWidget);
    expect(find.textContaining('建议不确定时先使用“安全预览”'), findsOneWidget);
  });
}
