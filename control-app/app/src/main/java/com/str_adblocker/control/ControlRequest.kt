package com.str_adblocker.control

import android.content.Context
import java.io.File

/**
 * 请求文件协议：应用不申请 root，只把请求写进自己的外部目录，
 * 由模块侧 control-watch.sh 每 2 秒消费（mv 握手，见模块脚本注释）。
 *
 * 写入规则：目标已存在（上一请求未被消费）则返回 BUSY 由调用方延时重试，
 * 先到先得，保证连续点击的意图不丢失。
 */
object ControlRequest {

    private const val FILE_NAME = "sad.request"

    enum class Result { OK, BUSY, UNAVAILABLE }

    fun submit(context: Context, command: String): Result {
        val dir = context.getExternalFilesDir(null) ?: return Result.UNAVAILABLE
        val target = File(dir, FILE_NAME)
        if (target.exists()) return Result.BUSY
        val tmp = File(dir, "$FILE_NAME.tmp")
        return try {
            tmp.writeText("$command\n")
            if (!tmp.renameTo(target)) {
                tmp.delete()
                if (target.exists()) Result.BUSY else Result.UNAVAILABLE
            } else {
                Result.OK
            }
        } catch (e: Exception) {
            tmp.delete()
            Result.UNAVAILABLE
        }
    }
}
