import 'package:claudechat/app.dart';
import 'package:claudechat/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('theme changes use a zero-duration transition', (tester) async {
    final controller = AppController.visualAudit(scenario: 'settings');
    controller.settings['themeMode'] = 'dark';
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.pump();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(app.themeAnimationDuration, Duration.zero);
  });
}
