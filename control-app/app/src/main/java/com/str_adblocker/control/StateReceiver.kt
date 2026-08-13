package com.str_adblocker.control

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * 唯一的广播入口（manifest 导出 + signature 权限，root 广播直接放行）：
 * - STATE：模块推送的权威状态，直接覆盖一切展示
 * - PAUSE/RESUME：通知按钮动作，写请求文件交模块侧执行
 * - EXEC_RESULT：WebUI 桥接命令的结果到达，转交 ExecChannel
 */
class StateReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "SAD"
        const val ACTION_STATE = "com.str_adblocker.control.STATE"
        const val ACTION_PAUSE = "com.str_adblocker.control.PAUSE"
        const val ACTION_RESUME = "com.str_adblocker.control.RESUME"
        const val ACTION_EXEC_RESULT = "com.str_adblocker.control.EXEC_RESULT"
        const val EXTRA_STATE = "state"
        const val EXTRA_REASON = "reason"
        const val EXTRA_ID = "id"

        private const val REVERT_DELAY_MS = 10_000L
        private const val RETRY_DELAY_MS = 2_500L
        private const val MAX_RETRIES = 2

        private val handler = Handler(Looper.getMainLooper())
        private val retryHandler = Handler(Looper.getMainLooper())
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_STATE -> {
                val state = intent.getStringExtra(EXTRA_STATE) ?: "UNKNOWN"
                val reason = intent.getStringExtra(EXTRA_REASON) ?: "unknown"
                Log.d(TAG, "STATE broadcast received: state=$state reason=$reason")
                handler.removeCallbacksAndMessages(null)
                NotificationHelper.update(context, state, reason)
            }

            ACTION_PAUSE, ACTION_RESUME -> {
                val command = if (intent.action == ACTION_PAUSE) "pause" else "resume"
                val app = context.applicationContext
                Log.d(TAG, "notification action: $command")
                submitWithRetry(app, command, 0)
                NotificationHelper.showPending(app)
                scheduleRevert(app)
            }

            ACTION_EXEC_RESULT -> {
                val id = intent.getStringExtra(EXTRA_ID) ?: return
                if (!id.matches(Regex("[A-Za-z0-9_-]+"))) return
                Log.d(TAG, "EXEC_RESULT broadcast received: id=$id")
                ExecChannel.onResult(context, id)
            }
        }
    }

    private fun submitWithRetry(context: Context, command: String, attempt: Int) {
        when (ControlRequest.submit(context, command)) {
            ControlRequest.Result.BUSY ->
                if (attempt < MAX_RETRIES) {
                    retryHandler.postDelayed({ submitWithRetry(context, command, attempt + 1) }, RETRY_DELAY_MS)
                }
            else -> Unit
        }
    }

    /**
     * 兜底：点击后 10 秒仍未收到任何权威 STATE（如模块被禁用）时，
     * 把按钮恢复为点击前的状态。时间戳守卫保证不会覆盖已到达的 STATE。
     */
    private fun scheduleRevert(context: Context) {
        val since = SystemClock.elapsedRealtime()
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({
            if (NotificationHelper.lastUpdateElapsed < since) {
                NotificationHelper.update(context, NotificationHelper.lastState(context), NotificationHelper.lastReason(context))
            }
        }, REVERT_DELAY_MS)
    }
}
