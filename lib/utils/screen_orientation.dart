import 'package:flutter/services.dart';

/// The orientation request the player's fullscreen toggle makes (issue #45).
///
/// **Why one orientation per direction, not a list of two.** Flutter packs the
/// requested orientations into a bitmask and hands the result to
/// `Activity.setRequestedOrientation()`. The mapping is in the engine at
/// `shell/platform/android/io/flutter/embedding/engine/systemchannels/
/// PlatformChannel.java` (`decodeOrientations`):
///
/// | Dart list                       | bitmask | Android constant                |
/// |---------------------------------|---------|---------------------------------|
/// | `[landscapeLeft, landscapeRight]` | `0x0a` | `SCREEN_ORIENTATION_USER_LANDSCAPE` |
/// | `[portraitUp, portraitDown]`       | `0x05` | `SCREEN_ORIENTATION_USER_PORTRAIT`   |
/// | `DeviceOrientation.values` (all 4) | `0x0f` | `SCREEN_ORIENTATION_FULL_USER`       |
/// | `[landscapeLeft]`                  | `0x02` | `SCREEN_ORIENTATION_LANDSCAPE`       |
/// | `[portraitUp]`                     | `0x01` | `SCREEN_ORIENTATION_PORTRAIT`        |
///
/// Asking for *both* orientations (or all four) lands on a `USER*` constant.
/// AOSP's `DisplayRotation.rotationForOrientation` only consults the sensor for
/// the `USER*` family while `mUserRotationMode == USER_ROTATION_FREE`:
///
/// ```java
/// } else if (((mUserRotationMode == WindowManagerPolicy.USER_ROTATION_FREE
///     || isTabletopAutoRotateOverrideEnabled())
///     && (orientation == SCREEN_ORIENTATION_USER
///         || orientation == SCREEN_ORIENTATION_UNSPECIFIED
///         || orientation == SCREEN_ORIENTATION_USER_LANDSCAPE
///         || orientation == SCREEN_ORIENTATION_USER_PORTRAIT
///         || orientation == SCREEN_ORIENTATION_FULL_USER))
///     || orientation == SCREEN_ORIENTATION_SENSOR
///     || orientation == SCREEN_ORIENTATION_FULL_SENSOR
///     || orientation == SCREEN_ORIENTATION_SENSOR_LANDSCAPE
///     || orientation == SCREEN_ORIENTATION_SENSOR_PORTRAIT) {
/// ```
///
/// So with rotation **locked** — the default on many phones — the request is
/// overridden by the lock and the screen does not move. `LANDSCAPE` and
/// `PORTRAIT` are deliberately absent from that sensor list and are exempted in
/// the lock branch below it, so they always rotate.
///
/// The old toggle requested `[landscapeLeft, landscapeRight]` to enter and
/// `DeviceOrientation.values` to leave, i.e. `USER_LANDSCAPE` then `FULL_USER`:
/// **both halves silently did nothing** for those users, which is what issue
/// #45 reported ("tapping it does absolutely nothing"). Requesting the single
/// forced constant in each direction fixes it.
///
/// Android still picks *which* of the two landscape rotations to use from the
/// sensor, so this does not hard-code landscape-left.
List<DeviceOrientation> fullscreenOrientations({required bool enter}) {
  return enter
      ? const <DeviceOrientation>[DeviceOrientation.landscapeLeft]
      : const <DeviceOrientation>[DeviceOrientation.portraitUp];
}