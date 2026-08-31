import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user's chosen audio track index per video, so resume restores
/// the same audio language/codec the user was listening to last time.
///
/// Keyed by `resumeKey` + engine (Media3 uses flat track index, MPV uses
/// track id string). The player saves on every user pick and reads on open.
class AudioTrackStore {
  AudioTrackStore._();

  static const _kPrefix = 'audio_track_';

  /// Save the selected audio track for a video.
  /// [trackIndex] is the flat index for Media3, or the track id string for MPV.
  static Future<void> save(
    String resumeKey, {
    required String engine,
    required dynamic trackIndex,
  }) async {
    if (resumeKey.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final key = '$_kPrefix${engine}_$resumeKey';
    if (trackIndex is int) {
      await p.setInt(key, trackIndex);
    } else if (trackIndex is String) {
      await p.setString(key, trackIndex);
    }
  }

  /// Load the saved audio track index for a video.
  /// Returns an [int] (Media3 flat index) or [String] (MPV track id), or null
  /// if nothing was saved.
  static Future<dynamic> load(
    String resumeKey, {
    required String engine,
  }) async {
    if (resumeKey.isEmpty) return null;
    final p = await SharedPreferences.getInstance();
    final key = '$_kPrefix${engine}_$resumeKey';
    // Try int first (Media3), then String (MPV).
    if (p.containsKey(key)) {
      return p.getInt(key) ?? p.getString(key);
    }
    return null;
  }

  /// Clear the saved audio track for a video (e.g. on "Watch from beginning").
  static Future<void> clear(
    String resumeKey, {
    required String engine,
  }) async {
    if (resumeKey.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.remove('$_kPrefix${engine}_$resumeKey');
  }
}
