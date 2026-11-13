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

        /// The variant used when nothing else is enabled and as the repair
        /// target in [ensureLaunchable]. Since 0.5.7 the DEFAULT LAUNCHER
        /// ICON IS THE MARK (logo only); the logo + wordmark ("default") is a
        /// regular selectable alternate.
        const val FALLBACK = "mark"
        private const val PKG = "com.dreamplayer.app"

        /** One-time migration flag: move installs that still show the old
         *  wordmark default over to the mark, once per install. */
        private const val MIGRATED_PREFS = "dreamplayer_icon"
        private const val MIGRATED_KEY = "migratedToMarkDefault"

        /**
         * Variant name -> activity-alias suffix. Mirrors the Dart enum.
         *
         * NOTE there is no entry mapping to the bare MainActivity: every icon
         * has its own alias (`MainActivityAltDefault` for the wordmark,
         * `MainActivityAltMark` for the logo only) so that exactly one ALIAS is
         * always enabled. MainActivity is never a toggle target.
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
        // The fallback wins if somehow two are enabled: it is the safe,
        // always present, always correct option.
        if (isEnabled(component(FALLBACK))) return FALLBACK
        return VARIANTS.keys.firstOrNull { it != FALLBACK && isEnabled(component(it)) } ?: FALLBACK
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
     * Repairs, all needed in practice:
     *
     * 1. **Re-enable MainActivity.** An early version of this feature disabled
     *    it, which bricked the launcher on a real device. Any install that ran
     *    that build still has it stuck in PackageManager's disabled-components
     *    list, and that state survives an APK update — so it has to be undone
     *    here or "Open with" keeps resolving through an alias instead of the
     *    real activity.
     * 2. **Guarantee a launcher entry.** If an interrupted toggle somehow left
     *    no alias enabled, re-enable the fallback (mark) so the app is still
     *    reachable.
     * 3. **Migrate the old default icon once (0.5.7).** Installs that predate
     *    the change still have the wordmark alias (`AltDefault`) enabled. The
     *    default icon is now the mark, so move those installs over — unless
     *    the user had explicitly picked a recolour (red/green/cyan), which is
     *    left alone. Runs once per install, guarded by a prefs flag.
     */
    fun ensureLaunchable() {
        enable(componentMain())
        if (VARIANTS.keys.none { isEnabled(component(it)) }) {
            enable(component(FALLBACK))
        }
        migrateDefaultIconOnce()
    }

    private fun migrateDefaultIconOnce() {
        try {
            val prefs = context.getSharedPreferences(MIGRATED_PREFS, Context.MODE_PRIVATE)
            if (prefs.getBoolean(MIGRATED_KEY, false)) return
            prefs.edit().putBoolean(MIGRATED_KEY, true).apply()
            val current = currentVariant()
            // Only the old default moves; an explicit recolour choice is kept.
            if (current == DEFAULT) {
                applyVariant(FALLBACK)
            }
        } catch (_: Exception) {
            // A failed migration must never block launch; the manifest default
            // (mark enabled) covers fresh installs anyway.
        }
    }

    private fun componentMain(): String = "$PKG.MainActivity"

    private fun component(variant: String): String =
        PKG + ".MainActivityAlt" + (VARIANTS[variant] ?: VARIANTS.getValue(FALLBACK))

    private fun isEnabled(component: String): Boolean =
        try {
            context.packageManager.getComponentEnabledSetting(ComponentName(context, component)) !=
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        } catch (_: Exception) {
            // Unknown component (install predating the aliases). Only the
            // fallback (mark) can be assumed present.
            component == component(FALLBACK)
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
                val variant = call.argument<String>("variant") ?: FALLBACK
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