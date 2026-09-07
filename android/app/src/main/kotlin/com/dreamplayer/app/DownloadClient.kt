package com.dreamplayer.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
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
                    val prefs = context.getSharedPreferences("flutter", Context.MODE_PRIVATE)
                    val custom = prefs.getString("dreamplayer.downloadDir", null)
                    val dir = if (custom != null && custom.isNotEmpty()) {
                        File(custom)
                    } else {
                        File(
                            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                            "DreamPlayer",
                        )
                    }
                    if (!dir.exists()) dir.mkdirs()
                    result.success(dir.absolutePath)
                }
                "setDownloadDir" -> {
                    val path = call.argument<String>("path") ?: ""
                    val prefs = context.getSharedPreferences("flutter", Context.MODE_PRIVATE)
                    if (path.isEmpty()) {
                        prefs.edit().remove("dreamplayer.downloadDir").apply()
                    } else {
                        prefs.edit().putString("dreamplayer.downloadDir", path).apply()
                    }
                    val dir = if (path.isEmpty()) {
                        File(
                            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                            "DreamPlayer",
                        )
                    } else {
                        File(path)
                    }
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
                "resolveLocalPath" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    val path = call.argument<String>("path") ?: ""
                    result.success(resolveLocalPath(uri, path))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun resolveLocalPath(uriStr: String, path: String): String? {
        // Plain filesystem path.
        if (path.isNotEmpty() && File(path).exists()) return path
        // content:// URI — resolve via DocumentsContract.
        if (uriStr.isNotEmpty()) {
            try {
                val uri = Uri.parse(uriStr)
                if (uri.scheme == "content") {
                    // Try to get the real file path from the document ID.
                    val docId = DocumentsContract.getDocumentId(uri)
                    if (docId.startsWith("primary:")) {
                        val rel = docId.removePrefix("primary:")
                        val file = File(Environment.getExternalStorageDirectory(), rel)
                        if (file.exists()) return file.absolutePath
                    }
                    // For other providers, copy to a temp file via ContentResolver.
                    val tmpFile = File(context.cacheDir, "dl_resolve.tmp")
                    context.contentResolver.openInputStream(uri)?.use { input ->
                        tmpFile.outputStream().use { output -> input.copyTo(output) }
                    }
                    if (tmpFile.exists()) return tmpFile.absolutePath
                } else if (uri.scheme == "file") {
                    val file = File(uri.path ?: "")
                    if (file.exists()) return file.absolutePath
                }
            } catch (_: Exception) {}
        }
        return null
    }
}
