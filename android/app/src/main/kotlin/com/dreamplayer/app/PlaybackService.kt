package com.dreamplayer.app

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.ServiceCompat
import androidx.media.session.MediaButtonReceiver

/**
 * Foreground service (type mediaPlayback) that keeps the process alive while
 * video plays in the background / with the screen locked, hosting the media
 * notification built by [PlaybackManager]. The player itself stays in the
 * Activity-scoped platform view — this service only holds foreground priority.
 */
class PlaybackService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == Intent.ACTION_MEDIA_BUTTON) {
            val mediaSession = PlaybackManager.mediaSessionForMediaButtons()
            if (mediaSession != null) {
                MediaButtonReceiver.handleIntent(mediaSession, intent)
            }
        }
        val notification = PlaybackManager.buildNotification(this)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
        // Tell PlaybackManager the foreground is up. If a stop was requested
        // while this start was still pending (a fast STATE_ENDED/IDLE right
        // after open), honor it here — stopping BEFORE startForeground would
        // trigger ForegroundServiceDidNotStartInTimeException on Android 12+.
        if (PlaybackManager.serviceStarted()) {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        PlaybackManager.serviceDestroyed()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Safe default: swiping the app away stops playback + notification.
        PlaybackManager.onTaskRemoved(this)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    companion object {
        private const val NOTIF_ID = 4210
    }
}
