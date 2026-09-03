package com.dreamplayer.app

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.net.URLDecoder
import java.util.concurrent.Executors

class MediaProbe(private val context: Context) {
    companion object {
        const val CHANNEL = "dreamplayer/mediaProbe"
        private const val TAG = "MediaProbe"
    }

    private val executor = Executors.newSingleThreadExecutor()

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "probe" -> {
                    val path = call.argument<String>("path")
                    val uri = call.argument<String>("uri")
                    @Suppress("UNCHECKED_CAST")
                    val headers = call.argument<Map<String, String>>("headers")
                    val allowSelfSigned = call.argument<Boolean>("allowSelfSigned") ?: false
                    executor.execute {
                        try {
                            val info = probe(path, uri, headers, allowSelfSigned)
                            result.success(info)
                        } catch (e: Exception) {
                            Log.e(TAG, "probe failed", e)
                            result.error("probe_failed", e.message, null)
                        }
                    }
                }
                "probeFile" -> {
                    // Probe a local temp file (used for FTP/SFTP where MediaExtractor
                    // can't open the URI directly — Dart downloads a prefix to temp).
                    val filePath = call.argument<String>("filePath")
                    executor.execute {
                        try {
                            val info = probeLocal(filePath)
                            result.success(info)
                        } catch (e: Exception) {
                            Log.e(TAG, "probeFile failed", e)
                            result.error("probe_failed", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isLocalPath(s: String): Boolean =
        !s.startsWith("content://") && !s.startsWith("http://") && !s.startsWith("https://") &&
        !s.startsWith("smb://") && !s.startsWith("ftp://") && !s.startsWith("ftps://") &&
        !s.startsWith("sftp://") && !s.startsWith("webdav://") && !s.startsWith("webdavs://")

    private fun probeSmb(smbUri: String): Map<String, Any?> {
        val stripped = smbUri.removePrefix("smb://")
        val parts = stripped.split("/", limit = 3)
        if (parts.size < 3) { Log.w(TAG, "probeSmb: bad URI parts=$parts"); return emptyMap() }
        val serverId = parts[0]
        val share = parts[1]
        val path = URLDecoder.decode(parts[2], "UTF-8")
        Log.d(TAG, "probeSmb serverId=$serverId share=$share path=$path")
        val httpUrl = SmbHttpProxy.start(context, serverId, share, path)
        if (httpUrl == null) { Log.w(TAG, "probeSmb: SmbHttpProxy.start returned null"); return emptyMap() }
        Log.d(TAG, "probeSmb httpUrl=$httpUrl")
        try {
            return probeHttp(httpUrl, null)
        } finally {
            val token = httpUrl.substringAfterLast("/")
            SmbHttpProxy.stop(token)
        }
    }

    private fun probeHttp(url: String, headers: Map<String, String>?): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>()
        val hdrs = headers ?: hashMapOf<String, String>()

        var retriever: MediaMetadataRetriever? = null
        try {
            retriever = MediaMetadataRetriever()
            retriever.setDataSource(url, hdrs)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.let { out["durationMs"] = it }
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()?.let { out["width"] = it }
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()?.let { out["height"] = it }
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)?.let { out["hasAudio"] = it }
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toLongOrNull()?.let { out["bitrate"] = it }
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)?.let { out["mime"] = it }
            Log.d(TAG, "probeHttp retriever OK: dur=${out["durationMs"]} w=${out["width"]} h=${out["height"]}")
        } catch (e: Exception) {
            Log.w(TAG, "probeHttp retriever failed: ${e.message}")
        } finally {
            try { retriever?.release() } catch (_: Exception) {}
        }

        var extractor: MediaExtractor? = null
        try {
            extractor = MediaExtractor()
            extractor.setDataSource(url, hdrs)
            Log.d(TAG, "probeHttp extractor tracks=${extractor.trackCount}")
            for (i in 0 until extractor.trackCount) {
                try {
                    val format = extractor.getTrackFormat(i)
                    val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                    if (mime.startsWith("video/")) {
                        if (!out.containsKey("width")) {
                            try { out["width"] = format.getInteger(MediaFormat.KEY_WIDTH) } catch (_: Exception) {}
                        }
                        if (!out.containsKey("height")) {
                            try { out["height"] = format.getInteger(MediaFormat.KEY_HEIGHT) } catch (_: Exception) {}
                        }
                        try { out["videoMime"] = mime } catch (_: Exception) {}
                        try { out["fps"] = format.getInteger(MediaFormat.KEY_FRAME_RATE) } catch (_: Exception) {}
                        try {
                            val durUs = format.getLong(MediaFormat.KEY_DURATION)
                            if (!out.containsKey("durationMs")) out["durationMs"] = durUs / 1000
                        } catch (_: Exception) {}
                    } else if (mime.startsWith("audio/")) {
                        try { out["audioMime"] = mime } catch (_: Exception) {}
                        try { out["audioChannels"] = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) } catch (_: Exception) {}
                        try {
                            val lang = format.getString(MediaFormat.KEY_LANGUAGE)
                            if (!lang.isNullOrEmpty() && lang != "und") out["audioLanguage"] = lang
                        } catch (_: Exception) {}
                        try {
                            val durUs = format.getLong(MediaFormat.KEY_DURATION)
                            if (!out.containsKey("durationMs")) out["durationMs"] = durUs / 1000
                        } catch (_: Exception) {}
                    }
                } catch (_: Exception) {}
            }
        } catch (e: Exception) {
            Log.w(TAG, "probeHttp extractor failed: ${e.message}")
        } finally {
            try { extractor?.release() } catch (_: Exception) {}
        }
        Log.d(TAG, "probeHttp final result: $out")
        return out
    }

