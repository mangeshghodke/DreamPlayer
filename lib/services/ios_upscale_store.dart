import 'package:shared_preferences/shared_preferences.dart';

/// iOS-only: request the AetherEngine MetalFX upscale stage (engine #846).
///
/// The engine decides per load whether the stage applies — SDR content whose
/// smaller dimension is <= 1080 (SD / 720p / 1080p), 8-bit 4:2:0, on a
/// MetalFX-capable Apple Silicon device running iOS 26+, with the display
/// larger than the source. 4K and HDR/DV are never upscaled (the native
/// AVPlayer path keeps real HDR passthrough). Default off.
class IosUpscaleStore {
  static const String prefsKey = 'dreamplayer.iosUpscale';

  bool _enabled = false;
  bool _loaded = false;

  bool get enabled => _enabled;

  Future<bool> load() async {
    if (_loaded) return _enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(prefsKey) ?? false;
    } catch (_) {
      _enabled = false;
    }
    _loaded = true;
    return _enabled;
  }

  Future<bool> setEnabled(bool value) async {
    _enabled = value;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey, value);
    } catch (_) {
      // Keep the in-memory value for this session even if persisting failed.
    }
    return _enabled;
  }
}
