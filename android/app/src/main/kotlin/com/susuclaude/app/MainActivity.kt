package com.susuclaude.app

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.media.RingtoneManager
import android.media.MediaPlayer
import android.os.Bundle
import android.provider.CalendarContract
import android.speech.RecognizerIntent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

object PreviewChannelBridge {
    @Volatile
    var channel: MethodChannel? = null
}

class MainActivity : FlutterActivity() {
    private val channelName = "com.susuclaude.app/native"
    private var ringtoneResult: MethodChannel.Result? = null
    private var speechResult: MethodChannel.Result? = null
    private var mediaPlayer: MediaPlayer? = null
    private var nativeChannel: MethodChannel? = null
    private var backgroundPlaybackEnabled = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        PreviewChannelBridge.channel = nativeChannel
        VoicePlaybackService.onPlaybackComplete = {
            runOnUiThread { nativeChannel?.invokeMethod("audioPlaybackComplete", null) }
        }
        nativeChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getTimeZoneIdentifier" -> result.success(TimeZone.getDefault().id)
                "beginChatBackgroundTask" -> {
                    ChatForegroundService.start(
                        this,
                        call.argument<String>("title").orEmpty().ifBlank { "ClaudeChat" },
                        call.argument<String>("status").orEmpty().ifBlank { "小机子正在回复" }
                    )
                    result.success(true)
                }
                "updateChatActivity" -> {
                    ChatForegroundService.update(
                        this,
                        null,
                        call.argument<String>("status").orEmpty(),
                        call.argument<String>("preview").orEmpty()
                    )
                    result.success(null)
                }
                "endChatBackgroundTask" -> {
                    ChatForegroundService.stop(this)
                    result.success(null)
                }
                "addCalendarEvent" -> {
                    val intent = Intent(Intent.ACTION_INSERT).setData(CalendarContract.Events.CONTENT_URI)
                        .putExtra(CalendarContract.Events.TITLE, call.argument<String>("title"))
                        .putExtra(CalendarContract.Events.DESCRIPTION, call.argument<String>("notes"))
                        .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, call.argument<Long>("start"))
                        .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, call.argument<Long>("end"))
                    startActivity(intent)
                    result.success(null)
                }
                "addSystemReminder" -> {
                    val intent = Intent(Intent.ACTION_INSERT).setData(CalendarContract.Events.CONTENT_URI)
                        .putExtra(CalendarContract.Events.TITLE, call.argument<String>("title"))
                        .putExtra(CalendarContract.Events.DESCRIPTION, call.argument<String>("notes"))
                        .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, call.argument<Long>("due"))
                        .putExtra(CalendarContract.Events.HAS_ALARM, true)
                    startActivity(intent)
                    result.success(null)
                }
                "pickSystemRingtone" -> {
                    if (ringtoneResult != null) {
                        result.error("busy", "Ringtone picker is already open", null)
                    } else {
                        ringtoneResult = result
                        val intent = Intent(RingtoneManager.ACTION_RINGTONE_PICKER)
                            .putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, RingtoneManager.TYPE_NOTIFICATION)
                            .putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, true)
                        startActivityForResult(intent, 701)
                    }
                }
                "updateWidget" -> {
                    val preferences = getSharedPreferences("claudechat_widget", MODE_PRIVATE)
                    preferences.edit().putString("title", call.argument<String>("title"))
                        .putString("body", call.argument<String>("body")).apply()
                    val manager = AppWidgetManager.getInstance(this)
                    val component = ComponentName(this, ClaudeChatWidgetProvider::class.java)
                    val update = Intent(this, ClaudeChatWidgetProvider::class.java)
                        .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, manager.getAppWidgetIds(component))
                    sendBroadcast(update)
                    result.success(null)
                }
                "previewHtml" -> {
                    val html = call.argument<String>("html").orEmpty()
                    startActivity(
                        Intent(this, HtmlPreviewActivity::class.java)
                            .putExtra("html", html)
                            .putExtra("runtimeScope", call.argument<String>("runtimeScope").orEmpty())
                            .putExtra("title", call.argument<String>("title").orEmpty())
                    )
                    result.success(null)
                }
                "clearPreviewCache" -> {
                    HtmlPreviewActivity.clearRuntime(
                        call.argument<String>("runtimeScope").orEmpty()
                    )
                    result.success(null)
                }
                "recognizeSpeech" -> {
                    if (speechResult != null) {
                        result.error("busy", "Speech recognition is already active", null)
                    } else {
                        speechResult = result
                        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, call.argument<String>("locale") ?: "zh-CN")
                            .putExtra(RecognizerIntent.EXTRA_PROMPT, "请说话")
                        try {
                            startActivityForResult(intent, 702)
                        } catch (error: Exception) {
                            speechResult = null
                            result.error("unavailable", "No system speech recognizer is installed", null)
                        }
                    }
                }
                "playAudio" -> {
                    val path = call.argument<String>("path").orEmpty()
                    backgroundPlaybackEnabled = call.argument<Boolean>("backgroundPlayback") ?: false
                    try {
                        mediaPlayer?.release()
                        mediaPlayer = null
                        if (backgroundPlaybackEnabled) {
                            VoicePlaybackService.play(
                                this,
                                path,
                                call.argument<String>("title").orEmpty().ifBlank { "语音播放" },
                                call.argument<String>("subtitle").orEmpty(),
                                call.argument<String>("preview").orEmpty()
                            )
                        } else {
                            VoicePlaybackService.stop(this)
                            mediaPlayer = MediaPlayer().apply {
                                setDataSource(path)
                                setOnPreparedListener { it.start() }
                                setOnCompletionListener {
                                    it.release()
                                    mediaPlayer = null
                                    nativeChannel?.invokeMethod("audioPlaybackComplete", null)
                                }
                                setOnErrorListener { player, _, _ ->
                                    player.release()
                                    mediaPlayer = null
                                    nativeChannel?.invokeMethod("audioPlaybackComplete", null)
                                    true
                                }
                                prepareAsync()
                            }
                        }
                        result.success(null)
                    } catch (error: Exception) {
                        mediaPlayer?.release()
                        mediaPlayer = null
                        result.error("audio", error.localizedMessage, null)
                    }
                }
                "stopAudio" -> {
                    VoicePlaybackService.stop(this)
                    mediaPlayer?.stop()
                    mediaPlayer?.release()
                    mediaPlayer = null
                    nativeChannel?.invokeMethod("audioPlaybackComplete", null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 701) {
            val uri = if (resultCode == Activity.RESULT_OK) data?.getParcelableExtra<android.net.Uri>(RingtoneManager.EXTRA_RINGTONE_PICKED_URI) else null
            val title = uri?.let { RingtoneManager.getRingtone(this, it)?.getTitle(this) }
            ringtoneResult?.success(mapOf("title" to (title ?: "静音"), "uri" to uri?.toString()))
            ringtoneResult = null
        }
        if (requestCode == 702) {
            val text = if (resultCode == Activity.RESULT_OK) {
                data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
            } else null
            speechResult?.success(text)
            speechResult = null
        }
    }

    override fun onDestroy() {
        mediaPlayer?.release()
        mediaPlayer = null
        VoicePlaybackService.onPlaybackComplete = null
        nativeChannel = null
        super.onDestroy()
    }

    override fun onStop() {
        if (!backgroundPlaybackEnabled) {
            mediaPlayer?.stop()
            mediaPlayer?.release()
            mediaPlayer = null
            nativeChannel?.invokeMethod("audioPlaybackComplete", null)
        }
        super.onStop()
    }
}
