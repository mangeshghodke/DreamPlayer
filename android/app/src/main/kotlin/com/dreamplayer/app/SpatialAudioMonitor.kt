package com.dreamplayer.app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.Spatializer
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executor

class SpatialAudioMonitor(
    private val context: Context,
    private val onChanged: (String) -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executor { command -> command.run() }
    private var channels = 0
    private var sampleRate = 0
    private var pcm = true
    private var registered = false
    private var lastEmitted: String? = null

    private val listener: Spatializer.OnSpatializerStateChangedListener? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            object : Spatializer.OnSpatializerStateChangedListener {
                override fun onSpatializerEnabledChanged(
                    spatializer: Spatializer,
                    enabled: Boolean,
                ) {
                    emit()
                }

                override fun onSpatializerAvailableChanged(
                    spatializer: Spatializer,
                    available: Boolean,
                ) {
                    emit()
                }
            }
        } else {
            null
        }

    fun update(channels: Int, sampleRate: Int, pcm: Boolean): String {
        this.channels = channels
        this.sampleRate = sampleRate
        this.pcm = pcm
        register()
        return status()
    }

    fun clear() {
        channels = 0
        sampleRate = 0
        pcm = true
        lastEmitted = null
        unregister()
    }

    fun close() {
        clear()
    }

    fun status(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return "unavailable"
        if (!pcm || channels <= 0) return "unavailable"
        return try {
            val spatializer = context.getSystemService(AudioManager::class.java).spatializer
            when {
                !spatializer.isAvailable -> "unavailable"
                !spatializer.isEnabled || channels <= 2 -> "available"
                canBeSpatialized(spatializer, channels, sampleRate) -> "on"
                else -> "available"
            }
        } catch (_: Exception) {
            "unavailable"
        }
    }

    private fun canBeSpatialized(
        spatializer: Spatializer,
        channels: Int,
        sampleRate: Int,
    ): Boolean {
        val channelMask = when {
            channels >= 8 -> AudioFormat.CHANNEL_OUT_7POINT1_SURROUND
            channels >= 6 -> AudioFormat.CHANNEL_OUT_5POINT1
            channels == 1 -> AudioFormat.CHANNEL_OUT_MONO
            else -> AudioFormat.CHANNEL_OUT_STEREO
        }
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(if (sampleRate > 0) sampleRate else 48_000)
            .setChannelMask(channelMask)
            .build()
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
            .build()
        return spatializer.canBeSpatialized(attributes, format)
    }

    private fun register() {
        if (registered || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        try {
            val spatializer = context.getSystemService(AudioManager::class.java).spatializer
            listener?.let {
                spatializer.addOnSpatializerStateChangedListener(executor, it)
                registered = true
            }
        } catch (_: Exception) {
            registered = false
        }
    }

    private fun unregister() {
        if (!registered || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        try {
            val spatializer = context.getSystemService(AudioManager::class.java).spatializer
            listener?.let { spatializer.removeOnSpatializerStateChangedListener(it) }
        } catch (_: Exception) {
        } finally {
            registered = false
        }
    }

    private fun emit() {
        handler.post {
            val value = status()
            if (value != lastEmitted) {
                lastEmitted = value
                onChanged(value)
            }
        }
    }
}
