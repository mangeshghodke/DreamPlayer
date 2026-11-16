package com.dreamplayer.app

import android.content.Context
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Clears the app's on-disk cache (`context.cacheDir`) on demand - the UTF-8
/// subtitle re-encode temp files (`dreamplayer_sub_*.utf8`) and anything else
/// the engine wrote there. Android may purge this directory at any time, so it
/// is always safe to delete; ExoPlayer keeps no disk cache of its own. The
/// in-memory image cache (TMDB posters/backdrops/stills) lives in Flutter and
/// is cleared from Dart (`CacheCleaner.clearMemoryImages`).
class CacheCleaner(private val context: Context) {

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "size" -> result.success(cacheSizeBytes())
                "clear" -> result.success(clearCacheBytes())
                else -> result.notImplemented()
            }
        }
    }

    private fun cacheDir(): File = context.cacheDir

    private fun cacheSizeBytes(): Long =
        cacheDir().walkBottomUp().filter { it.isFile }.sumOf { it.length() }

    private fun clearCacheBytes(): Long {
        var freed = 0L
        for (file in cacheDir().walkBottomUp()) {
            if (file.isFile) {
                freed += file.length()
                file.delete()
            } else if (file != cacheDir()) {
                file.delete()
            }
        }
        return freed
    }
}
