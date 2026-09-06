package com.dreamplayer.app

import android.content.Context
import android.content.Intent
import android.os.Environment
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import java.io.File

class DownloadClient(private val context: Context) {

    fun configure(channel: MethodChannel) {
        DownloadService.cancelCallback = { jobId ->
            try {
                channel.invokeMethod("onCancelFromNotification", jobId)
            } catch (_: Exception) {}
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getDownloadDir" -> {
                    val dir = File(
                        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                        "DreamPlayer",
                    )
                    if (!dir.exists()) dir.mkdirs()
                    result.success(dir.absolutePath)
                }
                "startService" -> {
                    val title = call.argument<String>("title") ?: "DreamPlayer"
                    val totalBytes = call.argument<Number>("totalBytes")?.toLong() ?: -1L
                    val jobId = call.argument<String>("jobId") ?: ""
                    val intent = Intent(context, DownloadService::class.java).apply {
                        putExtra(DownloadService.EXTRA_TITLE, title)
                        putExtra(DownloadService.EXTRA_TOTAL_BYTES, totalBytes)
                        putExtra(DownloadService.EXTRA_JOB_ID, jobId)
                    }
                    ContextCompat.startForegroundService(context, intent)
                    result.success(true)
                }
                "updateProgress" -> {
                    val title = call.argument<String>("title") ?: "DreamPlayer"
                    val bytesCopied = call.argument<Number>("bytesCopied")?.toLong() ?: 0L
                    val totalBytes = call.argument<Number>("totalBytes")?.toLong() ?: -1L
                    DownloadService.updateNotification(title, bytesCopied, totalBytes)
                    result.success(true)
                }
                "stopService" -> {
                    DownloadService.stop()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
