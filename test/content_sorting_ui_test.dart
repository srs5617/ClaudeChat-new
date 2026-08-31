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

  testWidgets('diaries are ordered only by latest modification time', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'content-rich');
    addTearDown(controller.dispose);
    final older = DateTime.utc(2026, 8, 20);
    final newer = DateTime.utc(2026, 8, 21);
    controller
      ..section = AppSection.diary
      ..settings['diaryViewMode'] = 'list'
      ..diaries = <DiaryEntry>[
        DiaryEntry(
          id: 'older-active',
          title: '较早修改的心事',
          status: 'active',
          tags: const <String>[],
          createdAt: older,
          updatedAt: older,
          originDeviceId: 'test',
        ),
        DiaryEntry(
          id: 'newer-deleted',
          title: '最新修改的心事',
          status: 'deleted',
          tags: const <String>[],
          createdAt: older,
          updatedAt: newer,
          deletedAt: newer,
          originDeviceId: 'test',
        ),
      ]
      ..visualAuditDiaryVersions = <DiaryVersion>[
        DiaryVersion(
          id: 'older-version',
          diaryId: 'older-active',
          title: '较早修改的心事',
          content: 'older',
          operation: 'create',
          tags: const <String>[],
          createdAt: older,
          originDeviceId: 'test',
        ),
        DiaryVersion(
          id: 'newer-version',
          diaryId: 'newer-deleted',
          title: '最新修改的心事',
          content: 'newer',
          operation: 'create',
          tags: const <String>[],
          createdAt: newer,
          originDeviceId: 'test',
        ),
      ];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    final newest = tester.getTopLeft(find.text('最新修改的心事'));
    final olderPosition = tester.getTopLeft(find.text('较早修改的心事'));
    expect(
      newest.dy < olderPosition.dy ||
          newest.dy == olderPosition.dy && newest.dx < olderPosition.dx,
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('files do not group deleted entries after active entries', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'content-rich');
    addTearDown(controller.dispose);
    final older = DateTime.utc(2026, 8, 20);
    final newer = DateTime.utc(2026, 8, 21);
    controller
      ..section = AppSection.files
      ..files = <UserFileRecord>[
        UserFileRecord(
          id: 'older-active',
          name: '较早修改.txt',
          type: 'txt',
          updatedAt: older,
        ),
        UserFileRecord(
          id: 'newer-deleted',
          name: '最新修改.txt',
          type: 'txt',
          status: 'deleted',
          updatedAt: newer,
          deletedAt: newer,
        ),
      ]
      ..visualAuditFileContents = <String, String>{
        'older-active': 'older',
        'newer-deleted': 'newer',
      };

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    final newest = tester.getTopLeft(find.text('最新修改.txt'));
    final olderPosition = tester.getTopLeft(find.text('较早修改.txt'));
    expect(
      newest.dy < olderPosition.dy ||
          newest.dy == olderPosition.dy && newest.dx < olderPosition.dx,
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('a single memory card keeps its natural content height', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'content-rich')
      ..section = AppSection.memories;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    final card = find.byKey(
      const ValueKey<String>('memory-card-visual-audit-memory'),
    );
    expect(card, findsOneWidget);
    expect(tester.getSize(card).height, lessThan(300));
    expect(tester.takeException(), isNull);
  });
}
