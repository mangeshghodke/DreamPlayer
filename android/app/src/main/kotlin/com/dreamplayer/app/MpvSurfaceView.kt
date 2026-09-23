package com.dreamplayer.app

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.lang.reflect.Method

/**
 * Hybrid-composition platform view that owns a single [SurfaceView] for the
 * libmpv engine. Distinct from `dreamplayer/exo_player` — the two views are
 * never mounted together (player_screen disposes Media3 before this attaches).
 *
 * On [surfaceCreated], creates a JNI global ref of the [android.view.Surface]
 * (via media_kit_libs' `MediaKitAndroidHelper`, same as media_kit's texture
 * path) and reports it to Dart as mpv `--wid`. Does NOT create a Flutter
 * texture — video is a real SurfaceFlinger layer.
 */
class MpvSurfaceViewFactory(
    private val activity: Activity,
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return MpvSurfaceView(activity, viewId, messenger)
    }
}

class MpvSurfaceView(
    private val activity: Activity,
    viewId: Int,
    messenger: BinaryMessenger,
) : PlatformView, SurfaceHolder.Callback {

    companion object {
        private const val TAG = "MpvSurfaceView"
        private var newGlobalObjectRef: Method? = null
        private var deleteGlobalObjectRef: Method? = null

        init {
            try {
                val clazz = Class.forName(
                    "com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper",
                )
                newGlobalObjectRef = clazz
                    .getDeclaredMethod("newGlobalObjectRef", Object::class.java)
                    .also { it.isAccessible = true }
                deleteGlobalObjectRef = clazz
                    .getDeclaredMethod(
                        "deleteGlobalObjectRef",
                        Long::class.javaPrimitiveType,
                    )
                    .also { it.isAccessible = true }
            } catch (e: Throwable) {
                Log.e(TAG, "MediaKitAndroidHelper not found", e)
            }
        }
    }

    // Media3 parity: never toggle SurfaceView visibility (GONE/VISIBLE churn
    // re-creates the surface, stacks layers, and flashes Flutter controls over
    // the gap). PlayerView only uses a shutter. FrameLayout is that shutter:
    //  - surface LIVE → transparent, or the opaque fill is composited into
    //    Flutter's hybrid buffer and covers the video punch-hole.
    //  - surface GONE → black, so the hole cannot reveal the details route.
    private val frameLayout = android.widget.FrameLayout(activity)
    private val surfaceView = SurfaceView(activity)
    private val channel = MethodChannel(messenger, "dreamplayer/mpv_$viewId")
    private var wid = 0L
    private var lastW = 0
    private var lastH = 0
    private var disposed = false
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        // Shutter until surfaceCreated proves video can punch through.
        frameLayout.setBackgroundColor(android.graphics.Color.BLACK)
        frameLayout.addView(
            surfaceView,
            android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        // Dual-SurfaceView window fix (same as ExoPlayerView): Flutter's own
        // surface + this video SurfaceView are two SurfaceViews in one window;
        // without media-overlay z-order the framework interposes an opaque
        // LayerDim between them and the rendered video is covered → black video
        // even though mpv decodes/presents (wid ok, decoder busies, no vo error).
        // NEVER setBackgroundColor on the SurfaceView itself — same punch-hole fill.
        surfaceView.setZOrderMediaOverlay(true)
        surfaceView.holder.addCallback(this)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getWid" -> result.success(wid)
                "getSize" -> result.success(
                    mapOf(
                        "width" to surfaceView.width,
                        "height" to surfaceView.height,
                    ),
                )
                else -> result.notImplemented()
            }
        }
    }

    override fun getView(): View = frameLayout

    override fun dispose() {
        if (disposed) return
        disposed = true
        surfaceView.holder.removeCallback(this)
        releaseWid(notifyDart = true)
        channel.setMethodCallHandler(null)
    }

    private fun releaseWid(notifyDart: Boolean) {
        if (wid == 0L) return
        val old = wid
        wid = 0L
        if (notifyDart) {
            try {
                channel.invokeMethod("surfaceLost", null)
            } catch (_: Throwable) {
            }
        }
        // Delay delete like media_kit VideoOutput — mpv may still hold the ref
        // for a moment after the surface goes away.
        mainHandler.postDelayed({
            try {
                deleteGlobalObjectRef?.invoke(null, old)
            } catch (e: Throwable) {
                Log.e(TAG, "deleteGlobalObjectRef failed", e)
            }
        }, 5000)
    }

    private fun createWid(surface: Any): Long {
        return try {
            (newGlobalObjectRef?.invoke(null, surface) as? Long) ?: 0L
        } catch (e: Throwable) {
            Log.e(TAG, "newGlobalObjectRef failed", e)
            0L
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        if (disposed) return
        wid = createWid(holder.surface)
        // Surface live — drop the shutter (black here covers the video hole).
        frameLayout.setBackgroundColor(android.graphics.Color.TRANSPARENT)
        val frame = holder.surfaceFrame
        val w = if (frame.width() > 0) frame.width() else surfaceView.width
        val h = if (frame.height() > 0) frame.height() else surfaceView.height
        lastW = w
        lastH = h
        try {
            channel.invokeMethod(
                "surfaceReady",
                mapOf("wid" to wid, "width" to w, "height" to h),
            )
        } catch (_: Throwable) {
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        if (disposed) return
        if (wid == 0L) {
            wid = createWid(holder.surface)
        }
        // Throttle: hybrid composition can fire surfaceChanged continuously
        // with same size; spamming Dart triggers repeated vo resets and
        // "Both surface and native_window are NULL" + black video.
        if (width == lastW && height == lastH && wid != 0L) return
        lastW = width
        lastH = height
        try {
            channel.invokeMethod(
                "surfaceChanged",
                mapOf("wid" to wid, "width" to width, "height" to height),
            )
        } catch (_: Throwable) {
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        // Shutter on — same as PlayerView.setShutterBackgroundColor(BLACK).
        // Do NOT set visibility GONE: that destroys/recreates the surface
        // (layer stack churn) and leaves a hole that shows the details route.
        frameLayout.setBackgroundColor(android.graphics.Color.BLACK)
        releaseWid(notifyDart = true)
    }
}
