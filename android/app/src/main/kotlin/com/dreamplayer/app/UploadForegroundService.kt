package com.dreamplayer.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground service for the WiFi upload server (WiFi file transfer).
 *
 * A transfer can be gigabytes and the user expects to keep using the phone:
 * without a foreground service Android stops the process shortly after the
 * app goes to the background and the half-written file dies. The service
 * also gives the user the one thing the in-app page cannot: a notification
 * row with live byte progress and a Cancel button.
 *
 * Same shape as [DownloadService]: silent LOW-importance ongoing
 * notification, partial wake lock, package-scoped cancel broadcast.
 */
class UploadForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var cancelReceiver: BroadcastReceiver? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        ensureChannel()
        ServiceCompat.startForeground(
            this,
            NOTIF_ID,
            buildNotification(),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            },
        )
        registerCancelReceiver()
        acquireWakeLock()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        unregisterCancelReceiver()
        releaseWakeLock()
        instance = null
        super.onDestroy()
    }

    // -- Cancel broadcast receiver --

    private fun registerCancelReceiver() {
        cancelReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == ACTION_CANCEL) {
                    // Stops the server, which tears the connections down and
                    // emits "stopped" so the Dart side clears its rows.
                    cancelCallback?.invoke()
                }
            }
        }
        val filter = IntentFilter(ACTION_CANCEL)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(cancelReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(cancelReceiver, filter)
        }
    }

    private fun unregisterCancelReceiver() {
        cancelReceiver?.let {
            try { unregisterReceiver(it) } catch (_: IllegalArgumentException) {}
        }
        cancelReceiver = null
    }

    // -- Wake lock --

    private fun acquireWakeLock() {
        if (wakeLock == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dreamplayer:upload").apply {
                acquire(6 * 60 * 60 * 1000L)
            }
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    // -- Notification --

    /// [name] null means no file in flight right now (waiting state).
    private fun buildNotification(
        name: String? = currentName,
        received: Long = currentReceived,
        total: Long = currentTotal,
    ): Notification {
        val text = if (name == null) {
            "Waiting for files\u2026"
        } else if (total > 0) {
            "$name - ${formatSize(received)} / ${formatSize(total)}"
        } else {
            "$name - ${formatSize(received)}"
        }
        val cancelIntent = Intent(ACTION_CANCEL).apply { setPackage(packageName) }
        val cancelPendingIntent = PendingIntent.getBroadcast(
            this,
            NOTIF_ID,
            cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_play)
            .setContentTitle("WiFi file transfer on")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setOngoing(true)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(R.drawable.ic_stat_cancel, "Cancel", cancelPendingIntent)
            .apply {
                if (name != null && total > 0) {
                    setProgress(total.toInt(), received.toInt(), false)
                } else {
                    setProgress(0, 0, false)
                }
            }
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "WiFi file transfer",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                setShowBadge(false)
            },
        )
    }

    private fun formatSize(bytes: Long): String = when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "${bytes / 1024} KB"
        bytes < 1024 * 1024 * 1024 -> "${bytes / (1024 * 1024)} MB"
        else -> "${"%.1f".format(bytes / (1024.0 * 1024 * 1024))} GB"
    }

    companion object {
        const val CHANNEL_ID = "dreamplayer_upload"
        const val NOTIF_ID = 4212
        const val ACTION_CANCEL = "com.dreamplayer.app.UPLOAD_CANCEL"

        private var instance: UploadForegroundService? = null
        private var currentName: String? = null
        private var currentReceived = 0L
        private var currentTotal = -1L

        /** Set by UploadServer: stops the server and its connections. */
        var cancelCallback: (() -> Unit)? = null

        /** Starts (or refreshes) the ongoing transfer notification. */
        fun start(context: Context) {
            val intent = Intent(context, UploadForegroundService::class.java)
            context.startService(intent)
        }

        fun stop() {
            instance?.let { svc ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    svc.stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    svc.stopForeground(true)
                }
                svc.stopSelf()
            }
            instance = null
            currentName = null
            currentReceived = 0
            currentTotal = -1
        }

        /**
         * Updates the row. [name] null = waiting for a file (progress bar
         * hidden); throttled to one notify per second so a fast LAN feed
         * cannot spam the notification manager.
         */
        fun update(name: String?, received: Long, total: Long) {
            val svc = instance ?: return
            val now = System.currentTimeMillis()
            if (now - lastUpdateMs < UPDATE_INTERVAL_MS && name != null) return
            lastUpdateMs = now
            currentName = name
            currentReceived = received
            currentTotal = total
            val nm = svc.getSystemService(NotificationManager::class.java) ?: return
            nm.notify(NOTIF_ID, svc.buildNotification(name, received, total))
        }

        private var lastUpdateMs = 0L
        private const val UPDATE_INTERVAL_MS = 1000L
    }
}