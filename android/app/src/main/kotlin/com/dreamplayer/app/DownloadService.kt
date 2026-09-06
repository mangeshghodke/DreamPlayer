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

class DownloadService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var cancelReceiver: BroadcastReceiver? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "DreamPlayer"
        val totalBytes = intent?.getLongExtra(EXTRA_TOTAL_BYTES, -1L) ?: -1L
        currentJobId = intent?.getStringExtra(EXTRA_JOB_ID) ?: ""
        ensureChannel()
        val notification = buildNotification(title, 0, totalBytes)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
        registerCancelReceiver()
        acquireWakeLock()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        unregisterCancelReceiver()
        releaseWakeLock()
        instance = null
        currentJobId = ""
        super.onDestroy()
    }

    // -- Cancel broadcast receiver --

    private fun registerCancelReceiver() {
        cancelReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == ACTION_CANCEL) {
                    val jobId = intent.getStringExtra(EXTRA_JOB_ID) ?: return
                    cancelCallback?.invoke(jobId)
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
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dreamplayer:download").apply {
                acquire(60 * 60 * 1000L)
            }
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    // -- Notification --

    private fun buildNotification(title: String, bytesCopied: Long, totalBytes: Long): Notification {
        val text = if (totalBytes > 0) {
            "${formatSize(bytesCopied)} / ${formatSize(totalBytes)}"
        } else {
            "Downloading\u2026"
        }

        val cancelIntent = Intent(ACTION_CANCEL).apply {
            putExtra(EXTRA_JOB_ID, currentJobId)
            setPackage(packageName)
        }
        val cancelPendingIntent = PendingIntent.getBroadcast(
            this,
            NOTIF_ID,
            cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_play)
            .setContentTitle("Downloading: $title")
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(R.drawable.ic_stat_cancel, "Cancel", cancelPendingIntent)
            .apply {
                if (totalBytes > 0) {
                    setProgress(totalBytes.toInt(), bytesCopied.toInt(), false)
                } else {
                    setProgress(0, 0, true)
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
                "Downloads",
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
        const val CHANNEL_ID = "dreamplayer_download"
        const val NOTIF_ID = 4211
        const val EXTRA_TITLE = "title"
        const val EXTRA_TOTAL_BYTES = "totalBytes"
        const val EXTRA_JOB_ID = "jobId"
        const val ACTION_CANCEL = "com.dreamplayer.app.DOWNLOAD_CANCEL"

        private var instance: DownloadService? = null
        var currentJobId: String = ""
            private set

        /** Set by DownloadClient to bridge notification Cancel taps to Dart. */
        var cancelCallback: ((String) -> Unit)? = null

        fun updateNotification(title: String, bytesCopied: Long, totalBytes: Long) {
            val svc = instance ?: return
            val nm = svc.getSystemService(NotificationManager::class.java) ?: return
            nm.notify(NOTIF_ID, svc.buildNotification(title, bytesCopied, totalBytes))
        }

        fun stop() {
            val svc = instance ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                svc.stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                svc.stopForeground(true)
            }
            svc.stopSelf()
            instance = null
            currentJobId = ""
        }
    }
}
