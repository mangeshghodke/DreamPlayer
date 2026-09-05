import 'continue_watching.dart';
import 'resume_store.dart';

/// Shared helper that loads resume positions and durations for a list of
/// resume keys so any browse screen can draw progress bars on file tiles.
class ResumeProgressHelper {
  ResumeProgressHelper._();

  /// Loads resume positions (ms) and durations (ms) for the given [keys].
  ///
  /// - Positions are read from [ResumeStore] for both media3 and mpv engines;
  ///   the larger value wins (matches the player UI's "most recent playhead").
  /// - Durations come from [ContinueWatchingStore] (which stores the real file
  ///   duration for every previously-played video).
  static Future<({
    Map<String, int> positions,
    Map<String, int> durations,
  })> load(List<String> keys) async {
    final positions = <String, int>{};
    final durations = <String, int>{};

    // Build duration map from continue-watching store.
    final cwEntries = await ContinueWatchingStore.load();
    for (final cw in cwEntries) {
      final key = ContinueWatchingStore.keyFor(cw.video);
      if (key.isNotEmpty && cw.video.duration.inMilliseconds > 0) {
        durations[key] = cw.video.duration.inMilliseconds;
      }
    }

    // Load resume positions (check both engines, take the most recent).
    for (final key in keys) {
      if (key.isEmpty) continue;
      final posM3 = await ResumeStore.positionFor(key, engine: 'media3');
      final posMpv = await ResumeStore.positionFor(key, engine: 'mpv');
      final pos = posM3 != null && posMpv != null
          ? (posM3 > posMpv ? posM3 : posMpv)
          : posM3 ?? posMpv;
      if (pos != null) {
        positions[key] = pos.inMilliseconds;
      }
    }

    return (positions: positions, durations: durations);
  }

  /// Computes a 0..1 progress value from the maps, or null when no data
  /// is available (no bar should be drawn).
  static double? progressFor(
    String key,
    Map<String, int> positions,
    Map<String, int> durations, {
    int? fallbackDurationMs,
  }) {
    final posMs = positions[key];
    if (posMs == null || posMs <= 0) return null;
    final durMs =
        durations[key] ?? (fallbackDurationMs != null && fallbackDurationMs > 0 ? fallbackDurationMs : null);
    if (durMs == null || durMs <= 0) return null;
    return (posMs / durMs).clamp(0.0, 1.0);
  }
}
