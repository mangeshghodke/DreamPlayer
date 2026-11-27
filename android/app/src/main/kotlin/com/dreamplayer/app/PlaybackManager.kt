package com.dreamplayer.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.media.session.MediaButtonReceiver
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException

/**
 * MediaSession + media-notification glue for background playback.
 *
 * The video player lives in the Activity-scoped platform view
 * ([ExoPlayerView]); this singleton wraps it in a MediaSessionCompat and
 * drives [PlaybackService] (a foreground service of type mediaPlayback) so
 * the process keeps foreground priority when the app is backgrounded or the
 * screen locks. The MediaStyle notification shows rewind-10s / play-pause /
 * forward-10s / close, all routed through the session callback back into the
 * live player instance.
 *
 * Lifecycle:
 *  - [attach] on `open` (lazily creates the session),
 *  - [sync] on every player-state change (called from ExoPlayerView.emit),
 *  - [release] when the platform view is disposed,
 *  - [stop] when the user taps Close or swipes the (paused) notification.
 *
 * The matched TMDB poster is pushed in with [setArtwork] and lands in both the
 * MediaSession metadata (the Android 13+ system media card / lock screen) and
 * the notification's large icon. Downloading here rather than in Dart keeps
 * the poster out of the method-channel payload and matches how the iOS side
 * owns its Now Playing artwork.
 */
object PlaybackManager {

    private const val CHANNEL_ID = "dreamplayer_playback"
    private const val NOTIF_ID = 4210

    private var session: MediaSessionCompat? = null
    private var player: ExoPlayer? = null
    private var title: String? = null

    /// Current poster (empty = none) plus the decoded bitmap used by both the
    /// session metadata and the notification. [artworkRequestId] invalidates
    /// an in-flight download when the title changes or the view is released,
    /// so a slow response cannot repaint a notification for another video.
    private var artworkUrl: String? = null
    private var artworkBitmap: Bitmap? = null
    /// True when the current artwork came from raw bytes (setArtworkData)
    /// rather than a URL - so a later URL fetch knows it must replace it.
    private var hasArtworkData = false
    private var artworkRequestId = 0
    private val artworkClient: OkHttpClient by lazy { OkHttpClient() }
    private val mainHandler: Handler by lazy { Handler(Looper.getMainLooper()) }

    /// Guards redundant notification rebuilds (position ticker emits ~1/s).
    private var lastNotifyKey: String? = null
    private var lastNotifyAtMs = 0L

    /// Background-service lifecycle handshake. `startForegroundService` must be
    /// followed by `startForeground` within the service's `onStartCommand`;
    /// calling `stopService` before that lands kills the service pre-foreground
    /// and Android 12+ turns it into a
    /// `ForegroundServiceDidNotStartInTimeException` crash. So the flags here
    /// serialize the three states:
    ///  - [servicePending]: a start was requested, the service hasn't yet run
    ///    `onStartCommand` + `startForeground`.
    ///  - [serviceRunning]: the service is currently foregrounded.
    ///  - [pendingStop]: a stop was requested while [servicePending] - the
    ///    service must stop itself immediately after it foregrounds.
    /// All three live on the platform-main thread (start/stop/onStartCommand
    /// all arrive there), so no synchronization is needed.
    private var servicePending = false
    private var serviceRunning = false
    private var pendingStop = false

    val sessionCompatToken: MediaSessionCompat.Token?
        get() = session?.sessionToken

    /// For [MediaButtonReceiver.handleIntent] - routes headset/Bluetooth
    /// media-button key events into the session callback.
    fun mediaSessionForMediaButtons(): MediaSessionCompat? = session

    fun attach(context: Context, exoPlayer: ExoPlayer) {
        player = exoPlayer
        if (session == null) {
            session = MediaSessionCompat(context.applicationContext, "DreamPlayer").apply {
                setCallback(object : MediaSessionCompat.Callback() {
                    override fun onPlay() {
                        player?.play()
                    }

                    override fun onPause() {
                        player?.pause()
                    }

                    override fun onSeekTo(pos: Long) {
                        player?.seekTo(pos)
                    }

                    override fun onRewind() {
                        seekBy(-10_000L)
                    }

                    override fun onFastForward() {
                        seekBy(10_000L)
                    }

                    override fun onStop() {
                        player?.pause()
                        stop(context)
                    }
                })
            }
        }
        session!!.isActive = true
    }

    fun setTitle(value: String?) {
        val next = value?.takeIf { it.isNotBlank() }
        if (next != title) {
            // A new video's title arrives before its metadata resolves. Drop
            // the previous poster now instead of leaving it on the lock screen
            // until setArtwork() lands (which can take a network round-trip).
            artworkUrl = null
            artworkBitmap = null
            artworkRequestId++
        }
        title = next
        lastNotifyKey = null
    }

