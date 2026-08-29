import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS HTML preview is app-owned and uses the document title', () {
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(source, contains('navigationItem.leftBarButtonItem'));
    expect(source, contains('document.title ||'));
    expect(source, contains('fallbackTitle'));
    expect(source, contains('tap.numberOfTapsRequired > 1'));
    expect(source, isNot(contains('barButtonSystemItem: .done')));
    expect(source, isNot(contains('title = "安全预览"')));
  });

  test('Android HTML preview keeps full source and app-owned navigation', () {
    final source = File(
      'android/app/src/main/kotlin/com/susuclaude/app/HtmlPreviewActivity.kt',
    ).readAsStringSync();

    expect(source, contains('setOnClickListener { finish() }'));
    expect(source, contains('view.title.orEmpty().trim()'));
    expect(source, contains('settings.setSupportZoom(false)'));
    expect(source, contains('View.OVER_SCROLL_NEVER'));
    expect(source, isNot(contains('.take(600_000)')));
    expect(source, isNot(contains('安全预览')));
  });

  test('Flutter forwards the file title as the native fallback', () {
    final platform = File(
      'lib/services/platform_service.dart',
    ).readAsStringSync();
    final app = File('lib/app.dart').readAsStringSync();

    expect(platform, contains("'title': fallbackTitle"));
    expect(app, contains('fallbackTitle: item.name'));
    expect(app, contains('fallbackTitle: file.name'));
  });
}
