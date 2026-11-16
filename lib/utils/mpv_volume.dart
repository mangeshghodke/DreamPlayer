// Volume model shared by the Media3 and MPV engines, and by the swipe
// gesture that drives them.
//
// ## Why boost is a gesture band and not a slider
//
// Boost is the 100-200% half of the volume gesture. The user swipes up to
// 100% as usual, keeps going, and past 100% the extra travel becomes
// over-amplification instead of system volume. It is gated behind
// Settings -> Audio -> Volume boost, because silently amplifying past 100%
// is not something to opt everyone into.
//
// ## Why the boost is staged differently per engine
//
// Media3 applies the gain to the decoded PCM inside the audio sink, followed
// by a peak limiter (`BoostLimiterProcessor`, issue #41). It used to attach
// `LoudnessEnhancer`/`DynamicsProcessing` effects instead; `LoudnessEnhancer` is
// hard-wired for STEREO in AOSP and dropped the centre channel of a 5.1 mix
// (the dialogue), and `DynamicsProcessing` is a vendor HAL effect that the
// reporter's OnePlus Pad 2 cannot create at all.
//
// MPV has no comparable hardware effect. Its gain therefore rides on mpv's own
// `volume` property, which is the one placement known to actually reach the
// speaker - a filter-based gain is discarded on an `audiotrack` output
// (measured on-device: `af` reads back empty). The limiter is still attached
// best-effort so a working build gets smoothing, but MPV must never *depend*
// on the filter for the boost to exist.
//
// `mpvVolumePercent` is the single place that decides the number, so the swipe
// gesture, night mode and the per-open apply cannot drift apart (#41: they
// once did, and the reporter described it as "boost works until I touch
// volume").

/// Ceiling of the gesture's boost band. 100-200% maps to 1.0x-2.0x.
const double kMaxVolumeBoost = 2.0;

/// Gesture ceiling when boost is switched off: plain system volume, 0-100%.
const double kMaxVolumeNoBoost = 1.0;

/// Ceiling for mpv's `volume`. Fixed rather than tracking the current value:
/// mpv clamps `volume` to `volume-max`, so a ceiling that moved with the boost
/// would silently clamp the volume gesture the moment it pushed past the last
/// boosted value.
const double kMpvVolumeMax = 400.0;

/// Extra lift for Night Mode, approximating the +4 dB the native engine gets
/// from its own DynamicsProcessing stage.
const double kMpvNightMultiplier = 1.6;

/// The mpv `volume` property for a [baseFraction] system volume (0..1) with
/// [boost] and [nightMode] applied.
double mpvVolumePercent({
  required double baseFraction,
  required double boost,
  required bool nightMode,
}) {
  var vol = baseFraction * 100.0;
  if (boost > 1.01) vol *= boost;
  if (nightMode) vol *= kMpvNightMultiplier;
  if (vol < 0) vol = 0;
  return vol > kMpvVolumeMax ? kMpvVolumeMax : vol;
}

/// MPV has NO peak limiter, and cannot be given one.
///
/// This is a measured, closed conclusion - five forms were tried against a real
/// device and every one failed, two of them SILENTLY:
///
/// | Form | Result |
/// |---|---|
/// | `lavfi='[alimiter=…]'` | `af` reads back EMPTY. Rejected, no error. |
/// | `lavfi-graph=alimiter=…` | `option af: lavfi-graph isn't supported` |
/// | `lavfi=graph=alimiter:a=1:b=2` | sub-options split on `:` |
/// | `lavfi=alimiter=limit=0.891` | `Error while parsing lavfi parameter alimiter (limit)` |
/// | `lavfi=alimiter` (bare) | accepted, but all defaults ⇒ `limit=1`, no limiting |
///
/// The last row is the decisive one. mpv parses everything after `lavfi=` as
/// **sub-option name=value pairs**, so a value may be a single token with no
/// `=` in it. `lavfi=anull` works for exactly that reason - one bare token,
/// which mpv maps onto the filter's `graph` sub-option. Any attempt to pass
/// filter *options* turns the filter name into a sub-option name, and the
/// whole `af` set is rejected - sometimes without a word of it.
///
/// So MPV's boost rides on `volume` alone (see [mpvVolumePercent]) and will
/// CLIP at high settings rather than limit. That is a known, accepted limit,
/// not an oversight. The engine that gets a proper peak limiter is the native
/// one, via `BoostLimiterProcessor` in the audio sink, which is where boost is
/// used by default. Adding a limiter to MPV would need a different
/// filter-delivery mechanism - a Lua script or a custom libmpv - not another
/// `af` string.
/// Do not add an `af` write to `_applyMpvVolume` without re-running the probe
/// in that file first.

