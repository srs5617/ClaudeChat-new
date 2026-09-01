import 'dart:convert';

import 'package:claudechat/app.dart';
import 'package:claudechat/app_controller.dart';
import 'package:claudechat/domain/entities.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tool lifecycle is folded into the final response capsule', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController.visualAudit(
      initialSection: AppSection.chat,
      scenario: 'chat-rich',
    );
    addTearDown(controller.dispose);
    final message = controller.messages.lastWhere(
      (candidate) => candidate.role == 'assistant',
    );
    controller.messagePartsByMessage[message.id] = <MessagePart>[
      MessagePart(
        id: 'tool-completed',
        messageId: message.id,
        sequence: 1,
        type: 'status',
        metadataJson: jsonEncode(<String, Object?>{
          'callId': 'call-create-1',
          'name': 'create_file',
          'status': 'tool_completed',
        }),
        createdAt: message.createdAt,
      ),
      MessagePart(
        id: 'tool-result',
        messageId: message.id,
        sequence: 2,
        type: 'tool',
        content: jsonEncode(<String, Object?>{
          'id': 'file-1',
          'name': 'demo.html',
        }),
        metadataJson: jsonEncode(<String, Object?>{
          'callId': 'call-create-1',
          'name': 'create_file',
          'arguments': <String, Object?>{'name': 'demo.html'},
          'status': 'success',
        }),
        createdAt: message.createdAt,
      ),
      MessagePart(
        id: 'reply-success',
        messageId: message.id,
        sequence: 3,
        type: 'status',
        metadataJson: jsonEncode(<String, Object?>{
          'status': 'success',
          'detail': '消息返回成功，工具：create_file',
        }),
        createdAt: message.createdAt,
      ),
    ];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('消息已发送'), findsOneWidget);
    expect(find.text('小机子正在回复'), findsOneWidget);
    expect(find.text('小机子已完成文件创建'), findsNothing);
    expect(find.text('小机子创建了文件「demo.html」'), findsOneWidget);
    expect(find.text('消息返回成功'), findsOneWidget);
    final sent = tester.getTopLeft(find.text('消息已发送'));
    final replying = tester.getTopLeft(find.text('小机子正在回复'));
    final result = tester.getTopLeft(find.text('小机子创建了文件「demo.html」'));
    final completed = tester.getTopLeft(find.text('消息返回成功'));
    expect(sent.dx, closeTo(replying.dx, .5));
    expect(replying.dy - sent.dy, inInclusiveRange(24, 34));
    expect(sent.dy, lessThan(replying.dy));
    expect(replying.dy, lessThan(result.dy));
    expect(result.dy, lessThan(completed.dy));
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('stream keeps delivery states and spins the final progress row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller =
        AppController.visualAudit(
            initialSection: AppSection.chat,
            scenario: 'chat-rich',
          )
          ..busy = true
          ..streamingText = '正在生成新的回复。';
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    expect(find.text('消息已发送'), findsNWidgets(2));
    expect(find.text('小机子正在回复'), findsNWidgets(2));
    expect(find.text('小机子正在组织回复'), findsOneWidget);
    expect(find.byKey(const Key('response-status-spinner')), findsOneWidget);

    controller
      ..busy = false
      ..streamingText = '';
    controller.notifyListeners();
    await tester.pumpAndSettle();
  });

  testWidgets('ordinary live reasoning is visible independently of workspace', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller =
        AppController.visualAudit(
            initialSection: AppSection.chat,
            scenario: 'chat-rich',
          )
          ..busy = true
          ..streamingReasoning = '普通聊天正在流式输出的思维链';
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    expect(find.text('思维链'), findsWidgets);
    final streamingThought = find.descendant(
      of: find.byKey(const Key('message-stream')),
      matching: find.text('思维链'),
    );
    expect(streamingThought, findsOneWidget);
    await tester.tap(streamingThought);
    await tester.pump();
    expect(find.text('普通聊天正在流式输出的思维链'), findsOneWidget);
  });

  testWidgets('legacy metadata thoughts remain visible without part rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController.visualAudit(
      initialSection: AppSection.chat,
      scenario: 'chat-rich',
    );
    addTearDown(controller.dispose);
    final assistant = controller.messages.lastWhere(
      (message) => message.role == 'assistant',
    );
    final restored = ChatMessage(
      id: assistant.id,
      conversationId: assistant.conversationId,
      sequence: assistant.sequence,
      role: assistant.role,
      content: assistant.content,
      status: assistant.status,
      error: assistant.error,
      metadataJson: jsonEncode(<String, Object?>{
        'thoughts': <Object?>[
          <String, Object?>{'content': '历史思维链第一段'},
          <String, Object?>{'content': '历史思维链第二段'},
        ],
      }),
      createdAt: assistant.createdAt,
      updatedAt: assistant.updatedAt,
      deletedAt: assistant.deletedAt,
      revision: assistant.revision,
      originDeviceId: assistant.originDeviceId,
    );
    controller.messages = controller.messages
        .map((message) => message.id == assistant.id ? restored : message)
        .toList();
    controller.messagePartsByMessage[assistant.id] = const <MessagePart>[];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('思维链'), findsNWidgets(2));
    await tester.tap(find.text('思维链').first);
    await tester.pumpAndSettle();
    expect(find.text('历史思维链第一段'), findsOneWidget);
    expect(find.text('消息已发送'), findsOneWidget);
    expect(find.text('小机子正在回复'), findsOneWidget);
  });

  testWidgets('ordinary chat restores legacy reasoning aliases', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController.visualAudit(
      initialSection: AppSection.chat,
      scenario: 'chat-rich',
    );
    addTearDown(controller.dispose);
    final assistant = controller.messages.lastWhere(
      (message) => message.role == 'assistant',
    );
    controller.messagePartsByMessage[assistant.id] = <MessagePart>[
      MessagePart(
        id: 'legacy-thinking-alias',
        messageId: assistant.id,
        sequence: 1,
        type: 'thinking',
        content: '普通对话的旧思维链',
        createdAt: assistant.createdAt,
      ),
    ];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('思维链'), findsOneWidget);
    await tester.tap(find.text('思维链'));
    await tester.pumpAndSettle();
    expect(find.text('普通对话的旧思维链'), findsOneWidget);
  });

  testWidgets(
    'legacy metadata reasoning is paired with surviving ordered content parts',
    (tester) async {
      tester.view.physicalSize = const Size(480, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = AppController.visualAudit(
        initialSection: AppSection.chat,
        scenario: 'chat-rich',
      );
      addTearDown(controller.dispose);
      final assistant = controller.messages.lastWhere(
        (message) => message.role == 'assistant',
      );
      final restored = ChatMessage(
        id: assistant.id,
        conversationId: assistant.conversationId,
        sequence: assistant.sequence,
        role: assistant.role,
        content: '第一段正文第二段正文',
        metadataJson: jsonEncode(<String, Object?>{
          'thoughts': <Object?>[
            <String, Object?>{'content': '第一轮思维链'},
            <String, Object?>{'content': '第二轮思维链'},
          ],
        }),
        createdAt: assistant.createdAt,
      );
      controller.messages = controller.messages
          .map((message) => message.id == assistant.id ? restored : message)
          .toList();
      controller.messagePartsByMessage[assistant.id] = <MessagePart>[
        MessagePart(
          id: 'legacy-content-1',
          messageId: assistant.id,
          sequence: 1,
          type: 'content',
          content: '第一段正文',
          createdAt: assistant.createdAt,
        ),
        MessagePart(
          id: 'legacy-tool',
          messageId: assistant.id,
          sequence: 2,
          type: 'tool',
          content: '{}',
          metadataJson: jsonEncode(<String, Object?>{
            'name': 'create_file',
            'arguments': <String, Object?>{'name': '顺序测试.md'},
            'status': 'success',
          }),
          createdAt: assistant.createdAt,
        ),
        MessagePart(
          id: 'legacy-content-2',
          messageId: assistant.id,
          sequence: 3,
          type: 'content',
          content: '第二段正文',
          createdAt: assistant.createdAt,
        ),
      ];

      await tester.pumpWidget(
        ClaudeChatApp(controller: controller, skipSplash: true),
      );
      await tester.pumpAndSettle();

      final thoughts = find.text('思维链');
      expect(thoughts, findsNWidgets(2));
      final firstThoughtY = tester.getTopLeft(thoughts.at(0)).dy;
      final firstContentY = tester.getTopLeft(find.text('第一段正文')).dy;
      final toolY = tester.getTopLeft(find.text('小机子创建了文件「顺序测试.md」')).dy;
      final secondThoughtY = tester.getTopLeft(thoughts.at(1)).dy;
      final secondContentY = tester.getTopLeft(find.text('第二段正文')).dy;
      expect(firstThoughtY, lessThan(firstContentY));
      expect(firstContentY, lessThan(toolY));
      expect(toolY, lessThan(secondThoughtY));
      expect(secondThoughtY, lessThan(secondContentY));
    },
  );
}
