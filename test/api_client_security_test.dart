import 'dart:async';

import 'package:claudechat/services/api_client.dart';
import 'package:claudechat/services/secure_vault.dart';
import 'package:claudechat/services/settings_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues(<String, String>{});

  test('rejects sensitive custom headers before sending', () async {
    final client = _RecordingClient();
    final api = ApiClient(SecureVault(), client: client);
    await expectLater(
      api.models(
        const ApiProfile(
          id: 'p',
          name: 'test',
          endpoint: 'https://api.example.test/v1',
          customHeaders: <String, String>{'Authorization': 'attacker'},
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(client.sent, isFalse);
  });

  test('rejects header-value newline injection before sending', () async {
    final client = _RecordingClient();
    final api = ApiClient(SecureVault(), client: client);
    await expectLater(
      api.models(
        const ApiProfile(
          id: 'p',
          name: 'test',
          endpoint: 'https://api.example.test/v1',
          customHeaders: <String, String>{'X-Test': 'ok\r\nX-Evil: yes'},
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(client.sent, isFalse);
  });

  test('API requests never automatically follow redirects', () async {
    final client = _RecordingClient(statusCode: 302);
    final api = ApiClient(SecureVault(), client: client);
    await expectLater(
      api.models(
        const ApiProfile(
          id: 'p',
          name: 'test',
          endpoint: 'https://api.example.test/v1',
        ),
      ),
      throwsA(isA<Exception>()),
    );
    expect(client.followRedirects, isFalse);
  });
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient({this.statusCode = 200});

  final int statusCode;
  bool sent = false;
  bool? followRedirects;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent = true;
    followRedirects = request.followRedirects;
    return http.StreamedResponse(
      Stream<List<int>>.value(
        statusCode == 200
            ? <int>[123, 34, 100, 97, 116, 97, 34, 58, 91, 93, 125]
            : <int>[],
      ),
      statusCode,
    );
  }
}
