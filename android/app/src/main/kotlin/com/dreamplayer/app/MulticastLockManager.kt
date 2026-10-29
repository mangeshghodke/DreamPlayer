package com.dreamplayer.app

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.util.Locale
import org.json.JSONObject

/// Wi-Fi MulticastLock + the Jellyfin/Emby UDP-7359 broadcast probe.
///
/// The lock lets the Dart-side mDNS scan (multicast_dns) actually receive
/// multicast on Android; without it the Wi-Fi driver silently drops multicast
/// frames. The probe is Jellyfin's proprietary discovery protocol
/// ("who is JellyfinServer?" → JSON {"Address","Id","Name"} on port 7359) —
/// modern Jellyfin ships NO mDNS responder, so this broadcast is the only
/// LAN scan that finds it.
class MulticastLockManager(private val context: Context) {

    private companion object {
        const val TAG = "JellyfinProbe"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var lock: WifiManager.MulticastLock? = null

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    acquire()
                    result.success(true)
                }
                "release" -> {
                    release()
                    result.success(true)
                }
                "discoverJellyfin" -> {
                    // Socket I/O must not touch the platform main thread.
                    Thread {
                        val servers = discoverJellyfin()
                        mainHandler.post { result.success(servers) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Broadcasts "who is JellyfinServer?" on UDP 7359 and returns every
    /// server that answers: [{address, port, name, id}].
    private fun discoverJellyfin(): List<Map<String, Any>> {
        val results = mutableListOf<Map<String, Any>>()
        try {
            val socket = DatagramSocket()
            socket.broadcast = true
            socket.soTimeout = 3000
            val message = "who is JellyfinServer?".toByteArray(Charsets.UTF_8)
            val targets = linkedSetOf("255.255.255.255")
            wifiBroadcastAddress()?.let { targets.add(it) }
            Log.d(TAG, "discoverJellyfin: sending to $targets")
            for (target in targets) {
                try {
                    socket.send(
                        DatagramPacket(message, message.size, InetAddress.getByName(target), 7359),
                    )
                    Log.d(TAG, "sent probe to $target:7359")
                } catch (e: Exception) {
                    Log.e(TAG, "send to $target failed: $e")
                }
            }
            val deadline = System.currentTimeMillis() + 3000
            while (System.currentTimeMillis() < deadline) {
                val buffer = ByteArray(4096)
                val packet = DatagramPacket(buffer, buffer.size)
                socket.receive(packet)
                val body =
                    String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
                Log.d(TAG, "probe response from ${packet.address}: $body")
                try {
                    val json = JSONObject(body)
                    val address = json.optString("Address", "")
                    if (address.isEmpty()) continue
                    results.add(
                        mapOf(
                            "address" to address,
                            "name" to (json.optString("Name", address)),
                            "id" to json.optString("Id", ""),
                        ),
                    )
                } catch (e: Exception) {
                    Log.e(TAG, "unparseable response: $e")
                }
            }
            socket.close()
        } catch (_: SocketTimeoutException) {
        } catch (e: Exception) {
            Log.e(TAG, "discoverJellyfin failed: $e")
        }
        Log.d(TAG, "discoverJellyfin done: ${results.size} server(s)")
        return results
    }

    /// Subnet-directed broadcast (192.168.x.255) from the current Wi-Fi IP,
    /// or null when Wi-Fi is unavailable. Home-net /24 assumed.
    private fun wifiBroadcastAddress(): String? = try {
        val wifi =
            context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val ip = wifi.connectionInfo?.ipAddress ?: return null
        ipToString(ip or 0x000000FF)
    } catch (_: Exception) {
        null
    }

    private fun ipToString(ip: Int): String =
        String.format(
            Locale.US,
            "%d.%d.%d.%d",
            ip and 0xFF,
            ip shr 8 and 0xFF,
            ip shr 16 and 0xFF,
            ip shr 24 and 0xFF,
        )

    private fun acquire() {
        if (lock != null) return
        try {
            val manager =
                context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            lock = manager.createMulticastLock("dreamplayer:mdns").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
            // Wi-Fi may be off; the scan will simply find nothing.
        }
    }

    private fun release() {
        try {
            lock?.release()
        } catch (_: Exception) {
        }
        lock = null
    }
}
