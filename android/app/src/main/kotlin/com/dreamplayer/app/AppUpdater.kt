package com.dreamplayer.app

import android.app.Activity
import android.content.Intent
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The install half of the in-app updater for the sideload (GitHub Releases)
 * build. Play Core's in-app update API is deliberately not used: it only works
 * for Play-installed apps, and this app is distributed as an APK.
 *
 * Dart checks the release feed and downloads the APK into the cache; this class
 * only turns that file into a package-installer intent (FileProvider URI). The
 * intent is always fired — when the "install unknown apps" grant is missing,
 * the system PackageInstaller shows its own popup with a Settings button.
 */
class AppUpdater(private val activity: Activity) {
    companion object {
        const val CHANNEL = "dreamplayer/updater"
        private const val DIR = "updates"
    }

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "currentAbi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a")
                "installApk" -> {
                    val fileName = call.argument<String>("fileName")
                    if (fileName.isNullOrBlank() || fileName.contains('/') || fileName.contains('\\')) {
                        result.error("bad_args", "fileName is required", null)
                        return@setMethodCallHandler
                    }
                    // No grant pre-check: the intent is always fired, and
                    // when it is missing the system PackageInstaller itself
                    // shows the "For your security" popup with its own
                    // Settings button, which opens the per-app "Allow from
                    // this source" toggle. That grant is kept by the OS per
                    // app, survives updates, and is wiped on uninstall —
                    // exactly the one-time behaviour wanted.
                    try {
                        installApk(fileName)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }
                "deleteApk" -> {
                    call.argument<String>("fileName")?.let { deleteApk(it) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun installApk(fileName: String) {
        val file = File(File(activity.cacheDir, DIR), fileName)
        check(file.isFile) { "APK not found: ${file.name}" }
        val uri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.fileprovider",
            file,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        activity.startActivity(intent)
    }

    private fun deleteApk(fileName: String) {
        runCatching { File(File(activity.cacheDir, DIR), fileName).delete() }
    }
}
