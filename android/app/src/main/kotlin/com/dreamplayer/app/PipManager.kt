package com.dreamplayer.app

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Rational
import io.flutter.plugin.common.MethodChannel

/// Picture-in-picture for the **libmpv fallback engine**.
///
/// The main engine's pip lives in [ExoPlayerView] because it owns a native
/// `SurfaceView` and the live `ExoPlayer` instance. In fallback mode that
/// platform view is NOT mounted (the video is a Flutter texture rendered by
/// media_kit's `Video` widget), and `ExoPlayerView.enterPipInternal` gates on
/// `player.isPlaying` of an idle ExoPlayer - so the pip request would silently
/// bail out.
///
/// Entering pip is an Activity-level operation, so the same
/// `enterPictureInPictureMode` call works for a Flutter-texture video: the
/// whole Flutter window is shrunk into the pip window, and the player screen
/// already hides every control while `_inPip` is set, so only the video shows.
///
/// The auto-entry decision happens in `onUserLeaveHint`, which cannot wait for
/// a round-trip to Dart - so Dart PUSHES its playback state here
/// (`setMpvState`) whenever it changes, and this object answers synchronously.
///
/// The pip window's own transport controls are [RemoteAction]s (rewind / play
/// or pause / forward). A Flutter texture can't receive touches while in pip,
/// so these system-drawn buttons are the ONLY way to control playback there;
/// each one fires a package-scoped broadcast back to a receiver registered
/// while pip is active, which forwards to Dart.
class PipManager(private val activity: Activity) {

    companion object {
        const val CHANNEL = "dreamplayer/pip"

        /// Broadcast action for the pip window's transport buttons. Package-
        /// scoped (see the explicit `setPackage` in the PendingIntent) so no
        /// other app can drive playback.
        private const val ACTION_CONTROL = "com.dreamplayer.app.PIP_CONTROL"
        private const val EXTRA_CONTROL = "control"
        private const val CONTROL_PLAY_PAUSE = "playPause"
        private const val CONTROL_REWIND = "rewind"
        private const val CONTROL_FORWARD = "forward"

        private const val REQ_PLAY_PAUSE = 2201
        private const val REQ_REWIND = 2202
        private const val REQ_FORWARD = 2203

        /// Live instance for the Activity lifecycle callbacks. Set in
        /// [configure]; the Activity outlives it, hence the nullable read.
        @Volatile
        var instance: PipManager? = null
            private set
    }

    private var channel: MethodChannel? = null

    /// True while the fallback engine owns playback (Dart-pushed).
    @Volatile
    private var mpvActive = false

    /// True while the fallback engine is actually playing (Dart-pushed).
    @Volatile
    private var mpvPlaying = false

    /// Video aspect (width / height) reported by the fallback engine, or 0 when
    /// unknown - then 16:9 is assumed.
    @Volatile
    private var mpvAspect = 0f

    /// Set once the app has been in pip during this playback session; cleared
    /// only on a real resume (expand-back). Mirrors ExoPlayerView's `pipSeen`
    /// latch: swiping the pip away delivers `onStop` while the system STILL
    /// reports `isInPictureInPictureMode=true`, so a "currently in pip" guard
    /// would skip the pause and audio would play on invisibly.
    @Volatile
    private var pipSeen = false

    /// True while the app is actually in the pip window - the action buttons
    /// are only rebuilt in that state (`setPictureInPictureParams` outside pip
    /// is wasted work).
    @Volatile
    private var inPip = false

    private var receiver: BroadcastReceiver? = null

