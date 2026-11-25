import 'package:shared_preferences/shared_preferences.dart';

/// Settings → Audio → "Transcode audio to AC3 (Dolby Digital)" (issue #70).
///
/// For receivers/home theatres that only support plain Dolby Digital over
/// HDMI: any audio that is not already AC3 is decoded and re-encoded to AC3
/// (Android Media3 path; see Ac3TranscodeSink + libac3enc). Android-only -
/// hidden on iOS where the engine has no transcode path.
class AudioTranscodeStore {
  AudioTranscodeStore._();

  static const String prefsKey = 'dreamplayer.audioTranscodeAc3';

  static Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefsKey) ?? false;
  }

  static Future<void> save(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, enabled);
  }
}
