package com.dreamplayer.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.app.UiModeManager
import android.content.res.Configuration
import android.graphics.drawable.ColorDrawable
import android.media.AudioManager
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var intentChannel: MethodChannel? = null
    private var fileBrowser: FileBrowser? = null

    companion object {
        /// Robust TV-box detection (mirrors Just Player's `Utils.isTvBox()`):
        /// Android TV ui mode, leanback/Fire TV feature flags, or the Fire TV
        /// package. More reliable than a screen-width heuristic (a 720p TV
        /// reports 640dp).
        fun isTvBox(context: Context): Boolean {
            val uiModeManager =
                context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
            if (uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
                return true
            }
            val pm = context.packageManager
            if (pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
                pm.hasSystemFeature("com.amazon.hardware.fire_tv") ||
                pm.hasSystemFeature("amazon.hardware.fire_tv")
            ) {
                return true
            }
            return try {
                pm.getPackageInfo("com.amazon.tv.launcher", 0)
                true
            } catch (_: PackageManager.NameNotFoundException) {
                false
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Nova-style transparent window on TV: the SurfaceView renders behind
        // the window; a transparent background lets it show through (avoids the
        // opaque LayerDim that Fire OS creates when the window has a solid
        // background + dual SurfaceViews).
        if (isTvBox(this)) {
            window.setBackgroundDrawable(ColorDrawable(android.graphics.Color.TRANSPARENT))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "dreamplayer/exo_player",
            ExoPlayerViewFactory(this, flutterEngine.dartExecutor.binaryMessenger),
        )
        fileBrowser = FileBrowser(this)
        fileBrowser!!.configure(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FileBrowser.CHANNEL),
        )
        WebDAVClient(this).configure(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WebDAVClient.CHANNEL),
        )
        CacheCleaner(this).configure(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dreamplayer/cache"),
        )
        MulticastLockManager(this).configure(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dreamplayer/multicast"),
        )
        SMBClient(this).configure(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMBClient.CHANNEL),
        )
        UpnpClient(this).configure(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UpnpClient.CHANNEL),
        )
        FtpClient(this).configure(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FtpClient.CHANNEL),
        )
        PipManager(this).configure(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PipManager.CHANNEL),
        )
        intentChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dreamplayer/intent",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialIntent" -> {
                        result.success(intentPayload(intent))
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dreamplayer/device",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isTv" -> result.success(isTvBox(this))
                else -> result.notImplemented()
            }
        }
        // Engine-agnostic OS controls — brightness (per-app window brightness)
        // and system media volume. Used by the MPV fallback engine because
        // ExoPlayerView (the only other owner of these handlers) is not
        // created when mpv is active — the player is just a Flutter texture,
        // not a platform view.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dreamplayer/system",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setBrightness" -> {
                    val brightness = call.argument<Number>("brightness")?.toFloat() ?: 0.5f
                    val params = window.attributes
                    params.screenBrightness = if (brightness < 0f)
                        WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    else
                        brightness.coerceIn(0f, 1f)
                    window.attributes = params
                    result.success(null)
                }
                "getBrightness" -> {
                    val b = window.attributes.screenBrightness
                    result.success(if (b < 0f) 0.5f else b)
                }
                "setSystemVolume" -> {
                    val volume = call.argument<Number>("volume")?.toFloat() ?: 1f
                    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    val target = (volume.coerceIn(0f, 1f) * maxVol).toInt()
                    am.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
                    result.success(null)
                }
                "getSystemVolume" -> {
                    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC).toFloat()
                    val curVol = am.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat()
                    result.success(if (maxVol > 0f) curVol / maxVol else 1f)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Launcher taps after unlock deliver a MAIN intent (singleTop);
        // intentPayload is null for non-VIDEO intents, so don't tell Dart to
        // open anything — the home screen stays put.
        intentPayload(intent)?.let { payload ->
            intentChannel?.invokeMethod("open", payload)
        }
    }

    // MARK: - Picture-in-picture

    /// Leaving the app (HOME / recents / app-switch) while a video plays
    /// drops into picture-in-picture instead of plain background audio.
    ///
    /// Two engines can own playback: the native Media3 platform view
    /// ([ExoPlayerView]) or the libmpv fallback (a Flutter texture, so pip is
    /// driven by [PipManager]). The fallback gets first refusal — when it is
    /// active the ExoPlayer instance is idle and its own pip path would bail.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (PipManager.instance?.enterPipIfPlaying() == true) return
        ExoPlayerView.activeView?.enterPipIfPlaying()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        val pip = PipManager.instance
        if (pip?.isMpvActive() == true) {
            pip.onPipModeChanged(isInPictureInPictureMode)
            return
        }
        ExoPlayerView.activeView?.onPipModeChanged(isInPictureInPictureMode)
    }

    override fun onResume() {
        super.onResume()
        PipManager.instance?.onResumed()
        ExoPlayerView.activeView?.onResumed()
    }

    override fun onStop() {
        super.onStop()
        // PiP dismissed from its window chrome: pause so audio doesn't keep
        // playing invisibly (plain background keeps playing — handled by the
        // foreground service; this only covers the pip-dismiss path).
        val pip = PipManager.instance
        if (pip?.isMpvActive() == true) {
            pip.onActivityStopped()
            return
        }
        ExoPlayerView.activeView?.onActivityStopped()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            FileBrowser.REQ_PICK_FOLDER -> fileBrowser?.onFolderPicked(resultCode, data)
            FileBrowser.REQ_PICK_SUBTITLE -> fileBrowser?.onSubtitlePicked(resultCode, data)
        }
    }

    /// Maps a VIEW intent to {uri, title, path?}. Returns null for non-VIDEO
    /// launches (launcher icon etc.).
    private fun intentPayload(intent: Intent?): Map<String, Any?>? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        val payload = HashMap<String, Any?>()
        when (data.scheme) {
            "file" -> {
                payload["uri"] = data.toString()
                payload["path"] = data.path
                payload["title"] = data.lastPathSegment
            }
            "content" -> {
                payload["uri"] = data.toString()
                payload["title"] = queryDisplayName(data) ?: data.lastPathSegment
                val realPath = queryPath(data)
                if (realPath != null) payload["path"] = realPath
            }
            else -> {
                payload["uri"] = data.toString()
                payload["title"] = data.lastPathSegment
            }
        }
        return payload
    }

    private fun queryDisplayName(uri: Uri): String? =
        queryString(uri, OpenableColumns.DISPLAY_NAME)

    /// The `_data` column is deprecated but still the only way to get a real
    /// file path for a content URI.
    private fun queryPath(uri: Uri): String? =
        queryString(uri, "_data")

    private fun queryString(uri: Uri, column: String): String? = try {
        contentResolver.query(uri, arrayOf(column), null, null, null)?.use { c ->
            val index = c.getColumnIndex(column)
            if (index >= 0 && c.moveToFirst()) c.getString(index) else null
        }
    } catch (_: Exception) {
        null
    }
}
