import 'package:shared_preferences/shared_preferences.dart';

/// Hardware SDR tone-mapping (GitHub issue #55).
///
/// When enabled, the native video codec is asked to output standard SDR
/// (`MediaFormat.KEY_COLOR_TRANSFER_REQUEST = COLOR_TRANSFER_SDR_VIDEO`)
/// instead of the source's HDR/Dolby-Vision signal. A supporting codec
/// (Qualcomm's `c2.qti.dv.decoder`) tone-maps in hardware, which means the
/// system's display colour modes (OxygenOS Vivid/Natural, white balance)
/// apply to the video again and Dolby Vision Profile 5 no longer renders
/// green/purple.
///
/// The trade-off is deliberate and the reason this is OFF by default: the
/// picture leaves the HDR path, so the panel no longer receives real Dolby
/// Vision / HDR10. It is a per-user preference, not a quality upgrade.
///
/// The preference is stored through shared_preferences, so on Android it
/// lands in `FlutterSharedPreferences` under
/// `flutter.dreamplayer.hwSdrToneMap` - the key the native side reads live
/// (the codec is created per open, so a change applies to the next video).
class HwSdrToneMapStore {
  HwSdrToneMapStore._();

  static const String prefsKey = 'dreamplayer.hwSdrToneMap';

  static Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefsKey) ?? false;
  }

  static Future<void> save(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, enabled);
  }
}
