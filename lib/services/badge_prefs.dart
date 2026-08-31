import 'package:shared_preferences/shared_preferences.dart';

/// Which on-screen badge categories the user wants to see during playback.
/// Each category is a checkbox under the "On-screen badges" toggle in
/// Settings → Player. The player reads these to filter the chip row.
class BadgePrefs {
  BadgePrefs._();

  static const _kEnabled = 'badge_enabled';
  static const _kHdr = 'badge_hdr';
  static const _kAudio = 'badge_audio';
  static const _kResolution = 'badge_resolution';
  static const _kVideoCodec = 'badge_video_codec';

  static Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kEnabled) ?? true;

  static Future<bool> hdr() async =>
      (await SharedPreferences.getInstance()).getBool(_kHdr) ?? true;

  static Future<bool> audio() async =>
      (await SharedPreferences.getInstance()).getBool(_kAudio) ?? true;

  static Future<bool> resolution() async =>
      (await SharedPreferences.getInstance()).getBool(_kResolution) ?? false;

  static Future<bool> videoCodec() async =>
      (await SharedPreferences.getInstance()).getBool(_kVideoCodec) ?? false;

  static Future<void> setEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kEnabled, v);

  static Future<void> setHdr(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kHdr, v);

  static Future<void> setAudio(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kAudio, v);

  static Future<void> setResolution(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kResolution, v);

  static Future<void> setVideoCodec(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kVideoCodec, v);

  /// Convenience: returns all five flags in one async call so the player
  /// screen can read them once at init without five separate prefs reads.
  static Future<BadgeFlags> load() async {
    final p = await SharedPreferences.getInstance();
    return BadgeFlags(
      enabled: p.getBool(_kEnabled) ?? true,
      hdr: p.getBool(_kHdr) ?? true,
      audio: p.getBool(_kAudio) ?? true,
      resolution: p.getBool(_kResolution) ?? false,
      videoCodec: p.getBool(_kVideoCodec) ?? false,
    );
  }
}

class BadgeFlags {
  const BadgeFlags({
    required this.enabled,
    required this.hdr,
    required this.audio,
    required this.resolution,
    required this.videoCodec,
  });

  final bool enabled;
  final bool hdr;
  final bool audio;
  final bool resolution;
  final bool videoCodec;
}
