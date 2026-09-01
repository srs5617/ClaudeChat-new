import 'package:claudechat/app.dart';
import 'package:claudechat/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('message voice action is a compact play control', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController.visualAudit(
      initialSection: AppSection.chat,
      scenario: 'chat-rich',
    );

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pumpAndSettle();

    final tooltipMessages = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((tooltip) => tooltip.message)
        .toList();
    expect(tooltipMessages, containsAll(<String>['分支', '播放语音']));
    final branch = find.byTooltip('分支').first;
    final play = find.byTooltip('播放语音').first;
    expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);
    final gap = tester.getRect(play).left - tester.getRect(branch).right;
    expect(gap, lessThanOrEqualTo(1.1));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('voice library and detail keep the app visual language', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController.visualAudit(
      initialSection: AppSection.voices,
      scenario: 'voices-rich',
    );

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    expect(find.text('Ta的声音'), findsWidgets);
    expect(find.text('0012'), findsOneWidget);
    expect(find.text('#0012'), findsNothing);
    expect(find.text('今晚想听你把这段话温柔地读给我听。'), findsWidgets);
    expect(find.textContaining('ElevenLabs'), findsOneWidget);
    expect(find.textContaining('eleven_multilingual_v2'), findsNothing);
    expect(find.textContaining('Sonnet'), findsOneWidget);
    expect(find.byTooltip('只看收藏'), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('今晚想听你把这段话温柔地读给我听。'));
    await tester.pumpAndSettle();
    expect(find.text('#0012'), findsOneWidget);
    expect(find.text('0012'), findsOneWidget);
    expect(find.text('今晚想听你把这段话温柔地读给我听。'), findsWidgets);
    expect(find.text('声音 #0012'), findsNothing);
    expect(find.byTooltip('返回上级'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
