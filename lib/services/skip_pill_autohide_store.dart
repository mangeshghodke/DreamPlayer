import 'package:shared_preferences/shared_preferences.dart';

/// Settings → Player → "Auto-hide skip button after 5 s" (issue #68).
///
/// Default ON keeps the 2026-11-16 behavior: the skip pill hides 5 s after
/// the playhead ENTERS an intro/recap/credits segment. OFF keeps the pill
/// visible for the whole segment (Netflix/Prime-style), which is what the
/// #68 reporter asked for - auto-hiding made the one-tap skip easy to miss.
class SkipPillAutoHideStore {
  SkipPillAutoHideStore._();

  static const String prefsKey = 'dreamplayer.skipPillAutoHide';

  static Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefsKey) ?? true;
  }

  static Future<void> save(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, enabled);
  }
}
