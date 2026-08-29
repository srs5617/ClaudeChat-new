import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class PickedRingtone {
  const PickedRingtone({required this.title, required this.uri});

  final String title;
  final String? uri;
}

class PlatformService {
  PlatformService();

  static const _channel = MethodChannel('com.susuclaude.app/native');
  final FlutterLocalNotificationsPlugin notifications =
      FlutterLocalNotificationsPlugin();
  void Function(String payload)? onNotificationPayload;
  VoidCallback? onAudioPlaybackComplete;
  String? initialNotificationPayload;
  Timer? _generationActivityTimer;
  Map<String, Object?>? _pendingGenerationActivity;
  final Map<String, Future<Map<String, String>?> Function()>
  _previewRefreshProviders =
      <String, Future<Map<String, String>?> Function()>{};

  Future<void> initialize() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'audioPlaybackComplete') {
        onAudioPlaybackComplete?.call();
        return null;
      }
      if (call.method == 'requestPreviewHtml') {
        final arguments = Map<String, Object?>.from(
          call.arguments as Map? ?? const <String, Object?>{},
        );
        final runtimeScope = _previewScope(
          '${arguments['runtimeScope'] ?? 'shared'}',
        );
        return _previewRefreshProviders[runtimeScope]?.call();
      }
      return null;
    });
    tz.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings();
    await notifications.initialize(
      settings: const InitializationSettings(android: android, iOS: darwin),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload?.trim();
        if (payload != null && payload.isNotEmpty) {
          onNotificationPayload?.call(payload);
        }
      },
    );
    final launch = await notifications.getNotificationAppLaunchDetails();
    initialNotificationPayload = launch?.notificationResponse?.payload;
  }

  Future<bool> requestNotificationPermission() async {
    if (Platform.isAndroid) {
      return await notifications
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    }
    return await notifications
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true) ??
        false;
  }

  Future<String> timeZoneIdentifier() async {
    try {
      final value = await _channel.invokeMethod<String>(
        'getTimeZoneIdentifier',
      );
      if (value != null && value.trim().isNotEmpty) return value.trim();
    } on PlatformException {
      // Older native shells fall back to Dart's local timezone abbreviation.
    } on MissingPluginException {
      // Unit tests and older installations do not expose this method yet.
    }
    return DateTime.now().timeZoneName;
  }

  Future<void> scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime at,
    String? soundUri,
  }) async {
    await requestNotificationPermission();
    var mode = AndroidScheduleMode.inexactAllowWhileIdle;
    if (Platform.isAndroid) {
      final android = notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      var exact = await android?.canScheduleExactNotifications() ?? false;
      if (!exact) {
        exact = await android?.requestExactAlarmsPermission() ?? false;
      }
      if (exact) mode = AndroidScheduleMode.exactAllowWhileIdle;
    }

    final isSilent = soundUri != null && soundUri.isEmpty;
    final channelSuffix = soundUri == null
        ? 'default'
        : (soundUri.hashCode & 0x7fffffff).toString();
    await notifications.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'claudechat_reminders_$channelSuffix',
          'Claude Chat 提醒',
          channelDescription: '用户在 Claude Chat 中创建的提醒',
          importance: Importance.high,
          priority: Priority.high,
          playSound: !isSilent,
          sound: soundUri == null || soundUri.isEmpty
              ? null
              : UriAndroidNotificationSound(soundUri),
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: !isSilent,
        ),
      ),
      androidScheduleMode: mode,
    );
  }

  Future<bool> showChatReplyNotification({
    required int id,
    required String title,
    required String body,
    required String conversationId,
  }) async {
    if (!await requestNotificationPermission()) return false;
    await notifications.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'claudechat_chat_replies',
          '聊天回复',
          channelDescription: 'ClaudeChat 在后台完成回复时显示的通知',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'conversation:$conversationId',
    );
    return true;
  }

  Future<void> addCalendarEvent({
    required String title,
    String? notes,
    required DateTime start,
    required DateTime end,
  }) => _channel.invokeMethod<void>('addCalendarEvent', <String, Object?>{
    'title': title,
    'notes': notes ?? '',
    'start': start.millisecondsSinceEpoch,
    'end': end.millisecondsSinceEpoch,
  });

  Future<void> addSystemReminder({
    required String title,
    String? notes,
    required DateTime due,
  }) => _channel.invokeMethod<void>('addSystemReminder', <String, Object?>{
    'title': title,
    'notes': notes ?? '',
    'due': due.millisecondsSinceEpoch,
  });

  Future<PickedRingtone?> pickSystemRingtone() async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'pickSystemRingtone',
    );
    if (result == null) return null;
    return PickedRingtone(
      title: '${result['title'] ?? '系统默认提示音'}',
      uri: result['uri'] as String?,
    );
  }

  Future<void> updateWidget({required String title, required String body}) =>
      _channel.invokeMethod<void>('updateWidget', <String, Object?>{
        'title': title,
        'body': body,
      });

  Future<void> previewHtml(
    String source, {
    String runtimeScope = 'shared',
    String fallbackTitle = 'HTML 预览',
    Future<Map<String, String>?> Function()? refreshProvider,
  }) {
    final scope = _previewScope(runtimeScope);
    if (refreshProvider != null) {
      _previewRefreshProviders[scope] = refreshProvider;
    }
    return _channel.invokeMethod<void>('previewHtml', <String, Object?>{
      'html': source,
      'runtimeScope': scope,
      'title': fallbackTitle,
    });
  }

  Future<void> clearPreviewCache({String runtimeScope = 'shared'}) =>
      _channel.invokeMethod<void>('clearPreviewCache', <String, Object?>{
        'runtimeScope': _previewScope(runtimeScope),
      });

  String _previewScope(String value) {
    final safe = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (safe.isEmpty) return 'shared';
    return safe.length <= 48 ? safe : safe.substring(0, 48);
  }

  Future<String?> recognizeSpeech({String locale = 'zh-CN'}) async {
    final value = await _channel.invokeMethod<String>(
      'recognizeSpeech',
      <String, Object?>{'locale': locale},
    );
    final clean = value?.trim();
    return clean == null || clean.isEmpty ? null : clean;
  }

  Future<void> playAudio(
    String path, {
    required bool backgroundPlayback,
    String title = '语音播放',
    String subtitle = '',
    String preview = '',
  }) => _channel.invokeMethod<void>('playAudio', <String, Object?>{
    'path': path,
    'backgroundPlayback': backgroundPlayback,
    'title': title,
    'subtitle': subtitle,
    'preview': preview.length <= 96 ? preview : preview.substring(0, 96),
  });

  Future<void> stopAudio() => _channel.invokeMethod<void>('stopAudio');

  /// Keeps an in-flight model request alive for as long as the host OS allows.
  /// Android uses a foreground service. iOS uses a finite UIKit background task
  /// and, when available, starts a Live Activity for the Lock Screen and Dynamic
  /// Island. The Live Activity is presentation only; it is not used as a network
  /// transport.
  Future<void> beginGenerationActivity({
    required String title,
    required String scopeId,
    bool workspace = false,
  }) async {
    _generationActivityTimer?.cancel();
    _pendingGenerationActivity = null;
    // Android 13+ separates foreground-service execution from notification
    // visibility. Ask once through the system permission sheet so users can
    // actually see and return to a reply that is continuing in the background.
    // A denial does not cancel the request: Android still exposes the running
    // foreground service in its active-apps surface.
    if (Platform.isAndroid) {
      try {
        await requestNotificationPermission();
      } on PlatformException {
        // Notification presentation is optional; generation remains usable.
      } on MissingPluginException {
        // Browser/tests and older native shells do not expose the permission.
      }
    }
    await _invokeOptional('beginChatBackgroundTask', <String, Object?>{
      'title': title.trim().isEmpty ? 'ClaudeChat' : title.trim(),
      'scopeId': scopeId,
      'status': workspace ? '工作区任务正在运行' : '小机子正在回复',
      'preview': '',
      'workspace': workspace,
    });
  }

  /// Coalesces frequent stream chunks so native Live Activity updates do not
  /// become a source of UI jank or hit ActivityKit's update budget.
  void updateGenerationActivity({
    required String status,
    String preview = '',
    bool working = true,
  }) {
    _pendingGenerationActivity = <String, Object?>{
      'status': status,
      'preview': preview.length <= 96
          ? preview
          : preview.substring(preview.length - 96),
      'working': working,
    };
    if (_generationActivityTimer?.isActive == true) return;
    _generationActivityTimer = Timer(const Duration(milliseconds: 650), () {
      final payload = _pendingGenerationActivity;
      _pendingGenerationActivity = null;
      if (payload != null) {
        unawaited(_invokeOptional('updateChatActivity', payload));
      }
    });
  }

  Future<void> endGenerationActivity({
    required String status,
    String preview = '',
    bool success = false,
  }) async {
    _generationActivityTimer?.cancel();
    _generationActivityTimer = null;
    _pendingGenerationActivity = null;
    await _invokeOptional('endChatBackgroundTask', <String, Object?>{
      'status': status,
      'preview': preview.length <= 96
          ? preview
          : preview.substring(preview.length - 96),
      'success': success,
    });
  }

  Future<void> _invokeOptional(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Web tests and older native shells do not expose lifecycle integration.
    } on PlatformException {
      // Background presentation must never make a chat request itself fail.
    }
  }
}
