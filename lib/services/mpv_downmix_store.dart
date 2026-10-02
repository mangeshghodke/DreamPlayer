import 'package:shared_preferences/shared_preferences.dart';

/// Whether the libmpv engine scales down audio when it downmixes surround to
/// stereo (`--audio-normalize-downmix`).
///
/// mpv's default is **off**, and its manual is explicit about why that matters:
/// "If this is disabled, downmix can cause clipping. If it's enabled, the output
/// might be too silent." mpv's own maintainer moved to `no` because "people
/// complained about the downmix being too quiet" — which is exactly issue #37,
/// where the MPV engine was noticeably quieter than Media3 for the same file.
///
/// Normalisation only applies when mpv performs the downmix itself (via
/// `lavrresample`), so this bites hardest on phone speakers and Bluetooth
/// earbuds; on an HDMI TV the receiver downmixes and the setting has no effect.
///
/// Off by default so the two Android engines match. Turn it on if you hear
/// clipping/distortion on the downmix and would rather trade that for a lower,
/// safer level.
class MpvDownmixStore {
  MpvDownmixStore._();

  static const String _prefsKey = 'dreamplayer.mpvNormalizeDownmix';

  /// `false` matches mpv's default and Media3's un-normalised downmix.
  static Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsKey) ?? false;
  }

  static Future<void> save(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, enabled);
  }
}
