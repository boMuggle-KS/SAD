package com.str_adblocker.control

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.Button
import android.widget.TextView

/**
 * 桌面图标 = WebUI 入口：首次启动请求通知权限（API 33+），随后尝试
 * 按序转发到 WebUI；全部失败时停留在一个极简状态页（可手动刷新）。
 * 每次打开都会写 sync 请求，让模块回推当前状态。
 */
class MainActivity : Activity() {

    private val handler = Handler(Looper.getMainLooper())

    private val statusPoller = object : Runnable {
        override fun run() {
            refreshStatusText()
            if (!isFinishing) handler.postDelayed(this, 2_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        findViewById<Button>(R.id.refreshButton).setOnClickListener {
            ControlRequest.submit(this, "sync")
            findViewById<TextView>(R.id.hintText).visibility = View.GONE
        }
        findViewById<Button>(R.id.webuiButton).setOnClickListener {
            openWebUi()
        }

        refreshStatusText()

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 100)
        } else {
            proceedToWebUi()
        }
    }

    override fun onResume() {
        super.onResume()
        handler.post(statusPoller)
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(statusPoller)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 100) proceedToWebUi()
    }

    private fun proceedToWebUi() {
        // BUSY 说明上一请求未被消费，模块消费后自然会广播当前状态，无需重试
        ControlRequest.submit(this, "sync")
        openWebUi()
    }

    private fun openWebUi() {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("ksuwebui://str_adblocker")))
            finish()
            return
        } catch (e: ActivityNotFoundException) {
        } catch (e: SecurityException) {
        }

        val managers = listOf("me.weishu.kernelsu", "com.rifsxd.ksunext")
        for (pkg in managers) {
            val launch = packageManager.getLaunchIntentForPackage(pkg) ?: continue
            try {
                startActivity(launch)
                finish()
                return
            } catch (e: ActivityNotFoundException) {
            } catch (e: SecurityException) {
            }
        }

        findViewById<TextView>(R.id.hintText).visibility = View.VISIBLE
    }

    private fun refreshStatusText() {
        val state = NotificationHelper.lastState(this)
        val reason = NotificationHelper.lastReason(this)
        val label = when (state) {
            "PAUSED" -> "已暂停"
            "FAIL_OPEN" -> "故障"
            "UNKNOWN" -> getString(R.string.status_unknown)
            else -> "运行中"
        }
        findViewById<TextView>(R.id.statusText).text =
            if (state == "UNKNOWN") label else "模块状态：$label（$reason）"
    }
}
