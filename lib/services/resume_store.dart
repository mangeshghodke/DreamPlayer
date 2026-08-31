import 'package:shared_preferences/shared_preferences.dart';

/// Persists per-video playback positions so a video stopped mid-way can be
/// resumed from where it left off on the next open.
///
/// Keyed by a stable source identifier (file path, content URI, or an explicit
/// `resumeKey` for sources whose playable URL rotates between sessions, e.g.
/// the iPad SMB per-file token URLs).
class ResumeStore {
  ResumeStore._();

  static const String _prefix = 'resume_pos_ms_';

  /// Returns the saved playhead for [key]. When [engine] is provided (e.g.
  /// `"media3"` or `"mpv"`), reads the engine-specific key so each engine
  /// keeps its own independent playhead. When [engine] is null, falls back
  /// to the legacy (non-prefixed) key for backward compatibility.
  static Future<Duration?> positionFor(String key, {String? engine}) async {
    if (key.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final storeKey = _prefix + (engine != null ? '$engine:$key' : key);
    final val = prefs.get(storeKey);
    if (val is! num || val <= 0) return null;
    return Duration(milliseconds: val.toInt());
  }

  static Future<void> save(String key, Duration position,
      {String? engine}) async {
    if (key.isEmpty) return;
    final ms = position.inMilliseconds;
    if (ms <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final storeKey = _prefix + (engine != null ? '$engine:$key' : key);
    await prefs.setInt(storeKey, ms);
  }

  static Future<void> clear(String key, {String? engine}) async {
    if (key.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final storeKey = _prefix + (engine != null ? '$engine:$key' : key);
    await prefs.remove(storeKey);
  }
}

/// Persists which playback engine was last used for a given video so the
/// details-screen resume button can highlight the matching engine.
///
/// Values are plain strings (`"media3"` or `"mpv"`) so this store has no
/// dependency on the `PlayEngine` enum defined in player_screen.
class LastEngineStore {
  LastEngineStore._();

  static const String _prefix = 'last_engine_';

  /// Returns `"media3"` or `"mpv"` if the engine was recorded, null otherwise.
  static Future<String?> load(String key) async {
    if (key.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final val = prefs.getString(_prefix + key);
    if (val == null || val.isEmpty) return null;
    return val;
  }

  static Future<void> save(String key, String engine) async {
    if (key.isEmpty || engine.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefix + key, engine);
  }

  static Future<void> clear(String key) async {
    if (key.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefix + key);
  }
}
