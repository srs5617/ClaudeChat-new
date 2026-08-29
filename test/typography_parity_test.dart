import 'package:claudechat/app.dart';
import 'package:claudechat/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('legacy chat typography uses exact families and compact sizes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController.visualAudit(scenario: 'chat-rich');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    final composerFinder = find.byKey(const Key('chat-composer-input'));
    final composer = tester.widget<TextField>(composerFinder);
    expect(composer.style?.fontSize, 14);
    expect(composer.style?.height, 1.18);
    expect(composer.style?.fontFamily, 'DMSans');
    expect(composer.minLines, 2);

    final userText = tester.widget<SelectableText>(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == '莫西莫西',
      ),
    );
    expect(userText.style?.fontFamily, 'Lora');
    expect(userText.style?.fontSize, closeTo(130 / 9, .000001));
    expect(userText.style?.height, 1.5);

    final assistant = tester.widget<MarkdownBody>(
      find.byWidgetPredicate(
        (widget) =>
            widget is MarkdownBody && widget.data.contains('我现在跑在你的本地网页里'),
      ),
    );
    expect(assistant.styleSheet?.p?.fontFamily, 'Lora');
    expect(assistant.styleSheet?.p?.fontSize, closeTo(130 / 9, .000001));
    await tester.pump(const Duration(milliseconds: 250));
  });
}
