import 'dart:io';

import 'package:claudechat/app.dart';
import 'package:claudechat/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app splash keeps icon, application name and splash phrase', (
    tester,
  ) async {
    final controller = AppController.visualAudit();
    controller.settings
      ..['appName'] = '团子的 Claude'
      ..['splashPhrases'] = '轻轻一捏，弹回来啦'
      ..['splashRandom'] = false;

    await tester.pumpWidget(ClaudeChatApp(controller: controller));

    expect(find.byKey(const ValueKey<String>('app-splash-brand')), findsOne);
    expect(find.text('团子的 Claude'), findsOne);
    expect(find.text('轻轻一捏，弹回来啦'), findsOne);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('App settings account name updates account pill and avatar', (
    tester,
  ) async {
    final controller = AppController.visualAudit(
      initialSection: AppSection.settings,
    );
    controller.settings['profileName'] = '苏苏';

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.tap(find.text('App'));
    await tester.pumpAndSettle();

    expect(find.text('账号名称'), findsOne);
    final accountField = tester.widget<TextFormField>(
      find.byType(TextFormField).first,
    );
    expect(accountField.initialValue, '苏苏');

    final appSource = File('lib/app.dart').readAsStringSync();
    expect(appSource, contains("saveSetting('profileName', value.trim())"));

    controller.settings['profileName'] = '团子';
    await tester.pumpWidget(
      ClaudeChatApp(
        key: const ValueKey<String>('updated-account'),
        controller: controller,
        skipSplash: true,
      ),
    );
    await tester.pump();

    expect(find.text('团子'), findsWidgets);
    expect(find.text('团'), findsWidgets);
  });

  test('native launch screens no longer render the isolated icon', () {
    final ios = File(
      'ios/Runner/Base.lproj/LaunchScreen.storyboard',
    ).readAsStringSync();
    final android = File(
      'android/app/src/main/res/drawable/launch_background.xml',
    ).readAsStringSync();
    final androidV21 = File(
      'android/app/src/main/res/drawable-v21/launch_background.xml',
    ).readAsStringSync();

    expect(ios, isNot(contains('LaunchImage')));
    expect(android, isNot(contains('launch_icon')));
    expect(androidV21, isNot(contains('launch_icon')));
  });
}
