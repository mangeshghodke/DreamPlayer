package com.dreamplayer.app

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Alternate launcher icon switch (issue #23).
 *
 * Android has no runtime "set icon" API. The mechanism is a set of
 * `activity-alias` entries that target [MainActivity] but carry a different
 * `android:icon`, toggled with
 * `PackageManager.setComponentEnabledSetting()`.
 *
 * ## Why this cannot brick the app
 *
 * **NEVER disable MainActivity.** Every alias declares
 * `android:targetActivity=".MainActivity"`, and an alias whose target is
 * disabled CANNOT BE LAUNCHED: the icon stays on the launcher but tapping it
 * opens App info instead of the app. That is not theoretical, it is exactly
 * what the first version of this did, and it shipped a dead icon on a real
 * device.
 *
 * So the launcher icon is owned entirely by the aliases, and MainActivity
 * carries no MAIN/LAUNCHER filter at all. MainActivity stays enabled forever,
 * which keeps it a valid alias target and keeps "Open with" resolving.
 *
 * The second rule is ordering: **enable the new alias BEFORE disabling the
 * others**. A brief moment with two icons is harmless; a moment with none is
 * unrecoverable without adb.
 */
class IconSwitcher(private val context: Context) {

    companion object {
        const val CHANNEL = "dreamplayer/appicon"

        const val DEFAULT = "default"
        private const val PKG = "com.dreamplayer.app"

        /**
         * Variant name -> activity-alias suffix. Mirrors the Dart enum.
         *
         * NOTE there is no entry mapping to the bare MainActivity: the default
         * icon has its own alias (`MainActivityAltDefault`) so that exactly one
         * ALIAS is always enabled. MainActivity is never a toggle target.
         */
        private val VARIANTS = mapOf(
            DEFAULT to "Default",
            "mark" to "Mark",
            "red" to "Red",
            "green" to "Green",
            "cyan" to "Cyan",
        )
    }

    /** Which variant the launcher is currently showing. */
    fun currentVariant(): String {
        // Default wins if somehow two are enabled: it is the safe, always
        // present, always correct option.
        if (isEnabled(component(DEFAULT))) return DEFAULT
        return VARIANTS.keys.firstOrNull { it != DEFAULT && isEnabled(component(it)) } ?: DEFAULT
    }

    /**
     * @param variant one of [VARIANTS]'s keys.
     * @return true when the requested variant ended up active.
     */
    fun applyVariant(variant: String): Boolean {
        val target = component(variant)
        enable(target)
        // Disable every other variant, default included, so exactly one icon
        // is ever on the launcher.
        VARIANTS.keys.filter { it != variant }.forEach { disable(component(it)) }
        // Re-assert the target: if the process died between the two calls above
        // the default would have been left disabled alongside it.
        enable(target)
        return currentVariant() == variant
    }

    /**
     * Self-heal, run on every launch before the UI can ask for anything.
     *
     * Two repairs, both needed in practice:
     *
     * 1. **Re-enable MainActivity.** An early version of this feature disabled
     *    it, which bricked the launcher on a real device. Any install that ran
     *    that build still has it stuck in PackageManager's disabled-components
     *    list, and that state survives an APK update — so it has to be undone
     *    here or "Open with" keeps resolving through an alias instead of the
     *    real activity.
     * 2. **Guarantee a launcher entry.** If an interrupted toggle somehow left
     *    no alias enabled, re-enable the default so the app is still reachable.
     */
    fun ensureLaunchable() {
        enable(componentMain())
        if (VARIANTS.keys.none { isEnabled(component(it)) }) {
            enable(component(DEFAULT))
        }
    }

    private fun componentMain(): String = "$PKG.MainActivity"

    private fun component(variant: String): String =
        PKG + ".MainActivityAlt" + (VARIANTS[variant] ?: VARIANTS.getValue(DEFAULT))

    private fun isEnabled(component: String): Boolean =
        try {
            context.packageManager.getComponentEnabledSetting(ComponentName(context, component)) !=
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        } catch (_: Exception) {
            // Unknown component (install predating the aliases). Only the
            // default can be assumed present.
            component == component(DEFAULT)
        }

    private fun enable(component: String) = setState(component, PackageManager.COMPONENT_ENABLED_STATE_ENABLED)

    private fun disable(component: String) = setState(component, PackageManager.COMPONENT_ENABLED_STATE_DISABLED)

    private fun setState(component: String, state: Int) {
        try {
            context.packageManager.setComponentEnabledSetting(
                ComponentName(context, component),
                state,
                PackageManager.DONT_KILL_APP,
            )
        } catch (_: Exception) {
            // Nothing useful to do here; ensureLaunchable() covers the
            // dangerous case (nothing enabled).
        }
    }

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "currentVariant" -> result.success(currentVariant())
            "applyVariant" -> {
                val variant = call.argument<String>("variant") ?: DEFAULT
                if (!VARIANTS.containsKey(variant)) {
                    result.error("bad_variant", "Unknown icon variant: $variant", null)
                } else {
                    result.success(applyVariant(variant))
                }
            }
            else -> result.notImplemented()
        }
    }
}