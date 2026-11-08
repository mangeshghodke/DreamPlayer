import 'package:shared_preferences/shared_preferences.dart';

/// "Downmix to stereo": fold 5.1/7.1 audio tracks into 2.0 so dialogue (the
/// centre channel) stays loud on stereo headphones and speakers.
///
/// The pref key is read natively as `flutter.dreamplayer.audioDownmix`
/// (shared_preferences prefixes its keys with `flutter.` on both Android's
/// FlutterSharedPreferences file and iOS UserDefaults), which is how the
/// native side learns the preference without a channel round trip.
///
/// NOT paywall-gated on iOS, unlike the DSP trio (spatial/night/bass):
/// downmix is about the audio channel count, and most 5.1/7.1 content is
/// ordinary SDR that free users can already play — gating it would lock a
/// basic stereo-listening fix behind the paywall. So no entitlement
/// correction is applied here either; the saved value is used as-is.
class AudioDownmixStore {
  AudioDownmixStore._();

  static const String prefsKey = 'dreamplayer.audioDownmix';

  /// `false` = play the track's native channel layout (Media3 default, mpv
  /// `audio-channels=auto`).
  static Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefsKey) ?? false;
  }

  static Future<void> save(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, enabled);
  }

  /// The saved value, uncorrected — the setting is free on every platform.
  static Future<bool> effectiveEnabled() async => load();
}
