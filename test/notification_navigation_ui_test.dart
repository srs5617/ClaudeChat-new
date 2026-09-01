import 'package:claudechat/app.dart';
import 'package:claudechat/app_controller.dart';
import 'package:claudechat/domain/entities.dart';
import 'package:claudechat/services/content_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> setViewport(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('diary notice opens the exact legacy detail target', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'content-rich');
    final notice = AppNotice(
      id: 'diary-notice',
      type: AppNoticeType.notice,
      text: '小机子写了一篇日记“安静的夜晚”',
      createdAt: DateTime.utc(2026, 8, 17, 13, 31),
      target: AppSection.diary,
      entryId: 'audit-diary-20260817',
    );
    controller.notifications = <AppNotice>[notice];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    controller.activateNotification(notice);
    await tester.pumpAndSettle();

    expect(controller.section, AppSection.diary);
    expect(controller.pendingNoticeNavigation, isNull);
    expect(find.bySemanticsLabel('日记详情'), findsOneWidget);
    expect(find.textContaining('明天继续按照自己的节奏前进'), findsWidgets);
    expect(find.byTooltip('复制'), findsOneWidget);
    expect(find.byTooltip('导出'), findsOneWidget);
    expect(find.byTooltip('历史版本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('file notice opens the exact legacy detail target', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'content-rich');
    controller.files = <UserFileRecord>[
      UserFileRecord(
        id: 'audit-file',
        name: '旅行清单.md',
        type: 'markdown',
        updatedAt: DateTime.utc(2026, 8, 17, 13, 30),
      ),
    ];
    controller.visualAuditFileContents = <String, String>{
      'audit-file': '- 护照\n- 充电器',
    };
    final notice = AppNotice(
      id: 'file-notice',
      type: AppNoticeType.info,
      text: '小机子创建了文件“旅行清单.md”',
      createdAt: DateTime.utc(2026, 8, 17, 13, 31),
      target: AppSection.files,
      entryId: 'audit-file',
    );
    controller.notifications = <AppNotice>[notice];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    controller.activateNotification(notice);
    await tester.pumpAndSettle();

    expect(controller.section, AppSection.files);
    expect(controller.pendingNoticeNavigation, isNull);
    expect(find.text('旅行清单.md'), findsWidgets);
    expect(find.byTooltip('返回列表'), findsOneWidget);
    expect(find.byTooltip('复制'), findsOneWidget);
    expect(find.byTooltip('导出'), findsOneWidget);
    expect(find.byTooltip('历史版本'), findsOneWidget);
    expect(find.byTooltip('删除'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty file detail identifies intentional empty content', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'content-rich');
    controller.files = <UserFileRecord>[
      UserFileRecord(
        id: 'audit-empty-file',
        name: '空白测试.txt',
        type: 'text',
        updatedAt: DateTime.utc(2026, 8, 17, 13, 30),
      ),
    ];
    controller.visualAuditFileContents = <String, String>{
      'audit-empty-file': '',
    };
    final notice = AppNotice(
      id: 'empty-file-notice',
      type: AppNoticeType.info,
      text: '小机子创建了文件“空白测试.txt”',
      createdAt: DateTime.utc(2026, 8, 17, 13, 31),
      target: AppSection.files,
      entryId: 'audit-empty-file',
    );
    controller.notifications = <AppNotice>[notice];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    controller.activateNotification(notice);
    await tester.pumpAndSettle();

    expect(find.text('小机子没有写入任何内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('runnable file detail exposes a play action', (tester) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'content-rich');
    controller.files = <UserFileRecord>[
      UserFileRecord(
        id: 'audit-html-file',
        name: '预览.html',
        type: 'html',
        updatedAt: DateTime.utc(2026, 8, 17, 13, 30),
      ),
    ];
    controller.visualAuditFileContents = <String, String>{
      'audit-html-file': '<h1>历史对比</h1>',
    };
    final notice = AppNotice(
      id: 'html-file-notice',
      type: AppNoticeType.info,
      text: '小机子创建了文件“预览.html”',
      createdAt: DateTime.utc(2026, 8, 17, 13, 31),
      target: AppSection.files,
      entryId: 'audit-html-file',
    );
    controller.notifications = <AppNotice>[notice];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    controller.activateNotification(notice);
    await tester.pumpAndSettle();

    expect(find.byTooltip('运行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('memory notice routes to its entry and consumes navigation', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'content-rich');
    final notice = AppNotice(
      id: 'memory-notice',
      type: AppNoticeType.info,
      text: '小机子创建了 “苏苏喜欢在晚上安静地写日记。”',
      createdAt: DateTime.utc(2026, 8, 17, 13, 31),
      target: AppSection.memories,
      entryId: 'visual-audit-memory',
    );
    controller.notifications = <AppNotice>[notice];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    controller.activateNotification(notice);
    await tester.pump();

    expect(controller.section, AppSection.memories);
    expect(controller.pendingNoticeNavigation, isNull);
    expect(find.text('用户喜欢在晚上安静地写日记。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'notice detail back restores chat offset while ordinary chat entry bottoms',
    (tester) async {
      await setViewport(tester);
      final controller = AppController.visualAudit(scenario: 'chat-rich');
      final conversationId = controller.activeConversation!.id;
      final timestamp = DateTime.utc(2026, 8, 17, 13, 30);
      controller.messages = <ChatMessage>[
        ...controller.messages,
        for (var index = 0; index < 24; index++)
          ChatMessage(
            id: 'long-$index',
            conversationId: conversationId,
            sequence: index + 3,
            role: 'assistant',
            content: '用于验证返回位置的长消息 $index。\n第二行内容保持列表可滚动。',
            createdAt: timestamp.add(Duration(seconds: index)),
          ),
      ];
      controller.files = <UserFileRecord>[
        UserFileRecord(
          id: 'return-file',
          name: '返回位置.md',
          type: 'markdown',
          updatedAt: timestamp,
        ),
      ];
      controller.visualAuditFileContents = <String, String>{
        'return-file': '返回后不应移动原对话。',
      };
      final notice = AppNotice(
        id: 'return-file-notice',
        type: AppNoticeType.info,
        text: '小机子创建了文件“返回位置.md”',
        createdAt: timestamp,
        target: AppSection.files,
        entryId: 'return-file',
      );
      controller.notifications = <AppNotice>[notice];

      await tester.pumpWidget(
        ClaudeChatApp(controller: controller, skipSplash: true),
      );
      await tester.pumpAndSettle();
      var list = tester.widget<ListView>(
        find.byKey(const Key('chat-message-list')),
      );
      expect(list.reverse, isTrue);
      expect(list.controller!.position.maxScrollExtent, greaterThan(400));
      list.controller!.jumpTo(286);
      await tester.pump();

      controller.activateNotification(notice);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回列表'));
      await tester.pumpAndSettle();

      expect(controller.section, AppSection.chat);
      list = tester.widget<ListView>(
        find.byKey(const Key('chat-message-list')),
      );
      expect(list.controller!.offset, closeTo(286, .5));

      controller.open(AppSection.files);
      await tester.pump();
      controller.open(AppSection.chat);
      await tester.pumpAndSettle();
      list = tester.widget<ListView>(
        find.byKey(const Key('chat-message-list')),
      );
      expect(
        list.controller!.offset,
        closeTo(list.controller!.position.minScrollExtent, .5),
      );
    },
  );
}
