/// Pure volume maths for the MPV engine's gain staging.
///
/// MPV applies boost and night mode by scaling its single `volume` property
/// (there is no separate gain stage we can leave alone — see
/// `ExoPlayerView.applyAudioEffects`, which uses a real `LoudnessEnhancer`).
/// That makes the multiplier load-bearing: **every** writer of mpv's volume has
/// to apply it, not just the boost slider.
///
/// It was the swipe gesture that didn't (#41). It wrote the raw system volume
/// straight through:
///
/// ```dart
/// _mpvPlayer?.setVolume(next * 100);   // 0..100 — wipes a 3x boost
/// ```
///
/// so the moment the user dragged volume the boost vanished and the audio went
/// quiet again. The reporter described this precisely: "changing the volume
/// through the swipe gesture overrides/resets the MPV volume boost".
///
/// [mpvVolumePercent] is the single place that decides the number, so the swipe
/// gesture, the boost slider, night mode and the per-open apply can't drift
/// apart again.
///
/// [nightMultiplier] approximates the +400 mB Night Mode lift that Media3 gets
/// from `LoudnessEnhancer`, which mpv has no equivalent of.
const double kMpvNightMultiplier = 1.6;

/// Ceiling for mpv's `volume`. Fixed rather than tracking the current value:
/// mpv clamps `volume` to `volume-max`, so a ceiling that moved with the boost
/// would silently clamp the volume gesture whenever it pushed past the last
/// boosted value. 400 matches `_applyMpvVolume`'s own clamp.
const double kMpvVolumeMax = 400.0;

/// The mpv `volume` value for a [baseFraction] system volume (0..1) with
/// [_audioBoost] and [nightMode] applied.
double mpvVolumePercent({
  required double baseFraction,
  required double audioBoost,
  required bool nightMode,
}) {
  var vol = baseFraction * 100.0;
  if (audioBoost > 1.01) vol *= audioBoost;
  if (nightMode) vol *= kMpvNightMultiplier;
  if (vol < 0) vol = 0;
  return vol > kMpvVolumeMax ? kMpvVolumeMax : vol;
}
