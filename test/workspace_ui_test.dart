import 'dart:io';

import 'package:claudechat/app.dart';
import 'package:claudechat/app_controller.dart';
import 'package:claudechat/services/api_client.dart';
import 'package:claudechat/services/content_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'workspace streaming only renders content not yet committed as parts',
    () {
      expect(uncommittedStreamText('第一段第二段', '第一段'), '第二段');
      expect(uncommittedStreamText('第一段', '第一段'), isEmpty);
      expect(uncommittedStreamText('新一轮', ''), '新一轮');
    },
  );

  Future<void> setViewport(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('workspace library keeps the legacy card content', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(
      initialSection: AppSection.workspaces,
      scenario: 'content-rich',
    );

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    expect(find.text('Ta的工作室'), findsWidgets);
    expect(find.text('搜索工作区名称'), findsOneWidget);
    expect(find.text('2 个文件'), findsOneWidget);
    expect(find.text('旅行手册'), findsOneWidget);
    expect(find.text('点击进入工作区'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening a workspace always enters chat at the absolute bottom', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(
      initialSection: AppSection.workspaces,
      scenario: 'content-rich',
    );
    addTearDown(controller.dispose);
    final workspace = controller.workspaces.single;
    final timestamp = DateTime.utc(2026, 8, 17, 13, 30);
    controller
      ..activeWorkspace = workspace
      ..workspaceMessages = List<WorkspaceMessageRecord>.generate(
        40,
        (index) => WorkspaceMessageRecord(
          id: 'workspace-message-$index',
          workspaceId: workspace.id,
          conversationId: 'audit-workspace-conversation',
          sequence: index + 1,
          role: index.isEven ? 'user' : 'assistant',
          content: '第 ${index + 1} 条工作区消息，用于确认长对话打开时直接位于最底部。',
          createdAt: timestamp.add(Duration(minutes: index)),
        ),
      );

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('计划'));
    await tester.pump();
    expect(find.text('还没有计划'), findsOneWidget);

    final messages = controller.workspaceMessages;
    controller.activeWorkspace = null;
    controller.open(AppSection.workspaces);
    await tester.pump();
    controller
      ..activeWorkspace = workspace
      ..workspaceMessages = messages;
    controller.workspaceActivity.value++;
    await tester.pumpAndSettle();

    expect(find.text('对话'), findsOneWidget);
    expect(find.text('还没有计划'), findsNothing);
    final list = tester.widget<ListView>(
      find.byKey(const Key('workspace-message-list')),
    );
    expect(list.reverse, isTrue);
    expect(list.controller!.position.pixels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('workspace detail uses files, chat, plan and top-bar settings', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(
      initialSection: AppSection.workspaces,
      scenario: 'content-rich',
    );
    controller.settings
      ..['fontFamily'] = 'custom'
      ..['customFontFamily'] = 'WorkspaceAuditCustom';
    final workspace = controller.workspaces.single;
    final timestamp = DateTime.utc(2026, 8, 17, 13, 30);
    controller
      ..activeWorkspace = workspace
      ..workspaceFiles = <WorkspaceFileRecord>[
        WorkspaceFileRecord(
          id: 'audit-workspace-file',
          workspaceId: workspace.id,
          name: 'README.md',
          type: 'markdown',
          relativePath: 'workspaces/audit/README.md',
          updatedAt: timestamp,
        ),
      ]
      ..workspaceFileContents = <String, String>{
        'audit-workspace-file': '这是一份旅行手册。',
      }
      ..workspaceBusy = true
      ..workspaceStreamingToolProgress = const ChatCompletionPart(
        type: 'tool',
        metadata: <String, Object?>{
          'name': 'create_workspace_file',
          'status': 'preparing',
          'arguments': <String, Object?>{'name': 'README.md'},
        },
      )
      ..workspaceMessages = <WorkspaceMessageRecord>[
        WorkspaceMessageRecord(
          id: 'audit-workspace-message',
          workspaceId: workspace.id,
          conversationId: 'audit-workspace-conversation',
          sequence: 1,
          role: 'user',
          content: '先整理目录',
          createdAt: timestamp,
        ),
      ];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    expect(find.text('旅行手册'), findsOneWidget);
    expect(find.text('文件 (1)'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('计划'), findsOneWidget);
    expect(find.byTooltip('工作区设置'), findsOneWidget);

    await tester.tap(find.text('文件 (1)'));
    await tester.pump();
    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('运行'), findsOneWidget);
    expect(find.text('导出'), findsOneWidget);
    final exportButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '导出'),
    );
    final runButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '运行'),
    );
    expect(
      exportButton.style?.textStyle?.resolve(const <WidgetState>{})?.fontFamily,
      'WorkspaceAuditCustom',
    );
    expect(
      runButton.style?.textStyle?.resolve(const <WidgetState>{})?.fontFamily,
      'WorkspaceAuditCustom',
    );
    expect(find.byIcon(Icons.ios_share_rounded), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.text('markdown · 27 B'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('对话'));
    await tester.pump();
    expect(find.text('先整理目录'), findsOneWidget);
    expect(find.text('让 AI 帮你写文件...'), findsOneWidget);
    expect(find.text('准备创建 README.md'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('工作区设置'));
    await tester.pump();
    expect(find.text('工作区'), findsOneWidget);
    expect(find.text('Agent'), findsWidgets);
    expect(find.text('检查点'), findsOneWidget);

    await tester.tap(find.text('工作区'));
    await tester.pump();
    expect(find.text('项目类型'), findsOneWidget);

    await tester.tap(find.text('管理'));
    await tester.pump();
    expect(find.text('归档工作区'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('workspace chat uses its own extended Markdown renderer', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(
      initialSection: AppSection.workspaces,
      scenario: 'content-rich',
    );
    addTearDown(controller.dispose);
    final workspace = controller.workspaces.single;
    final timestamp = DateTime.utc(2026, 8, 28, 10);
    controller
      ..activeWorkspace = workspace
      ..workspaceMessages = <WorkspaceMessageRecord>[
        WorkspaceMessageRecord(
          id: 'workspace-extended-markdown',
          workspaceId: workspace.id,
          conversationId: 'workspace-markdown-conversation',
          sequence: 1,
          role: 'assistant',
          content:
              'H<sub>2</sub>O、x<sup>2</sup>、==工作区重点==。\n\n'
              '1. 工作区一级\n'
              '   - 工作区二级\n'
              '     1. 工作区三级',
          createdAt: timestamp,
        ),
      ];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('工作区二级', findRichText: true), findsOneWidget);
    expect(find.text('工作区三级', findRichText: true), findsOneWidget);
    expect(find.textContaining('<sup>'), findsNothing);
    expect(find.textContaining('<sub>'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('persistent workspace status stays visible without a task', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(
      initialSection: AppSection.workspaces,
      scenario: 'content-rich',
    );
    final original = controller.workspaces.single;
    controller.activeWorkspace = WorkspaceRecord(
      id: original.id,
      name: original.name,
      updatedAt: original.updatedAt,
      description: original.description,
      projectType: original.projectType,
      settings: const <String, Object?>{
        'taskPersistent': true,
        'taskDisplayStyle': 'top',
      },
    );

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();
    await tester.tap(find.text('对话'));
    await tester.pump();

    expect(find.text('任务尚未开始'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('workspace task persistence and presentation are independent', () {
    final controller = AppController.visualAudit(
      initialSection: AppSection.workspaces,
      scenario: 'content-rich',
    );
    addTearDown(controller.dispose);
    final original = controller.workspaces.single;

    WorkspaceRecord configure({
      required bool persistent,
      required String style,
    }) {
      final record = WorkspaceRecord(
        id: original.id,
        name: original.name,
        updatedAt: original.updatedAt,
        description: original.description,
        projectType: original.projectType,
        settings: <String, Object?>{
          'taskPersistent': persistent,
          'taskDisplayStyle': style,
        },
      );
      controller
        ..workspaces = <WorkspaceRecord>[record]
        ..activeWorkspace = record;
      return record;
    }

    configure(persistent: false, style: 'top');
    expect(controller.workspaceTaskVisible, isFalse);
    expect(controller.workspaceTaskQueue, isEmpty);

    controller.workspaceBusy = true;
    expect(controller.workspaceTaskVisible, isTrue);
    expect(controller.workspaceTaskQueue, isEmpty);

    configure(persistent: false, style: 'ball');
    expect(controller.workspaceTaskVisible, isTrue);
    expect(controller.workspaceTaskQueue, hasLength(1));
    controller.workspaceBusy = false;
    expect(controller.workspaceTaskVisible, isFalse);
    expect(controller.workspaceTaskQueue, isEmpty);

    configure(persistent: true, style: 'ball');
    expect(controller.workspaceTaskVisible, isTrue);
    expect(controller.workspaceTaskQueue, hasLength(1));

    configure(persistent: true, style: 'top');
    expect(controller.workspaceTaskVisible, isTrue);
    expect(controller.workspaceTaskQueue, isEmpty);
  });

  testWidgets('workspace task ball can hint from an ordinary chat', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'chat-rich');
    final backgroundWorkspace = WorkspaceRecord(
      id: 'background-workspace',
      name: '后台工作区',
      updatedAt: DateTime.utc(2026, 8, 27),
      settings: const <String, Object?>{
        'taskPersistent': true,
        'taskDisplayStyle': 'ball',
      },
    );
    controller.workspaces = <WorkspaceRecord>[backgroundWorkspace];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
    expect(find.text('任务尚未开始'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('leaving a busy workspace returns to chooser and keeps task alive', () {
    final controller = AppController.visualAudit(
      initialSection: AppSection.workspaces,
      scenario: 'content-rich',
    );
    final workspace = controller.workspaces.single;
    controller
      ..activeWorkspace = workspace
      ..workspaceBusy = true;

    controller.closeWorkspace();

    expect(controller.section, AppSection.workspaces);
    expect(controller.activeWorkspace, isNull);
    expect(controller.workspaceBusy, isTrue);
  });

  test('workspace tool progress is isolated from global chat notices', () {
    final source = File('lib/app_controller.dart').readAsStringSync();
    final workspaceRequest = source.substring(
      source.indexOf('Future<void> sendWorkspaceMessage'),
      source.indexOf('void stopWorkspaceGeneration'),
    );

    expect(workspaceRequest, isNot(contains('target: AppSection.workspaces')));
  });

  test('file runtimes persist localStorage in isolated scopes', () {
    final app = File('lib/app.dart').readAsStringSync();
    final android = File(
      'android/app/src/main/kotlin/com/susuclaude/app/HtmlPreviewActivity.kt',
    ).readAsStringSync();
    final androidManifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final iosInfo = File('ios/Runner/Info.plist').readAsStringSync();

    expect(
      app,
      contains("runtimeScope: runtimeScope ?? 'file-\${item.id}'"),
    );
    expect(app, contains("runtimeScope: 'workspace-\${file.workspaceId}'"));
    expect(android, contains('settings.domStorageEnabled = true'));
    expect(android, contains('settings.blockNetworkLoads = false'));
    expect(android, contains('connect-src http: https:'));
    expect(android, contains('WebSettings.MIXED_CONTENT_ALWAYS_ALLOW'));
    expect(android, contains('settings.allowFileAccess = false'));
    expect(android, contains('.runtime.claudechat.local/'));
    expect(androidManifest, contains('android:usesCleartextTraffic="true"'));
    expect(ios, contains('configuration.websiteDataStore = .default()'));
    expect(ios, contains('connect-src http: https:'));
    expect(ios, contains('scheme == "http"'));
    expect(ios, contains('scheme == "https"'));
    expect(ios, contains('.runtime.claudechat.local/'));
    expect(iosInfo, contains('NSAllowsArbitraryLoadsInWebContent'));
  });

  test(
    'in-flight chat and workspace requests use native background activity',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final android = File(
        'android/app/src/main/kotlin/com/susuclaude/app/ChatForegroundService.kt',
      ).readAsStringSync();
      final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      final platform = File(
        'lib/services/platform_service.dart',
      ).readAsStringSync();

      expect(manifest, contains('android.permission.WAKE_LOCK'));
      expect(manifest, contains('android:foregroundServiceType="dataSync"'));
      expect(android, contains('PowerManager.PARTIAL_WAKE_LOCK'));
      expect(android, contains('startForeground(notificationId'));
      expect(ios, contains('UIApplication.shared.beginBackgroundTask'));
      expect(platform, contains('requestNotificationPermission()'));
    },
  );

  test('checkpoint restore creates one safety checkpoint, not two commits', () {
    final source = File(
      'lib/services/content_repository.dart',
    ).readAsStringSync();
    final restore = source.substring(
      source.indexOf('Future<void> restoreWorkspaceCheckpoint'),
    );

    expect(restore, contains("trigger: 'before_restore'"));
    expect(restore, isNot(contains("trigger: 'restore'")));
    expect(
      RegExp(r'createWorkspaceCheckpoint\(').allMatches(restore).length,
      1,
    );
  });
}
