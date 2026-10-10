import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _deviceChannel = MethodChannel('dreamplayer/device');

/// Native Android TV / Fire TV detection result, cached after first resolve.
/// `null` until [initTvMode] completes (falls back to the width heuristic).
bool? _nativeTv;

/// Starts the native TV detection on Android. Best-effort: on failure the
/// width heuristic in [isTvMode] keeps working.
Future<void> initTvMode() async {
  if (defaultTargetPlatform != TargetPlatform.android) {
    _nativeTv = false;
    return;
  }
  try {
    final result = await _deviceChannel.invokeMethod<bool>('isTv');
    _nativeTv = result ?? false;
  } catch (_) {
    // `dreamplayer/device` missing (non-Android): keep `_nativeTv` null and let
    // the width heuristic in [isTvMode] decide.
  }
}

/// Whether the app is running on an Android TV / Fire TV device.
///
/// Prefers the native check (Android TV ui mode, leanback/Fire TV feature
/// flags — mirrors Just Player's `isTvBox()`), falling back to the screen
/// width heuristic (960dp+ landscape) until [initTvMode] resolves and on
/// non-Android platforms.
bool isTvMode(BuildContext context) {
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  if (_nativeTv != null) return _nativeTv!;
  return _wideScreen();
}

bool _wideScreen() {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  return view.physicalSize.width / view.devicePixelRatio >= 960;
}

/// SharedPreferences key for the audio passthrough toggle.
const kAudioPassthroughKey = 'dreamplayer.audioPassthrough';

/// Whether audio passthrough is enabled (Android only).
///
/// When enabled AND an HDMI output is detected, ExoPlayer routes
/// compressed surround formats (AC3, E-AC3, DTS, DTS-HD, TrueHD)
/// through AudioTrack passthrough mode — the encoded bitstream goes
/// to the TV / soundbar / AVR for decoding.
Future<bool> isAudioPassthroughEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kAudioPassthroughKey) ?? false;
}

/// SharedPreferences key for the swipe-gestures toggle.
const kSwipeGesturesKey = 'dreamplayer.swipeGestures';

/// Whether vertical swipe gestures (brightness/volume) are enabled in the
/// player. Default true (on for phones/tablets, never fires on TV).
Future<bool> areSwipeGesturesEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kSwipeGesturesKey) ?? true;
}

/// SharedPreferences key for the picture-in-picture auto-entry toggle.
const kPipEnabledKey = 'dreamplayer.pipEnabled';

/// SharedPreferences key for "Match MPV audio (FFmpeg)" (issue #41).
///
/// Read natively by `PlayerCodecs.ffmpegAudioEnabled()` via the
/// `flutter.`-prefixed mirror of this key, so a change takes effect on the next
/// `open()` without recreating the player view.
const kFfmpegAudioKey = 'dreamplayer.ffmpegAudio';

/// Whether leaving the app while a video plays auto-enters picture-in-
/// picture. Default true. Only the automatic HOME/recents entry respects
/// this — the player ⋮-sheet row is an explicit user action and always
/// enters.
Future<bool> isPipEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kPipEnabledKey) ?? true;
}
