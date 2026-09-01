import 'package:claudechat/app.dart';
import 'package:claudechat/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> setViewport(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('chat reading surface dismisses the composer keyboard', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'chat-rich');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    final composer = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          '${widget.decoration?.hintText}'.startsWith('Reply to '),
    );
    expect(composer, findsOneWidget);
    await tester.tap(composer);
    await tester.pump();
    expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);

    await tester.tap(find.byKey(const Key('chat-reading-surface')));
    await tester.pump();
    expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isFalse);
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('dragging the message list dismisses the composer keyboard', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'chat-rich');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: AppShell(controller: controller)),
    );
    await tester.pump();

    final composer = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          '${widget.decoration?.hintText}'.startsWith('Reply to '),
    );
    await tester.tap(composer);
    await tester.pump();
    expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);

    await tester.drag(find.byType(ListView).first, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isFalse);
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('composer grows to eight lines and then scrolls internally', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'chat-rich');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: AppShell(controller: controller)),
    );
    await tester.pump();

    final composer = find.byKey(const Key('chat-composer-input'));
    final field = tester.widget<TextField>(composer);
    expect(field.minLines, 2);
    expect(field.maxLines, 8);
    expect(field.style?.fontSize, 14);
    expect(field.style?.height, 1.18);
    final initialHeight = tester.getSize(composer).height;

    await tester.enterText(
      composer,
      List<String>.generate(10, (index) => '第 ${index + 1} 行').join('\n'),
    );
    await tester.pump();
    expect(tester.getSize(composer).height, greaterThan(initialHeight * 2.5));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('composer plus and network controls have no extra column gap', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'chat-rich');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    final plus = tester.getRect(find.byTooltip('更多操作'));
    final network = tester.getRect(find.byTooltip('关闭联网搜索'));
    expect(network.left - plus.right, closeTo(0, .001));
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('composer plus menu exposes mobile attachment and tool entries', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'chat-rich');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump();

    expect(find.text('相机'), findsOneWidget);
    expect(find.text('照片'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('工具箱'), findsOneWidget);
    expect(find.text('插件'), findsOneWidget);
    expect(find.text('导出当前对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('long press edit and resend returns content to the composer', (
    tester,
  ) async {
    await setViewport(tester);
    final controller = AppController.visualAudit(scenario: 'chat-rich');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    final userMessage = find.byWidgetPredicate(
      (widget) => widget is SelectableText && widget.data == '莫西莫西',
    );
    await tester.ensureVisible(userMessage);
    await tester.pumpAndSettle();

    expect(find.byTooltip('编辑并重发'), findsNothing);
    await tester.tap(userMessage);
    await tester.pump();
    expect(find.byTooltip('编辑并重发'), findsNothing);

    await tester.longPress(userMessage);
    await tester.pump();
    expect(find.byTooltip('编辑并重发'), findsOneWidget);
    expect(
      tester.getSize(find.byTooltip('重编')),
      tester.getSize(find.byTooltip('重新回答')),
    );
    expect(tester.getSize(find.byTooltip('重编')).width, 30);

    await tester.tap(find.byTooltip('编辑并重发'));
    await tester.pump();

    expect(find.text('编辑并重发'), findsOneWidget);
    final composer = tester.widget<TextField>(
      find.byKey(const Key('chat-composer-input')),
    );
    expect(composer.controller?.text, '莫西莫西');
    expect(composer.focusNode?.hasFocus, isTrue);

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(find.text('编辑并重发'), findsNothing);
    expect(composer.controller?.text, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 250));
  });
}