    fun configure(channel: MethodChannel) {
        this.channel = channel
        instance = this
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Dart pushes fallback-engine state so onUserLeaveHint can
                // decide synchronously.
                "setMpvState" -> {
                    val wasPlaying = mpvPlaying
                    mpvActive = call.argument<Boolean>("active") ?: false
                    mpvPlaying = call.argument<Boolean>("playing") ?: false
                    mpvAspect = (call.argument<Double>("aspect") ?: 0.0).toFloat()
                    if (!mpvActive) pipSeen = false
                    // The pip window's play/pause button has to flip with the
                    // real state, which means re-publishing the actions.
                    if (inPip && mpvActive && wasPlaying != mpvPlaying) {
                        updatePipActions()
                    }
                    result.success(null)
                }
                // Explicit user action from the ⋮ sheet - ignores the Settings
                // toggle (which only gates automatic entry), like the main
                // engine's `enterPip`.
                "enterPip" -> result.success(enterPip(auto = false))
                else -> result.notImplemented()
            }
        }
    }

    /// Called from `MainActivity.onUserLeaveHint`. Returns true when pip was
    /// requested, so the Activity knows the fallback path handled it.
    fun enterPipIfPlaying(): Boolean {
        if (!mpvActive || !mpvPlaying) return false
        return enterPip(auto = true)
    }

    /// True when the fallback engine currently owns playback - the Activity
    /// uses this to route its lifecycle callbacks to the right engine.
    fun isMpvActive(): Boolean = mpvActive

    private fun enterPip(auto: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (MainActivity.isTvBox(activity)) return false
        if (!mpvActive) return false
        if (auto) {
            if (!mpvPlaying) return false
            if (!pipSettingEnabled()) return false
        }
        return try {
            activity.enterPictureInPictureMode(buildParams())
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun buildParams(): PictureInPictureParams {
        val raw = if (mpvAspect > 0f) mpvAspect else 16f / 9f
        // The system requires roughly 0.418–2.39; clamp + scale into a
        // Rational (same bounds as the main engine's path).
        val clamped = raw.coerceIn(0.42f, 2.39f)
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(Math.round(clamped * 1000), 1000))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setActions(buildActions())
        }
        return builder.build()
    }

    /// Rewind / play-pause / forward, in that order. The system shows at most
    /// `getMaxNumPictureInPictureActions()` (3 on virtually every device).
    private fun buildActions(): List<RemoteAction> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return emptyList()
        return listOf(
            remoteAction(
                iconRes = R.drawable.ic_stat_rewind,
                title = "Rewind 10s",
                control = CONTROL_REWIND,
                requestCode = REQ_REWIND,
            ),
            if (mpvPlaying) {
                remoteAction(
                    iconRes = R.drawable.ic_stat_pause,
                    title = "Pause",
                    control = CONTROL_PLAY_PAUSE,
                    requestCode = REQ_PLAY_PAUSE,
                )
            } else {
                remoteAction(
                    iconRes = R.drawable.ic_stat_play,
                    title = "Play",
                    control = CONTROL_PLAY_PAUSE,
                    requestCode = REQ_PLAY_PAUSE,
                )
            },
            remoteAction(
                iconRes = R.drawable.ic_stat_forward,
                title = "Forward 10s",
                control = CONTROL_FORWARD,
                requestCode = REQ_FORWARD,
            ),
        )
    }

    private fun remoteAction(
        iconRes: Int,
        title: String,
        control: String,
        requestCode: Int,
    ): RemoteAction {
        val intent = Intent(ACTION_CONTROL)
            // Explicit package: an implicit broadcast could otherwise be
            // received by another app on older API levels.
            .setPackage(activity.packageName)
            .putExtra(EXTRA_CONTROL, control)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pending = PendingIntent.getBroadcast(activity, requestCode, intent, flags)
        return RemoteAction(
            Icon.createWithResource(activity, iconRes),
            title,
            title,
            pending,
        )
    }

    /// Re-publishes the pip actions so the play/pause button matches the real
    /// playback state. Safe to call while in pip only.
    private fun updatePipActions() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            activity.setPictureInPictureParams(buildParams())
        } catch (_: Exception) {
        }
    }

    /// Tells Dart to hide/show the player chrome. Dart flips `_inPip`, which
    /// every control-reveal path is already gated on.
    fun onPipModeChanged(inPip: Boolean) {
        this.inPip = inPip
        if (inPip) {
            pipSeen = true
            registerReceiver()
        } else {
            unregisterReceiver()
        }
        channel?.invokeMethod("pipChanged", mapOf("inPip" to inPip))
    }

    fun onResumed() {
        // Expand-back from pip: clear the latch so a later onStop (real
        // backgrounding) doesn't pause as if the pip had been dismissed.
        pipSeen = false
    }

    /// `onStop` after the pip has been seen = the user swiped the pip window
    /// away. Pause so audio doesn't keep playing invisibly.
    fun onActivityStopped() {
        unregisterReceiver()
        if (!mpvActive || !pipSeen) return
        pipSeen = false
        channel?.invokeMethod("pipDismissed", null)
    }

    private fun registerReceiver() {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.getStringExtra(EXTRA_CONTROL)) {
                    CONTROL_PLAY_PAUSE -> channel?.invokeMethod("pipPlayPause", null)
                    CONTROL_REWIND -> channel?.invokeMethod("pipRewind", null)
                    CONTROL_FORWARD -> channel?.invokeMethod("pipForward", null)
                }
            }
        }
        receiver = r
        val filter = IntentFilter(ACTION_CONTROL)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // API 33+ requires an explicit export flag. These broadcasts
                // come from our own PendingIntents, so keep them internal.
                activity.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                activity.registerReceiver(r, filter)
            }
        } catch (_: Exception) {
            receiver = null
        }
    }

    private fun unregisterReceiver() {
        val r = receiver ?: return
        receiver = null
        try {
            activity.unregisterReceiver(r)
        } catch (_: Exception) {
        }
    }

    /// The `flutter.dreamplayer.pipEnabled` pref (Settings toggle, default
    /// true) read natively - same key and default as the main engine.
    private fun pipSettingEnabled(): Boolean = try {
        activity.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.dreamplayer.pipEnabled", true)
    } catch (_: Exception) {
        true
    }
}
