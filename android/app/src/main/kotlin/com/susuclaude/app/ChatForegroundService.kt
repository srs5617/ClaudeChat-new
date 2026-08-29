package com.susuclaude.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class ChatForegroundService : Service() {
    companion object {
        private const val channelId = "claudechat_generation"
        private const val notificationId = 24861
        private const val actionStart = "com.susuclaude.app.CHAT_START"
        private const val actionUpdate = "com.susuclaude.app.CHAT_UPDATE"
        private const val actionStop = "com.susuclaude.app.CHAT_STOP"

        fun start(context: Context, title: String, status: String) {
            val intent = Intent(context, ChatForegroundService::class.java)
                .setAction(actionStart)
                .putExtra("title", title)
                .putExtra("status", status)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun update(context: Context, title: String?, status: String, preview: String) {
            val intent = Intent(context, ChatForegroundService::class.java)
                .setAction(actionUpdate)
                .putExtra("title", title)
                .putExtra("status", status)
                .putExtra("preview", preview)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ChatForegroundService::class.java))
        }
    }

    private var currentTitle = "ClaudeChat"
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    "后台回复",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "模型或工作区任务在后台继续运行时显示"
                    setShowBadge(false)
                }
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            actionStop -> {
                releaseWakeLock()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
                return START_NOT_STICKY
            }
            actionStart -> {
                acquireWakeLock()
                currentTitle = intent.getStringExtra("title").orEmpty().ifBlank { "ClaudeChat" }
                val status = intent.getStringExtra("status").orEmpty().ifBlank { "小机子正在回复" }
                startForeground(notificationId, notification(currentTitle, status, ""))
            }
            actionUpdate -> {
                acquireWakeLock()
                currentTitle = intent.getStringExtra("title").orEmpty().ifBlank { currentTitle }
                val status = intent.getStringExtra("status").orEmpty().ifBlank { "任务正在运行" }
                val preview = intent.getStringExtra("preview").orEmpty()
                // `update` can revive a service that the OS reclaimed. Calling
                // startForeground here satisfies the foreground-service start
                // deadline in both the normal and revived paths.
                startForeground(notificationId, notification(currentTitle, status, preview))
            }
        }
        return START_NOT_STICKY
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(PowerManager::class.java)
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:ModelGeneration"
        ).apply {
            setReferenceCounted(false)
            // Matches Android 15's maximum dataSync foreground-service window.
            acquire(6L * 60L * 60L * 1000L)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    private fun notification(title: String, status: String, preview: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launch.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val body = preview.trim().ifEmpty { status }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setSubText(status)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(pending)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
