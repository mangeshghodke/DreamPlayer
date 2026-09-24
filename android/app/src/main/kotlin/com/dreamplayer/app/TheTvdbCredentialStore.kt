package com.dreamplayer.app

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.plugin.common.MethodChannel

class TheTvdbCredentialStore(private val context: Context) {
    companion object {
        const val CHANNEL = "dreamplayer/the_tvdb_credentials"
        private const val PREFS = "dreamplayer.theTvdbSecrets"
        private const val API_KEY = "apiKey"
        private const val PIN = "pin"
        private const val LEGACY_PREFS = "FlutterSharedPreferences"
        private const val LEGACY_API_KEY = "dreamplayer.theTvdbApiKey"
        private const val LEGACY_PIN = "dreamplayer.theTvdbPin"
    }

    private val secrets by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            PREFS,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun configure(channel: MethodChannel) {
        migrateLegacy()
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "read" -> result.success(
                        mapOf(
                            "apiKey" to secrets.getString(API_KEY, null),
                            "pin" to secrets.getString(PIN, null),
                        ),
                    )
                    "write" -> {
                        val args = call.arguments as? Map<*, *>
                        val apiKey = args?.get("apiKey") as? String
                        val pin = args?.get("pin") as? String
                        val editor = secrets.edit()
                        if (apiKey.isNullOrBlank()) {
                            editor.remove(API_KEY)
                        } else {
                            editor.putString(API_KEY, apiKey.trim())
                        }
                        if (pin.isNullOrBlank()) {
                            editor.remove(PIN)
                        } else {
                            editor.putString(PIN, pin.trim())
                        }
                        editor.apply()
                        result.success(null)
                    }
                    "clear" -> {
                        secrets.edit().remove(API_KEY).remove(PIN).apply()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("credential_store", error.message, null)
            }
        }
    }

    private fun migrateLegacy() {
        try {
            val legacy = context.getSharedPreferences(LEGACY_PREFS, Context.MODE_PRIVATE)
            val legacyKey = legacy.getString(LEGACY_API_KEY, null)
            if (legacyKey.isNullOrBlank()) return
            val editor = secrets.edit()
            if (secrets.getString(API_KEY, null).isNullOrBlank()) {
                editor.putString(API_KEY, legacyKey.trim())
            }
            val legacyPin = legacy.getString(LEGACY_PIN, null)
            if (secrets.getString(PIN, null).isNullOrBlank() && !legacyPin.isNullOrBlank()) {
                editor.putString(PIN, legacyPin.trim())
            }
            if (editor.commit()) {
                legacy.edit().remove(LEGACY_API_KEY).remove(LEGACY_PIN).apply()
            }
        } catch (_: Exception) {
        }
    }
}
