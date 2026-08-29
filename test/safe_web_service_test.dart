import 'dart:io';

import 'package:claudechat/services/safe_web_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects localhost before issuing HTTP request', () async {
    final service = SafeWebService();
    expect(
      () => service.fetch('http://127.0.0.1/private'),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects non-http URL schemes', () async {
    final service = SafeWebService();
    expect(
      () => service.fetch('file:///etc/passwd'),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects IPv6 loopback', () async {
    final service = SafeWebService();
    expect(
      () => service.fetch('http://[::1]/private'),
      throwsA(anyOf(isA<FormatException>(), isA<SocketException>())),
    );
  });
}
