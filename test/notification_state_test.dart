import 'package:claudechat/app_controller.dart';
import 'package:claudechat/services/tool_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('actionable notices expand and route to their target section', () {
    final controller = AppController.visualAudit(
      scenario: 'chat-notifications',
    );

    expect(controller.notifications, hasLength(3));
    expect(controller.notificationsOpen, isFalse);

    controller.toggleNotifications();
    expect(controller.notificationsOpen, isTrue);

    final diary = controller.notifications.firstWhere(
      (item) => item.target == AppSection.diary,
    );
    controller.activateNotification(diary);

    expect(controller.section, AppSection.diary);
    expect(controller.notificationsOpen, isFalse);
    expect(controller.notifications, isNot(contains(diary)));
    expect(controller.pendingNoticeNavigation?.target, AppSection.diary);
    expect(controller.pendingNoticeNavigation?.entryId, diary.entryId);
  });

  test('notice navigation retains the originating chat viewport snapshot', () {
    final controller = AppController.visualAudit(scenario: 'chat-rich');
    final notice = AppNotice(
      id: 'returnable-file',
      type: AppNoticeType.info,
      text: '小机子创建了文件',
      createdAt: DateTime.utc(2026, 8, 17, 12, 5),
      target: AppSection.files,
      entryId: 'file-1',
    );
    final conversationId = controller.activeConversation!.id;
    controller.recordChatViewport(conversationId, 326.5, scrollable: true);

    controller.activateNotification(notice);
    expect(controller.canReturnFromNotice, isTrue);
    expect(
      controller.activeNoticeNavigation?.returnConversationId,
      conversationId,
    );
    expect(controller.activeNoticeNavigation?.returnScrollOffset, 326.5);

    controller.returnFromNoticeNavigation();
    expect(controller.section, AppSection.chat);
    final request = controller.takeChatViewportRequest(conversationId);
    expect(request?.disposition, ChatViewportDisposition.restore);
    expect(request?.offset, 326.5);
    expect(request?.reserveLegacyScrollbar, isTrue);
  });

  test('expanded notice rows keep the legacy open-time snapshot', () {
    final controller = AppController.visualAudit(
      scenario: 'chat-notifications',
    );
    controller.toggleNotifications();
    final openedIds = controller.expandedActionableNotifications
        .map((item) => item.id)
        .toList();

    controller.notifications = <AppNotice>[
      AppNotice(
        id: 'arrived-while-open',
        type: AppNoticeType.info,
        text: '小机子创建了文件“后来.txt”',
        createdAt: DateTime.utc(2026, 8, 17, 12, 4),
        target: AppSection.files,
        entryId: 'later-file',
      ),
      ...controller.notifications,
    ];

    expect(
      controller.expandedActionableNotifications.map((item) => item.id),
      openedIds,
    );
    expect(controller.actionableNotifications, hasLength(4));
  });

  test(
    'opening one target notice clears every notice for that legacy view',
    () {
      final controller = AppController.visualAudit(
        scenario: 'chat-notifications',
      );
      final first = controller.notifications.firstWhere(
        (item) => item.target == AppSection.diary,
      );
      controller.notifications = <AppNotice>[
        ...controller.notifications,
        AppNotice(
          id: 'another-diary',
          type: AppNoticeType.notice,
          text: '小机子修订了日记“另一篇”',
          createdAt: DateTime.utc(2026, 8, 17, 12, 2),
          target: AppSection.diary,
          entryId: 'another-diary',
        ),
      ];

      controller.activateNotification(first);

      expect(
        controller.notifications.where(
          (item) => item.target == AppSection.diary,
        ),
        isEmpty,
      );
    },
  );

  test('non-action notices never replace the chat pending-work capsule', () {
    final controller = AppController.visualAudit(
      scenario: 'chat-notifications',
    );
    controller.notifications = <AppNotice>[
      ...controller.notifications,
      AppNotice(
        id: 'informational-only',
        type: AppNoticeType.info,
        text: '普通提示',
        createdAt: DateTime.utc(2026, 8, 17, 12, 3),
      ),
    ];

    expect(controller.actionableNotifications, hasLength(3));
  });

  test('actionable notices show approvals first and newest first', () {
    final controller = AppController.visualAudit();
    controller.notifications = <AppNotice>[
      AppNotice(
        id: 'newer',
        type: AppNoticeType.notice,
        text: '较新的通知',
        createdAt: DateTime.utc(2026, 8, 17, 12, 2),
        target: AppSection.files,
      ),
      AppNotice(
        id: 'oldest',
        type: AppNoticeType.notice,
        text: '最早的通知',
        createdAt: DateTime.utc(2026, 8, 17, 12),
        target: AppSection.diary,
      ),
      AppNotice(
        id: 'middle',
        type: AppNoticeType.notice,
        text: '中间的通知',
        createdAt: DateTime.utc(2026, 8, 17, 12, 1),
        target: AppSection.memories,
      ),
      AppNotice(
        id: 'approval',
        type: AppNoticeType.danger,
        text: '需要审批',
        createdAt: DateTime.utc(2026, 8, 17, 11, 59),
        approval: const ToolRequest(
          callId: 'approval-order',
          name: 'delete_memory',
          arguments: <String, Object?>{'id': 'memory-1'},
        ),
      ),
    ];

    expect(controller.actionableNotifications.map((item) => item.id), <String>[
      'approval',
      'newer',
      'middle',
      'oldest',
    ]);
  });

  test(
    'tool approval waits in the notice capsule until user opens it',
    () async {
      final controller = AppController.visualAudit();
      const request = ToolRequest(
        callId: 'approval-1',
        name: 'delete_memory',
        arguments: <String, Object?>{'id': 'memory-1', 'reason': '已过期'},
      );

      controller.requestToolApproval(request);
      expect(controller.pendingToolApproval, isNull);
      expect(controller.approvalDialogRequested, isFalse);
      expect(controller.notifications.single.isApproval, isTrue);

      controller.activateNotification(controller.notifications.single);
      expect(controller.pendingToolApproval, request);
      expect(controller.approvalDialogRequested, isTrue);

      await controller.resolveToolApproval(false);
      expect(controller.pendingToolApproval, isNull);
      expect(controller.notifications, isEmpty);
    },
  );
}
