package com.susuclaude.app

import android.annotation.SuppressLint
import android.app.Activity
import android.content.res.Configuration
import android.graphics.Color
import android.os.Bundle
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.Window
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

class HtmlPreviewActivity : Activity() {
    private var preview: WebView? = null
    private var titleView: TextView? = null
    private var fallbackTitle = "HTML 预览"
    private var source = ""
    private var runtimeScope = "shared"

    companion object {
        private val activePreviews = mutableMapOf<String, WeakReference<HtmlPreviewActivity>>()
        private val invalidatedScopes = mutableSetOf<String>()

        fun clearRuntime(value: String) {
            val scope = safeRuntimeScope(value)
            synchronized(invalidatedScopes) { invalidatedScopes.add(scope) }
            WebStorage.getInstance().deleteOrigin("https://$scope.runtime.claudechat.local")
            val activity = synchronized(activePreviews) { activePreviews[scope]?.get() }
            activity?.runOnUiThread {
                activity.preview?.evaluateJavascript(
                    "try{localStorage.clear();sessionStorage.clear();}catch(e){};" +
                        "if(window.caches){caches.keys().then(function(keys){return Promise.all(keys.map(function(key){return caches.delete(key);}));});}" +
                        "if(navigator.serviceWorker){navigator.serviceWorker.getRegistrations().then(function(items){items.forEach(function(item){item.unregister();});});}",
                    null
                )
                activity.preview?.clearCache(true)
                synchronized(invalidatedScopes) { invalidatedScopes.remove(scope) }
                activity.requestLatestDocument()
            }
        }

        private fun safeRuntimeScope(value: String): String {
            val safe = value.lowercase().map { character ->
                if (character.isLetterOrDigit() || character == '-') character else '-'
            }.joinToString("").trim('-').take(48)
            return safe.ifEmpty { "shared" }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        super.onCreate(savedInstanceState)
        val dark = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        val background = Color.parseColor(if (dark) "#1C1B1F" else "#F9F9F7")
        val foreground = Color.parseColor(if (dark) "#F5F2EF" else "#101010")
        val divider = Color.parseColor(if (dark) "#3A383A" else "#E4DFDA")
        fallbackTitle = intent.getStringExtra("title").orEmpty().trim().ifEmpty { "HTML 预览" }
        source = intent.getStringExtra("html").orEmpty()
        runtimeScope = safeRuntimeScope(intent.getStringExtra("runtimeScope").orEmpty())
        synchronized(activePreviews) {
            activePreviews[runtimeScope] = WeakReference(this)
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(background)
        }
        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(background)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(52)
            )
        }
        val back = ImageButton(this).apply {
            setImageResource(R.drawable.ic_preview_back)
            setColorFilter(foreground)
            setBackgroundColor(Color.TRANSPARENT)
            contentDescription = "返回"
            setPadding(dp(16), dp(14), dp(16), dp(14))
            setOnClickListener { finish() }
        }
        toolbar.addView(back, LinearLayout.LayoutParams(dp(56), dp(52)))
        titleView = TextView(this).apply {
            text = fallbackTitle
            setTextColor(foreground)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            typeface = android.graphics.Typeface.DEFAULT_BOLD
        }
        toolbar.addView(titleView, LinearLayout.LayoutParams(0, dp(52), 1f))
        val refresh = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_popup_sync)
            setColorFilter(foreground)
            setBackgroundColor(Color.TRANSPARENT)
            contentDescription = "刷新页面"
            setPadding(dp(16), dp(14), dp(16), dp(14))
            setOnClickListener { requestLatestDocument() }
        }
        toolbar.addView(refresh, LinearLayout.LayoutParams(dp(56), dp(52)))
        root.addView(toolbar)
        root.addView(
            View(this).apply { setBackgroundColor(divider) },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(1))
        )
        preview = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.databaseEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.blockNetworkLoads = false
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            settings.setSupportZoom(false)
            settings.builtInZoomControls = false
            settings.displayZoomControls = false
            overScrollMode = View.OVER_SCROLL_NEVER
            isHorizontalScrollBarEnabled = false
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String) {
                    super.onPageFinished(view, url)
                    val htmlTitle = view.title.orEmpty().trim()
                    titleView?.text = htmlTitle.ifEmpty { fallbackTitle }
                }
            }
            if (synchronized(invalidatedScopes) { invalidatedScopes.remove(runtimeScope) }) {
                clearCache(true)
            }
        }
        root.addView(
            preview,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
        )
        setContentView(root)
        loadDocument()
    }

    override fun onDestroy() {
        preview?.apply {
            stopLoading()
            loadUrl("about:blank")
            clearHistory()
            removeAllViews()
            destroy()
        }
        preview = null
        titleView = null
        synchronized(activePreviews) {
            if (activePreviews[runtimeScope]?.get() === this) {
                activePreviews.remove(runtimeScope)
            }
        }
        super.onDestroy()
    }

    private fun requestLatestDocument() {
        val channel = PreviewChannelBridge.channel
        if (channel == null) {
            loadDocument()
            return
        }
        channel.invokeMethod(
            "requestPreviewHtml",
            mapOf("runtimeScope" to runtimeScope),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    val payload = result as? Map<*, *>
                    source = payload?.get("html") as? String ?: source
                    fallbackTitle = (payload?.get("title") as? String)
                        ?.trim()?.ifEmpty { fallbackTitle } ?: fallbackTitle
                    loadDocument()
                }

                override fun error(code: String, message: String?, details: Any?) {
                    loadDocument()
                }

                override fun notImplemented() {
                    loadDocument()
                }
            }
        )
    }

    private fun loadDocument() {
        titleView?.text = fallbackTitle
        preview?.loadDataWithBaseURL(
            "https://$runtimeScope.runtime.claudechat.local/?previewRevision=${System.nanoTime()}",
            securedDocument(source),
            "text/html",
            "UTF-8",
            null
        )
    }

    private fun securedDocument(source: String): String {
        val policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src http: https: data: blob: 'unsafe-inline' 'unsafe-eval'; script-src http: https: data: blob: 'unsafe-inline' 'unsafe-eval'; worker-src blob: data:; connect-src http: https: data: blob:; img-src http: https: data: blob:; media-src http: https: data: blob:\">"
        val viewport = "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover\">"
        val interaction = "<style>html,body{overscroll-behavior:none;-webkit-text-size-adjust:100%;}</style>"
        val viewportPattern = Regex(
            """<meta\s+[^>]*name\s*=\s*[\"']?viewport[\"']?[^>]*>""",
            RegexOption.IGNORE_CASE
        )
        val withoutViewport = source.replace(viewportPattern, "")
        val metadata = "$policy$viewport$interaction"
        return if (withoutViewport.contains("<head", ignoreCase = true)) {
            val head = Regex("<head[^>]*>", RegexOption.IGNORE_CASE)
            withoutViewport.replaceFirst(
                head,
                "${head.find(withoutViewport)?.value.orEmpty()}$metadata"
            )
        } else {
            "<!doctype html><html><head>$metadata</head><body>$withoutViewport</body></html>"
        }
    }

    private fun dp(value: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP,
        value.toFloat(),
        resources.displayMetrics
    ).toInt()
}
