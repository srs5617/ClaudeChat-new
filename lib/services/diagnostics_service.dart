import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A local-only, redacted diagnostic event log.
///
/// The log intentionally stores event metadata rather than request/response
/// bodies. A final sanitizing pass protects against a future caller
/// accidentally including credentials or full conversation content.
class DiagnosticsService {
  DiagnosticsService(this.directory, {this.maxBytes = 5 * 1024 * 1024});

  final Directory directory;
  final int maxBytes;
  Future<void> _tail = Future<void>.value();

  File get _logFile =>
      File('${directory.path}${Platform.pathSeparator}model-events.ndjson');

  Future<void> record(Map<String, Object?> event) {
    final safe = _sanitize(<String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      ...event,
    });
    final next = _tail.then((_) async {
      await directory.create(recursive: true);
      await _rotateIfNeeded();
      await _logFile.writeAsString(
        '${jsonEncode(safe)}\n',
        mode: FileMode.append,
        flush: true,
      );
    });
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<List<Map<String, Object?>>> entries({int limit = 300}) async {
    await _tail;
    if (!await _logFile.exists()) return const <Map<String, Object?>>[];
    final lines = await _logFile.readAsLines();
    final result = <Map<String, Object?>>[];
    for (final line in lines.reversed) {
      if (result.length >= limit) break;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) result.add(decoded.cast<String, Object?>());
      } on FormatException {
        // A partially written final line is ignored; older events stay usable.
      }
    }
    return result;
  }

  Future<String> export({required Directory destination}) async {
    final values = await entries(limit: 2000);
    await destination.create(recursive: true);
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    final output = File(
      '${destination.path}${Platform.pathSeparator}ClaudeChat_diagnostics_$stamp.json',
    );
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'format': 'claudechat-redacted-diagnostics',
        'version': 1,
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'redaction': <String, Object?>{
          'apiKeys': 'removed',
          'authorization': 'removed',
          'messageContent': 'length-only',
          'toolArguments': 'keys-and-length-only',
        },
        'events': values.reversed.toList(growable: false),
      }),
      flush: true,
    );
    return output.path;
  }

  Future<void> clear() async {
    await _tail;
    if (await _logFile.exists()) await _logFile.delete();
  }

  Future<void> _rotateIfNeeded() async {
    if (!await _logFile.exists()) return;
    if (await _logFile.length() < maxBytes) return;
    final lines = await _logFile.readAsLines();
    final keepFrom = (lines.length * .55).floor();
    final kept = lines.skip(keepFrom).where((line) => line.trim().isNotEmpty);
    await _logFile.writeAsString(
      kept.isEmpty ? '' : '${kept.join('\n')}\n',
      flush: true,
    );
  }

  Object? _sanitize(Object? value, {String key = ''}) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    const secrets = <String>{
      'authorization',
      'apikey',
      'password',
      'secret',
      'headers',
      'requestbody',
      'responsebody',
      'content',
      'arguments',
    };
    if (secrets.contains(normalized)) return '[REDACTED]';
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          '${entry.key}': _sanitize(entry.value, key: '${entry.key}'),
      };
    }
    if (value is List) {
      return value.map((item) => _sanitize(item, key: key)).toList();
    }
    if (value is String && value.length > 800) {
      return '${value.substring(0, 800)}…';
    }
    return value;
  }
}
