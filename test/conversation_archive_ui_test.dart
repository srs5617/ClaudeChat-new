import 'package:claudechat/app.dart';
import 'package:claudechat/app_controller.dart';
import 'package:claudechat/domain/entities.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('settings exposes archived conversations as compact rows', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController.visualAudit(
      initialSection: AppSection.settings,
    );
    controller.archivedConversations = <Conversation>[
      Conversation(
        id: 'archived-chat',
        title: '需要保留的旧对话',
        createdAt: DateTime.utc(2026, 8, 20, 8),
        updatedAt: DateTime.utc(2026, 8, 20, 9),
        archivedAt: DateTime.utc(2026, 8, 20, 10),
      ),
    ];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.ensureVisible(find.text('Archive'));
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(find.text('需要保留的旧对话'), findsOneWidget);
    expect(find.text('已归档'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('conversation archive timestamp survives entity serialization', () {
    final archivedAt = DateTime.utc(2026, 8, 20, 10);
    final value = Conversation(
      id: 'archived-chat',
      title: '旧对话',
      createdAt: archivedAt,
      updatedAt: archivedAt,
      archivedAt: archivedAt,
    );

    expect(Conversation.fromMap(value.toMap()).archivedAt, archivedAt);
  });

  testWidgets('starred conversations use a filled star in the sidebar', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController.visualAudit(scenario: 'chat-rich');
    addTearDown(controller.dispose);
    final timestamp = DateTime.utc(2026, 8, 20, 10);
    controller.conversations = <Conversation>[
      Conversation(
        id: 'starred-chat',
        title: '已经收藏的对话',
        starred: true,
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    ];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();

    expect(find.text('已经收藏的对话'), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.byTooltip('取消置顶'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
