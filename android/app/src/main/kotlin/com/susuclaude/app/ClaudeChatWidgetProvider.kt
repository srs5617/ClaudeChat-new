package com.susuclaude.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

class ClaudeChatWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val preferences = context.getSharedPreferences("claudechat_widget", Context.MODE_PRIVATE)
        ids.forEach { id ->
            val views = RemoteViews(context.packageName, R.layout.claudechat_widget)
            views.setTextViewText(R.id.widget_title, preferences.getString("title", "ClaudeChat"))
            views.setTextViewText(R.id.widget_body, preferences.getString("body", "今天想聊些什么？"))
            val intent = Intent(context, MainActivity::class.java)
            views.setOnClickPendingIntent(R.id.widget_root, PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            manager.updateAppWidget(id, views)
        }
    }
}
