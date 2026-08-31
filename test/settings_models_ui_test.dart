import 'package:claudechat/app.dart';
import 'package:claudechat/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('model fields keep readable height and spacing', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController.visualAudit(
      initialSection: AppSection.settings,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ClaudeChatApp(controller: controller, skipSplash: true),
    );
    await tester.ensureVisible(find.text('Models'));
    await tester.tap(find.text('Models'));
    await tester.pumpAndSettle();

    final sonnetField = find.byWidgetPredicate(
      (widget) =>
          widget is TextFormField && widget.controller?.text == 'Sonnet',
    );
    expect(sonnetField, findsOneWidget);
    expect(tester.getSize(sonnetField).height, greaterThanOrEqualTo(40));
    expect(find.text('上下文预算(K)'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
