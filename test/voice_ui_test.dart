import 'package:claudechat/app.dart';
import 'package:claudechat/app_controller.dart';
import 'package:claudechat/services/voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tool voice and whole-message voice selectors stay independent', () {
    final controller = AppController.visualAudit(
      initialSection: AppSection.chat,
      scenario: 'chat-rich',
    );
    final timestamp = DateTime.utc(2026, 8, 19, 12);
    VoiceAsset asset({
      required String id,
      required String sourceKind,
      String toolCallId = '',
      String sourceText = '',
    }) => VoiceAsset(
      id: id,
      libraryNumber: id == 'message-voice' ? 1 : 2,
      messageId: 'visual-audit-assistant',
      conversationId: 'visual-audit-chat',
      profileId: null,
      provider: 'custom',
      model: 'visual-audit',
      voiceId: 'visual-audit',
      relativePath: '$id.mp3',
      mediaType: 'audio/mpeg',
      byteSize: 128,
      sha256: id,
      favorite: false,
      bound: true,
      createdAt: timestamp,
      updatedAt: timestamp,
      sourceKind: sourceKind,
      toolCallId: toolCallId,
      sourceText: sourceText,
    );
    final messageVoice = asset(id: 'message-voice', sourceKind: 'message');
    final toolVoice = asset(
      id: 'tool-voice',
      sourceKind: 'tool',
      toolCallId: 'call-1',
      sourceText: '小机子自己说的话',
    );
    controller.voiceAssets = <VoiceAsset>[toolVoice, messageVoice];

    expect(controller.voiceForMessage('visual-audit-assistant'), messageVoice);
    expect(controller.voicesForMessage('visual-audit-assistant'), <VoiceAsset>[
      messageVoice,
    ]);
    expect(
      controller.toolVoiceForCall(
        'visual-audit-assistant',
        'call-1',
        text: '小机子自己说的话',
      ),
      toolVoice,
    );
  });

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

  testWidgets('bound message voice uses the waveform scrubber', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController.visualAudit(
      initialSection: AppSection.chat,
      scenario: 'chat-rich',
    );
    final timestamp = DateTime.utc(2026, 8, 19, 12);
    controller.voiceAssets = <VoiceAsset>[
      VoiceAsset(
        id: 'message-waveform-voice',
        libraryNumber: 13,
        messageId: 'visual-audit-assistant',
        conversationId: 'visual-audit-chat',
        profileId: null,
        provider: 'custom',
        model: 'visual-audit',
        voiceId: 'visual-audit',
        relativePath: 'visual-audit.mp3',
        mediaType: 'audio/mpeg',
        byteSize: 128,
        sha256: 'visual-audit',
        durationMs: 11000,
        favorite: false,
        bound: true,
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    ];

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('message-voice-waveform')), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
