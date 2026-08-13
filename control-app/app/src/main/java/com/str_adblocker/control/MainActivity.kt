package com.str_adblocker.control

import android.annotation.SuppressLint
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import java.io.ByteArrayInputStream

/**
 * 桌面图标 = WebUI 入口：内嵌 WebView 自托管模块 webroot（assets），
 * window.ksu.exec 经 __strNativeBridge → 请求文件通道 → 模块侧 root 执行，
 * 结果由 EXEC_RESULT 广播推送。每次打开都会写 sync 请求，让模块回推
 * 当前状态以刷新常驻通知。
 */
class MainActivity : Activity() {

    companion object {
        private const val HOST = "sad-webui.local"
        private const val BASE_URL = "https://$HOST/index.html"
    }

    private lateinit var webView: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        ControlRequest.submit(this, "sync")

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 100)
            Toast.makeText(this, "未授予通知权限：模块状态通知将无法显示", Toast.LENGTH_LONG).show()
        }

        webView = findViewById(R.id.webView)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            cacheMode = WebSettings.LOAD_DEFAULT
        }
        webView.addJavascriptInterface(WebUiBridge(), "__strNativeBridge")
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                val uri = request?.url ?: return null
                if (uri.scheme != "https" || uri.host != HOST) return null
                val path = uri.path ?: "/"
                val asset = "webroot" + if (path == "/" || path.endsWith("/")) "${path}index.html" else path
                return try {
                    WebResourceResponse(mimeType(path), "utf-8", assets.open(asset))
                } catch (e: Exception) {
                    WebResourceResponse("text/plain", "utf-8", 404, "Not Found",
                        emptyMap(), ByteArrayInputStream(ByteArray(0)))
                }
            }
        }
        ExecChannel.attach(this, webView)
        webView.loadUrl(BASE_URL)
    }

    override fun onDestroy() {
        super.onDestroy()
        ExecChannel.detach()
        if (::webView.isInitialized) webView.destroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 100) {
            val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            Log.d("SAD", "POST_NOTIFICATIONS granted=$granted")
        }
    }

    private fun mimeType(path: String): String = when (path.substringAfterLast('.', "").lowercase()) {
        "html" -> "text/html"
        "js" -> "text/javascript"
        "css" -> "text/css"
        "svg" -> "image/svg+xml"
        "png" -> "image/png"
        "json" -> "application/json"
        else -> "application/octet-stream"
    }
}
