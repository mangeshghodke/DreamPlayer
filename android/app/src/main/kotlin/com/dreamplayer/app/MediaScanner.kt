package com.dreamplayer.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.MethodChannel

/// Queries the system MediaStore for every video file and pushes the results
/// to Dart via a MethodChannel.  No background service — the scan runs on
/// a daemon thread and delivers a single batch on completion.
class MediaScanner(private val context: Context) {

    companion object {
        const val CHANNEL = "dreamplayer/media_scanner"
    }

    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun configure(ch: MethodChannel) {
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "scanAll" -> scanAll(result)
                else -> result.notImplemented()
            }
        }
    }

    /// Scans MediaStore for all videos and returns a List<Map> to Dart.
    private fun scanAll(result: MethodChannel.Result) {
        Thread {
            try {
                val videos = queryMediaStore()
                mainHandler.post { result.success(videos) }
            } catch (e: Exception) {
                mainHandler.post { result.error("scan_error", e.message, null) }
            }
        }.start()
    }

    private fun queryMediaStore(): List<Map<String, Any?>> {
        val videos = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DATA,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.WIDTH,
            MediaStore.Video.Media.HEIGHT,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.DATE_ADDED,
            MediaStore.Video.Media.MIME_TYPE,
        )
        val selection = "${MediaStore.Video.Media.MIME_TYPE} LIKE ?"
        val selectionArgs = arrayOf("video/%")
        val sortOrder = "${MediaStore.Video.Media.DATE_ADDED} DESC"

        context.contentResolver.query(
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            sortOrder,
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
            val pathCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DATA)
            val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DISPLAY_NAME)
            val durationCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DURATION)
            val widthCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.WIDTH)
            val heightCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.HEIGHT)
            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.SIZE)
            val dateCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DATE_ADDED)
            val mimeCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.MIME_TYPE)

            while (cursor.moveToNext()) {
                val path = cursor.getString(pathCol) ?: continue
                // Skip hidden files / directories
                val name = cursor.getString(nameCol) ?: continue
                if (name.startsWith(".")) continue

                val title = name.substringBeforeLast('.', name)
                videos.add(
                    mapOf(
                        "id" to cursor.getLong(idCol),
                        "path" to path,
                        "title" to title,
                        "duration" to cursor.getInt(durationCol),
                        "width" to cursor.getInt(widthCol),
                        "height" to cursor.getInt(heightCol),
                        "sizeBytes" to cursor.getLong(sizeCol),
                        "dateAdded" to cursor.getInt(dateCol),
                        "mimeType" to (cursor.getString(mimeCol) ?: ""),
                    ),
                )
            }
        }
        return videos
    }
}
