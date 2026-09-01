package com.susuclaude.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.IBinder

class VoicePlaybackService : Service() {
    companion object {
        private const val channelId = "claudechat_voice"
        private const val notificationId = 24862
        private const val actionPlay = "com.susuclaude.app.VOICE_PLAY"
        private const val actionStop = "com.susuclaude.app.VOICE_STOP"

        var onPlaybackComplete: (() -> Unit)? = null
        @Volatile
        private var activeInstance: VoicePlaybackService? = null

        fun playbackState(): Map<String, Any> {
            val current = activeInstance?.player
            return mapOf(
                "positionMs" to runCatching { current?.currentPosition ?: 0 }.getOrDefault(0),
                "durationMs" to runCatching { current?.duration ?: 0 }.getOrDefault(0),
                "playing" to runCatching { current?.isPlaying == true }.getOrDefault(false)
            )
        }

        fun seekTo(positionMs: Int) {
            runCatching { activeInstance?.player?.seekTo(positionMs.coerceAtLeast(0)) }
        }

        fun play(
            context: Context,
            path: String,
            title: String,
            subtitle: String,
            preview: String
        ) {
            val intent = Intent(context, VoicePlaybackService::class.java)
                .setAction(actionPlay)
                .putExtra("path", path)
                .putExtra("title", title)
                .putExtra("subtitle", subtitle)
                .putExtra("preview", preview)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, VoicePlaybackService::class.java))
        }
    }

    private var player: MediaPlayer? = null
    private var completionSent = false
    private var currentTitle = "语音播放"
    private var currentSubtitle = "ClaudeChat"
    private var currentPreview = ""

    override fun onCreate() {
        super.onCreate()
        activeInstance = this
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(
                    channelId,
                    "语音播放",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "在后台播放 Ta 的声音时显示"
                    setShowBadge(false)
                }
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            actionStop -> finishPlayback(notifyFlutter = true)
            actionPlay -> {
                currentTitle = intent.getStringExtra("title").orEmpty().ifBlank { "语音播放" }
                currentSubtitle = intent.getStringExtra("subtitle").orEmpty().ifBlank { "ClaudeChat" }
                currentPreview = intent.getStringExtra("preview").orEmpty()
                startForeground(notificationId, notification("正在准备播放…"))
                startPlayer(intent.getStringExtra("path").orEmpty())
            }
        }
        return START_NOT_STICKY
    }

    private fun startPlayer(path: String) {
        if (path.isBlank()) {
            finishPlayback(notifyFlutter = true)
            return
        }
        completionSent = false
        player?.release()
        player = null
        try {
            player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                setDataSource(path)
                setOnPreparedListener {
                    it.start()
                    getSystemService(NotificationManager::class.java)
                        .notify(notificationId, notification(currentPreview))
                }
                setOnCompletionListener { finishPlayback(notifyFlutter = true) }
                setOnErrorListener { _, _, _ ->
                    finishPlayback(notifyFlutter = true)
                    true
                }
                prepareAsync()
            }
        } catch (_: Exception) {
            finishPlayback(notifyFlutter = true)
        }
    }

    private fun finishPlayback(notifyFlutter: Boolean) {
        player?.setOnCompletionListener(null)
        player?.setOnErrorListener(null)
        player?.release()
        player = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
        if (notifyFlutter && !completionSent) {
            completionSent = true
            onPlaybackComplete?.invoke()
        }
    }

    private fun notification(body: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launch.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        val openApp = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, VoicePlaybackService::class.java).setAction(actionStop),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(currentTitle)
            .setContentText(body.ifBlank { currentSubtitle })
            .setSubText(currentSubtitle)
            .setContentIntent(openApp)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .addAction(android.R.drawable.ic_media_pause, "停止", stop)
            .build()
    }

    override fun onDestroy() {
        player?.release()
        player = null
        if (activeInstance === this) activeInstance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