/// The two values a volume gesture has to push: the system volume and the
/// engine make-up.
///
/// They are deliberately separate because the OS volume is capped at 100%
/// while the boost is not, so the gesture's single 0-200% value has to be
/// split rather than multiplied. Splitting (not multiplying) is also what
/// makes "swipe to 100%, keep going for boost" behave: below 100% you are
/// changing the system volume, above it the system volume simply stays pinned
/// at max and the extra travel becomes boost.
class VolumeSplit {
  const VolumeSplit(this.system, this.boost);

  /// 0..1, pushed to the OS so the system volume UI tracks the gesture.
  final double system;

  /// 1.0..[kMaxVolumeBoost], pushed to the engine as make-up gain.
  final double boost;

  @override
  bool operator ==(Object other) =>
      other is VolumeSplit && other.system == system && other.boost == boost;

  @override
  int get hashCode => Object.hash(system, boost);

  @override
  String toString() => 'VolumeSplit(system: ${system.toStringAsFixed(3)}, '
      'boost: ${boost.toStringAsFixed(3)})';
}

/// Where a NEW volume gesture starts from, given the live system volume and
/// the boost the user last left applied.
///
/// The gesture is one continuous 0-200% range, but the level lives in a
/// different place depending on which side of 100% it is, so the base has to
/// follow it:
///
///   * boost above 1.0 - the system volume is pinned at max and [boost] is
///     what holds the level, so the base is [boost].
///   * boost at 1.0 - the boost is not in play at all and the system volume IS
///     the level, so the base is [systemVolume].
///
/// Two wrong versions of this shipped first, both from trying to be clever:
/// reading only [boost] made every gesture start at 100%, and taking
/// `max(systemVolume, boost)` did the same thing from the other side -
/// `max(0.3, 1.0)` is `1.0`, so any volume below 100% snapped upward. The
/// lesson is that this is a question with a conditional answer, not a max.
double volumeGestureBase({
  required double systemVolume,
  required double boost,
  required bool boostEnabled,
}) {
  if (!boostEnabled) return systemVolume.clamp(0.0, kMaxVolumeNoBoost);
  return boost > 1.0 ? boost.clamp(0.0, kMaxVolumeBoost)
                     : systemVolume.clamp(0.0, kMaxVolumeNoBoost);
}

/// Splits a gesture value in 0..[volumeCeiling] into system volume + boost.
///
/// When [boostEnabled] is false the gesture is clamped to 100% and the boost
/// is pinned at 1.0, so switching the setting off restores the stock volume
/// behaviour exactly.
VolumeSplit splitVolume(double level, {required bool boostEnabled}) {
  if (!boostEnabled) {
    return VolumeSplit(level.clamp(0.0, kMaxVolumeNoBoost), 1.0);
  }
  if (level <= kMaxVolumeNoBoost) {
    return VolumeSplit(level.clamp(0.0, kMaxVolumeNoBoost), 1.0);
  }
  // Above 100% the system volume is already at max; the rest is boost.
  return VolumeSplit(kMaxVolumeNoBoost, level.clamp(1.0, kMaxVolumeBoost));
}

/// Gesture ceiling: 200% with boost on, 100% with it off.
double volumeCeiling({required bool boostEnabled}) =>
    boostEnabled ? kMaxVolumeBoost : kMaxVolumeNoBoost;

/// The value a NEW swipe gesture starts from, for either axis.
///
/// Volume runs on the 0-200% boosted scale, so its base has to come from
/// [volumeGestureBase]. Brightness is always the raw platform value on 0-1.
///
/// The two must be selected by axis, not applied to both: piping a brightness
/// reading through [volumeGestureBase] returns the *boost* whenever boost is
/// above 1.0, which seeds the gesture at 2.0. Since the brightness axis then
/// clamps `(base + delta)` to 1.0, brightness is pinned at 100% for the whole
/// gesture no matter how far you drag down (issue #41: "when volume boost is
/// set to 200%, brightness is locked at 100%").
double swipeStartBase({
  required bool isVolume,
  required double platformValue,
  required double boost,
  required bool boostEnabled,
}) {
  if (!isVolume) return platformValue.clamp(0.0, kMaxVolumeNoBoost);
  return volumeGestureBase(
    systemVolume: platformValue,
    boost: boost,
    boostEnabled: boostEnabled,
  );
}