    private fun probeLocal(filePath: String?): Map<String, Any?> {
        if (filePath.isNullOrEmpty()) return emptyMap()
        val out = mutableMapOf<String, Any?>()

        var retriever: MediaMetadataRetriever? = null
        try {
            retriever = MediaMetadataRetriever()
            retriever.setDataSource(filePath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.let { out["durationMs"] = it }
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()?.let { out["width"] = it }
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()?.let { out["height"] = it }
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)?.let { out["hasAudio"] = it }
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toLongOrNull()?.let { out["bitrate"] = it }
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)?.let { out["mime"] = it }
        } catch (_: Exception) {
        } finally {
            try { retriever?.release() } catch (_: Exception) {}
        }

        var extractor: MediaExtractor? = null
        try {
            extractor = MediaExtractor()
            extractor.setDataSource(filePath)
            for (i in 0 until extractor.trackCount) {
                try {
                    val format = extractor.getTrackFormat(i)
                    val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                    if (mime.startsWith("video/")) {
                        if (!out.containsKey("width")) {
                            try { out["width"] = format.getInteger(MediaFormat.KEY_WIDTH) } catch (_: Exception) {}
                        }
                        if (!out.containsKey("height")) {
                            try { out["height"] = format.getInteger(MediaFormat.KEY_HEIGHT) } catch (_: Exception) {}
                        }
                        try { out["videoMime"] = mime } catch (_: Exception) {}
                        try { out["fps"] = format.getInteger(MediaFormat.KEY_FRAME_RATE) } catch (_: Exception) {}
                        try {
                            val durUs = format.getLong(MediaFormat.KEY_DURATION)
                            if (!out.containsKey("durationMs")) out["durationMs"] = durUs / 1000
                        } catch (_: Exception) {}
                    } else if (mime.startsWith("audio/")) {
                        try { out["audioMime"] = mime } catch (_: Exception) {}
                        try { out["audioChannels"] = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) } catch (_: Exception) {}
                        try {
                            val lang = format.getString(MediaFormat.KEY_LANGUAGE)
                            if (!lang.isNullOrEmpty() && lang != "und") out["audioLanguage"] = lang
                        } catch (_: Exception) {}
                        try {
                            val durUs = format.getLong(MediaFormat.KEY_DURATION)
                            if (!out.containsKey("durationMs")) out["durationMs"] = durUs / 1000
                        } catch (_: Exception) {}
                    }
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {
        } finally {
            try { extractor?.release() } catch (_: Exception) {}
        }
        return out
    }

    private fun probe(path: String?, uri: String?, headers: Map<String, String>?, allowSelfSigned: Boolean): Map<String, Any?> {
        // smb:// URIs → temporary HTTP loopback
        val smbUri = when {
            !uri.isNullOrEmpty() && uri.startsWith("smb://") -> uri
            !path.isNullOrEmpty() && path.startsWith("smb://") -> path
            else -> null
        }
        if (smbUri != null) return probeSmb(smbUri)

        // HTTP/HTTPS source
        val httpUri = when {
            !uri.isNullOrEmpty() && (uri.startsWith("http://") || uri.startsWith("https://")) -> uri
            !path.isNullOrEmpty() && (path.startsWith("http://") || path.startsWith("https://")) -> path
            else -> null
        }
        if (httpUri != null) return probeHttp(httpUri, headers)

        // Local or content:// source
        val localPath = if (!path.isNullOrEmpty() && isLocalPath(path)) path else null
        val contentUri = if (!uri.isNullOrEmpty() && uri.startsWith("content://")) uri else null
        Log.d(TAG, "probe path=$path uri=$uri localPath=$localPath contentUri=$contentUri")
        val out = mutableMapOf<String, Any?>()

        var retriever: MediaMetadataRetriever? = null
        try {
            retriever = MediaMetadataRetriever()
            when {
                localPath != null -> retriever.setDataSource(localPath)
                contentUri != null -> {
                    try {
                        context.contentResolver.openFileDescriptor(Uri.parse(contentUri), "r")?.use { pfd ->
                            retriever.setDataSource(pfd.fileDescriptor)
                        }
                    } catch (_: Exception) {
                        retriever.setDataSource(contentUri, hashMapOf<String, String>())
                    }
                }
                else -> { retriever.release(); retriever = null }
            }
            if (retriever != null) {
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.let { out["durationMs"] = it }
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()?.let { out["width"] = it }
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()?.let { out["height"] = it }
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)?.let { out["hasAudio"] = it }
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toLongOrNull()?.let { out["bitrate"] = it }
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)?.let { out["mime"] = it }
            }
        } catch (_: Exception) {
        } finally {
            try { retriever?.release() } catch (_: Exception) {}
        }

