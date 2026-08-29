import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class WebSearchResult {
  const WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
  });
  final String title;
  final String url;
  final String snippet;
  Map<String, String> toJson() => <String, String>{
    'title': title,
    'url': url,
    'snippet': snippet,
  };
}

class SafeWebService {
  SafeWebService({http.Client? client}) : _client = client ?? http.Client();

  static const maxResponseBytes = 2 * 1024 * 1024;
  final http.Client _client;

  Future<List<WebSearchResult>> search(String query, {int limit = 5}) async {
    final value = query.trim();
    if (value.isEmpty) throw const FormatException('搜索词不能为空');
    final uri = Uri.https('html.duckduckgo.com', '/html/', <String, String>{
      'q': value,
    });
    final body = await _getPublicText(uri);
    final resultPattern = RegExp(
      r'<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>(.*?)</a>[\s\S]*?<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>',
      caseSensitive: false,
    );
    final output = <WebSearchResult>[];
    for (final match in resultPattern.allMatches(body)) {
      var url = _decodeHtml(match.group(1) ?? '');
      final redirect = Uri.tryParse(url);
      final uddg = redirect?.queryParameters['uddg'];
      if (uddg != null && uddg.isNotEmpty) url = uddg;
      if (Uri.tryParse(url)?.scheme case 'http' || 'https') {
        output.add(
          WebSearchResult(
            title: _stripHtml(match.group(2) ?? ''),
            url: url,
            snippet: _stripHtml(match.group(3) ?? ''),
          ),
        );
      }
      if (output.length >= limit.clamp(1, 10)) break;
    }
    return output;
  }

  Future<Map<String, String>> fetch(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority)
      throw const FormatException('网页地址无效');
    final body = await _getPublicText(uri);
    final titleMatch = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(body);
    final title = titleMatch == null
        ? uri.host
        : _stripHtml(titleMatch.group(1) ?? '');
    final content = _stripHtml(body).replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return <String, String>{
      'url': uri.toString(),
      'title': title,
      'content': content.substring(0, content.length.clamp(0, 8000)),
    };
  }

  Future<String> _getPublicText(Uri initial) async {
    var uri = initial;
    for (var redirect = 0; redirect <= 5; redirect++) {
      await _assertPublic(uri);
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll(<String, String>{
          'user-agent': 'ClaudeChat/0.1 (+local mobile client)',
          'accept': 'text/html,text/plain,application/json,application/xml',
        });
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 25));
      if (response.isRedirect) {
        final location = response.headers['location'];
        if (location == null) throw const HttpException('网页重定向缺少目标地址');
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw HttpException('网页请求失败 (${response.statusCode})');
      final type = response.headers['content-type']?.toLowerCase() ?? '';
      if (!(type.startsWith('text/') ||
          type.contains('json') ||
          type.contains('xml')))
        throw const FormatException('只允许抓取文本、HTML、JSON 或 XML');
      final declared = int.tryParse(response.headers['content-length'] ?? '');
      if (declared != null && declared > maxResponseBytes)
        throw const FormatException('网页响应超过 2 MB');
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        if (bytes.length > maxResponseBytes)
          throw const FormatException('网页响应超过 2 MB');
      }
      return utf8.decode(bytes, allowMalformed: true);
    }
    throw const HttpException('网页重定向次数过多');
  }

  Future<void> _assertPublic(Uri uri) async {
    if (uri.scheme != 'https' && uri.scheme != 'http')
      throw const FormatException('只允许 HTTP 或 HTTPS 地址');
    if (uri.userInfo.isNotEmpty) throw const FormatException('网页地址不能包含用户名或密码');
    if (uri.host.isEmpty) throw const FormatException('网页地址缺少主机名');
    final addresses = await InternetAddress.lookup(
      uri.host,
    ).timeout(const Duration(seconds: 10));
    if (addresses.isEmpty || addresses.any(_isPrivate))
      throw const FormatException('出于安全原因，不能访问本机、局域网、链路本地或云元数据地址');
  }

  bool _isPrivate(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast)
      return true;
    final raw = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = raw[0], b = raw[1];
      return a == 0 ||
          a == 10 ||
          a == 127 ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 100 && b >= 64 && b <= 127) ||
          a >= 224;
    }
    if (raw.every((value) => value == 0) ||
        (raw.take(15).every((value) => value == 0) && raw[15] == 1))
      return true;
    return (raw[0] & 0xfe) == 0xfc ||
        (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80);
  }

  String _stripHtml(String value) => _decodeHtml(
    value
        .replaceAll(
          RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\s*\n\s*'), '\n')
        .trim(),
  );

  String _decodeHtml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (match) => String.fromCharCode(int.tryParse(match.group(1) ?? '') ?? 0),
      );
}
