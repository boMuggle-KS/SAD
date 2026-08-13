package com.str_adblocker.control

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.webkit.WebView
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference
import java.util.ArrayDeque

/**
 * WebUI 桥接的命令通道：应用不申请 root，把命令写进自己的外部目录
 * （sad.exec.request，base64 编码），由模块侧 control-watch.sh 以 root
 * 执行，结果写回 sad.exec.<id>.result 并通过 EXEC_RESULT 广播推送
 * （应用侧无轮询）。同一时刻只有一个在途命令，其余排队，模块 45s
 * timeout 保证先于本侧 60s 超时返回。
 */
object ExecChannel {

    private const val REQUEST_NAME = "sad.exec.request"
    private const val RESULT_PREFIX = "sad.exec."
    private const val RESULT_SUFFIX = ".result"
    private const val TIMEOUT_MS = 60_000L
    private const val BUSY_RETRY_MS = 1_000L
    private const val READ_RETRY_MS = 300L
    private const val READ_RETRY_MAX = 10

    private val queue = ArrayDeque<Pair<String, String>>()
    private var currentId: String? = null
    private var webViewRef = WeakReference<WebView>(null)
    private var contextRef = WeakReference<Context>(null)
    private val handler = Handler(Looper.getMainLooper())
    // 初始化 lambda 不能自引用 timeoutRunnable，拆到独立方法
    private val timeoutRunnable = Runnable { runTimeout() }

    private fun runTimeout() {
        val id: String? = synchronized(this) {
            val current = currentId
            if (current == null) null
            else {
                handler.removeCallbacks(timeoutRunnable)
                currentId = null
                current
            }
        }
        if (id == null) return
        deliver(id, 124, "", "timeout")
        synchronized(this) { maybeSendNext() }
    }

    @Synchronized
    fun attach(context: Context, webView: WebView) {
        contextRef = WeakReference(context.applicationContext)
        webViewRef = WeakReference(webView)
        context.getExternalFilesDir(null)?.listFiles()
            ?.filter { it.name.startsWith(RESULT_PREFIX) && it.name.endsWith(RESULT_SUFFIX) }
            ?.forEach { it.delete() }
        maybeSendNext()
    }

    @Synchronized
    fun detach() {
        webViewRef = WeakReference(null)
        handler.removeCallbacks(timeoutRunnable)
        currentId = null
        queue.clear()
    }

    @Synchronized
    fun submit(command: String, cbId: String) {
        if (cbId.isEmpty()) return
        queue.add(command to cbId)
        maybeSendNext()
    }

    @Synchronized
    fun onResult(context: Context, cbId: String) {
        if (cbId != currentId) return
        handler.removeCallbacks(timeoutRunnable)
        currentId = null
        readResult(context.applicationContext, cbId, 0)
    }

    /**
     * 模块侧 root 经 /data/media/0 直写的结果文件，应用经 FUSE 视图读取时
     * 目录缓存可能尚未失效（广播已到达但文件不可见）。短暂重试等待文件
     * 出现，最多约 3 秒，之后按缺失处理。
     */
    private fun readResult(context: Context, cbId: String, attempt: Int) {
        var errno = 1
        var stdout = ""
        var stderr = "result missing"
        var done = false
        val result = context.getExternalFilesDir(null)
            ?.let { File(it, "$RESULT_PREFIX$cbId$RESULT_SUFFIX") }
        if (result != null && result.exists()) {
            try {
                val lines = result.readLines().associate { line ->
                    val at = line.indexOf('=')
                    if (at > 0) line.substring(0, at) to line.substring(at + 1) else line to ""
                }
                errno = lines["errno"]?.toIntOrNull() ?: 1
                stdout = decodeB64(lines["stdout"])
                stderr = decodeB64(lines["stderr"])
            } catch (e: Exception) {
                stderr = "result parse failed"
            }
            result.delete()
            done = true
        }
        if (!done && attempt < READ_RETRY_MAX) {
            handler.postDelayed({ readResult(context, cbId, attempt + 1) }, READ_RETRY_MS)
            return
        }
        deliver(cbId, errno, stdout, stderr)
        synchronized(this) { maybeSendNext() }
    }

    private fun maybeSendNext() {
        if (currentId != null) return
        if (queue.isEmpty()) return
        val (command, cbId) = queue.removeFirst()
        val context = contextRef.get()
        val dir = context?.getExternalFilesDir(null)
        if (dir == null) {
            deliver(cbId, 1, "", "external storage unavailable")
            return
        }
        val target = File(dir, REQUEST_NAME)
        if (target.exists()) {
            // 上一请求尚未被模块消费（BUSY）：放回队首稍后重试
            queue.addFirst(command to cbId)
            handler.postDelayed({ synchronized(this) { maybeSendNext() } }, BUSY_RETRY_MS)
            return
        }
        val tmp = File(dir, "$REQUEST_NAME.tmp")
        val encoded = Base64.encodeToString(command.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        try {
            tmp.writeText("id=$cbId\ncmd=$encoded\n")
            if (!tmp.renameTo(target)) {
                tmp.delete()
                queue.addFirst(command to cbId)
                handler.postDelayed({ synchronized(this) { maybeSendNext() } }, BUSY_RETRY_MS)
                return
            }
        } catch (e: Exception) {
            tmp.delete()
            deliver(cbId, 1, "", "request write failed")
            return
        }
        currentId = cbId
        handler.postDelayed(timeoutRunnable, TIMEOUT_MS)
    }

    private fun deliver(cbId: String, errno: Int, stdout: String, stderr: String) {
        val webView = webViewRef.get() ?: return
        val js = "window.__strCb_$cbId && window.__strCb_$cbId(" +
            "$errno, ${JSONObject.quote(stdout)}, ${JSONObject.quote(stderr)});"
        handler.post { webView.evaluateJavascript(js, null) }
    }

    private fun decodeB64(value: String?): String =
        if (value.isNullOrEmpty()) "" else try {
            String(Base64.decode(value, Base64.DEFAULT), Charsets.UTF_8)
        } catch (e: Exception) {
            value
        }
}
