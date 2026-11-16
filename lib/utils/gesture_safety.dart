// Safety warnings for the player's brightness / volume swipe gesture.
//
// The gesture can push the volume past 100% (the boost band) and the
// brightness to the top of its range. Both have a consequence worth one brief
// flash: over-amplification can damage small speakers, and a full-brightness
// panel drains the battery faster.
//
// The trigger is PURE so it can be unit-tested: it only ever sees the previous
// and the next gesture value, never the platform.

/// The warning a gesture step can trigger.
enum GestureSafetyWarning {
  /// Nothing to warn about.
  none,

  /// The volume crossed above 100% into the boost band.
  volumeAboveNormal,

  /// The brightness reached the warning level (80%).
  brightnessHigh,
}

/// The gesture value where the volume leaves the system-volume range.
const double kVolumeNormalCeiling = 1.0;

/// The brightness level from which the battery warning fires (80%).
const double kBrightnessWarningLevel = 0.8;

/// Which safety warning (if any) a gesture step triggers.
///
/// [previous] and [next] are the gesture values before and after the step:
/// 0-2 for volume (100% + boost) and 0-1 for brightness.
///
/// Volume only warns ABOVE 100%, because that is the boost band - with the
/// setting off the gesture is clamped to 100% and never reaches it. The
/// comparison is strict, so a gesture that tops out exactly at 100% (the
/// system maximum, no boost) stays silent.
///
/// Brightness warns from [kBrightnessWarningLevel] (80%) upwards, because a
/// bright panel is what drains the battery - there is no "boost band" to
/// cross, just a level the user should know about. The comparison is
/// inclusive there: reaching exactly 80% already counts.
GestureSafetyWarning gestureSafetyWarning({
  required bool isVolume,
  required double previous,
  required double next,
}) {
  if (isVolume) {
    if (previous <= kVolumeNormalCeiling && next > kVolumeNormalCeiling) {
      return GestureSafetyWarning.volumeAboveNormal;
    }
    return GestureSafetyWarning.none;
  }
  if (previous < kBrightnessWarningLevel &&
      next >= kBrightnessWarningLevel) {
    return GestureSafetyWarning.brightnessHigh;
  }
  return GestureSafetyWarning.none;
}