    /// Sets the poster shown on the lock screen / in the system media card.
    /// `null` (or a blank string) clears it. Downloads off the main thread and
    /// ignores a response whose video has already been replaced.
    fun setArtwork(context: Context, value: String?) {
        val url = value?.takeIf { it.isNotBlank() }
        hasArtworkData = false
        if (url == artworkUrl) {
            // The title may have changed with no artwork (or the same artwork)
            // - still rebuild so the notification shows the new title.
            sync(context.applicationContext)
            return
        }
        artworkUrl = url
        val requestId = ++artworkRequestId
        artworkBitmap = null
        lastNotifyKey = null
        val appContext = context.applicationContext

        if (url == null) {
            sync(appContext)
            return
        }
        // Publish the cleared state immediately; the poster follows when the
        // download completes (a notification rebuild is already in flight).
        sync(appContext)
        artworkClient.newCall(
            Request.Builder().url(url).header("User-Agent", "DreamPlayer").build(),
        ).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) = Unit

            override fun onResponse(call: Call, response: Response) {
                val bitmap = response.use { r ->
                    if (!r.isSuccessful) {
                        null
                    } else {
                        r.body?.byteStream()?.use { BitmapFactory.decodeStream(it) }
                    }
                }
                mainHandler.post {
                    if (requestId != artworkRequestId) {
                        bitmap?.recycle()
                        return@post
                    }
                    artworkBitmap = bitmap
                    lastNotifyKey = null
                    sync(appContext)
                }
            }
        })
    }

    /// Sets the lock-screen / media-card artwork from raw image BYTES - used
    /// for audio files whose embedded cover art has no URL. Mirrors
    /// [setArtwork]: null clears, and a later URL-based [setArtwork] replaces
    /// the bytes (and vice versa).
    fun setArtworkData(context: Context, bytes: ByteArray?) {
        artworkUrl = null
        hasArtworkData = true
        artworkRequestId++
        val bitmap = bytes?.let {
            try {
                BitmapFactory.decodeByteArray(it, 0, it.size)
            } catch (_: Exception) {
                null
            }
        }
        artworkBitmap = bitmap
        lastNotifyKey = null
        sync(context.applicationContext)
    }

    /**
     * Reflects the current player state into the session + notification.
     * Safe to call on every event: playback-state writes are cheap, and the
     * notification itself is only rebuilt when something visible changed.
     */
    fun sync(context: Context) {
        val p = player ?: return
        val s = session ?: return
        // Reactivate after a transient IDLE (setMediaItem resets the player
        // to IDLE between opens) or an earlier stop().
        s.isActive = true
        when {
            p.playbackState == Player.STATE_IDLE -> {
                stop(context)
                return
            }
            p.playbackState == Player.STATE_ENDED -> {
                stop(context)
                return
            }
        }

        val playing = p.isPlaying
        val duration = if (p.duration == C.TIME_UNSET) 0L else p.duration
        val stateAction = if (playing) {
            PlaybackStateCompat.STATE_PLAYING
        } else if (p.playbackState == Player.STATE_BUFFERING && p.playWhenReady) {
            PlaybackStateCompat.STATE_BUFFERING
        } else {
            PlaybackStateCompat.STATE_PAUSED
        }

        s.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY
                        or PlaybackStateCompat.ACTION_PAUSE
                        or PlaybackStateCompat.ACTION_PLAY_PAUSE
                        or PlaybackStateCompat.ACTION_SEEK_TO
                        or PlaybackStateCompat.ACTION_FAST_FORWARD
                        or PlaybackStateCompat.ACTION_REWIND
                        or PlaybackStateCompat.ACTION_STOP
                )
                .setState(stateAction, p.currentPosition, if (playing) p.playbackParameters.speed else 0f)
                .build(),
        )
        // The lock screen shows ONLY the system media card, so it carries the
        // poster here. Our own notification is hidden on the lock screen
        // (VISIBILITY_SECRET in buildNotification) and appears in the
        // notification panel, so the two surfaces no longer duplicate on the
        // lock screen.
        val metadata = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title ?: "DreamPlayer")
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, "DreamPlayer")
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, duration)
        artworkBitmap?.let {
            metadata.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, it)
            metadata.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, it)
        }
        s.setMetadata(metadata.build())

        // Start the foreground service only when it isn't already running (or
        // still pending its foreground). A redundant startForegroundService per
        // emit is normally harmless, but if a stop raced in between the start
        // and the service's onStartCommand the service would be torn down
        // before startForeground → ForegroundServiceDidNotStartInTimeException.
        if (!servicePending && !serviceRunning) {
            pendingStop = false
            servicePending = true
            ContextCompat.startForegroundService(context, Intent(context, PlaybackService::class.java))
        }

        // Rebuild the notification when a visible aspect changed, or once a
        // second while playing so the progress bar tracks playback. The
        // lockscreen extrapolates position from state.speed between updates.
        val now = android.os.SystemClock.elapsedRealtime()
        val key = "${p.playbackState}|$playing|$title"
        if (key != lastNotifyKey || (playing && now - lastNotifyAtMs >= 1000)) {
            lastNotifyKey = key
            lastNotifyAtMs = now
            notify(context)
        }
    }

    /// User tapped Close (or dismissed a paused notification): stop playback,
    /// drop the foreground UI, keep the player itself alive for the screen.
    fun stop(context: Context) {
        lastNotifyKey = null
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIF_ID)
        session?.isActive = false
        when {
            servicePending -> {
                // The service hasn't reached startForeground yet - stopping it
                // now would trigger the FGS start-timeout crash. Ask it to stop
                // as soon as it foregrounds instead.
                servicePending = false
                pendingStop = true
            }
            serviceRunning -> {
                // Already foregrounded - safe to stopService immediately.
                serviceRunning = false
                pendingStop = false
                context.stopService(Intent(context, PlaybackService::class.java))
            }
            else -> pendingStop = false
        }
    }

    /// Called from [PlaybackService.onStartCommand] right after the
    /// foreground notification went up. Returns true when a stop was requested
    /// while the start was still pending - the caller must stopSelf now.
    fun serviceStarted(): Boolean {
        servicePending = false
        serviceRunning = true
        if (pendingStop) {
            pendingStop = false
            serviceRunning = false
            return true
        }
        return false
    }

    /// Called from the service's onDestroy so the flags track reality even if
    /// the system kills or restarts the service behind our back.
    fun serviceDestroyed() {
        servicePending = false
        serviceRunning = false
        pendingStop = false
    }

    /// Full teardown when the platform view goes away: the player is being
    /// released, so the notification/service must not outlive it.
    fun release(context: Context) {
        stop(context)
        servicePending = false
        serviceRunning = false
        pendingStop = false
        player = null
        lastNotifyKey = null
        artworkUrl = null
        artworkBitmap = null
        artworkRequestId++
        try {
            session?.isActive = false
            session?.release()
        } catch (_: Exception) {}
        session = null
        title = null
    }

    /// Swipe-away while backgrounded: pause so audio doesn't keep playing
    /// with no way back except reopening the app (safe default).
    fun onTaskRemoved(context: Context) {
        player?.pause()
        stop(context)
    }

    private fun seekBy(deltaMs: Long) {
        val p = player ?: return
        val target = (p.currentPosition + deltaMs).coerceIn(0L, p.duration.coerceAtLeast(0L))
        p.seekTo(target)
    }

    private fun notify(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        nm.notify(NOTIF_ID, buildNotification(context))
    }

    fun buildNotification(context: Context): Notification {
        ensureChannel(context)
        val p = player
        val playing = p?.isPlaying == true
        val duration = p?.duration?.takeIf { it != C.TIME_UNSET }?.coerceAtLeast(0L) ?: 0L
        val position = p?.currentPosition?.coerceIn(0L, if (duration > 0) duration else Long.MAX_VALUE) ?: 0L

        val contentPi = PendingIntent.getActivity(
            context,
            0,
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, Class.forName("com.dreamplayer.app.MainActivity")),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        fun button(action: Long, iconRes: Int, label: String): NotificationCompat.Action =
            NotificationCompat.Action.Builder(
                iconRes,
                label,
                MediaButtonReceiver.buildMediaButtonPendingIntent(context, action),
            ).build()

        // Deliberately a PLAIN notification, not MediaStyle: on Android 13+ /
        // OxygenOS a MediaStyle notification bound to the session token is
        // pulled out of the notification panel entirely and rendered as the
        // system media card in the quick-settings shade (verified on-device -
        // Poweramp behaves the same). Users expect a visible row here, so we
        // post a normal silent notification with transport actions; the
        // MediaSession stays active for headset/Bluetooth keys and the action
        // PendingIntents still route through it into the player.
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_play)
            .setContentTitle(title ?: "DreamPlayer")
            .setContentText("DreamPlayer")
            .setContentIntent(contentPi)
            .setOnlyAlertOnce(true)
            // The lock screen belongs to the system media card (which carries
            // the poster via the session metadata). Hiding this row there on a
            // secure lock screen leaves exactly one media surface; it still
            // shows normally in the notification panel after unlock.
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setOngoing(playing)
            .setDeleteIntent(
                MediaButtonReceiver.buildMediaButtonPendingIntent(
                    context, PlaybackStateCompat.ACTION_STOP,
                ),
            )
            .addAction(button(PlaybackStateCompat.ACTION_REWIND, android.R.drawable.ic_media_rew, "Back 10s"))
            .addAction(
                button(
                    PlaybackStateCompat.ACTION_PLAY_PAUSE,
                    if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (playing) "Pause" else "Play",
                ),
            )
            .addAction(button(PlaybackStateCompat.ACTION_FAST_FORWARD, android.R.drawable.ic_media_ff, "Forward 10s"))
            .addAction(button(PlaybackStateCompat.ACTION_STOP, android.R.drawable.ic_menu_close_clear_cancel, "Close"))
        // Keeps the poster in the notification panel. On the lock screen this
        // row is hidden (VISIBILITY_SECRET above), so it cannot duplicate the
        // system media card poster.
        artworkBitmap?.let { builder.setLargeIcon(it) }
        if (duration > 0) {
            builder.setProgress(duration.toInt(), position.toInt(), false)
        }
        return builder.build()
    }

    private fun ensureChannel(context: Context) {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Playback",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                setShowBadge(false)
            },
        )
    }
}
