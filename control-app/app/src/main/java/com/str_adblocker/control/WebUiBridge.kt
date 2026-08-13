package com.str_adblocker.control

import android.webkit.JavascriptInterface

/**
 * 注入到 WebUI 页面的原生桥（window.__strNativeBridge），由 webroot/app-bridge.js
 * 包装成 window.ksu.exec。命令经 ExecChannel 交模块侧 root 执行。
 */
class WebUiBridge {

    @JavascriptInterface
    fun exec(cmd: String?, cbId: String?) {
        ExecChannel.submit(cmd ?: "", cbId ?: "")
    }
}