        var extractor: MediaExtractor? = null
        try {
            extractor = MediaExtractor()
            var set = false
            try {
                when {
                    localPath != null -> { extractor.setDataSource(localPath); set = true }
                    contentUri != null -> {
                        context.contentResolver.openFileDescriptor(Uri.parse(contentUri), "r")?.use { pfd ->
                            extractor.setDataSource(pfd.fileDescriptor); set = true
                        }
                    }
                }
            } catch (_: Exception) {}

            if (set) {
                for (i in 0 until extractor.trackCount) {
                    try {
                        val format = extractor.getTrackFormat(i)
                        val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                        if (mime.startsWith("video/")) {
                            if (!out.containsKey("width")) {
                                try { out["width"] = format.getInteger(MediaFormat.KEY_WIDTH) } catch (_: Exception) {}
                            }
                            if (!out.containsKey("height")) {
                                try { out["height"] = format.getInteger(MediaFormat.KEY_HEIGHT) } catch (_: Exception) {}
                            }
                            try { out["videoMime"] = mime } catch (_: Exception) {}
                            try { out["fps"] = format.getInteger(MediaFormat.KEY_FRAME_RATE) } catch (_: Exception) {}
                            try {
                                val durUs = format.getLong(MediaFormat.KEY_DURATION)
                                if (!out.containsKey("durationMs")) out["durationMs"] = durUs / 1000
                            } catch (_: Exception) {}
                        } else if (mime.startsWith("audio/")) {
                            try { out["audioMime"] = mime } catch (_: Exception) {}
                            try { out["audioChannels"] = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) } catch (_: Exception) {}
                            try {
                                val lang = format.getString(MediaFormat.KEY_LANGUAGE)
                                if (!lang.isNullOrEmpty() && lang != "und") out["audioLanguage"] = lang
                            } catch (_: Exception) {}
                            try {
                                val durUs = format.getLong(MediaFormat.KEY_DURATION)
                                if (!out.containsKey("durationMs")) out["durationMs"] = durUs / 1000
                            } catch (_: Exception) {}
                        }
                    } catch (_: Exception) {}
                }
            }
        } catch (_: Exception) {
        } finally {
            try { extractor?.release() } catch (_: Exception) {}
        }
        Log.d(TAG, "probe result: $out")
        return out
    }
}
