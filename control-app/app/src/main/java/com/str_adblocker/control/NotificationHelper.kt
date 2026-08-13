package com.str_adblocker.control

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 常驻状态通知。模块状态只有三种：运行中 / 已暂停 / 故障，
 * 状态由模块侧 STATE 广播推送（唯一权威状态源），本类只负责渲染。
 * 锁屏可见性 SECRET：锁屏不显示，因此请求文件在解锁前不可消费的场景不可达。
 */
object NotificationHelper {

    const val CHANNEL_ID = "sad-control"
    const val NOTIFICATION_ID = 1

    private const val PREFS = "sad_control"
    private const val KEY_STATE = "last_state"
    private const val KEY_REASON = "last_reason"

    /** 最近一次收到权威 STATE 广播的时刻（elapsedRealtime），
     *  由 StateReceiver 的兜底计时器用时间戳守卫防止覆盖已到达的状态。 */
    @Volatile
    var lastUpdateElapsed = 0L
        private set

    fun lastState(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_STATE, "UNKNOWN") ?: "UNKNOWN"

    fun lastReason(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_REASON, "unknown") ?: "unknown"

    private fun canNotify(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        return context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun ensureChannel(nm: NotificationManager) {
        val channel = NotificationChannel(
            CHANNEL_ID, "模块状态", NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "SAD 模块运行状态与快捷控制"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        nm.createNotificationChannel(channel)
    }

    private fun baseBuilder(context: Context, nm: NotificationManager): Notification.Builder {
        ensureChannel(nm)
        val contentIntent = PendingIntent.getActivity(
            context, 3,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_shield)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .setCategory(Notification.CATEGORY_STATUS)
            .setContentIntent(contentIntent)
    }

    private fun webUiAction(context: Context): Notification.Action {
        val pi = PendingIntent.getActivity(
            context, 2,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return Notification.Action.Builder(null, "打开 WebUI", pi).build()
    }

    private fun toggleAction(context: Context, label: String, action: String): Notification.Action {
        val pi = PendingIntent.getBroadcast(
            context, 1,
            Intent(context, StateReceiver::class.java).setAction(action),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return Notification.Action.Builder(
            android.graphics.drawable.Icon.createWithResource(context, R.drawable.ic_shield),
            label, pi
        ).build()
    }

    fun update(context: Context, state: String, reason: String) {
        lastUpdateElapsed = SystemClock.elapsedRealtime()
        val app = context.applicationContext
        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_STATE, state)
            .putString(KEY_REASON, reason)
            .apply()
        if (!canNotify(app)) return
        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = baseBuilder(app, nm)
        val (title, toggleLabel, toggleActionName) = when (state) {
            "PAUSED" -> Triple("SAD：已暂停", "恢复", StateReceiver.ACTION_RESUME)
            "FAIL_OPEN" -> Triple("SAD：故障", "恢复", StateReceiver.ACTION_RESUME)
            else -> Triple("SAD：运行中", "暂停", StateReceiver.ACTION_PAUSE)
        }
        val time = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
        builder.setContentTitle(title)
            .setContentText("$reason · $time")
            .addAction(toggleAction(app, toggleLabel, toggleActionName))
            .addAction(webUiAction(app))
        nm.notify(NOTIFICATION_ID, builder.build())
    }

    /** 点击后、收到权威 STATE 前的占位展示：移除切换按钮即防连点。 */
    fun showPending(context: Context) {
        val app = context.applicationContext
        if (!canNotify(app)) return
        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = baseBuilder(app, nm)
        builder.setContentTitle("SAD：切换中…")
            .setContentText("等待模块确认（约 2 秒）")
            .addAction(webUiAction(app))
        nm.notify(NOTIFICATION_ID, builder.build())
    }
}
